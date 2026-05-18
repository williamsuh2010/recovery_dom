# Recovery DOM 스크립트 레퍼런스

설치 단계 / 운영자 도구 / 자동 실행 세 그룹.
운영자가 직접 입력하는 명령은 모두 `/usr/local/sbin/` 에 설치됨 (PATH 안).

---

## 1. 설치 단계 (한 번씩 순서대로)

| 스크립트 | 위치 | 실행 시점 | 역할 |
|---|---|---|---|
| `install.sh` | Arch live USB | Phase 1, 사용자 직접 | 디스크 파티셔닝 + base 시스템 + chroot 에서 configure.sh 호출 |
| `configure.sh` | live USB → chroot | Phase 1, install.sh 가 자동 호출 | GRUB 빌드 + failover 인프라 + 마커 파일 생성 |
| `setup_phase2.sh` | 새 시스템 | Phase 2, 첫 부팅 nvr-setup.service 가 자동 실행 | 패키지 설치 + netplan + tgtmnt2 binary 배치 |
| `setup_phase3.sh` | 새 시스템 | Phase 3, 옛 DOM 꽂고 사용자 직접 | 옛 DOM 데이터 이관 + ecryptfs + 슬롯 클론 + install_mode 활성화 |

`post-dd-uuid-regen.sh` 는 dd 클론 시나리오 전용 — install 본 흐름과 별도.

---

## 2. 운영자 도구 (수동 호출, `/usr/local/sbin/`)

### 2.1 설치 마무리 / 작업 보호

#### `finalize-install.sh`
**용도**: 초기 설치 완료 → 슬롯 페일오버 활성화 (production 진입).
Phase 3 가 자동 생성한 `install_mode` 플래그 제거.
```bash
finalize-install.sh
```
모든 앱 설치/검증 끝나면 1회 실행. 호출 후 다음 부팅부터 정상 페일오버 동작.

#### `enter-maintenance.sh "사유"`
**용도**: 운영 중 일시 작업 보호 (DNVR 종료/재시작 등). 24h 자동 만료.
```bash
enter-maintenance.sh "DNVR config 변경"
# ... 작업 ...
exit-maintenance.sh
```

#### `exit-maintenance.sh`
**용도**: maintenance 모드 해제, 정상 페일오버 복귀.
```bash
exit-maintenance.sh
```

#### `mark-installed.sh`
**용도**: 다음 **1회 reboot 만** 슬롯 advance 방지. 위 둘로 커버 안 되는 단발 케이스용.
```bash
mark-installed.sh
reboot
```

### 2.2 슬롯 조작

#### `switch-slot.sh A|B|C|D`
**용도**: 다음 부팅 시 지정 슬롯으로 전환.
```bash
switch-slot.sh B    # 다음 reboot 후 slot B 부팅
```

#### `sync-all-slots.sh`
**용도**: 현재 슬롯의 `/` 를 B + C + D 전부에 rsync.
```bash
sync-all-slots.sh
```
주간/월간 timer 안 기다리고 즉시 propagate 필요할 때.

#### `sync-root.sh B|C|D`
**용도**: 단일 슬롯 rsync (`sync-all-slots.sh` 의 단위 동작).
```bash
sync-root.sh B
```
시스템 자동 호출됨 (sync-root-b.timer 매주 일 03:00, sync-root-c.timer 매월 1일 04:00). 수동도 가능.

#### `sync-config.sh [B|C|D]`
**용도**: `/tgtdvr/Config.ini` + `Config_TEMP.ini` 만 빠르게 atomic 복사. 매 부팅 boot_ok=1 마킹 시 자동 호출됨.
```bash
sync-config.sh         # B, C, D 전부 (현재 슬롯 제외)
sync-config.sh B       # B 만
```
설정 변경 직후 즉시 propagate 하고 싶을 때.

### 2.3 dd 클론

#### `post-dd-uuid-regen.sh`
**용도**: 마스터 이미지를 dd 로 새 DOM 에 복제 후 UUID 재생성 + GRUB 재빌드.
```bash
post-dd-uuid-regen.sh
```
복제 직후 1회만 실행. 모든 파티션 UUID 새로 생성, `slot-uuids.conf` / fstab / grub.cfg / EFI 갱신.

