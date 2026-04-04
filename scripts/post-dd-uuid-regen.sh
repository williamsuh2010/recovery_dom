#!/bin/bash
# dd 후 UUID 재생성 + GRUB 재빌드
# 출고 공정에서 마스터 이미지를 dd로 복제한 후 1회 실행
# 모든 파티션의 UUID를 재생성하고 grub.cfg, fstab, early.cfg, slot-uuids.conf를 갱신

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

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

# ── Partition names ──
if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
    P="${TARGET_DISK}p"
else
    P="${TARGET_DISK}"
fi

PART_EFI_A="${P}1"
PART_EFI_B="${P}2"
PART_BOOT_A="${P}3"
PART_BOOT_B="${P}4"
# PART5 = swap (UUID 재생성 불필요)
PART_ROOT_A="${P}6"
PART_ROOT_B="${P}7"
PART_ROOT_C="${P}8"
PART_ROOT_D="${P}9"

# ── Confirmation ──
echo ""
warn "WARNING: UUID regeneration for all partitions on ${TARGET_DISK}"
echo "  EFI_A:  ${PART_EFI_A}"
echo "  EFI_B:  ${PART_EFI_B}"
echo "  boot_A: ${PART_BOOT_A}"
echo "  boot_B: ${PART_BOOT_B}"
echo "  root_A: ${PART_ROOT_A}"
echo "  root_B: ${PART_ROOT_B}"
echo "  root_C: ${PART_ROOT_C}"
echo "  root_D: ${PART_ROOT_D}"
echo ""
read -p "Continue? (yes/no): " confirm
[ "$confirm" = "yes" ] || { echo "Cancelled."; exit 0; }

# ── Regenerate ext4 UUIDs ──
info "Regenerating ext4 UUIDs..."
tune2fs -U random "$PART_BOOT_A"
tune2fs -U random "$PART_BOOT_B"
tune2fs -U random "$PART_ROOT_A"
tune2fs -U random "$PART_ROOT_B"
tune2fs -U random "$PART_ROOT_C"
tune2fs -U random "$PART_ROOT_D"

