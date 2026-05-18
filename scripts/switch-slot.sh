#!/bin/bash
# 수동 슬롯 전환 — 다음 재부팅 시 지정 슬롯으로 부팅
# 사용법: switch-slot.sh [A|B|C|D]

set -uo pipefail

SLOT="${1:-}"

if [[ ! "$SLOT" =~ ^[ABCD]$ ]]; then
    echo "사용법: switch-slot.sh [A|B|C|D]"
    echo "  다음 재부팅 시 지정 슬롯으로 부팅합니다."
    exit 1
fi

# /boot 마운트 (noauto이므로 수동 마운트 필요)
mount /boot 2>/dev/null || mount "$(grep '/boot' /etc/fstab | awk '{print $1}' | head -1)" /boot

# boot_ok=1 필수 — GRUB 의 advance 로직이 boot_ok != 1 시 다음 슬롯으로 자동 전진하므로,
# 사용자가 지정한 슬롯으로 정확히 부팅되게 하려면 boot_ok=1 로 명시 (advance 우회).
# 부팅 후 GRUB 가 boot_ok=0 으로 리셋하므로 한 번만 보호됨 (다음 reboot 부터는 정상 페일오버 로직).
grub-editenv /boot/grub/grubenv set boot_try="$SLOT" boot_ok=1 retry_round=0 boot_attempts=0

umount /boot

echo "$(date '+%Y-%m-%d %H:%M:%S') manual switch to slot $SLOT" >> /var/log/failover.log
echo "다음 재부팅 시 slot $SLOT 로 부팅됩니다."
