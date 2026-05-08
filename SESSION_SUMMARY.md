# Recovery DOM 작업 세션 요약 (2026-04-10)

## 프로젝트 개요
NVR DOM SSD 열화 대응을 위한 GRUB 기반 4슬롯(A/B/C/D) 자동 복구 시스템.
128GB SSD에 10개 파티션(EFI x2, boot x2, swap, root x4).

## 이번 세션에서 수행한 작업

### 1. make_dom 변경사항 recovery_dom 반영
- `nvr.conf`: AWESOME_SNAPSHOT="2026/03/15" 추가
- `config/environment`: LD_LIBRARY_PATH=/root/tgtdnvr/lib 추가
- `enp1s0.yaml`: 새 파일 생성 (netplan 설정)
- `install.sh`: AWESOME_SNAPSHOT 미러 설정 추가
- `setup_phase2.sh`: 미러설정, ibus/netplan/rsync 패키지, netplan 복사, opendoas 제거
- `setup_phase3.sh`: 라이브러리를 /usr/lib 대신 /root/tgtdnvr/lib로 복사, ecryptfs 먼저 마운트
- `popup.sh`: make_dom에서 복사

### 2. 워치독 리부팅 문제 해결
- **문제**: Phase 2 실행 중/후 시스템 리부팅
- **원인**: RuntimeWatchdogSec=20이 하드웨어 워치독 활성화, nowayout 특성으로 비활성화 불가
- **해결**: configure.sh에서 RuntimeWatchdogSec=0으로 설정 (Phase 3 완료 후 20으로 변경)
- setup_phase2.sh에서 failover-success.service mask + boot_ok=1 선제 마킹

### 3. GRUB 설정 수정
- **grub-mkimage 실패**: --long-option 형식 + --prefix=/grub + 디버깅 출력 추가
- **`[` 명령 못 찾음**: `test` 모듈 누락 → 모듈 목록에 `test` 추가
- **grubenv not found**: `load_env -f /grub/grubenv`, `save_env -f /grub/grubenv` 명시적 경로
- **GRUB 문법 호환성**: `-z` 제거, `$var` 형식, `] ;` 공백, 기본값 선설정 후 load_env
- **boot_ok 초기값**: 0→1로 변경 (첫 부팅이 A슬롯에서 시작하도록)
- **boot 파티션 포맷**: ext4→ext2로 변경 (GRUB save_env 쓰기 호환성)

### 4. systemd Generator Sandbox 문제 해결 (가장 큰 이슈)
- **증상**: "Failed to fork off sandboxing environment for executing generators: Protocol error"
- **재현**: Phase 2 완료 후 리부팅 시 100% 재현, 10회 이상 재설치에서 동일
- **시도했지만 효과 없었던 것**:
  - SYSTEMD_SECCOMP=0 커널 파라미터
  - ManagerEnvironment=SYSTEMD_SECCOMP=0
  - 다른 AWESOME_SNAPSHOT 날짜 (02/15, 03/15)
- **해결**: generator 디렉토리를 비워서 sandbox 생성 자체를 회피
  - setup_phase2.sh 끝에서 모든 generator를 .bak으로 이동
  - swap-enable.service로 swap 수동 활성화
  - 네트워크는 systemd-networkd가 20-wired.network에서 직접 처리
  - NVR은 고정 구성이라 generator 없어도 문제 없음

### 5. rsync 누락 수정
- setup_phase2.sh 패키지 목록에 `rsync` 추가 (슬롯 클론에 필수)

### 6. sudo 제거 에러 숨김
- `pacman -R --noconfirm sudo` → `2>/dev/null` 추가

## 현재 파일 상태 (수정된 파일 목록)
- `nvr.conf` — AWESOME_SNAPSHOT 추가
- `install.sh` — AWESOME_SNAPSHOT 미러, boot 파티션 ext2
- `configure.sh` — GRUB 빌드/설정 전면 수정, 워치독 0, ManagerEnvironment, SECCOMP
- `setup_phase2.sh` — 미러, 패키지(ibus/netplan/rsync), failover 보호, generator 비활성화
- `setup_phase3.sh` — 라이브러리 /root/tgtdnvr/lib, ecryptfs 선마운트, failover 원복
- `config/environment` — LD_LIBRARY_PATH 추가
- `enp1s0.yaml` — 새 파일
- `popup.sh` — make_dom에서 복사
- `scripts/sync-root.sh` — 변경 없음 (pager 수정 원복됨)

