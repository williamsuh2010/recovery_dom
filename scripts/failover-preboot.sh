#!/bin/bash
# 부팅 시 현재 슬롯 판별 및 로깅
# failover-prepare.service에 의해 부팅 초기에 실행

set -uo pipefail

FAILOVER_LOG="/var/log/failover.log"
SLOT_CONF="/etc/recovery/slot-uuids.conf"

# /proc/cmdline에서 root UUID 추출
ROOT_UUID=$(cat /proc/cmdline | grep -oP 'root=UUID=\K[^ ]+')

if [ -z "$ROOT_UUID" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') booted slot=UNKNOWN (no UUID in cmdline)" >> "$FAILOVER_LOG"
    exit 0
fi

# slot-uuids.conf에서 슬롯 매칭
SLOT="UNKNOWN"
if [ -f "$SLOT_CONF" ]; then
    source "$SLOT_CONF"
    if [ "$ROOT_UUID" = "$ROOT_A_UUID" ]; then SLOT=A;
    elif [ "$ROOT_UUID" = "$ROOT_B_UUID" ]; then SLOT=B;
    elif [ "$ROOT_UUID" = "$ROOT_C_UUID" ]; then SLOT=C;
    elif [ "$ROOT_UUID" = "$ROOT_D_UUID" ]; then SLOT=D;
    fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') booted slot=$SLOT (UUID=$ROOT_UUID)" >> "$FAILOVER_LOG"
