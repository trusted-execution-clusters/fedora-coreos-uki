ARG BASE=quay.io/fedora/fedora-coreos:stable
ARG KBC_IMG=quay.io/trusted-execution-clusters/trustee-attester:fedora-b13fd8a
ARG CLEVIS_PIN_IMG=quay.io/trusted-execution-clusters/clevis-pin-trustee
ARG IGNITION_IMG=ghcr.io/trusted-execution-clusters/ignition:20260112-85608d6

FROM quay.io/fedora/fedora:43 as fedora
RUN dnf install -y systemd

FROM $KBC_IMG as kbc
FROM $CLEVIS_PIN_IMG as clevis
FROM $IGNITION_IMG as ignition

FROM $BASE as rootfs

ARG ID=overridden
ARG VERSION=overridden
ARG DESCRIPTION=overridden
ARG STREAM=overridden
ARG NAME=overridden

COPY --from=kbc /usr/local/bin/trustee-attester /usr/bin/trustee-attester
COPY --from=clevis /usr/bin/clevis-pin-trustee /usr/bin/clevis-pin-trustee
COPY --from=clevis /usr/bin/clevis-encrypt-trustee /usr/bin/clevis-encrypt-trustee
COPY --from=clevis /usr/bin/clevis-decrypt-trustee /usr/bin/clevis-decrypt-trustee
COPY --from=ignition /usr/bin/ignition /usr/lib/dracut/modules.d/30ignition/ignition

COPY extra-coreos /

COPY --from=fedora /usr/lib/systemd/system-generators/systemd-gpt-auto-generator /usr/lib/systemd/system-generators/systemd-gpt-auto-generator
COPY --from=fedora /usr/lib64/systemd/libsystemd-shared-*.so /usr/lib64/systemd/

RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=tmpfs,target=/var \
    <<EORUN
set -euo pipefail
set -x

# We don't want openh264
rm -f "/etc/yum.repos.d/fedora-cisco-openh264.repo"

# Install fsverity utils to make it easier to check things
# Install systemd-boot (will be replaced by the signed version later)
dnf install -y fsverity-utils systemd-boot-unsigned

# Remove rpm-ostree
dnf remove -y rpm-ostree

# Remove Discover's rpm-ostree backend
dnf remove -y plasma-discover-rpm-ostree

# Install latest bootc release
# https://bodhi.fedoraproject.org/updates/FEDORA-2026-cfa95147df
# dnf upgrade -y --enablerepo=updates-testing --refresh --advisory=FEDORA-2026-56ec3c4a6a

# Install bootc from rpm
curl https://www.rpmfind.net/linux/fedora/linux/development/rawhide/Everything/x86_64/os/Packages/b/bootc-1.15.0-1.fc45.x86_64.rpm \
    --output bootc.rpm
dnf install -y bootc.rpm
rm -f bootc.rpm

cp /usr/lib/bootc/initramfs-setup /usr/lib/dracut/modules.d/37coreos-root-setup/bootc-initramfs-setup

# Uninstall bootupd (no support for systemd-boot yet)
rpm -e bootupd
rm -vrf "/usr/lib/bootupd/updates"

cat > "/usr/lib/bootc/kargs.d/10-rootfs-kargs.toml" << 'EOF'
# Mount the root filesystem read-write
# Add console
kargs = ["rw", "console=ttyS0,115000n"]
EOF

# Default to ext4
cat > "/usr/lib/bootc/install/80-rootfs.toml" << 'EOF'
[install.filesystem.root]
type = "ext4"
EOF

# Dracut will always fail to set security.selinux xattrs at build time
# https://github.com/dracut-ng/dracut-ng/issues/1561
cat > "/usr/lib/dracut/dracut.conf.d/20-bootc-base.conf" << 'EOF'
export DRACUT_NO_XATTR=1
EOF

# Don't include bootc module as it conflicts with coreos-root-setup
# cat > "/usr/lib/dracut/dracut.conf.d/20-bootc-composefs.conf" << 'EOF'
# add_dracutmodules+=" bootc "
# EOF

# Rebuild the initramfs to get bootc-initramfs-setup
kver=$(cd "/usr/lib/modules" && echo *)
dracut -vf --install "/etc/passwd /etc/group" "/usr/lib/modules/$kver/initramfs.img" "$kver"

# Enable sshd for bcvk
systemctl enable sshd.service

# Disable root password for development
passwd -d root

# Prepare folders in /boot
mkdir -p /boot/EFI/Linux
EORUN

# COPY /systemd-bootx64.efi /usr/lib/systemd/boot/efi/systemd-bootx64.efi

FROM rootfs as lint
RUN bootc container lint

# Use more layers (128)
# Ignore legacy ostree folders
FROM quay.io/coreos/chunkah AS chunkah
RUN --mount=from=rootfs,src=/,target=/chunkah,ro \
    --mount=type=bind,target=/run/src,rw \
        chunkah build \
            --max-layers 128 \
            --prune /ostree \
            --prune /sysroot/ostree \
            > /run/src/out.ociarchive

FROM oci-archive:out.ociarchive as rootfs-clean
LABEL containers.bootc 1
LABEL ostree.bootable 1
LABEL org.opencontainers.image.title="Fedora UKI"
# LABEL org.opencontainers.image.source="https://github.com/travier/fedora-kinoite"
LABEL org.opencontainers.image.licenses="MIT"
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

FROM rootfs as sealed-uki
RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=bind,from=rootfs-clean,src=/,target=/run/target \
    --mount=type=secret,id=secureboot_key \
    --mount=type=secret,id=secureboot_cert <<EORUN
set -euo pipefail
set -x

# We don't want openh264
rm -f "/etc/yum.repos.d/fedora-cisco-openh264.repo"

# Install ukify & signing tools
dnf install -y systemd-ukify sbsigntools
dnf clean all

target="/run/target"
output="/boot/EFI/Linux"
secrets="/run/secrets"

mkdir -p /boot/EFI/Linux

# Find the kernel version (needed for output filename)
kver=$(bootc container inspect --rootfs "${target}" --json | jq -r '.kernel.version')
if [ -z "$kver" ] || [ "$kver" = "null" ]; then
  echo "Error: No kernel found" >&2
  exit 1
fi

# Baseline ukify options
ukifyargs=(--measure
           --json pretty
           --output "${output}/${kver}.efi")

# Signing options, we use sbsign by default
# ukifyargs+=(--signtool sbsign
#             --secureboot-private-key "${secrets}/secureboot_key"
#             --secureboot-certificate "${secrets}/secureboot_cert")

# Baseline container ukify options
containerukifyargs=(--rootfs "${target}")

# Build the UKI using bootc container ukify
# This computes the composefs digest, reads kargs from kargs.d, and invokes ukify
bootc container ukify "${containerukifyargs[@]}" "${missing_verity[@]}" -- "${ukifyargs[@]}"

addon_path="${output}/${kver}.efi.extra.d"
mkdir -p "$addon_path"

ukify build \
    --cmdline "ignition.firstboot ignition.platform.id=qemu" \
    --output "$addon_path/ignition.addon.efi"
EORUN

FROM rootfs-clean as final
COPY --from=sealed-uki /boot/EFI/Linux /boot/EFI/Linux
