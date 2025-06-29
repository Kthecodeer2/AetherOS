#!/usr/bin/env bash
# Build AetherOS: Custom Ubuntu 25.04 (Oracular Oriole) spin focused on lightweight desktop and full Windows app compatibility.
#
# This script requires being run on an Ubuntu 25.04 (or newer) build host **with sudo privileges**.
# It automates:
#  1. Creating a minimal Ubuntu root filesystem using debootstrap
#  2. Installing a curated package set (see packages-include.txt / packages-exclude.txt)
#  3. Performing cleanup & optimisations (remove snaps, docs, localisation, etc.)
#  4. Integrating Wine, DXVK, and related components for Windows binaries
#  5. Generating a bootable hybrid ISO image capable of UEFI & BIOS boot
#
# USAGE:
#   sudo ./scripts/build_os.sh /path/to/workdir
# The resulting ISO will be written to $WORKDIR/aetheros-$(date +%Y%m%d).iso
set -euo pipefail

#-------------------------
# Configuration constants
#-------------------------
RELEASE="PluckyPuffin"          # Ubuntu 25.04 code-name
ARCH="amd64"
MIRROR="http://archive.ubuntu.com/ubuntu/"
PROFILE_NAME="aetheros"
WORKDIR="${1:-$HOME/${PROFILE_NAME}-build}"
CHROOT_DIR="$WORKDIR/chroot"
IMAGE_DIR="$WORKDIR/image"
ISO_NAME="$WORKDIR/${PROFILE_NAME}-$(date +%Y%m%d).iso"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_INCLUDE_FILE="$SCRIPT_DIR/packages-include.txt"
PKG_EXCLUDE_FILE="$SCRIPT_DIR/packages-exclude.txt"

#-------------------------
# Helpers
#-------------------------
log() { echo -e "\e[1;34m[INFO]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*"; exit 1; }

require_binary() {
  command -v "$1" &>/dev/null || err "$1 is required but not installed."
}

#-------------------------
# Prerequisite checks
#-------------------------
for bin in debootstrap xorriso squashfs-tools grub-mkstandalone mksquashfs; do
  require_binary $bin
done

if [[ $EUID -ne 0 ]]; then
  err "Run this script with sudo (it needs root)."
fi

#-------------------------
# Step 1 – Create base system via debootstrap
#-------------------------
log "=== Stage 1: Creating base system in $CHROOT_DIR ==="
mkdir -p "$CHROOT_DIR"

# Use --variant=minbase for lightweight rootfs
if [[ ! -f "$CHROOT_DIR/.debootstrap_debcompleted" ]]; then
  debootstrap --arch=$ARCH --variant=minbase $RELEASE "$CHROOT_DIR" "$MIRROR"
  touch "$CHROOT_DIR/.debootstrap_debcompleted"
fi

#-------------------------
# Step 2 – Bind mounts for chroot
#-------------------------
log "Setting up bind mounts..."
mount --bind /dev  "$CHROOT_DIR/dev"
mount --bind /run  "$CHROOT_DIR/run"
mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /sys  "$CHROOT_DIR/sys"

# Ensure DNS works inside chroot
cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

#-------------------------
# Step 3 – Chroot provisioning function
#-------------------------
cat > "$CHROOT_DIR/tmp/chroot-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Update apt sources & basic system upgrade
apt-get update
apt-get -y dist-upgrade

# Install core packages as per include list
xargs -a /packages-include.txt apt-get install -y --no-install-recommends

# Remove unwanted packages from exclude list if present
if [[ -f /packages-exclude.txt ]]; then
  xargs -a /packages-exclude.txt apt-get purge -y || true
fi

# Purge snapd and snaps to reduce bloat
apt-get purge -y snapd || true
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd

# Clean up APT caches & locales to trim size
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

# Configure systemd default target
systemctl set-default graphical.target

exit 0
EOF
chmod +x "$CHROOT_DIR/tmp/chroot-setup.sh"