## make_dom에 적용 필요한 항목
- generator sandbox 우회 (GENERATOR_SANDBOX_FIX.md 참조)
- setup_phase2.sh에 generator 비활성화 + swap-enable.service 코드 추가

## 미해결/보류 사항
- ecryptfs 마운트 확인 필요 (Phase 3 후 tgtdnvr 상태)
- 실제 DNVR 실행 확인은 구 DOM 연결 후 Phase 3 완료 필요
- post-dd-uuid-regen.sh 실 테스트 미완

## 핵심 설계 규칙 (메모리)
- 기존 make_dom 스크립트 수정 금지 (참고만)
- fail/ 사진 날짜는 서로 다른 DOM의 독립 사례
- DNVR 소스에 upgrade_sync_d 플래그 생성 코드 추가 필요

---

# Recovery DOM 추가 작업 메모 (2026-04-24)

## 이번 세션에서 실제로 한 일

### 1. TTA 로컬 콘솔 차단 로직 추가 및 커밋
- `nvr.conf`에 아래 옵션 추가
  - `TTA_CERTIFICATION`
  - `TTA_CERTIFICATION_DEBUG`
- `setup_phase2.sh`에 아래 로직 추가
  - Xorg `DontVTSwitch=true`
  - `tty2~tty6` getty disable/mask
  - `autovt@.service` mask
  - TTA 최종 모드에서 sshd disable/mask
  - TTA 최종 모드에서 터미널 패키지 제거
- 커밋:
  - `5bc554a` `TTA 설치 시 로컬 콘솔 차단 추가`

### 2. 문서/스크립트 작업 파일 커밋
- 커밋:
  - `ed03a0f` `문서 및 스크립트 작업 파일 추가`
- 포함 파일:
  - `GENERATOR_SANDBOX_FIX.md`
  - `SESSION_SUMMARY.md`
  - `chat_history.txt`
  - `popup.sh`
  - `configure.sh`
  - `install.sh`
  - `setup_phase3.sh`

### 3. 환경/네트워크 설정 파일 커밋
- 커밋:
  - `5da5d50` `환경 및 네트워크 설정 파일 추가`
- 포함 파일:
  - `config/environment`
  - `enp1s0.yaml`

### 4. TTA_DEBUG 모드 동작 수정 (현재 미커밋)
- 배경:
  - `TTA_CERTIFICATION=1`, `TTA_CERTIFICATION_DEBUG=1`에서도
    xterm/termite를 막아버려 디버깅 경로가 사라짐
- 수정 내용:
  - `TTA_CERTIFICATION=1 && TTA_CERTIFICATION_DEBUG=1`
    - `xterm` 설치 유지
    - `termite` 빌드 유지
    - 터미널 패키지 제거하지 않음
    - sshd 유지
  - `TTA_CERTIFICATION=1 && TTA_CERTIFICATION_DEBUG=0`
    - 기존처럼 터미널 미설치/제거 + sshd 차단
- 현재 상태:
  - `setup_phase2.sh` 수정 완료
  - bash 문법 검사 통과
  - 아직 커밋 안 함

## 현재 작업트리 상태
- 수정됨:
  - `setup_phase2.sh`
    - DEBUG 모드에서 xterm/termite 허용하도록 수정됨
- 미추적:
  - `.claude/`
  - `IMG_5638.JPG`
  - `IMG_5642.JPG`
  - `IMG_5643.JPG`
  - `IMG_5646.JPG`
  - `IMG_5652.JPG`
  - `IMG_5653.JPG`
  - `IMG_5654.JPG`
  - `fail/`

## 중요 메모
- recovery_dom도 make_dom과 동일한 TTA 정책으로 맞춰졌고,
  현재는 DEBUG 모드에서 로컬 터미널을 허용하도록 추가 수정된 상태
- 아직 이 DEBUG 허용 수정은 커밋되지 않았음

## 다음 세션 시작 시 바로 할 일
1. `recovery_dom/setup_phase2.sh` DEBUG 모드 수정 커밋
2. make_dom과 recovery_dom의 DEBUG 정책이 완전히 동일한지 재확인
3. 필요하면 실제 장비 복구 절차와 테스트 절차 정리

