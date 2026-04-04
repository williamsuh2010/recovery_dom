#!/bin/bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
check() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}[FAIL]${NC} $1"
        read -p "Continue anyway? (yes/no): " ans
        [ "$ans" = "yes" ] || exit 1
    fi
}

# ── Log setup ──
LOGFILE="/tmp/phase1.log"
rm -f "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

# ── Load nvr.conf ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
info "SCRIPT_DIR=${SCRIPT_DIR}"
source "${SCRIPT_DIR}/nvr.conf" || error "nvr.conf not found"

# ── Avoid /mnt conflict ──
if [[ "${SCRIPT_DIR}" == /mnt* ]]; then
    warn "Script is under /mnt, copying to /tmp"
    INSTALL_SRC="/tmp/recovery_dom"
    rm -rf "$INSTALL_SRC"
    cp -a "${SCRIPT_DIR}" "$INSTALL_SRC"
    cd /
    info "Unmounting /mnt..."
    umount -l /mnt
else
    INSTALL_SRC="${SCRIPT_DIR}"
fi
info "INSTALL_SRC=${INSTALL_SRC}"

# ── Unmount /mnt if still mounted ──
if mountpoint -q /mnt 2>/dev/null; then
    warn "/mnt is still mounted, unmounting..."
    umount -l /mnt
fi

# ── Check internet ──
info "Checking internet connection..."
ping -c 3 archlinux.org > /dev/null 2>&1 || error "No internet. Check LAN cable."

# ── Sync time ──
timedatectl set-ntp true
sleep 2

