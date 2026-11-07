#!/usr/bin/env bash
# Build Arch Linux ARM for Huawei gaokun3 and optionally write it to USB.
# Targets upstream Linux v7.0 plus the legacy gaokun3 patch stack.
# The patches were developed on a newer kernel; this does not guarantee stable
# display or power behavior on v7.0. The script stops on patch or build errors.
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

[[ "$(uname -s)" == Linux ]] || die "Run this script on a Linux build host."
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GAOKUN_DIR="$SCRIPT_DIR"
WORKDIR="${WORKDIR:-$GAOKUN_DIR/build-arch-v7.0}"
KERNEL_TAG="v7.0"
KERNEL_REPOSITORY="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
LEGACY_PATCH_COMMIT="315528c028843794ccd0f3d9dab373b03033150f"
TARGET_USER="i4104"
TARGET_PASSWORD="i4104"
IMAGE_SIZE="${IMAGE_SIZE:-12G}"
IMAGE_FILE="${IMAGE_FILE:-$WORKDIR/archlinuxarm-gaokun3-v7.0.img}"

if (( EUID == 0 )); then
  as_root() { "$@"; }
else
  require_cmd sudo
  as_root() { sudo "$@"; }
fi

for cmd in git make bc bison flex openssl pahole curl bsdtar rsync \
  parted losetup partprobe mkfs.vfat mkfs.ext4 blkid mount umount mountpoint \
  chroot lsblk jq dd numfmt swapon findmnt readlink udevadm; do
  require_cmd "$cmd"
done

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == aarch64 || "$HOST_ARCH" == arm64 ]]; then
  CROSS_COMPILE=""
