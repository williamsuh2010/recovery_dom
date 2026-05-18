#!/bin/bash
# 초기 설치 완료 — 슬롯 페일오버 검사 활성화 (production 모드 진입).
#
# Phase 3 가 install_mode 플래그를 자동 생성 → 그때부터 failover-success.sh
# 가 DNVR 검사 건너뛰고 항상 boot_ok=1 마킹 (슬롯 advance 무력화).
#
# 운영자가 DNVR 앱 설치/검증 모두 마치고 본 스크립트 실행 → 플래그 제거
# → 다음 부팅부터 정상 페일오버 (DNVR 20분 stable 검증) 동작.
#
# 사용법: finalize-install.sh

set -uo pipefail

FLAG="/etc/recovery/install_mode"
FAILOVER_LOG="/var/log/failover.log"

if [ ! -f "$FLAG" ]; then
    echo "install_mode 플래그가 없음. 이미 production 상태."
    exit 0
fi

# 사용자 의식 환기
echo "==============================================="
echo "  Production 모드 전환 — 슬롯 페일오버 활성화"
echo "==============================================="
echo ""
echo "이 시점부터 failover-success.sh 가 정상 DNVR PID 검사를 수행합니다."
echo "  - 부팅 후 ~20분 동안 DNVR 가 안정적으로 동작해야 boot_ok=1 마킹됨."
echo "  - DNVR 가 부팅 후 20분 안에 알아서 떠야 함 (autologin → .bash_profile)."
echo "  - 운영 중 작업 필요 시 enter-maintenance.sh / exit-maintenance.sh 사용."
echo ""

rm -f "$FLAG"
echo "$(date '+%Y-%m-%d %H:%M:%S') install_mode CLEARED — production mode active" >> "$FAILOVER_LOG"
echo "install_mode 플래그 제거 완료."
echo "다음 부팅부터 정상 슬롯 페일오버 동작."
