# Recovery DOM 설계 논의 기록

## 1. 배경 및 문제 정의

### 현재 환경
- 128GB SSD, 32GB만 사용 (나머지 미할당)
- OS: Arch Linux
- 부팅: UEFI + systemd-boot (현재, 새 설계에서 GRUB으로 전환)
- init: systemd
- 파티션: boot(EFI 512MB) + swap(4GB) + root(~28GB, ext4)
- 24/7 365일 연속 가동 (NVR 관제 시스템)
- 관제 현장은 항상 원격지, 현장 접근에 시간 소요
- 내부망 환경 (원격 SSH 접근 어려움)

### NVR 시스템 특성
- 운용 프로그램: DNVR_va 또는 DNVR
- superdaemon이 실행 파일을 관리 (죽으면 자동 재실행)
- `/root/tgt` — ecryptfs 암호화 원본 (운용 프로그램 + 각종 파일)
- `/root/tgtdnvr` — ecryptfs 복호화 마운트 포인트
- `/tgtdvr` — 설정 파일 + SQLite 로그 DB (변경 빈도 낮음)
- NVR 녹화 영상 — 별도 HDD (root와 무관)
- root 파티션은 거의 정적 시스템 (설치 후 변경 거의 없음)

### 발생하는 문제
운영 중 (업데이트 없이) 간헐적으로 부팅 실패 또는 앱 가동 불가 발생.
원인은 SSD 물리적 열화 및 파일시스템 손상.

---

## 2. 장애 사진 분석 (fail/ 폴더)

### 장애 유형 분류

| 유형 | 설명 | 해당 사진 | 빈도 |
|------|------|-----------|------|
| A | SSD 물리적 오류(NAND bad block) → ext4 오류 → 커널 panic | KakaoTalk_20241210, KakaoTalk_20260105 | 높음 |
| B | root ext4 파일시스템 손상 → fsck 수동 요구로 부팅 중단 | 20260403_213421 | 높음 |
| C | initramfs 파일 손상 → "Decoding failed" → 부팅 불가 | 20260403_213837 | 중간 |
| D | systemd 서비스 연쇄 실패 → OS 올라왔으나 정상 동작 불가 | 20260403_213510, 213651, 214106 | 높음 |
| E | 시스템 hang → watchdog did not stop 반복 | 20260403_213922 | 중간 |
| F | X.Org 디스플레이 서버 기동 실패 → 화면 출력 불가 | KakaoTalk_20250313 | 낮음 |
| G | 부팅은 됐으나 NVR 앱 미구동 (검은 화면) | KakaoTalk_20241224 | 중간 |

### 핵심 발견
1. 장애의 대부분이 SSD 물리적 열화 또는 파일시스템 손상에서 시작됨
2. 여러 현장에서 유사 장애가 반복 보고됨 (2024-12, 2025-03, 2025-11, 2026-01 — 각각 서로 다른 DOM/현장의 독립 사례, 같은 SSD의 시간 간격 아님)
3. initramfs 손상(유형 C)은 systemd-boot에서는 대응 불가, GRUB /boot 분리 시 대응 가능
4. 모든 장애 유형이 multi-slot GRUB failover로 대응 가능

---

## 3. 확정 사항

### 3.1 부트로더: GRUB (systemd-boot에서 전환)

#### 선택 이유: 외부 failover 로직의 한계

systemd-boot + 외부 failover는 OS가 정상적으로 올라온 후에만 동작.
GRUB은 커널 로드 전에 grubenv를 읽고 슬롯을 판단할 수 있음.

| 실패 지점 | systemd-boot failover | GRUB failover |
|-----------|----------------------|---------------|
| 커널 로드 실패 | X | O |
| initramfs 실패 | X | O |
| root 마운트 실패 | X | O |
| systemd 기동 실패 | X | O |
| 앱 기동 실패 | O | O |

```
GRUB 흐름:
전원 ON → UEFI → GRUB → grubenv 읽기 (boot_counter 확인) → 슬롯 선택 → 커널 로드
                         ↑ 여기서 이미 failover 판단
```

