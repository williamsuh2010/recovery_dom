#!/bin/bash
# Health check + boot_ok 마킹
# failover-success.service에 의해 실행 (10분 sleep 후)
# 1. DNVR PID 확인
# 2. 10분 동안 30초 간격 sampling → distinct PID 가짓수 + empty sample 카운트
# 3. 가짓수 ≤ 임계 (합법 재시작 허용) + 끝 시점 alive → boot_ok=1
# 4. D 슬롯 동기화 플래그 확인
#
# 사용자 트리거 재시작 (설정 변경 등) 은 PID 가 1~2회 바뀌는 정도라 통과.
# 크래시 루프는 가짓수 임계 넘어 실패. 임계값은 운영 데이터로 추후 튜닝.

set -uo pipefail

FAILOVER_LOG="/var/log/failover.log"
HEALTH_CHECK_PID_WAIT=600
HEALTH_CHECK_SAMPLE_INTERVAL=30
HEALTH_CHECK_MAX_DISTINCT_PIDS=3
MAINTENANCE_FLAG="/etc/recovery/maintenance_mode"
MAX_MAINTENANCE_HOURS=24

mark_boot_ok_and_sync_d() {
    mount /boot 2>/dev/null || mount "$(grep '/boot' /etc/fstab | awk '{print $1}' | head -1)" /boot
    grub-editenv /boot/grub/grubenv set boot_ok=1 retry_round=0
    umount /boot
    # config 빠른 propagation (작은 파일들 atomic 복사) — boot_ok 마킹 시점의
    # 최신 설정을 B/C/D 에 즉시 push. 슬롯 전환 시 설정 손실 최소화.
    /usr/local/sbin/sync-config.sh
    # D 슬롯 전체 동기화 (DNVR 업그레이드 후에만 작동, 플래그 기반)
    /usr/local/sbin/upgrade-sync-d.sh
}

# Maintenance mode: 관리자가 enter-maintenance.sh 로 명시한 작업 윈도우.
# DNVR PID 검사 건너뛰고 boot_ok=1 즉시 마킹 (24h 자동 만료).
if [ -f "$MAINTENANCE_FLAG" ]; then
    flag_ts=$(head -1 "$MAINTENANCE_FLAG" 2>/dev/null)
    if [[ "$flag_ts" =~ ^[0-9]+$ ]]; then
        age=$(( $(date +%s) - flag_ts ))
        if [ $age -lt $((MAX_MAINTENANCE_HOURS * 3600)) ]; then
            reason=$(sed -n '2p' "$MAINTENANCE_FLAG" 2>/dev/null)
            echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance mode active (age=$((age/60))min, reason=[${reason}]) — marking boot_ok=1, skipping DNVR check" >> "$FAILOVER_LOG"
            mark_boot_ok_and_sync_d
            exit 0
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance mode expired (age=$((age/3600))h > ${MAX_MAINTENANCE_HOURS}h) — clearing flag, normal check follows" >> "$FAILOVER_LOG"
            rm -f "$MAINTENANCE_FLAG"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') maintenance flag malformed (no valid timestamp) — clearing, normal check follows" >> "$FAILOVER_LOG"
        rm -f "$MAINTENANCE_FLAG"
    fi
fi

# DNVR 프로세스 PID 확인 (시작 시점)
pid=$(pgrep -f "DNVR_va|DNVR" | head -1)
if [ -z "$pid" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') health check FAILED: no DNVR process at start" >> "$FAILOVER_LOG"
    exit 1
fi

sample_count=$((HEALTH_CHECK_PID_WAIT / HEALTH_CHECK_SAMPLE_INTERVAL))
echo "$(date '+%Y-%m-%d %H:%M:%S') health check start: DNVR PID=$pid, sampling ${sample_count}x every ${HEALTH_CHECK_SAMPLE_INTERVAL}s" >> "$FAILOVER_LOG"

# Sampling: 30초 간격으로 20회 (=10분) PID 채집
declare -A seen_pids
seen_pids[$pid]=1
empty_samples=0

for ((i=1; i<=sample_count; i++)); do
    sleep "$HEALTH_CHECK_SAMPLE_INTERVAL"
    cur=$(pgrep -f "DNVR_va|DNVR" | head -1)
    if [ -z "$cur" ]; then
        empty_samples=$((empty_samples + 1))
    else
        seen_pids[$cur]=1
    fi
done

distinct=${#seen_pids[@]}
pid_end=$(pgrep -f "DNVR_va|DNVR" | head -1)
end_alive=$([ -n "$pid_end" ] && echo 1 || echo 0)

# 통계 항상 기록 (임계값 튜닝용 — 운영 데이터 누적)
echo "$(date '+%Y-%m-%d %H:%M:%S') health check stats: distinct_pids=$distinct empty_samples=$empty_samples/$sample_count end_alive=$end_alive end_pid=${pid_end:-none}" >> "$FAILOVER_LOG"

# 판정
if [ -z "$pid_end" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') health check FAILED: no DNVR at end" >> "$FAILOVER_LOG"
    exit 1
fi
if [ $distinct -gt $HEALTH_CHECK_MAX_DISTINCT_PIDS ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') health check FAILED: distinct_pids=$distinct > threshold ${HEALTH_CHECK_MAX_DISTINCT_PIDS} (crash loop suspected)" >> "$FAILOVER_LOG"
    exit 1
fi

# 성공 — boot_ok=1 기록 + D 슬롯 동기화
mark_boot_ok_and_sync_d
echo "$(date '+%Y-%m-%d %H:%M:%S') boot_ok=1 (final_pid=$pid_end, distinct=$distinct)" >> "$FAILOVER_LOG"
