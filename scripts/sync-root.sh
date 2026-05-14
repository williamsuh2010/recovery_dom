#!/bin/bash
# root_A를 지정 슬롯으로 rsync
# 사용법: sync-root.sh [B|C|D]
# sync-root-b.timer, sync-root-c.timer, upgrade-sync-d.sh 에서 호출

set -uo pipefail

SLOT="${1:-}"
SLOT_CONF="/etc/recovery/slot-uuids.conf"
FAILOVER_LOG="/var/log/failover.log"

if [[ ! "$SLOT" =~ ^[BCD]$ ]]; then
    echo "사용법: sync-root.sh [B|C|D]"
    exit 1
fi

if [ ! -f "$SLOT_CONF" ]; then
    echo "ERROR: $SLOT_CONF not found"
    exit 1
fi

source "$SLOT_CONF"

# 슬롯에 해당하는 디바이스 결정
case "$SLOT" in
    B) TARGET_UUID="$ROOT_B_UUID" ;;
    C) TARGET_UUID="$ROOT_C_UUID" ;;
    D) TARGET_UUID="$ROOT_D_UUID" ;;
esac

TARGET_DEV=$(blkid -U "$TARGET_UUID" 2>/dev/null)
if [ -z "$TARGET_DEV" ]; then
    echo "ERROR: Cannot find device for UUID=$TARGET_UUID (slot $SLOT)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') sync slot=$SLOT FAILED (device not found)" >> "$FAILOVER_LOG"
    exit 1
fi

# 마운트
MOUNT_POINT="/mnt/root_${SLOT,,}"
mkdir -p "$MOUNT_POINT"
mount "$TARGET_DEV" "$MOUNT_POINT"
if [ $? -ne 0 ]; then
    echo "ERROR: Cannot mount $TARGET_DEV to $MOUNT_POINT"
    echo "$(date '+%Y-%m-%d %H:%M:%S') sync slot=$SLOT FAILED (mount failed)" >> "$FAILOVER_LOG"
    exit 1
fi

# rsync
rsync -aAX --delete / "$MOUNT_POINT/" \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/dev \
    --exclude=/tmp \
    --exclude=/run \
    --exclude=/mnt \
    --exclude=/root/tgtdnvr \
    --exclude=/root/tgt_dec

RSYNC_RESULT=$?

# 언마운트
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT" 2>/dev/null

if [ $RSYNC_RESULT -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') sync slot=$SLOT OK" >> "$FAILOVER_LOG"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') sync slot=$SLOT FAILED (rsync exit=$RSYNC_RESULT)" >> "$FAILOVER_LOG"
    exit 1
fi