### 3.2 파티션 구조 (10개, 확정)

```
[ EFI_A  ]   512MB    FAT32     GRUB 바이너리 (primary)
[ EFI_B  ]   512MB    FAT32     GRUB 바이너리 (backup)
[ boot_A ]   1GB      ext4      커널/initramfs/grub.cfg/grubenv (primary)
[ boot_B ]   1GB      ext4      커널/initramfs/grub.cfg (backup)
[ swap   ]   4GB      swap
[ root_A ]   27.5GB   ext4      운영 시스템 (live)
[ root_B ]   27.5GB   ext4      1주 백업
[ root_C ]   27.5GB   ext4      1개월 백업
[ root_D ]   27.5GB   ext4      최초 설치 상태 보존
나머지 ~11GB  미할당
```

총: 0.5 + 0.5 + 1 + 1 + 4 + 27.5x4 = 117GB

### 3.3 파일시스템 (확정)
- EFI: FAT32 (UEFI 필수)
- boot: ext4 (저널링 보호)
- root: **ext4** (확정)

#### ext4 선택 근거 (Btrfs 검토 결과)
Btrfs의 체크섬이 rsync 시 손상 전파를 차단할 수 있다는 이점을 검토했으나:
1. rsync는 기본적으로 크기+mtime 비교 → SSD 손상으로 내용만 깨진 파일은 **건너뜀** (전파 안 됨)
2. `--checksum` 옵션 사용 시에만 전파 차단 가능하나, 전체 파일 읽기 부하가 큼 → 사용 불가
3. 실제 장애 사진 분석 결과, Btrfs가 결과를 바꾸는 장애 유형 없음 (전부 failover가 해결)
4. ext4가 안정성/성숙도/fsck 도구 면에서 우위

### 3.14 파티션/root 식별: UUID (확정)

#### LABEL 대신 UUID 선택 근거
기존 방식(LABEL=dnvr_os)의 문제:
- 현장에서 USB 디버그 DOM으로 부팅 시, 내장 DOM과 같은 LABEL → 충돌
- 바이오스에서 내장 NVMe 비활성화해도 LABEL을 못 찾는 메인보드 존재 (원인 불명, 디바이스 열거 타이밍 문제 추정)
- 내장 DOM을 물리적으로 분리하기 극히 어려움 (현장 환경)

UUID는 전 세계 유일하므로 충돌 불가능.
grub.cfg, fstab 전부 UUID 기반으로 작성.

#### 출고 공정: dd 후 UUID 재생성 (필수)
출고 시 마스터 이미지를 dd로 복제하면 모든 DOM이 동일 UUID를 가짐 → 충돌 문제 재발.
**dd 후 반드시 UUID 재생성 스크립트를 실행해야 함:**
```bash
# post_dd_uuid_regen.sh — dd 후 각 DOM에서 1회 실행
tune2fs -U random /dev/sda3   # boot_A
tune2fs -U random /dev/sda4   # boot_B
tune2fs -U random /dev/sda6   # root_A
tune2fs -U random /dev/sda7   # root_B
tune2fs -U random /dev/sda8   # root_C
tune2fs -U random /dev/sda9   # root_D
# 새 UUID 읽어서 grub.cfg, fstab 자동 갱신
ROOT_A_UUID=$(blkid -s UUID -o value /dev/sda6)
# ... grub.cfg, fstab에 반영
```
이 스크립트는 설치 스크립트 suite에 포함.

### 3.4 Failover 순서
```
A 실패 → B → C → D → 시스템 정지 (무한 재부팅 방지)
```

### 3.5 Recovery 파티션: 없음
- 관제 현장이 원격지 + 내부망 → SSH 접근 어려움
- A/B/C/D 전부 실패 시 fsck도 대부분 실패, 복구할 정상 슬롯 없음
- 현장 출동 → USB 복구 또는 DOM 교체

