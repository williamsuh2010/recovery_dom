#!/bin/bash
# DNVR 업그레이드 후 D 슬롯 동기화
# failover-success.sh에서 호출되거나 수동 실행 가능
# 플래그 파일: /var/lib/recovery/upgrade_sync_d

set -uo pipefail

UPGRADE_SYNC_FLAG="/var/lib/recovery/upgrade_sync_d"
FAILOVER_LOG="/var/log/failover.log"

if [ ! -f "$UPGRADE_SYNC_FLAG" ]; then
    exit 0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') upgrade sync D: starting" >> "$FAILOVER_LOG"

/usr/local/sbin/sync-root.sh D
RESULT=$?

if [ $RESULT -eq 0 ]; then
    rm -f "$UPGRADE_SYNC_FLAG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') upgrade sync D: completed, flag removed" >> "$FAILOVER_LOG"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') upgrade sync D: FAILED (keeping flag for retry)" >> "$FAILOVER_LOG"
fi

exit $RESULT