---

# DNVR Atomic Upgrade 세션 (2026-04-27 ~ 2026-04-28)

> 본 세션의 주 작업은 recovery_dom이 아닌 **DNVR 앱(c:/dnvr2)** 의 업그레이드 메커니즘 개선이었습니다.
> 해당 코드는 자체 SVN으로 관리되므로 이 git 저장소에는 변경분이 없으며, 본 항목은 컨텍스트 보존용입니다.

## 1. 배경 (recovery_dom 관점)
- recovery_dom의 GRUB 4-슬롯 페일오버 = **시스템 레벨** 복구
- DNVR 앱의 atomic 업데이트 = **앱 레벨** 무결성 (TTA 6.1.3)
- 두 시스템은 직교: recovery_dom은 root_D 슬롯에 DNVR 업그레이드 후 sync, DNVR atomic은 동일 슬롯 내 v_<ts>/ 폴더 사이 symlink 교체

## 2. 수행한 작업 요약 (c:/dnvr2 SVN)

### 진단
라이브 디바이스(192.168.0.28) SSH 조사로 `TStorageInit::InstallUpdate`의 결함 확인:
1. `tgtSystem` 리턴값 검사 무력화 (실패가 항상 "성공"으로 로깅)
2. `/etc/` 파일이 atomic switch 이전에 덮어쓰여 atomic 깨짐
3. 옛 `v_*` 폴더 무한 누적
4. `tgtmnt` 갱신 경로 끊김 (TTA 단계엔 의도된 상태로 확인)

### 수정
- **헬퍼 매크로**: `IUD_LOG`, `IUD_RUN_CHECKED`, `IUD_RUN_BEST`, `IUD_LOG_RESET`
- **명령 카테고리화**: CHECKED(중단) vs BEST(무시)
- **Step 5 제거**: `/etc/` 복사 → 부팅 시 `dnvr-apply-config.sh`가 self-heal
- **Step 6b 추가**: 회전 (KEEP_VERSION_COUNT=1, symlink 기반 → 다운그레이드 안전)
- **apply-config.sh 신규**: 2개 위치(`apps/D100_UP/`, `tgtdnvr/`)
- **errno 정리**: stale errno noise 제거
- **두 파일 분리 로그 모델**: `install_update_debug.log`(C++) + `apply_config_debug.log`(bash) — 자동 재부팅 후에도 둘 다 보존

### 라이브 검증
- 업그레이드 + 자동 재부팅 + idempotent 부팅 apply 정상
- KEEP=1 회전: v_1777349962 삭제, v_1777350763 보존 확인
- 실행 권한 보존 이슈 발견 → 사용자가 SVN에 chmod+x 비트 포함 수동 커밋

## 3. 관련 파일 (c:/dnvr2 SVN, 본 git에 없음)
| 파일 | 변경 |
|---|---|
| `c:/dnvr2/app/dnvr.pro` | `INSTALL_UPDATE_DEBUG` 매크로 (`use_tta` 블록) |
| `c:/dnvr2/app/source/process/TStorageInit.cpp` | `InstallUpdate` atomic 블록 전면 재작성 |
| `c:/dnvr2/apps/D100_UP/dnvr-apply-config.sh` | 신규 — 부팅 시 self-heal |
| `c:/dnvr2/tgtdnvr/dnvr-apply-config.sh` | 신규 — 동일 사본 |
| `c:/dnvr2/utils/dnvr-apply-config/DEPLOY.md` | 배포 가이드 |
| `c:/dnvr2/utils/dnvr-apply-config/SESSION_NOTES.md` | 작업기록 (상세) |

## 4. 본 git 저장소 변경 (이번 세션)
- `.gitignore` 신규 (IMG, fail/, .claude/settings.* 무시)
- `.claude/settings.local.json` untracked
- 본 SESSION_SUMMARY.md에 본 항목 추가

## 5. 후속 변경 (2026-04-28 ~ 2026-05-08)