### 3.6 Rotation 주기
```
root_A = live (운영)
root_B = 1주 1회 rsync (자동, 새벽 시간대)
root_C = 1개월 1회 rsync (자동, 새벽 시간대)
root_D = DNVR 버전 업그레이드 시에만 수동 갱신
```

근거:
- 시스템이 거의 정적 (설치 후 변경 거의 없음)
- 빈번한 rsync는 SSD 쓰기 수명만 소모
- 정상 상태를 오래 보존하는 게 중요

#### D 갱신 정책
- **DNVR 버전 업그레이드 시에만** 실행 (커널 업데이트/설정 변경은 해당 없음)
- 업그레이드 후 **10분 이상 DNVR 정상 동작 확인** (기존 health check와 동일 기준)
- 확인 후 **D만 rsync** (B, C는 자동 주기가 알아서 처리)

#### D 갱신 흐름 (자동)
```
1. DNVR 소스코드에서 업그레이드 실행 시 플래그 생성
   → DNVR이 /var/lib/recovery/upgrade_sync_d 파일 생성 (DNVR 소스코드 수정 필요)
2. DNVR 프로그램 재실행 또는 시스템 재부팅
3. failover-success.sh (health check)가 DNVR 10분 정상 동작 확인
4. 플래그 파일 존재 확인 → D로 rsync
5. 플래그 삭제
```
- 플래그 위치: `/var/lib/recovery/upgrade_sync_d` (/tmp는 재부팅 시 날아가므로 사용 불가)
- DNVR 소스코드에 플래그 생성 로직 추가 필요 (한 줄: 파일 touch/create)

### 3.7 rsync 정책
```bash
rsync -aAX --delete / /mnt/root_B \
  --exclude=/proc --exclude=/sys --exclude=/dev \
  --exclude=/tmp --exclude=/run \
  --exclude=/root/tgtdnvr   # ecryptfs 마운트 포인트 제외
  # /root/tgt 는 포함 (암호화된 원본)
  # /tgtdvr 는 포함 (설정 + SQLite 로그)
```

### 3.8 앱 Health Check (boot_ok 판단)
```
부팅 후 10분 대기
→ DNVR_va 또는 DNVR PID 확인
→ 10분 후 같은 PID 생존 확인
→ 성공 → boot_ok=1
→ 실패 → boot_ok 안 찍음 → 다음 부팅에서 슬롯 전환
```

superdaemon이 DNVR을 계속 재실행하므로, 프로세스 존재 여부가 아닌
"동일 PID가 10분 이상 유지되는지"로 안정성 판단.

### 3.9 Boot 이중화
- boot_A + boot_B 별도 ext4 파티션
- 평소 read-only 운영

### 3.10 EFI 이중화
- EFI_A + EFI_B
- UEFI boot entry 2개 등록
- UEFI 펌웨어 레벨 자동 failover

### 3.11 추가 보호
- watchdog 활성화
- `kernel.panic = 10` (커널 panic 시 10초 후 자동 재부팅)
- `RuntimeWatchdogSec=20`
- `RebootWatchdogSec=30`
- /boot read-only 운영
- SMART 모니터링

### 3.12 Data 파티션: 없음
- failover 상태 → grubenv (boot 파티션)
- 로그 → root 내 /var/log
- 별도 data 파티션이 필요한 기능 없음

### 3.13 Over-provisioning
- 의도적으로 하지 않음
- 현재 96GB 미할당에서도 장애 발생 → 효과 없음 확인됨
- ~11GB 미할당은 파티션 크기 조정의 자연 발생분

### 3.15 GRUB boot_A/B 전환: 방안 A (내장 fallback 설정) 확정

GRUB 바이너리 빌드 시 `grub-mkimage -c early.cfg`로 fallback 설정을 내장:
```bash
# early.cfg — GRUB 바이너리에 내장되는 설정
search --fs-uuid <boot_A_UUID> --set=root
if [ -f /grub/grub.cfg ]; then
    configfile /grub/grub.cfg
else
    search --fs-uuid <boot_B_UUID> --set=root
    if [ -f /grub/grub.cfg ]; then
        configfile /grub/grub.cfg
    else
        echo "boot_A, boot_B 둘 다 실패"
    fi
fi
```

