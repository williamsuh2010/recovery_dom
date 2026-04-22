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