# Copy package lists into chroot
install -Dm644 "$PKG_INCLUDE_FILE" "$CHROOT_DIR/packages-include.txt"
install -Dm644 "$PKG_EXCLUDE_FILE" "$CHROOT_DIR/packages-exclude.txt"

log "=== Stage 2: Provisioning inside chroot ==="
chroot "$CHROOT_DIR" /tmp/chroot-setup.sh

#-------------------------
# Step 4 – Create SquashFS image for casper live system
#-------------------------
log "=== Stage 3: Building SquashFS ==="
mkdir -p "$IMAGE_DIR/casper"

mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/casper/filesystem.squashfs" -b 1048576 -comp zstd -Xcompression-level 19 -e boot

# Save filesystem size for installer UI
printf "$(du -sx --block-size=1 "$CHROOT_DIR" | cut -f1)" > "$IMAGE_DIR/casper/filesystem.size"

#-------------------------
# Step 5 – Bootloader setup (GRUB for BIOS & UEFI)
#-------------------------
log "=== Stage 4: GRUB setup ==="
mkdir -p "$IMAGE_DIR/boot/grub"

# Create grub.cfg
cat > "$IMAGE_DIR/boot/grub/grub.cfg" <<'EOF'
search --set=root --file /AETHEROS
set default="0"
set timeout=5

menuentry "Boot AetherOS (live)" {
    linux /casper/vmlinuz boot=casper quiet splash --
    initrd /casper/initrd
}
EOF

# Create dummy marker file for grub search
touch "$IMAGE_DIR/AETHEROS"

# Generate standalone GRUB EFI and BIOS images
mkdir -p "$WORKDIR/bootloader"

grub-mkstandalone -O x86_64-efi -o "$WORKDIR/bootloader/bootx64.efi" \
    "boot/grub/grub.cfg=$IMAGE_DIR/boot/grub/grub.cfg"

grub-mkstandalone -O i386-pc -o "$WORKDIR/bootloader/core.img" \
    "boot/grub/grub.cfg=$IMAGE_DIR/boot/grub/grub.cfg"
cat /usr/lib/grub/i386-pc/cdboot.img "$WORKDIR/bootloader/core.img" > "$WORKDIR/bootloader/bios.img"

# Place EFI files into ISO tree
dir="EFI/boot"
mkdir -p "$IMAGE_DIR/$dir"
cp "$WORKDIR/bootloader/bootx64.efi" "$IMAGE_DIR/$dir/bootx64.efi"

#-------------------------
# Step 6 – Copy kernel & initrd from chroot
#-------------------------
log "Copying kernel & initrd"
KERNEL_VER=$(ls "$CHROOT_DIR/boot" | grep -E '^vmlinuz-' | head -n1 | sed 's/vmlinuz-//')
cp "$CHROOT_DIR/boot/vmlinuz-$KERNEL_VER" "$IMAGE_DIR/casper/vmlinuz"
cp "$CHROOT_DIR/boot/initrd.img-$KERNEL_VER" "$IMAGE_DIR/casper/initrd"

#-------------------------
# Step 7 – Generate ISO
#-------------------------
log "=== Stage 5: Generating ISO at $ISO_NAME ==="
xorriso -as mkisofs \
  -iso-level 3 -J -joliet-long -full-iso9660-filenames \
  -volid "AETHEROS" \
  -output "$ISO_NAME" \
  -eltorito-boot boot/grub/bios.img -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e EFI/boot/bootx64.efi -no-emul-boot \
  -append_partition 2 0xef EFI/boot/bootx64.efi \
  -isohybrid-gpt-basdat \
  "$IMAGE_DIR"

log "ISO successfully created at $ISO_NAME"

#-------------------------
# Cleanup mounts
#-------------------------
umount -lf "$CHROOT_DIR/dev" || true
umount -lf "$CHROOT_DIR/run" || true
umount -lf "$CHROOT_DIR/proc" || true
umount -lf "$CHROOT_DIR/sys" || true

log "Done." 