#### 선택 근거
- UEFI 펌웨어 failover에 의존하지 않음 (메인보드마다 동작이 다름)
- LABEL 못 찾는 보드도 있었으므로 펌웨어를 신뢰할 수 없음
- GRUB 바이너리 하나로 boot_A/B 자동 전환

#### 중요: dd 후 UUID 재생성 시 GRUB 재빌드 필수
출고 공정에서 dd로 이미지 복제 후 UUID를 재생성하면, early.cfg에 내장된 boot_A/B UUID도 달라지므로 **GRUB 바이너리도 반드시 재빌드**해야 함.
`post_dd_uuid_regen.sh` 스크립트에 포함:
```bash
# UUID 재생성 후
BOOT_A_UUID=$(blkid -s UUID -o value /dev/sda3)
BOOT_B_UUID=$(blkid -s UUID -o value /dev/sda4)

# early.cfg 재생성
cat > /tmp/early.cfg <<EOF
search --fs-uuid ${BOOT_A_UUID} --set=root
if [ -f /grub/grub.cfg ]; then
    configfile /grub/grub.cfg
else
    search --fs-uuid ${BOOT_B_UUID} --set=root
    if [ -f /grub/grub.cfg ]; then
        configfile /grub/grub.cfg
    else
        echo "boot_A, boot_B failure"
    fi
fi
EOF

# GRUB 바이너리 재빌드 및 EFI_A, EFI_B에 복사
grub-mkimage -c /tmp/early.cfg -o grubx64.efi -p /grub ...
cp grubx64.efi /mnt/efi_a/EFI/BOOT/
cp grubx64.efi /mnt/efi_b/EFI/BOOT/
```

### 3.16 EFI-boot-root 매핑: Primary/Backup 구조 (확정)

```
EFI_A ─┐
       ├→ 동일한 GRUB 바이너리 (early.cfg 내장)
EFI_B ─┘
         │
         ├→ boot_A (primary) → grub.cfg → root_A/B/C/D 선택
         └→ boot_B (backup)  → grub.cfg → root_A/B/C/D 선택
```

- EFI_A = EFI_B: **완전 동일** 복사본
- boot_A → boot_B: primary/backup, 주기적 동기화
- boot에서 root_A/B/C/D **전부 접근 가능** (독립 분리 아님)
- boot_B의 grubenv가 약간 오래되어도 failover 로직이 알아서 처리

### 3.18 /boot 보호: 평소 umount (확정)

- fstab에 `noauto`로 설정 → 부팅 시 자동 마운트 안 됨
- health check 성공 시에만 mount → boot_ok=1 기록 → umount
- 평소 /boot가 마운트되지 않으므로 어떤 프로세스도 건드릴 수 없음
- GRUB은 OS mount와 무관하게 직접 파티션에 쓰므로 영향 없음
```
# /etc/fstab
UUID=<boot_A>  /boot  ext4  noauto,defaults  0 0
```
```bash
# failover-success.sh 에서
mount /dev/sdaX /boot
grub-editenv /boot/grub/grubenv set boot_ok=1
umount /boot
```

### 3.22 수동 슬롯 전환 스크립트 (확정)

```bash
# /usr/local/sbin/switch_slot.sh
#!/bin/bash
if [ -z "$1" ]; then
    echo "사용법: switch_slot.sh [A|B|C|D]"
    exit 1
fi
mount /dev/sdaX /boot
grub-editenv /boot/grub/grubenv set boot_try=$1 boot_ok=0
umount /boot
echo "$(date '+%Y-%m-%d %H:%M:%S') manual switch to slot $1" >> /var/log/failover.log
echo "다음 재부팅 시 slot $1 로 부팅됩니다."
```

### 3.23 Failover 이력 로그 (확정)

`/var/log/failover.log`에 부팅/성공/수동전환 이력 기록.

