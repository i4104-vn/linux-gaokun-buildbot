#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"

EFI_END_MIB=1025
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
sudo mkfs.vfat -F32 -n ARCH_EFI "${LOOP}p1"
sudo mkfs.ext4 -F -L ARCH_ROOT "${LOOP}p2"

EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

MNT=/mnt/ego-arch
cleanup() {
  set +e
  for m in "$MNT/dev/pts" "$MNT/boot" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT"; do
    if [ -n "$m" ] && mountpoint -q "$m"; then
      sudo umount "$m" 2>/dev/null || sudo umount -l "$m" 2>/dev/null || true
    fi
  done
  [[ -z "${LOOP:-}" ]] || sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"

# Rsync rootfs while /boot is on ext4 (preserves all permissions and attributes)
sudo rsync -aHAX --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' "$ROOTFS_DIR/" "$MNT/"
install_common_image_assets "$MNT" "$GAOKUN_DIR"

# Now mount ESP to /boot so mkinitcpio and bootctl write directly to ESP
sudo mkdir -p "$MNT/boot"
sudo mount "${LOOP}p1" "$MNT/boot"

# Populate ESP with kernel and devicetree
sudo cp "$ROOTFS_DIR/boot/vmlinuz-$KREL" "$MNT/boot/vmlinuz-$KREL"
sudo mkdir -p "$MNT/boot/dtb-$KREL/qcom"
sudo cp "$ROOTFS_DIR/boot/dtb-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb" \
  "$MNT/boot/dtb-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb"

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /      ext4  defaults,noatime  0  1
UUID=${EFI_UUID}   /boot  vfat  defaults,nofail   0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" ROOT_UUID="$ROOT_UUID" /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "gaokun3" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   gaokun3
EOF

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

ln -sfn /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc 2>/dev/null || true

# User setup — keep consistent with Fedora/Ubuntu images.
id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel,audio,video,storage,input user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
# Lock the stock Arch ARM user and root.
usermod -L alarm 2>/dev/null || true
passwd -l root

# DNS — let systemd-resolved manage it at runtime.
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Prevent automated sleep/suspend loops and watchdog bite after boot.
# The Huawei EC reports lid state which triggers logind suspend if not ignored,
# and S3/sleep can cause TrustZone firmware crashes on this platform.
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/00-gaokun3.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandlePowerKey=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/00-disable-sleep.conf <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/00-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=0
RebootWatchdogSec=0
KexecWatchdogSec=0
EOF

# Services
systemctl enable \
  NetworkManager.service \
  bluetooth.service \
  sshd.service \
  patch-nvm-bdaddr.service \
  systemd-timesyncd.service \
  systemd-resolved.service

# mkinitcpio ─────────────────────────────────────────────────────────────────
# All essential storage and bus drivers (NVMe, Ext4, SCSI, DWC3/XHCI) are built-in
# into the gaokun3 kernel binary (=y). Keeping MODULES empty prevents missing-module
# errors for built-in drivers while udev hooks handle all discovered runtime devices.
cat > /etc/mkinitcpio.conf <<'EOF'
MODULES=()
BINARIES=()
FILES=(
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn
)
HOOKS=(base udev modconf block filesystems fsck)
COMPRESSION="zstd"
EOF

depmod -a "$KREL"
mkinitcpio -k "$KREL" -g "/boot/initramfs-$KREL.img"

# systemd-boot ──────────────────────────────────────────────────────────────
bootctl --no-variables --esp-path=/boot install || bootctl --esp-path=/boot install

# Ensure standard UEFI fallback bootloader path exists
mkdir -p /boot/EFI/BOOT
if [ -f /boot/EFI/systemd/systemd-bootaa64.efi ]; then
  cp -f /boot/EFI/systemd/systemd-bootaa64.efi /boot/EFI/BOOT/BOOTAA64.EFI
elif [ -f /usr/lib/systemd/boot/efi/systemd-bootaa64.efi ]; then
  cp -f /usr/lib/systemd/boot/efi/systemd-bootaa64.efi /boot/EFI/BOOT/BOOTAA64.EFI
fi

mkdir -p /boot/loader/entries

cat > /boot/loader/loader.conf <<EOF
default arch-gaokun3.conf
timeout 5
console-mode keep
editor no
EOF

cat > /boot/loader/entries/arch-gaokun3.conf <<EOF
title   Arch Linux ARM - Huawei gaokun3
version $KREL
linux   /vmlinuz-$KREL
initrd  /initramfs-$KREL.img
devicetree /dtb-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb
options root=UUID=$ROOT_UUID rw rootwait clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF

CHROOT_EOF

sync

trap - EXIT
cleanup