---

## 3. 자동 실행 (시스템이 호출)

| 스크립트 | 트리거 | 동작 |
|---|---|---|
| `failover-preboot.sh` | failover-prepare.service (부팅 직후) | `/proc/cmdline` UUID → 슬롯 식별 → `/var/log/failover.log` 기록 |
| `failover-success.sh` | failover-success.service (multi-user 도달 후 10분 sleep) | install_mode/maintenance_mode 검사, 없으면 DNVR PID sampling 10분, 성공 시 boot_ok=1 마킹 |
| `sync-root.sh B` | sync-root-b.timer (매주 일 03:00) | 슬롯 B 전체 rsync |
| `sync-root.sh C` | sync-root-c.timer (매월 1일 04:00) | 슬롯 C 전체 rsync |
| `upgrade-sync-d.sh` | failover-success.sh 끝에서 호출 | `/var/lib/recovery/upgrade_sync_d` 플래그 있으면 슬롯 D 동기화 + 플래그 제거 |
| `sync-config.sh` | failover-success.sh 의 boot_ok 마킹 직후 | B/C/D 에 Config 파일 atomic propagation |
| `check-smart.sh` | check-smart.timer (매일 04:00) | `smartctl -H` 실행, FAILED 시 `/tmp/smart_failed` 플래그 생성 |

---

## 4. 자주 쓰는 시나리오

### 신규 NVR 출고
```bash
# (Arch live USB 부팅 후)
bash /path/to/recovery_dom/install.sh
# → reboot → Phase 2 자동 → 옛 DOM 꽂고:
bash /root/recovery_dom/setup_phase3.sh
# → reboot → DNVR 앱 설치/설정/검증 (install_mode 덕에 슬롯 보호됨)
# 모두 완료:
finalize-install.sh
```

### DNVR 설정 변경 후 즉시 백업 슬롯에도 반영
```bash
# (DNVR GUI 에서 설정 저장 후)
sync-config.sh
```

### 일시적으로 DNVR 멈추고 작업
```bash
enter-maintenance.sh "라이브러리 디버깅"
# 작업 ...
exit-maintenance.sh
```

### 슬롯 강제 전환 (테스트 / 의심)
```bash
switch-slot.sh B
reboot
```

### 마스터 이미지 복제로 새 DOM 만들기
```bash
# 마스터에서 dd 로 이미지 추출 (별도 도구)
# 새 DOM 에 dd 로 복원
# 새 DOM 부팅 후 1회:
post-dd-uuid-regen.sh
```

---

## 5. 상태 확인 명령 (스크립트 아님, 참고)

```bash
# 현재 슬롯
tail -1 /var/log/failover.log

# grubenv 상태 (boot_try, boot_ok, retry_round)
mount /boot && grub-editenv /boot/grub/grubenv list && umount /boot

# 현재 모드 (install/maintenance/production)
[ -f /etc/recovery/install_mode ] && echo "INSTALL MODE" || \
  ([ -f /etc/recovery/maintenance_mode ] && echo "MAINTENANCE MODE" || echo "production")

# 워치독 활성 여부
wdctl

# SMART 상태
smartctl -H "$(lsblk -rpno PKNAME "$(awk '$2=="/" {print $1}' /proc/mounts)")"

# failover 이력
tail -30 /var/log/failover.log
```

---

## 6. 모드 표 (state machine)

| 플래그 | 만료 | 진입 | 해제 | 페일오버 |
|---|---|---|---|---|
| install_mode | 없음 | Phase 3 자동 | `finalize-install.sh` | 비활성 |
| maintenance_mode | 24h 자동 | `enter-maintenance.sh` | `exit-maintenance.sh` 또는 24h | 비활성 |
| (둘 다 없음) | — | — | — | **활성** (DNVR 검증) |

`install_mode` 가 `maintenance_mode` 보다 우선순위 높음 — 둘 다 있어도 install_mode 로 동작.