# ── Auto-detect target disk ──
detect_disk() {
    local nvme_disks=( $(lsblk -dpno NAME,TYPE | awk '$2=="disk" && /nvme/' | awk '{print $1}') )
    if [ ${#nvme_disks[@]} -gt 0 ]; then
        echo "${nvme_disks[0]}"
        return
    fi
    local boot_disk=""
    boot_disk=$(lsblk -rpno NAME,TYPE,MOUNTPOINT | grep -E "/$|/run/archiso" | awk '{print $1}' | sed 's/p\?[0-9]*$//' | head -1)
    local sata_disks=( $(lsblk -dpno NAME,TYPE | awk '$2=="disk" && /sd/' | awk '{print $1}') )
    for disk in "${sata_disks[@]}"; do
        if [ "$disk" != "$boot_disk" ]; then
            echo "$disk"
            return
        fi
    done
    return 1
}

TARGET_DISK=$(detect_disk) || error "No target disk found"
info "Target disk: ${TARGET_DISK}"

# ── Partition names (NVMe vs SATA) ──
if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
    P="${TARGET_DISK}p"
else
    P="${TARGET_DISK}"
fi

PART_EFI_A="${P}1"
PART_EFI_B="${P}2"
PART_BOOT_A="${P}3"
PART_BOOT_B="${P}4"
PART_SWAP="${P}5"
PART_ROOT_A="${P}6"
PART_ROOT_B="${P}7"
PART_ROOT_C="${P}8"
PART_ROOT_D="${P}9"

# ── Confirmation prompt ──
echo ""
warn "WARNING: ALL data on ${TARGET_DISK} will be erased!"
echo "  Partition Layout (10 partitions):"
echo "    1. EFI_A:  ${PART_EFI_A}  (${EFI_SIZE})"
echo "    2. EFI_B:  ${PART_EFI_B}  (${EFI_SIZE})"
echo "    3. boot_A: ${PART_BOOT_A} (${BOOT_SIZE})"
echo "    4. boot_B: ${PART_BOOT_B} (${BOOT_SIZE})"
echo "    5. swap:   ${PART_SWAP}   (${SWAP_SIZE})"
echo "    6. root_A: ${PART_ROOT_A} (${ROOT_SIZE})"
echo "    7. root_B: ${PART_ROOT_B} (${ROOT_SIZE})"
echo "    8. root_C: ${PART_ROOT_C} (${ROOT_SIZE})"
echo "    9. root_D: ${PART_ROOT_D} (${ROOT_SIZE})"
echo ""
read -p "Continue? (yes/no): " confirm
[ "$confirm" = "yes" ] || { echo "Cancelled."; exit 0; }

# ── Partitioning (sgdisk) — 9 partitions ──
info "Partitioning ${TARGET_DISK}..."
sgdisk -Z "$TARGET_DISK"

sgdisk -n 1:0:+${EFI_SIZE}  -t 1:ef00 "$TARGET_DISK"   # EFI_A
sgdisk -n 2:0:+${EFI_SIZE}  -t 2:ef00 "$TARGET_DISK"   # EFI_B
sgdisk -n 3:0:+${BOOT_SIZE} -t 3:8300 "$TARGET_DISK"   # boot_A
sgdisk -n 4:0:+${BOOT_SIZE} -t 4:8300 "$TARGET_DISK"   # boot_B
sgdisk -n 5:0:+${SWAP_SIZE} -t 5:8200 "$TARGET_DISK"   # swap
sgdisk -n 6:0:+${ROOT_SIZE} -t 6:8300 "$TARGET_DISK"   # root_A
sgdisk -n 7:0:+${ROOT_SIZE} -t 7:8300 "$TARGET_DISK"   # root_B
sgdisk -n 8:0:+${ROOT_SIZE} -t 8:8300 "$TARGET_DISK"   # root_C
sgdisk -n 9:0:+${ROOT_SIZE} -t 9:8300 "$TARGET_DISK"   # root_D

sync
sleep 1
partprobe "$TARGET_DISK"
sleep 1

# ── Format ──
info "Formatting..."
mkfs.fat -F 32 "$PART_EFI_A"
mkfs.fat -F 32 "$PART_EFI_B"
mkfs.ext4 -F "$PART_BOOT_A"
mkfs.ext4 -F "$PART_BOOT_B"
mkswap "$PART_SWAP"
mkfs.ext4 -F "$PART_ROOT_A"
mkfs.ext4 -F "$PART_ROOT_B"
mkfs.ext4 -F "$PART_ROOT_C"
mkfs.ext4 -F "$PART_ROOT_D"
sync

# ── Mount ──
info "Mounting..."
swapon "$PART_SWAP"
mount "$PART_ROOT_A" /mnt
mkdir -p /mnt/boot
mount "$PART_BOOT_A" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$PART_EFI_A" /mnt/boot/efi

# ── Pre-create vconsole.conf ──
mkdir -p /mnt/etc
echo "KEYMAP=us" > /mnt/etc/vconsole.conf

# ── Install base system ──
info "Installing base system... (takes several minutes)"
pacstrap /mnt base base-devel linux linux-firmware vim
check "pacstrap failed"

# ── Generate fstab (UUID-based) ──
info "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab
check "fstab generation failed"

# fstab 수정: boot_A를 noauto로 변경
sed -i '/\/boot[[:space:]]/s/defaults/noauto,defaults/' /mnt/etc/fstab
# fstab에서 EFI 마운트 제거 (GRUB이 직접 관리)
sed -i '/\/boot\/efi/d' /mnt/etc/fstab

# ── Copy recovery_dom to new system ──
info "Copying install files: ${INSTALL_SRC} -> /mnt/root/recovery_dom"
rm -rf /mnt/root/recovery_dom
cp -a "$INSTALL_SRC" /mnt/root/recovery_dom

# ── Verify copy ──
info "=== Verifying copy ==="
ls -la /mnt/root/recovery_dom/ || error "recovery_dom copy failed!"
[ -f /mnt/root/recovery_dom/configure.sh ] || error "configure.sh missing!"
info "=== Verification passed ==="

# ── Store partition info for configure.sh ──
cat > /mnt/root/recovery_dom/partinfo.env <<EOF
TARGET_DISK=${TARGET_DISK}
PART_EFI_A=${PART_EFI_A}
PART_EFI_B=${PART_EFI_B}
PART_BOOT_A=${PART_BOOT_A}
PART_BOOT_B=${PART_BOOT_B}
PART_SWAP=${PART_SWAP}
PART_ROOT_A=${PART_ROOT_A}
PART_ROOT_B=${PART_ROOT_B}
PART_ROOT_C=${PART_ROOT_C}
PART_ROOT_D=${PART_ROOT_D}
EOF

# ── Copy log file to new system ──
cp "$LOGFILE" /mnt/tmp/

# ── Run configure.sh in chroot ──
info "Configuring system (chroot)..."
arch-chroot /mnt /bin/bash /root/recovery_dom/configure.sh
check "configure.sh failed in chroot"

# ── Copy boot_A to boot_B ──
info "Copying boot_A to boot_B..."
mkdir -p /tmp/boot_b_mnt
mount "$PART_BOOT_B" /tmp/boot_b_mnt
rsync -aAX /mnt/boot/ /tmp/boot_b_mnt/
umount /tmp/boot_b_mnt
rmdir /tmp/boot_b_mnt

# ── Copy EFI_A to EFI_B ──
info "Copying EFI_A to EFI_B..."
mkdir -p /tmp/efi_b_mnt
mount "$PART_EFI_B" /tmp/efi_b_mnt
rsync -aAX /mnt/boot/efi/ /tmp/efi_b_mnt/
umount /tmp/efi_b_mnt
rmdir /tmp/efi_b_mnt

# ── Done ──
info "Phase 1 done. Unmounting..."
umount /mnt/boot/efi
umount /mnt/boot
umount -lR /mnt
swapoff "$PART_SWAP"

echo ""
info "==================================="
info " Phase 1 complete!"
info " Remove all USB drives and reboot."
info " Phase 2 will run automatically on first boot."
info "==================================="
echo ""