# ── Regenerate FAT32 UUIDs (reformat EFI partitions) ──
info "Regenerating EFI partition UUIDs..."
# EFI_A: 마운트 → 내용 백업 → 포맷 → 복원
mkdir -p /tmp/efi_backup
mount "$PART_EFI_A" /tmp/efi_backup_mnt 2>/dev/null || { mkdir -p /tmp/efi_backup_mnt; mount "$PART_EFI_A" /tmp/efi_backup_mnt; }
cp -a /tmp/efi_backup_mnt/* /tmp/efi_backup/
umount /tmp/efi_backup_mnt
mkfs.fat -F 32 "$PART_EFI_A"
mount "$PART_EFI_A" /tmp/efi_backup_mnt
cp -a /tmp/efi_backup/* /tmp/efi_backup_mnt/
umount /tmp/efi_backup_mnt
rm -rf /tmp/efi_backup /tmp/efi_backup_mnt

# EFI_B: 동일 처리
mkdir -p /tmp/efi_backup /tmp/efi_backup_mnt
mount "$PART_EFI_B" /tmp/efi_backup_mnt
cp -a /tmp/efi_backup_mnt/* /tmp/efi_backup/
umount /tmp/efi_backup_mnt
mkfs.fat -F 32 "$PART_EFI_B"
mount "$PART_EFI_B" /tmp/efi_backup_mnt
cp -a /tmp/efi_backup/* /tmp/efi_backup_mnt/
umount /tmp/efi_backup_mnt
rm -rf /tmp/efi_backup /tmp/efi_backup_mnt

# ── Read new UUIDs ──
info "Reading new UUIDs..."
BOOT_A_UUID=$(blkid -s UUID -o value "$PART_BOOT_A")
BOOT_B_UUID=$(blkid -s UUID -o value "$PART_BOOT_B")
ROOT_A_UUID=$(blkid -s UUID -o value "$PART_ROOT_A")
ROOT_B_UUID=$(blkid -s UUID -o value "$PART_ROOT_B")
ROOT_C_UUID=$(blkid -s UUID -o value "$PART_ROOT_C")
ROOT_D_UUID=$(blkid -s UUID -o value "$PART_ROOT_D")
EFI_A_UUID=$(blkid -s UUID -o value "$PART_EFI_A")
SWAP_UUID=$(blkid -s UUID -o value "${P}5")

info "  BOOT_A: $BOOT_A_UUID"
info "  BOOT_B: $BOOT_B_UUID"
info "  ROOT_A: $ROOT_A_UUID"
info "  ROOT_B: $ROOT_B_UUID"
info "  ROOT_C: $ROOT_C_UUID"
info "  ROOT_D: $ROOT_D_UUID"

# ── Rebuild GRUB binary with new early.cfg ──
info "Rebuilding GRUB binary..."
cat > /tmp/early.cfg <<EOF
search --fs-uuid ${BOOT_A_UUID} --set=root
if [ -f /grub/grub.cfg ]; then
    configfile /grub/grub.cfg
else
    search --fs-uuid ${BOOT_B_UUID} --set=root
    if [ -f /grub/grub.cfg ]; then
        configfile /grub/grub.cfg
    else
        echo "boot_A and boot_B both failed"
    fi
fi
EOF

grub-mkimage -d /usr/lib/grub/x86_64-efi -c /tmp/early.cfg \
    -o /tmp/grubx64.efi -O x86_64-efi \
    part_gpt ext2 fat normal search search_fs_uuid configfile loadenv linux echo

# ── Install GRUB binary to both EFI partitions ──
info "Installing GRUB binary..."
mkdir -p /tmp/efi_mnt
mount "$PART_EFI_A" /tmp/efi_mnt
mkdir -p /tmp/efi_mnt/EFI/BOOT
cp /tmp/grubx64.efi /tmp/efi_mnt/EFI/BOOT/BOOTx64.EFI
umount /tmp/efi_mnt

mount "$PART_EFI_B" /tmp/efi_mnt
mkdir -p /tmp/efi_mnt/EFI/BOOT
cp /tmp/grubx64.efi /tmp/efi_mnt/EFI/BOOT/BOOTx64.EFI
umount /tmp/efi_mnt

# ── Generate new grub.cfg ──
info "Generating grub.cfg..."
cat > /tmp/grub.cfg <<'GRUBEOF'
load_env

if [ -z "${boot_try}" ]; then
    set boot_try=A
fi
if [ -z "${boot_ok}" ]; then
    set boot_ok=0
fi
if [ -z "${retry_round}" ]; then
    set retry_round=0
fi

if [ "${boot_ok}" != "1" ]; then
    if [ "${boot_try}" = "A" ]; then set boot_try=B;
    elif [ "${boot_try}" = "B" ]; then set boot_try=C;
    elif [ "${boot_try}" = "C" ]; then set boot_try=D;
    elif [ "${boot_try}" = "D" ]; then
        if [ "${retry_round}" = "0" ]; then
            set retry_round=1
            set boot_try=A
        else
            set boot_try=HALT
        fi
    fi
fi

set boot_ok=0
save_env boot_try boot_ok retry_round

GRUBEOF

# UUID 치환하여 슬롯별 부팅 로직 추가
cat >> /tmp/grub.cfg <<EOF
if [ "\${boot_try}" = "A" ]; then
    set root_uuid=${ROOT_A_UUID}
elif [ "\${boot_try}" = "B" ]; then
    set root_uuid=${ROOT_B_UUID}
elif [ "\${boot_try}" = "C" ]; then
    set root_uuid=${ROOT_C_UUID}
elif [ "\${boot_try}" = "D" ]; then
    set root_uuid=${ROOT_D_UUID}
elif [ "\${boot_try}" = "HALT" ]; then
    echo ""
    echo "============================================"
    echo "  ALL SLOTS FAILED - SYSTEM HALTED"
    echo "  Replace DOM or boot from USB"
    echo "============================================"
    echo ""
    sleep 999999
fi

linux /vmlinuz-linux root=UUID=\${root_uuid} rw panic=10
initrd /intel-ucode.img /initramfs-linux.img
boot
EOF

# ── Install grub.cfg to boot_A and boot_B ──
info "Installing grub.cfg..."
mkdir -p /tmp/boot_mnt

mount "$PART_BOOT_A" /tmp/boot_mnt
mkdir -p /tmp/boot_mnt/grub
cp /tmp/grub.cfg /tmp/boot_mnt/grub/grub.cfg
# Re-initialize grubenv
grub-editenv /tmp/boot_mnt/grub/grubenv create
grub-editenv /tmp/boot_mnt/grub/grubenv set boot_try=A boot_ok=0 retry_round=0
umount /tmp/boot_mnt

mount "$PART_BOOT_B" /tmp/boot_mnt
mkdir -p /tmp/boot_mnt/grub
cp /tmp/grub.cfg /tmp/boot_mnt/grub/grub.cfg
grub-editenv /tmp/boot_mnt/grub/grubenv create
grub-editenv /tmp/boot_mnt/grub/grubenv set boot_try=A boot_ok=0 retry_round=0
umount /tmp/boot_mnt

# ── Update fstab and slot-uuids.conf in all root partitions ──
info "Updating fstab and slot-uuids.conf in all root partitions..."

SLOT_UUIDS_CONTENT="# Recovery DOM Slot UUIDs (auto-generated by post-dd-uuid-regen.sh)
ROOT_A_UUID=${ROOT_A_UUID}
ROOT_B_UUID=${ROOT_B_UUID}
ROOT_C_UUID=${ROOT_C_UUID}
ROOT_D_UUID=${ROOT_D_UUID}
BOOT_A_UUID=${BOOT_A_UUID}
BOOT_B_UUID=${BOOT_B_UUID}
"

for PART in "$PART_ROOT_A" "$PART_ROOT_B" "$PART_ROOT_C" "$PART_ROOT_D"; do
    ROOT_UUID_THIS=$(blkid -s UUID -o value "$PART")
    mount "$PART" /tmp/boot_mnt

    # fstab 갱신
    cat > /tmp/boot_mnt/etc/fstab <<EOF
# Recovery DOM fstab (auto-generated)
UUID=${ROOT_UUID_THIS}  /       ext4    defaults        0 1
UUID=${SWAP_UUID}       none    swap    defaults        0 0
UUID=${BOOT_A_UUID}     /boot   ext4    noauto,defaults 0 2
EOF

    # slot-uuids.conf 갱신
    mkdir -p /tmp/boot_mnt/etc/recovery
    echo "$SLOT_UUIDS_CONTENT" > /tmp/boot_mnt/etc/recovery/slot-uuids.conf

    umount /tmp/boot_mnt
done

rmdir /tmp/boot_mnt /tmp/efi_mnt 2>/dev/null

# ── Register UEFI boot entries ──
info "Registering UEFI boot entries..."
# 기존 엔트리 삭제 시도 (에러 무시)
for num in $(efibootmgr | grep -i "recovery\|arch\|grub" | grep -oP 'Boot\K[0-9A-F]+'); do
    efibootmgr -b "$num" -B 2>/dev/null || true
done

DISK_NUM=$(echo "$TARGET_DISK" | grep -oP '\d+$')
efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Recovery DOM (primary)" --loader '\EFI\BOOT\BOOTx64.EFI' 2>/dev/null || true
efibootmgr --create --disk "$TARGET_DISK" --part 2 --label "Recovery DOM (backup)" --loader '\EFI\BOOT\BOOTx64.EFI' 2>/dev/null || true

# ── Cleanup ──
rm -f /tmp/early.cfg /tmp/grub.cfg /tmp/grubx64.efi

info "=========================================="
info " UUID regeneration complete!"
info " All partitions have new unique UUIDs."
info " GRUB binary rebuilt and installed."
info " fstab, grub.cfg, slot-uuids.conf updated."
info "=========================================="
