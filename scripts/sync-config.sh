#!/bin/bash
# DNVR 설정 파일 (Config.ini, Config_TEMP.ini) 을 백업 슬롯에 빠르게 복제.
# failover-success.sh 가 boot_ok=1 마킹 직후 자동 호출 (인자 없음 = 전 슬롯).
# 수동 호출도 가능.
#
# 사용법:
#   sync-config.sh         # 현재 슬롯 제외 B/C/D 전부
#   sync-config.sh B       # B 만
#   sync-config.sh C
#   sync-config.sh D
#
# 특성:
# - atomic rename (.tmp → mv) 로 중간 전원 차단 시에도 슬롯의 기존 config 손상 없음
# - 현재 슬롯 자동 skip (root UUID 비교)
# - 슬롯 단위 독립 처리, 한 슬롯 실패해도 나머지 계속

set -uo pipefail

FAILOVER_LOG="/var/log/failover.log"
SLOT_CONF="/etc/recovery/slot-uuids.conf"
CONFIG_FILES=("/tgtdvr/Config.ini" "/tgtdvr/Config_TEMP.ini")

if [ ! -f "$SLOT_CONF" ]; then
    echo "ERROR: $SLOT_CONF not found"
    exit 1
fi
source "$SLOT_CONF"

# 현재 root 디바이스의 UUID — 자기 자신 mount 시도 회피
ROOT_DEV=$(awk '$2=="/" {print $1}' /proc/mounts | tail -1)
CURRENT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)

sync_slot() {
    local name="$1"
    local uuid_var="ROOT_${name}_UUID"
    local uuid="${!uuid_var:-}"

    if [ -z "$uuid" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') config sync slot=$name SKIP (UUID undefined)" >> "$FAILOVER_LOG"
        return 0
    fi

    if [ "$uuid" = "$CURRENT_UUID" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') config sync slot=$name SKIP (current root)" >> "$FAILOVER_LOG"
        return 0
    fi

    local dev
    dev=$(blkid -U "$uuid" 2>/dev/null)
    if [ -z "$dev" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') config sync slot=$name FAILED (device not found UUID=$uuid)" >> "$FAILOVER_LOG"
        return 1
    fi

    local mnt="/mnt/cfgsync_${name,,}"
    mkdir -p "$mnt"
    if ! mount "$dev" "$mnt" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') config sync slot=$name FAILED (mount $dev)" >> "$FAILOVER_LOG"
        rmdir "$mnt" 2>/dev/null
        return 1
    fi

    mkdir -p "$mnt/tgtdvr"

    local copied=()
    local failed=()
    for src in "${CONFIG_FILES[@]}"; do
        local base
        base=$(basename "$src")
        local dst="$mnt/tgtdvr/$base"
        if [ ! -f "$src" ]; then
            continue  # 소스 없으면 silently skip
        fi
        # atomic rename: cp 가 partial 일 수 있어도 mv 가 한 번에 교체 → dst 는 old 또는 new 만
        if cp -p "$src" "${dst}.tmp" 2>/dev/null && mv "${dst}.tmp" "$dst" 2>/dev/null; then
            copied+=("$base")
        else
            failed+=("$base")
            rm -f "${dst}.tmp" 2>/dev/null
        fi
    done

    sync
    umount "$mnt"
    rmdir "$mnt" 2>/dev/null

    if [ ${#failed[@]} -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') config sync slot=$name OK (${copied[*]:-no files})" >> "$FAILOVER_LOG"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') config sync slot=$name FAILED (copied=[${copied[*]:-none}] failed=[${failed[*]}])" >> "$FAILOVER_LOG"
        return 1
    fi
}

if [ -z "${1:-}" ]; then
    # 전 슬롯 (B, C, D)
    result=0
    for s in B C D; do
        sync_slot "$s" || result=1
    done
    exit $result
elif [[ "$1" =~ ^[BCD]$ ]]; then
    sync_slot "$1"
else
    echo "사용법: $0 [B|C|D]   (인자 없으면 B C D 전부)"
    exit 1
fi
