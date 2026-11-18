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
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT/sys" 2>/dev/null || true
  sudo umount "$MNT/run" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"
sudo mkdir -p "$MNT/boot"
sudo mount "${LOOP}p1" "$MNT/boot"

sudo rsync -aHAX --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' "$ROOTFS_DIR/" "$MNT/"
install_common_image_assets "$MNT" "$GAOKUN_DIR"

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

# Services
systemctl enable \
  NetworkManager.service \
  bluetooth.service \
  sshd.service \
  patch-nvm-bdaddr.service \
  systemd-timesyncd.service \
  systemd-resolved.service

# mkinitcpio ─────────────────────────────────────────────────────────────────
cat > /etc/mkinitcpio.conf <<'EOF'
MODULES=(nvme ext4 usb_storage uas sd_mod scsi_mod xhci_hcd xhci_pci xhci_plat_hcd dwc3 dwc3_qcom phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 pci-pwrctrl-pwrseq ath11k_pci i2c-hid-of typec)
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
BOOT_EFI="/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
if [ ! -f "$BOOT_EFI" ]; then
  echo "systemd-boot EFI binary not found: $BOOT_EFI" >&2
  exit 1
fi
bootctl --no-variables --esp-path=/boot install

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
options root=UUID=$ROOT_UUID rw rootwait clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
EOF

CHROOT_EOF

sync

trap - EXIT
cleanup