### 5.1 sync-root 타이머에서 `Persistent=true` 제거 (2026-04-28, 커밋 `1591a82`)
- **이유**: 점검 등으로 시스템이 꺼져 있어 예약 시각을 놓친 경우, 부팅 직후 즉시 rsync 실행 → DNVR 초기화 + health check 10분 윈도우의 디스크 I/O와 충돌 → boot_ok 미마킹 위험.
- **결과**: 놓친 회차는 그냥 건너뛰고 다음 정상 스케줄(일요일 03:00 / 매월 1일 04:00)에 수행.
- **적용 파일**: `config/sync-root-b.timer`, `config/sync-root-c.timer`
- **이미 설치된 DOM에 적용하려면**: 두 .timer 파일 복사 후 `systemctl daemon-reload && systemctl restart sync-root-{b,c}.timer` 필요.

### 5.2 Dashboard Node 옵션 추가 (사용자 직접 커밋 `774432d`)
- `setup_phase2.sh`에 `install_dashboard_node_support()` 함수 추가
- `ENABLE_DASHBOARD_NODE=1`일 때 docker / docker-compose / curl 설치 + `nvr-dashboard-node.service` 생성
- 활성화 시 사용자가 `${DASHBOARD_NODE_DIR:-/opt/nvr-dashboard}`에 프로젝트 파일 복사 후 enable

### 5.3 TTA 콘솔 락다운 함수 정리 (사용자 직접)
- `apply_tta_console_lockdown()` 함수로 분리
- DontVTSwitch / DontZap, NAutoVTs=1 / ReserveVT=1, getty@tty2~6 disable+mask, autovt@.service mask
- TTA debug=1: 로컬 터미널/sshd 유지
- TTA debug=0: 터미널 패키지 제거 + sshd disable+mask

## 6. 다음 세션 시작 가이드

### 6.1 빠른 컨텍스트 복원 (대화 시작 시)
```
SESSION_SUMMARY.md 읽고 컨텍스트 파악해줘
```
이 한 줄로 두 git 저장소(recovery_dom, make_dom) 작업 흐름을 모두 받음.

### 6.2 DNVR atomic 후속 작업 시 우선 읽을 문서
1. `c:/dnvr2/utils/dnvr-apply-config/SESSION_NOTES.md` — 왜 / 어떻게 (설계 결정 배경)
2. `c:/dnvr2/utils/dnvr-apply-config/DEPLOY.md` — 어떻게 배포/사용
3. (필요 시) `c:/dnvr2/app/source/process/TStorageInit.cpp` 의 `InstallUpdate` 함수 (atomic 블록)

### 6.3 디바이스 접속 정보
- IP: `192.168.0.28`
- user: `tgt` / pw: `1q2w3e4r!Q` / sudo passwordless
- 빌드: TTA_CERTIFICATION + INSTALL_UPDATE_DEBUG
- 상태: tgtmnt2 수동 배치 (`/bin/tgtmnt2` = 새 빌드, `/bin/tgtmnt` = 옛 데드 코드)
- 로그 파일 (재부팅 후에도 유지):
  - `/root/install_update_debug.log` — 마지막 업그레이드
  - `/root/apply_config_debug.log` — 마지막 부팅 apply

### 6.4 운영 점검 명령 (한 번에 둘 다 보기)
```bash
ssh tgt@192.168.0.28 'sudo bash -c "
  echo === UPGRADE ===; cat /root/install_update_debug.log
  echo === BOOT APPLY ===; cat /root/apply_config_debug.log
  echo === STATE ===
  echo current=\$(readlink /root/tgt_dec/current)
  ls /root/tgt_dec/ | grep -E \"^v_|current\"
"'
```

### 6.5 미해결/대기 항목
- DNVR 소스에 `/var/lib/recovery/upgrade_sync_d` 플래그 생성 코드 추가 (root_D 갱신 트리거, 메모 기록됨)
- 일반 버전(non-TTA) 적용 시 `tgtmnt` 갱신 경로 활성화 — 현재는 의도된 데드 코드
- 두 .sh 사본(apply-config) 동기화 자동화 — 현재 수동 (필요 시 빌드 스크립트 도입 검토)

### 6.6 git 저장소 위치
| 저장소 | 위치 | 원격 |
|---|---|---|
| recovery_dom | `e:/claude-code/dome_install/recovery_dom/` | https://github.com/williamsuh2010/recovery_dom.git |
| make_dom | `e:/claude-code/dome_install/make_dom/` | https://github.com/williamsuh2010/make_dom.git |
| **c:/dnvr2** | `c:/dnvr2/` | **자체 SVN** — git 명령 제안 금지 |
