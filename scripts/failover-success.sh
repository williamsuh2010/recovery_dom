#!/bin/bash
# Health check + boot_ok 마킹
# failover-success.service에 의해 실행 (10분 sleep 후)
# 1. DNVR PID 확인
# 2. 10분 대기 후 같은 PID 생존 확인
# 3. 성공 시 boot_ok=1 기록
# 4. D 슬롯 동기화 플래그 확인

set -uo pipefail

FAILOVER_LOG="/var/log/failover.log"
HEALTH_CHECK_PID_WAIT=600
MAINTENANCE_FLAG="/etc/recovery/maintenance_mode"
MAX_MAINTENANCE_HOURS=24

mark_boot_ok_and_sync_d() {
    mount /boot 2>/dev/null || mount "$(grep '/boot' /etc/fstab | awk '{print $1}' | head -1)" /boot
    grub-editenv /boot/grub/grubenv set boot_ok=1 retry_round=0
    umount /boot
    /usr/local/sbin/upgrade-sync-d.sh
}

# Maintenance mode: 관리자가 enter-maintenance.sh 로 명시한 작업 윈도우.
# DNVR PID 검사 건너뛰고 boot_ok=1 즉시 마킹 (24h 자동 만료).
if [ -f "$MAINTENANCE_FLAG" ]; then
    flag_ts=$(head -1 "$MAINTENANCE_FLAG" 2>/dev/null)
    if [[ "$flag_ts" =~ ^[0-9]+$ ]]; then
        age=$(( $(date +%s) - flag_ts ))
        if [ $age -lt $((MAX_MAINTENANCE_HOURS * 3600)) ]; then
            reason=$(sed -n '2p' "$MAINTENANCE_FLAG" 2>/dev/null)
            echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance mode active (age=$((age/60))min, reason=[${reason}]) — marking boot_ok=1, skipping DNVR check" >> "$FAILOVER_LOG"
            mark_boot_ok_and_sync_d
            exit 0
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance mode expired (age=$((age/3600))h > ${MAX_MAINTENANCE_HOURS}h) — clearing flag, normal check follows" >> "$FAILOVER_LOG"
            rm -f "$MAINTENANCE_FLAG"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance flag malformed (no valid timestamp) — clearing, normal check follows" >> "$FAILOVER_LOG"
        rm -f "$MAINTENANCE_FLAG"
    fi
fi

# DNVR 프로세스 PID 확인
pid=$(pgrep -f "DNVR_va|DNVR" | head -1)
if [ -z "$pid" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') health check FAILED: no DNVR process" >> "$FAILOVER_LOG"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') health check: DNVR PID=$pid, waiting ${HEALTH_CHECK_PID_WAIT}s" >> "$FAILOVER_LOG"

# 10분 대기
sleep "$HEALTH_CHECK_PID_WAIT"

# 같은 PID 생존 확인
pid2=$(pgrep -f "DNVR_va|DNVR" | head -1)

if [ "$pid" != "$pid2" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') health check FAILED: PID changed ($pid -> $pid2)" >> "$FAILOVER_LOG"
    exit 1
fi

# 성공 — boot_ok=1 기록 + D 슬롯 동기화
mark_boot_ok_and_sync_d
echo "$(date '+%Y-%m-%d %H:%M:%S') boot_ok=1 (PID=$pid stable)" >> "$FAILOVER_LOG"
