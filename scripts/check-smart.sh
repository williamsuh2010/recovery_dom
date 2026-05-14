#!/bin/bash
# SMART FAILED 감시 — 하루 1회 cron/timer로 실행
# SMART FAILED 감지 시 /tmp/smart_failed 파일 생성
# DNVR이 이 파일을 확인하여 화면에 "DOM 교체 필요" 경고 표시

# 마스터 이미지를 dd로 다른 타입(NVMe↔SATA) DOM에 복제해도 자동 추종되도록
# 현재 마운트된 root의 부모 디스크를 런타임에 산출한다.
ROOT_DEV=$(awk '$2=="/" {print $1}' /proc/mounts | tail -1)
SMART_CHECK_DISK=$(lsblk -rpno PKNAME "$ROOT_DEV" 2>/dev/null | head -1)
[ -z "$SMART_CHECK_DISK" ] && SMART_CHECK_DISK="/dev/sda"

result=$(smartctl -H "$SMART_CHECK_DISK" 2>/dev/null | grep "SMART overall-health")

if echo "$result" | grep -q "FAILED"; then
    touch /tmp/smart_failed
    echo "$(date '+%Y-%m-%d %H:%M:%S') SMART FAILED detected on $SMART_CHECK_DISK" >> /var/log/failover.log
elif [ -f /tmp/smart_failed ]; then
    # PASSED로 복구된 경우 (디스크 교체 등) 플래그 제거
    rm -f /tmp/smart_failed
fi
