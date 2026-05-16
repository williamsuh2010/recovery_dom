#!/bin/bash
# 현재 부팅 슬롯의 / 를 root_B, root_C, root_D 에 한 번에 rsync.
# 주간/월간 timer 안 기다리고 즉시 propagate 필요할 때 사용.
# (예: 수동 앱 설치/대규모 변경 직후)
#
# 사용법: sync-all-slots.sh

set -uo pipefail

FAILOVER_LOG="/var/log/failover.log"
FAILED=()
OK=()

echo "$(date '+%Y-%m-%d %H:%M:%S') sync-all-slots START" >> "$FAILOVER_LOG"

for slot in B C D; do
    echo "=== Syncing slot $slot ==="
    if /usr/local/sbin/sync-root.sh "$slot"; then
        OK+=("$slot")
    else
        FAILED+=("$slot")
    fi
done

echo ""
echo "=== Summary ==="
echo "OK:     ${OK[*]:-none}"
echo "FAILED: ${FAILED[*]:-none}"

if [ ${#FAILED[@]} -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') sync-all-slots END (failed: ${FAILED[*]})" >> "$FAILOVER_LOG"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') sync-all-slots END (all OK)" >> "$FAILOVER_LOG"