- failover-preboot.sh (부팅 초기): 어느 슬롯으로 부팅했는지 기록
- failover-success.sh (health check 성공): boot_ok=1 + 슬롯 기록
- switch_slot.sh (수동 전환): 수동 전환 기록

```
# /var/log/failover.log 예시
2026-04-01 03:12:15 booted slot=A
2026-04-01 03:32:20 boot_ok=1 slot=A
2026-06-15 08:01:03 booted slot=B        ← A 실패 → B로 전환됨
2026-06-15 08:21:08 boot_ok=1 slot=B
2026-07-01 14:00:00 manual switch to slot D
```

- root 손상 시 해당 슬롯의 로그도 유실되지만, 다음 슬롯에서 새로 기록
- 부팅당 1~2줄, 부작용 없음

### 3.21 SMART 모니터링 (확정)

- **SMART FAILED만 감시** (개별 속성 이상은 오탐 많아 부적합)
- cron + smartctl 방식 (smartd 데몬 불필요)
- **하루 1회** 체크
- SMART FAILED 감지 시 `/tmp/smart_failed` 파일 생성
- DNVR이 해당 파일 존재 확인 → 화면에 "DOM 교체 필요" 경고 표시 (신규 개발 필요)
- SMART로 못 잡는 고장(64%)은 failover가 대응

```bash
# /usr/local/sbin/check_smart.sh
result=$(smartctl -H /dev/sda | grep "SMART overall-health")
if echo "$result" | grep -q "FAILED"; then
    touch /tmp/smart_failed
fi
```
```
# crontab — 하루 1회 (새벽)
0 4 * * * /usr/local/sbin/check_smart.sh
```

### 3.20 D 실패 후 동작: 1회 재시도 후 멈춤 (확정)

```
A→B→C→D 전부 실패
→ A부터 다시 1회씩 시도 (A→B→C→D)
→ 전부 또 실패 → GRUB에서 멈춤 + "ALL SLOTS FAILED" 표시
```

- 일시적 문제(전원 불안정, 접촉 불량) 시 재시도 중 자동 복구 가능
- 영구적 고장이면 2라운드 실패 후 멈춤 → 화면에 메시지 → 관제 요원 인지
- 무한 재부팅 루프 방지

### 3.19 Failover 방식: 단순 순차 이동, 복원 없음 (확정)

실패한 슬롯은 복원하지 않고 다음 슬롯으로 이동. 순서 고정.
```
A 실패 → B 운영
B 실패 → C 운영
C 실패 → D 운영
D 실패 → DOM 교체 (현장 출동)
```

#### 선택 근거
- 복원 방식(실패 슬롯 포맷+rsync) 대비:
  - 코드 단순 → 버그 적음 → 원격지 신뢰성 높음
  - 같은 물리 영역 재사용 시 재실패 위험 없음
  - SSD에 추가 쓰기 부하 없음
  - GRUB failover 순서 고정 (동적 순서 변경 불필요)
- 슬롯 복원을 하더라도 같은 SSD 위이므로 SSD 전체 수명 문제는 해결 안 됨
- 하나의 DOM에서 장애 간격을 알 수 없으므로 4슬롯으로 충분한지는 불확실하나, D까지 도달하면 SSD 자체 수명 문제이므로 DOM 교체가 맞음

### 3.17 boot 동기화: 안 함 (확정)

- 설치 시 boot_A → boot_B 1회 복사 후 **이후 동기화 없음**
- 커널 업데이트 안 하므로 커널/initramfs 변경 없음
- grubenv만 차이 발생 가능하나, boot_A 손상 시 boot_B의 옛날 값으로 부팅해도 failover가 알아서 처리
- 동기화 중 전원 차단 시 boot_B 손상 위험 → 안 건드리는 게 가장 안전

---

## 4. GRUB Failover 로직 설계

### 4.1 GRUB 자체 failover (grub.cfg)

