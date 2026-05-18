#!/bin/bash
set -uo pipefail

source /root/recovery_dom/nvr.conf
source /root/recovery_dom/partinfo.env

info()  { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
check() {
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31m[FAIL]\033[0m $1"
        read -p "Continue anyway? (yes/no): " ans
        [ "$ans" = "yes" ] || exit 1
    fi
}

# ── Log ──
LOGFILE="/tmp/configure.log"
exec > >(tee -a "$LOGFILE") 2>&1

# ── Timezone ──
info "Setting timezone: ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc --utc

# ── Locale ──
info "Setting locale..."
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^#ko_KR.UTF-8 UTF-8/ko_KR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
check "locale-gen failed"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
export LANG=en_US.UTF-8

# ── Hostname ──
echo "${HOSTNAME}" > /etc/hostname

# ── Users ──
info "Setting up users..."
echo "root:${ROOT_PASS}" | chpasswd
check "root password set failed"
useradd -m -g users -G wheel -s /bin/bash "${USER_NAME}"
check "user creation failed"
echo "${USER_NAME}:${USER_PASS}" | chpasswd

# ── Sudoers ──
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── Install GRUB and dependencies ──
info "Installing GRUB..."
pacman -S --noconfirm grub efibootmgr intel-ucode
check "GRUB install failed"

# ── Read UUIDs ──
BOOT_A_UUID=$(blkid -s UUID -o value "$PART_BOOT_A")
BOOT_B_UUID=$(blkid -s UUID -o value "$PART_BOOT_B")
ROOT_A_UUID=$(blkid -s UUID -o value "$PART_ROOT_A")
ROOT_B_UUID=$(blkid -s UUID -o value "$PART_ROOT_B")
ROOT_C_UUID=$(blkid -s UUID -o value "$PART_ROOT_C")
ROOT_D_UUID=$(blkid -s UUID -o value "$PART_ROOT_D")
SWAP_UUID=$(blkid -s UUID -o value "$PART_SWAP")

info "UUIDs:"
info "  BOOT_A: $BOOT_A_UUID"
info "  BOOT_B: $BOOT_B_UUID"
info "  ROOT_A: $ROOT_A_UUID"
info "  ROOT_B: $ROOT_B_UUID"
info "  ROOT_C: $ROOT_C_UUID"
info "  ROOT_D: $ROOT_D_UUID"

# ── Generate early.cfg ──
info "Generating early.cfg..."
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

# ── Build custom GRUB binary ──
info "Building GRUB binary with embedded early.cfg..."
info "grub-mkimage version: $(grub-mkimage --version 2>&1 || true)"
info "Module dir contents: $(ls /usr/lib/grub/x86_64-efi/*.mod 2>&1 | wc -l) modules"
info "early.cfg contents:"
cat /tmp/early.cfg

grub-mkimage \
    --directory=/usr/lib/grub/x86_64-efi \
    --config=/tmp/early.cfg \
    --output=/tmp/grubx64.efi \
    --format=x86_64-efi \
    --prefix=/grub \
    part_gpt ext2 fat normal search search_fs_uuid configfile loadenv linux echo test
check "grub-mkimage failed"

# ── Install GRUB binary to EFI_A ──
info "Installing GRUB binary to EFI_A..."
mkdir -p /boot/efi/EFI/BOOT
cp /tmp/grubx64.efi /boot/efi/EFI/BOOT/BOOTx64.EFI
check "GRUB binary copy failed"

# ── Generate grub.cfg ──
info "Generating grub.cfg..."
mkdir -p /boot/grub
cat > /boot/grub/grub.cfg <<'GRUBEOF'
set boot_try=A
set boot_ok=0
set retry_round=0
load_env -f /grub/grubenv

if [ "$boot_ok" != "1" ] ; then
    if [ "$boot_try" = "A" ] ; then
        set boot_try=B
    elif [ "$boot_try" = "B" ] ; then
        set boot_try=C
    elif [ "$boot_try" = "C" ] ; then
        set boot_try=D
    elif [ "$boot_try" = "D" ] ; then
        if [ "$retry_round" = "0" ] ; then
            set retry_round=1
            set boot_try=A
        else
            set boot_try=HALT
        fi
    fi
fi

set boot_ok=0
save_env -f /grub/grubenv boot_try boot_ok retry_round

GRUBEOF

cat >> /boot/grub/grub.cfg <<EOF
if [ "\$boot_try" = "A" ] ; then
    set root_uuid=${ROOT_A_UUID}
elif [ "\$boot_try" = "B" ] ; then
    set root_uuid=${ROOT_B_UUID}
elif [ "\$boot_try" = "C" ] ; then
    set root_uuid=${ROOT_C_UUID}
elif [ "\$boot_try" = "D" ] ; then
    set root_uuid=${ROOT_D_UUID}
elif [ "\$boot_try" = "HALT" ] ; then
    echo "ALL SLOTS FAILED - SYSTEM HALTED"
    echo "Replace DOM or boot from USB"
    sleep 999999
fi

linux /vmlinuz-linux root=UUID=\$root_uuid rw panic=10 systemd.setenv=SYSTEMD_SECCOMP=0 fsck.repair=yes
initrd /intel-ucode.img /initramfs-linux.img
boot
EOF

# ── Initialize grubenv ──
info "Initializing grubenv..."
grub-editenv /boot/grub/grubenv create
grub-editenv /boot/grub/grubenv set boot_try=A boot_ok=1 retry_round=0

# ── Register UEFI boot entries ──
info "Registering UEFI boot entries..."
efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Recovery DOM (primary)" --loader '\EFI\BOOT\BOOTx64.EFI' 2>/dev/null || true
efibootmgr --create --disk "$TARGET_DISK" --part 2 --label "Recovery DOM (backup)" --loader '\EFI\BOOT\BOOTx64.EFI' 2>/dev/null || true

# ── Regenerate initramfs ──
info "Regenerating initramfs..."
[ -f /etc/vconsole.conf ] || echo "KEYMAP=us" > /etc/vconsole.conf
# autodetect 는 install 시점 로드된 블록 드라이버만 포함하므로,
# 마스터 이미지를 다른 버스 타입(NVMe↔SATA) DOM 에 dd 클론하면
# initramfs 가 새 디스크를 못 찾아 부팅 실패함. 양쪽 다 명시 포함.
sed -i 's|^MODULES=.*|MODULES=(nvme nvme_core ahci sd_mod)|' /etc/mkinitcpio.conf
mkinitcpio -P
check "mkinitcpio failed"

# ── Network (systemd-networkd) ──
info "Setting up network..."
cat > /etc/systemd/network/20-wired.network <<NETEOF
[Match]
Name=en*

[Network]
DHCP=yes
DNS=${DNS1}
DNS=${DNS2}

[DHCPv4]
UseDNS=no
NETEOF
systemctl enable systemd-networkd

# ── DNS ──
cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF

# ── Watchdog configuration ──
info "Configuring watchdog..."
mkdir -p /etc/sysctl.d
echo "kernel.panic = 10" > /etc/sysctl.d/99-panic.conf

# systemd watchdog — 설치 중에는 비활성화 (Phase 3 완료 후 활성화)
# nowayout 특성: 한번 /dev/watchdog을 열면 끌 수 없으므로
# 설치가 완전히 끝나기 전에 활성화하면 안 됨
sed -i 's/^#RuntimeWatchdogSec=.*/RuntimeWatchdogSec=0/' /etc/systemd/system.conf
sed -i 's/^#RebootWatchdogSec=.*/RebootWatchdogSec=30/' /etc/systemd/system.conf

# ── systemd generator sandbox 호환성 (seccomp Protocol error 방지) ──
mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/no-sandbox.conf <<'SBOXEOF'
[Manager]
ManagerEnvironment=SYSTEMD_SECCOMP=0
SBOXEOF
info "systemd seccomp disabled via ManagerEnvironment"

# ── Generate slot-uuids.conf ──
info "Generating slot-uuids.conf..."
mkdir -p /etc/recovery
cat > /etc/recovery/slot-uuids.conf <<EOF
# Recovery DOM Slot UUIDs (auto-generated)
ROOT_A_UUID=${ROOT_A_UUID}
ROOT_B_UUID=${ROOT_B_UUID}
ROOT_C_UUID=${ROOT_C_UUID}
ROOT_D_UUID=${ROOT_D_UUID}
BOOT_A_UUID=${BOOT_A_UUID}
BOOT_B_UUID=${BOOT_B_UUID}
EOF

# ── Create recovery state directory ──
mkdir -p /var/lib/recovery

# ── Recovery DOM 식별 마커 ──
# DNVR 등 상위 컴포넌트가 atomic 업그레이드 적용 여부를 결정하는 신호.
# 적용 조건: TTA_CERTIFICATION 빌드 OR 이 마커 존재 (recovery DOM).
# 현장 일반 DOM 에는 이 파일이 없으므로 atomic 업그레이드를 적용하지 않고
# 기존 single-mount 레이아웃을 유지해야 함.
touch /etc/recovery/is_recovery_dom

# ── Install failover scripts ──
info "Installing failover scripts..."
cp /root/recovery_dom/scripts/failover-preboot.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/failover-success.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/sync-root.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/upgrade-sync-d.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/check-smart.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/switch-slot.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/mark-installed.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/enter-maintenance.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/exit-maintenance.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/sync-all-slots.sh /usr/local/sbin/
cp /root/recovery_dom/scripts/sync-config.sh /usr/local/sbin/
chmod 755 /usr/local/sbin/failover-preboot.sh
chmod 755 /usr/local/sbin/failover-success.sh
chmod 755 /usr/local/sbin/sync-root.sh
chmod 755 /usr/local/sbin/upgrade-sync-d.sh
chmod 755 /usr/local/sbin/check-smart.sh
chmod 755 /usr/local/sbin/switch-slot.sh
chmod 755 /usr/local/sbin/mark-installed.sh
chmod 755 /usr/local/sbin/enter-maintenance.sh
chmod 755 /usr/local/sbin/exit-maintenance.sh
chmod 755 /usr/local/sbin/sync-all-slots.sh
chmod 755 /usr/local/sbin/sync-config.sh

# ── Install systemd services ──
info "Installing systemd services..."
cp /root/recovery_dom/config/failover-prepare.service /etc/systemd/system/
cp /root/recovery_dom/config/failover-success.service /etc/systemd/system/
cp /root/recovery_dom/config/sync-root-b.service /etc/systemd/system/
cp /root/recovery_dom/config/sync-root-b.timer /etc/systemd/system/
cp /root/recovery_dom/config/sync-root-c.service /etc/systemd/system/
cp /root/recovery_dom/config/sync-root-c.timer /etc/systemd/system/
cp /root/recovery_dom/config/check-smart.service /etc/systemd/system/
cp /root/recovery_dom/config/check-smart.timer /etc/systemd/system/

# ── Enable failover services ──
systemctl enable failover-prepare.service
systemctl enable failover-success.service
systemctl enable sync-root-b.timer
systemctl enable sync-root-c.timer
systemctl enable check-smart.timer

# ── Register Phase 2 auto-run service ──
info "Registering Phase 2 service..."
cp /root/recovery_dom/config/nvr-setup.service /etc/systemd/system/
systemctl enable nvr-setup.service

# ── Initialize failover log ──
touch /var/log/failover.log

# ── Cleanup ──
rm -f /tmp/early.cfg /tmp/grubx64.efi

# partinfo.env 는 install 1회용. 잔존 시 dd 클론된 다른 타입(NVMe↔SATA)
# DOM에서 누군가 configure.sh를 재실행하면 마스터의 디바이스 경로로
# GRUB을 재빌드해 부팅 불능이 됨 → 흔적 자체를 남기지 않는다.
rm -f /root/recovery_dom/partinfo.env

info "configure.sh done"
