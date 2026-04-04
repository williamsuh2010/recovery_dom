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

# 성공 — boot_ok=1 기록
mount /boot 2>/dev/null || mount "$(grep '/boot' /etc/fstab | awk '{print $1}' | head -1)" /boot

grub-editenv /boot/grub/grubenv set boot_ok=1 retry_round=0

umount /boot

echo "$(date '+%Y-%m-%d %H:%M:%S') boot_ok=1 (PID=$pid stable)" >> "$FAILOVER_LOG"

# D 슬롯 동기화 플래그 확인
/usr/local/sbin/upgrade-sync-d.sh