```bash
load_env
set boot_try="${boot_try}"
if [ -z "$boot_try" ]; then
    set boot_try=A
fi

# 이전 부팅 실패 → 다음 슬롯
if [ "$boot_ok" != "1" ]; then
    if [ "$boot_try" = "A" ]; then set boot_try=B;
    elif [ "$boot_try" = "B" ]; then set boot_try=C;
    elif [ "$boot_try" = "C" ]; then set boot_try=D;
    else set boot_try=FAIL; fi
fi

# 이번 시도 기록 (아직 성공 아님)
set boot_ok=0
save_env boot_try boot_ok

# 슬롯별 부팅
if [ "$boot_try" = "A" ]; then
    linux /vmlinuz-linux root=UUID=<root_A> rw
elif [ "$boot_try" = "B" ]; then
    linux /vmlinuz-linux root=UUID=<root_B> rw
elif [ "$boot_try" = "C" ]; then
    linux /vmlinuz-linux root=UUID=<root_C> rw
elif [ "$boot_try" = "D" ]; then
    linux /vmlinuz-linux root=UUID=<root_D> rw
elif [ "$boot_try" = "FAIL" ]; then
    # 전부 실패 → 시스템 정지
    linux /vmlinuz-linux root=UUID=<root_D> rw single
fi
initrd /initramfs-linux.img
boot
```

### 4.2 OS 레벨 성공 마킹

```bash
grub-editenv /boot/grub/grubenv set boot_ok=1
```

### 4.3 상태 파일 (/boot/failover/state.env)

```
CURRENT_SLOT=A
TRY_SLOT=A
BOOT_OK=0
FAIL_COUNT_A=0
FAIL_COUNT_B=0
FAIL_COUNT_C=0
FAIL_COUNT_D=0
LAST_GOOD_SLOT=A
```

### 4.4 systemd 서비스

**failover-prepare.service** (부팅 초기):
```ini
[Unit]
Description=Failover prepare
DefaultDependencies=no
After=local-fs.target boot.mount
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/failover-preboot.sh

[Install]
WantedBy=multi-user.target
```

**failover-success.service** (앱 정상 후):
```ini
[Unit]
Description=Mark boot success
After=network-online.target your-app.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 600
ExecStart=/usr/local/sbin/failover-success.sh

[Install]
WantedBy=multi-user.target
```

### 4.5 Health Check 스크립트 (failover-success.sh)

```bash
#!/bin/bash
# 부팅 후 10분 대기는 ExecStartPre=/bin/sleep 600 으로 처리

# DNVR 프로세스 PID 확인
pid=$(pgrep -f "DNVR_va|DNVR")
if [ -z "$pid" ]; then
    exit 1  # 프로세스 없음 → 실패
fi

# 10분 후에도 같은 PID인지 확인 (재시작 안 됐는지)
sleep 600
pid2=$(pgrep -f "DNVR_va|DNVR")

if [ "$pid" = "$pid2" ]; then
    # 성공 — GRUB 환경 변수 기록
    mount -o remount,rw /boot
    grub-editenv /boot/grub/grubenv set boot_ok=1
    mount -o remount,ro /boot

    # 상태 파일도 업데이트
    source /boot/failover/state.env
    BOOT_OK=1
    LAST_GOOD_SLOT="$TRY_SLOT"
    cat > /boot/failover/state.env <<EOF
CURRENT_SLOT=$CURRENT_SLOT
TRY_SLOT=$TRY_SLOT
BOOT_OK=$BOOT_OK
FAIL_COUNT_A=$FAIL_COUNT_A
FAIL_COUNT_B=$FAIL_COUNT_B
FAIL_COUNT_C=$FAIL_COUNT_C
FAIL_COUNT_D=$FAIL_COUNT_D
LAST_GOOD_SLOT=$LAST_GOOD_SLOT
EOF
    sync
else
    exit 1  # PID 바뀜 = 재시작됨 = 비정상
fi
```

---

## 5. Btrfs snapshot vs rsync 비교 (참고)

| 항목 | rsync (multi-root) | Btrfs snapshot |
|------|-------------------|----------------|
| 구조 | 완전 별도 파티션 | 동일 FS 내부 subvolume |
| 격리 | **매우 강함** | 약함 |
| 물리 손상 대응 | **강함** | 약함 |
| FS 손상 대응 | **강함** | 취약 (같이 영향) |

