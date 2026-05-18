#!/bin/bash
# 현재 부팅을 "성공" 으로 즉시 마킹 — 다음 재부팅 시 슬롯 advance 방지.
#
# 사용 시점:
#   Phase 3 완료 후 첫 부팅에서 DNVR 앱을 수동으로 설치하고 즉시 재부팅하는
#   경우. 자동 health check (failover-success.sh) 는 부팅 후 ~20분 (10분 초기
#   대기 + 10분 PID 안정 검증) 후에야 boot_ok=1 을 마킹하므로, 그 전에 수동
#   재부팅하면 GRUB 가 boot_ok=0 으로 보고 다음 슬롯으로 전진해 버림.
#
#   본 스크립트는 그 윈도우를 우회하기 위한 명시적 수동 마커.
#
# 사용법: mark-installed.sh
#
# 주의: DNVR 가 실제로 정상 동작하지 않는 상태에서 호출하면 슬롯 페일오버
#       보호를 건너뛰는 셈이 됨. 앱 설치/검증이 끝났을 때만 사용.

set -uo pipefail

FAILOVER_LOG="/var/log/failover.log"

# /boot 마운트 (noauto이므로 수동 마운트 필요)
mount /boot 2>/dev/null || mount "$(grep '/boot' /etc/fstab | awk '{print $1}' | head -1)" /boot

grub-editenv /boot/grub/grubenv set boot_ok=1 retry_round=0 boot_attempts=0

umount /boot

echo "$(date '+%Y-%m-%d %H:%M:%S') manual mark-installed (boot_ok=1)" >> "$FAILOVER_LOG"
echo "boot_ok=1 마킹 완료. 다음 재부팅 시 슬롯 전진하지 않음."
echo "(이후 부팅에서 DNVR 가 정상 동작하면 failover-success.sh 가 자동 마킹 이어감.)"
