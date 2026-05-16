#!/bin/bash
# 슬롯 페일오버 정상화 — maintenance mode 해제.
# enter-maintenance.sh 의 짝.
#
# 사용법: exit-maintenance.sh

set -uo pipefail

FLAG="/etc/recovery/maintenance_mode"

if [ -f "$FLAG" ]; then
    rm -f "$FLAG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance mode EXIT" >> /var/log/failover.log
    echo "Maintenance mode DISABLED. 정상 페일오버 동작 복귀."
    echo "  - 다음 부팅부터 failover-success.sh 가 DNVR PID 정상 검사."
else
    echo "Maintenance mode 가 활성화되어 있지 않음. (할 일 없음)"
fi