결론: 물리적 손상 대응이 핵심이므로 **rsync multi-root 구조** 채택.

> "rsync는 생존, Btrfs는 편의"

---

## 6. SSD 내 파티션 분리의 효과 (참고)

같은 SSD 내 다른 파티션은 서로 다른 LBA 영역 → 다른 NAND 페이지에 매핑될 확률 높음.

| 장애 유형 | 다른 파티션 생존 확률 |
|-----------|---------------------|
| 파일시스템 손상 | 99% |
| 일부 bad block | 95%+ |
| FTL 오류 | 70~90% |
| SSD 전체 고장 | 0% |

---

## 7. 미결정 사항

| # | 항목 | 설명 |
|---|------|------|
| ~~1~~ | ~~GRUB boot_A/B 전환~~ | **확정 → 3.15로 이동** |
| ~~2~~ | ~~EFI-boot-root 매핑~~ | **확정 → 3.16으로 이동** |
| ~~3~~ | ~~boot 동기화 주기~~ | **확정 → 3.17로 이동** |
| ~~4~~ | ~~/boot read-only 자동화~~ | **확정 → 3.18로 이동** |
| ~~5~~ | ~~SMART 모니터링~~ | **확정 → 3.21로 이동** |
| ~~6~~ | ~~D 실패 후 동작~~ | **확정 → 3.20으로 이동** |
| ~~7~~ | ~~superdaemon 재시작 제한~~ | **제외** — 오탐 가능성 큼, 전원 재시작으로 해결 가능 |

---

## 8. 기존 설치 스크립트 참고 (make_dom)

새 설치 스크립트는 기존 make_dom의 3개 스크립트를 기반으로 작성 예정:
- `install.sh` — Phase 1: 파티션, base install, chroot
- `setup_phase2.sh` — Phase 2: 첫 부팅 후 패키지 설치, 서비스 설정
- `setup_phase3.sh` — Phase 3: 구 DOM에서 설정/라이브러리 복사

### 기존 → 새 설계 변경점

| 항목 | 기존 (make_dom) | 새 설계 (recovery_dom) |
|------|----------------|----------------------|
| 부트로더 | systemd-boot | GRUB |
| EFI | 1개 | 2개 (이중화) |
| /boot | EFI 파티션 내 (FAT32) | 별도 ext4 파티션 2개 |
| root | 1개 (27.5GB) | 4개 (27.5GB x 4) |
| 파티션 수 | 3개 | 10개 |
| 파일시스템 | ext4 | ext4 (확정) |
| 복구 | 없음 | 자동 failover (A→B→C→D) |
| watchdog | 없음 | 필수 |
| SMART 모니터링 | 없음 | 필수 |
| health check | 없음 | DNVR PID 생존 확인 |
| /boot 보호 | 없음 | read-only 운영 |

---

## 9. CLI vs VS Code vs Desktop App 비교 (참고)

| | CLI (터미널) | VS Code 확장 | Desktop App |
|---|---|---|---|
| 렌더링 | 텍스트만 | 그래픽 채팅 패널 | 그래픽 채팅 UI |
| 한글 | 폰트/터미널 의존 | 잘 됨 | 잘 됨 |
| diff 보기 | 텍스트 | 시각적 side-by-side | 시각적 diff |
| 파일 첨부 | X | @ 멘션 | 이미지, PDF 가능 |
| 스크립팅 | O (--print, SDK) | X | X |
| MCP/Hooks/Skills | O | O | O |

핵심 엔진과 도구는 전부 동일. 차이는 UI/UX.
한글 + 테이블이 많은 설계 논의는 VS Code나 Desktop App이 편함.

### 세션 이어가기
직접 세션 이어받기 기능은 없음.
Desktop App에서 새 세션 열고 "design_discussion.md 를 읽고 이어서 미결정 사항을 논의하자" 로 시작하면 됨.
