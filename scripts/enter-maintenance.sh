#!/bin/bash
# 슬롯 페일오버 임시 비활성화 — DNVR 수동 종료/디버깅 작업 전 호출.
#
# 효과: failover-success.sh 가 DNVR PID 검사 건너뛰고 boot_ok=1 무조건 마킹.
#       즉 작업 도중 시스템이 자체 reboot (워치독/panic) 해도 슬롯 advance 안 됨.
#
# 안전장치: 24시간 후 자동 만료. exit-maintenance.sh 수동 해제 권장.
#
# 사용법: enter-maintenance.sh [reason 메모]

set -uo pipefail

FLAG="/etc/recovery/maintenance_mode"
REASON="${*:-no reason}"

mkdir -p /etc/recovery
{
    date +%s
    echo "$REASON"
} > "$FLAG"

echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance mode ENTER ($REASON)" >> /var/log/failover.log

echo "Maintenance mode ENABLED."
echo "  - failover-success.sh 가 DNVR 검사 건너뛰고 boot_ok=1 즉시 마킹."
echo "  - 최대 24시간 후 자동 만료 (안전장치)."
echo "  - 작업 끝나면 명시적 해제: exit-maintenance.sh"