else
  require_cmd aarch64-linux-gnu-gcc
  require_cmd qemu-aarch64-static
  [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || \
    die "AArch64 binfmt is not registered. Enable qemu-user-static/binfmt support first."
  CROSS_COMPILE="aarch64-linux-gnu-"
fi

[[ ! -e "$WORKDIR" ]] || die "WORKDIR already exists: $WORKDIR. Choose a new WORKDIR."
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"
ROOTFS_DIR="$WORKDIR/rootfs"
KERN_SRC="$WORKDIR/linux-v7.0"
KERN_OUT="$WORKDIR/kernel-out"
ROOTFS_MNT="$WORKDIR/image-root"
ESP_MNT="$ROOTFS_MNT/boot"
IMAGE_FILE="${IMAGE_FILE:-$WORKDIR/archlinuxarm-gaokun3-v7.0.img}"
IMAGE_SIZE_BYTES="$(numfmt --from=iec "$IMAGE_SIZE")"
LOOP_DEV=""
RESOLV_TOUCHED=0
RESOLV_BACKUP="$WORKDIR/resolv.conf.original"

cleanup_resolv() {
  if (( RESOLV_TOUCHED )); then
    as_root rm -f "$ROOTFS_DIR/etc/resolv.conf"
    if [[ -e "$RESOLV_BACKUP" || -L "$RESOLV_BACKUP" ]]; then
      as_root cp -a "$RESOLV_BACKUP" "$ROOTFS_DIR/etc/resolv.conf"
    fi
    RESOLV_TOUCHED=0
  fi
}
cleanup() {
  set +e
  cleanup_resolv
  for mount_path in "$ESP_MNT" "$ROOTFS_MNT" \
    "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/proc" \
    "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run"; do
    if [[ -n "$mount_path" ]] && mountpoint -q "$mount_path"; then
      as_root umount "$mount_path" >/dev/null 2>&1
    fi
  done
  [[ -z "$LOOP_DEV" ]] || as_root losetup -d "$LOOP_DEV" >/dev/null 2>&1
}
trap cleanup EXIT

note "Fetching Linux $KERNEL_TAG"
git clone --depth 1 --branch "$KERNEL_TAG" \
  "$KERNEL_REPOSITORY" "$KERN_SRC"
[[ "$(git -C "$KERN_SRC" describe --tags --exact-match HEAD)" == "$KERNEL_TAG" ]] || \
  die "Kernel source is not exactly $KERNEL_TAG."
git -C "$GAOKUN_DIR" cat-file -e "$LEGACY_PATCH_COMMIT^{commit}" 2>/dev/null || \
  die "Legacy gaokun3 patches are unavailable. Use a full clone of this repository."

PATCH_DIR="$WORKDIR/device-patches"
mkdir -p "$PATCH_DIR"
mapfile -t PATCH_PATHS < <(
  git -C "$GAOKUN_DIR" ls-tree -r --name-only "$LEGACY_PATCH_COMMIT" -- \
    patches/upstream patches/others patches/media | LC_ALL=C sort -V
)
PATCH_PATHS+=("patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch")
((${#PATCH_PATHS[@]} > 1)) || die "No gaokun3 kernel patches were found."
PATCH_FILES=()
for patch_path in "${PATCH_PATHS[@]}"; do
  patch_file="$PATCH_DIR/$(basename "$patch_path")"
  git -C "$GAOKUN_DIR" show "$LEGACY_PATCH_COMMIT:$patch_path" > "$patch_file" || \
    die "Could not extract legacy patch: $patch_path"
  PATCH_FILES+=("$patch_file")
done

note "Applying gaokun3 patches to Linux $KERNEL_TAG"
git -C "$KERN_SRC" -c user.name="gaokun3 local builder" \
  -c user.email="builder@localhost" am --3way "${PATCH_FILES[@]}" || \
  die "The gaokun3 patch stack does not apply cleanly to $KERNEL_TAG."

note "Configuring and compiling the AArch64 kernel"
make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig
"$KERN_SRC/scripts/config" --file "$KERN_OUT/.config" --set-str LOCALVERSION "-gaokun3-arch"
"$KERN_SRC/scripts/config" --file "$KERN_OUT/.config" --enable EFI --enable EFI_STUB
make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  -j"${JOBS:-$(nproc)}" Image modules dtbs
KREL="$(cat "$KERN_OUT/include/config/kernel.release")"
[[ "$KREL" == 7.0* ]] || die "Built kernel release is $KREL, expected Linux 7.0."

note "Preparing the Arch Linux ARM root filesystem"
ROOTFS_TARBALL="$WORKDIR/ArchLinuxARM-aarch64-latest.tar.gz"
curl -fL --retry 3 \
  https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz \
  -o "$ROOTFS_TARBALL"
mkdir -p "$ROOTFS_DIR"
as_root bsdtar -xpf "$ROOTFS_TARBALL" -C "$ROOTFS_DIR"
if [[ "$HOST_ARCH" != aarch64 && "$HOST_ARCH" != arm64 ]]; then
  as_root install -D -m 0755 "$(command -v qemu-aarch64-static)" \
    "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
fi

for path in dev dev/pts proc sys run; do as_root mkdir -p "$ROOTFS_DIR/$path"; done
if [[ -e "$ROOTFS_DIR/etc/resolv.conf" || -L "$ROOTFS_DIR/etc/resolv.conf" ]]; then
  as_root cp -a "$ROOTFS_DIR/etc/resolv.conf" "$RESOLV_BACKUP"
fi
as_root rm -f "$ROOTFS_DIR/etc/resolv.conf"
as_root cp --dereference /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
RESOLV_TOUCHED=1
as_root mount --bind /dev "$ROOTFS_DIR/dev"
as_root mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
as_root mount -t proc proc "$ROOTFS_DIR/proc"
as_root mount -t sysfs sys "$ROOTFS_DIR/sys"
as_root mount -t tmpfs tmpfs "$ROOTFS_DIR/run"

note "Installing Arch ARM desktop and device packages"
as_root chroot "$ROOTFS_DIR" /bin/bash -euc '
  pacman-key --init
  pacman-key --populate archlinuxarm
  pacman -Syu --noconfirm --needed \
    base base-devel sudo systemd systemd-sysvcompat \
    gnome gdm gnome-tweaks \
    networkmanager bluez bluez-utils \
    mesa vulkan-freedreno \
    linux-firmware alsa-ucm-conf alsa-utils pipewire pipewire-alsa wireplumber \
    mkinitcpio dosfstools e2fsprogs openssh
'
cleanup_resolv
for mount_path in "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" \
  "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run"; do
  as_root umount "$mount_path"
done

note "Installing the gaokun3 kernel, firmware, and tools"
as_root make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$ROOTFS_DIR" modules_install
as_root rm -f "$ROOTFS_DIR/lib/modules/$KREL/build" "$ROOTFS_DIR/lib/modules/$KREL/source"
as_root cp "$KERN_OUT/arch/arm64/boot/Image" "$ROOTFS_DIR/boot/vmlinuz-$KREL"
as_root mkdir -p "$ROOTFS_DIR/boot/dtb-$KREL/qcom"
as_root cp "$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" \
  "$ROOTFS_DIR/boot/dtb-$KREL/qcom/"
as_root mkdir -p "$ROOTFS_DIR/usr/lib/firmware"
as_root cp -a "$GAOKUN_DIR/firmware/." "$ROOTFS_DIR/usr/lib/firmware/"
as_root cp -a "$GAOKUN_DIR/tools/image-assets/etc/." "$ROOTFS_DIR/etc/"

as_root install -D -m 0644 "$GAOKUN_DIR/tools/audio/sc8280xp.conf" \
  "$ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/sc8280xp.conf"
as_root install -D -m 0755 "$GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py" \
  "$ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py"
as_root install -D -m 0644 "$GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.service" \
  "$ROOTFS_DIR/etc/systemd/system/patch-nvm-bdaddr.service"
as_root install -D -m 0755 "$GAOKUN_DIR/tools/monitors/gdm-monitor-sync" \
  "$ROOTFS_DIR/usr/local/bin/gdm-monitor-sync"
as_root install -D -m 0644 "$GAOKUN_DIR/tools/monitors/gdm-monitor-sync.service" \
  "$ROOTFS_DIR/etc/systemd/system/gdm-monitor-sync.service"
as_root sed -i 's#/home/user/#/home/i4104/#g' \
  "$ROOTFS_DIR/usr/local/bin/gdm-monitor-sync" \
  "$ROOTFS_DIR/etc/systemd/system/gdm-monitor-sync.service"
as_root install -D -m 0755 "$GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune" \
  "$ROOTFS_DIR/usr/local/bin/touchscreen-tune"
as_root install -D -m 0644 "$GAOKUN_DIR/tools/touchscreen-tuner/tune.py" \
  "$ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner/tune.py"
as_root install -D -m 0644 "$GAOKUN_DIR/tools/touchscreen-tuner/tune-icon.svg" \
  "$ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner/tune-icon.svg"
as_root install -D -m 0644 "$GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune.desktop" \
  "$ROOTFS_DIR/usr/share/applications/touchscreen-tune.desktop"

as_root chroot "$ROOTFS_DIR" /bin/bash -euc '
  useradd -m -G wheel,audio,video,storage,input -s /bin/bash i4104
  printf "%s\n" "LANG=en_US.UTF-8" > /etc/locale.conf
  sed -i "s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
  locale-gen
  ln -sfn /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
  printf "%s\n" "gaokun3-arch" > /etc/hostname
  printf "%s\n" "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
  chmod 0440 /etc/sudoers.d/10-wheel
  passwd -l root
  usermod -L alarm 2>/dev/null || true
  systemctl enable NetworkManager.service bluetooth.service gdm.service \
    patch-nvm-bdaddr.service gdm-monitor-sync.service
'
printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | \
  as_root chroot "$ROOTFS_DIR" chpasswd
as_root install -D -m 0644 \
  "$GAOKUN_DIR/tools/image-assets/usr/local/share/gaokun/monitors.xml" \
  "$ROOTFS_DIR/home/$TARGET_USER/.config/monitors.xml"
as_root chroot "$ROOTFS_DIR" chown -R "$TARGET_USER:$TARGET_USER" \
  "/home/$TARGET_USER"

cat > "$WORKDIR/mkinitcpio.conf" <<'EOF'
MODULES=(nvme ext4 usb_storage uas sd_mod scsi_mod xhci_hcd xhci_pci xhci_plat_hcd dwc3 dwc3_qcom)
BINARIES=()
FILES=(
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn
  /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin
)
HOOKS=(base udev modconf block filesystems fsck)
COMPRESSION="zstd"
EOF
as_root install -m 0644 "$WORKDIR/mkinitcpio.conf" "$ROOTFS_DIR/etc/mkinitcpio.conf"
as_root chroot "$ROOTFS_DIR" /usr/bin/env KREL="$KREL" /bin/bash -euc '
  depmod -a "$KREL"
  mkinitcpio -k "$KREL" -g "/boot/initramfs-$KREL.img"
'

note "Creating the bootable disk image"
ROOTFS_MNT="$WORKDIR/image-root"
ESP_MNT="$ROOTFS_MNT/boot"
mkdir -p "$ROOTFS_MNT"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
as_root parted -s "$IMAGE_FILE" mklabel gpt
as_root parted -s "$IMAGE_FILE" mkpart ESP fat32 1MiB 1025MiB
as_root parted -s "$IMAGE_FILE" set 1 esp on
as_root parted -s "$IMAGE_FILE" mkpart rootfs ext4 1025MiB 100%
LOOP_DEV="$(as_root losetup --show --find --partscan "$IMAGE_FILE")"
as_root partprobe "$LOOP_DEV"
as_root udevadm settle
as_root mkfs.vfat -F32 -n ARCH_EFI "${LOOP_DEV}p1"
as_root mkfs.ext4 -F -L ARCH_ROOT "${LOOP_DEV}p2"
ESP_UUID="$(as_root blkid -s UUID -o value "${LOOP_DEV}p1")"
ROOT_UUID="$(as_root blkid -s UUID -o value "${LOOP_DEV}p2")"

as_root mount "${LOOP_DEV}p2" "$ROOTFS_MNT"
as_root mkdir -p "$ESP_MNT"
as_root mount "${LOOP_DEV}p1" "$ESP_MNT"
as_root rsync -aHAX --numeric-ids \
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/run/* \
  "$ROOTFS_DIR/" "$ROOTFS_MNT/"
printf 'UUID=%s / ext4 defaults,noatime 0 1\nUUID=%s /boot vfat defaults,nofail 0 2\n' \
  "$ROOT_UUID" "$ESP_UUID" | as_root tee "$ROOTFS_MNT/etc/fstab" >/dev/null

BOOTLOADER="$ROOTFS_DIR/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
[[ -f "$BOOTLOADER" ]] || die "Arch ARM systemd-boot ARM64 EFI binary was not found: $BOOTLOADER"
as_root install -D -m 0644 "$BOOTLOADER" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
as_root install -D -m 0644 "$ROOTFS_DIR/boot/vmlinuz-$KREL" "$ESP_MNT/vmlinuz-$KREL.efi"
as_root install -D -m 0644 "$ROOTFS_DIR/boot/initramfs-$KREL.img" "$ESP_MNT/initramfs-$KREL.img"
as_root install -D -m 0644 \
  "$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" \
  "$ESP_MNT/dtbs/qcom/sc8280xp-huawei-gaokun3.dtb"

as_root mkdir -p "$ESP_MNT/loader/entries"
printf 'default arch-gaokun3.conf\ntimeout 5\nconsole-mode keep\neditor no\n' | \
  as_root tee "$ESP_MNT/loader/loader.conf" >/dev/null
printf '%s\n' \
  'title Arch Linux ARM - Huawei gaokun3 - Linux 7.0' \
  "version $KREL" \
  "linux /vmlinuz-$KREL.efi" \
  "initrd /initramfs-$KREL.img" \
  'devicetree /dtbs/qcom/sc8280xp-huawei-gaokun3.dtb' \
  "options root=UUID=$ROOT_UUID rw rootwait clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 consoleblank=0 loglevel=4" | \
  as_root tee "$ESP_MNT/loader/entries/arch-gaokun3.conf" >/dev/null
as_root sync
as_root umount "$ESP_MNT"
as_root umount "$ROOTFS_MNT"
as_root losetup -d "$LOOP_DEV"
LOOP_DEV=""

note "Disk image is ready: $IMAGE_FILE"
printf 'Image size: %s\n' "$(numfmt --to=iec --suffix=B "$IMAGE_SIZE_BYTES")"
printf 'Target user: %s\n' "$TARGET_USER"
printf 'Kernel: %s\n' "$KREL"

while true; do
  mapfile -t USB_ROWS < <(
    lsblk --json --bytes --nodeps --output PATH,MODEL,SIZE,TRAN,TYPE |
      jq -r --argjson min "$IMAGE_SIZE_BYTES" \
        '.blockdevices[] | select(.type == "disk" and .tran == "usb" and .size >= $min) |
         [.path, (.model // "USB disk"), (.size | tostring)] | @tsv'
  )
  if ((${#USB_ROWS[@]} == 0)); then
    read -r -p "No large enough USB disk found. Connect one and press Enter to refresh, or Ctrl+C to keep the image only: " _
    continue
  fi
  printf '\nUSB disks large enough for this image:\n'
  for index in "${!USB_ROWS[@]}"; do
    IFS=$'\t' read -r USB_PATH USB_MODEL USB_BYTES <<<"${USB_ROWS[$index]}"
    printf '  %d) %s - %s - %s\n' \
      "$((index + 1))" "$USB_PATH" "$USB_MODEL" \
      "$(numfmt --to=iec --suffix=B "$USB_BYTES")"
  done
  read -r -p "Select a USB number to create the boot drive: " USB_CHOICE
  [[ "$USB_CHOICE" =~ ^[0-9]+$ ]] || { printf 'Enter a number from the list.\n'; continue; }
  USB_INDEX="$((USB_CHOICE - 1))"
  (( USB_INDEX >= 0 && USB_INDEX < ${#USB_ROWS[@]} )) || { printf 'Selection is out of range.\n'; continue; }
  IFS=$'\t' read -r USB_PATH USB_MODEL USB_BYTES <<<"${USB_ROWS[$USB_INDEX]}"

  ROOT_SOURCE="$(findmnt -nro SOURCE -T / 2>/dev/null || true)"
  WORK_SOURCE="$(findmnt -nro SOURCE -T "$WORKDIR" 2>/dev/null || true)"
  for protected_source in "$ROOT_SOURCE" "$WORK_SOURCE"; do
    [[ -n "$protected_source" ]] || continue
    protected_source="$(readlink -f "$protected_source" 2>/dev/null || printf '%s' "$protected_source")"
    if lsblk -sno PATH "$protected_source" 2>/dev/null | grep -Fxq "$USB_PATH"; then
      die "Refusing to overwrite a USB disk containing the running system or build files: $USB_PATH"
    fi
  done
  for swap_path in $(swapon --noheadings --raw --output NAME); do
    if lsblk -sno PATH "$swap_path" 2>/dev/null | grep -Fxq "$USB_PATH"; then
      die "The selected USB disk is active as swap: $USB_PATH"
    fi
  done
  if lsblk -nrpo MOUNTPOINT "$USB_PATH" | awk 'NF { found=1 } END { exit !found }'; then
    die "The selected USB disk has mounted partitions. Unmount them and run the USB step again."
  fi

  printf '\nThis will erase all data on %s (%s, %s).\n' "$USB_PATH" "$USB_MODEL" \
    "$(numfmt --to=iec --suffix=B "$USB_BYTES")"
  read -r -p "Type 'ERASE $USB_PATH' to continue: " ERASE_CONFIRM
  [[ "$ERASE_CONFIRM" == "ERASE $USB_PATH" ]] || die "USB writing cancelled."

  note "Writing the boot image to $USB_PATH"
  as_root dd if="$IMAGE_FILE" of="$USB_PATH" bs=16M status=progress conv=fsync
  as_root partprobe "$USB_PATH" || true
  as_root sync
  printf '\nBootable USB created successfully: %s (%s)\n' "$USB_PATH" "$USB_MODEL"
  break
done
