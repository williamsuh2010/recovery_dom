# systemd Generator Sandbox 문제 및 해결

## 증상
- 설치 후 리부팅 시 매번 동일 에러 발생:
  ```
  systemd[1]: Failed to fork off sandboxing environment for executing generators: Protocol error
  Failed to start up manager: Freezing execution.
  ```
- Phase 2까지는 정상 부팅, 이후 리부팅부터 100% 재현
- SYSTEMD_SECCOMP=0 (커널 파라미터, ManagerEnvironment 모두) 효과 없음

## 원인
- systemd가 generator 실행 시 sandbox(namespace + seccomp) 환경을 생성하려 함
- 특정 하드웨어(NVR)에서 clone(CLONE_NEWNS) 또는 seccomp 설정 시 EPROTO 반환
- seccomp만 비활성화해도 namespace 생성 자체가 실패하여 해결 안 됨
- Phase 2의 첫 부팅은 Phase 2 서비스가 실행되면서 정상 동작하지만, 이후 부팅에서 실패

## 해결 방법
generator 디렉토리를 비우면 systemd가 sandbox 생성을 시도하지 않음.

### 1. setup_phase2.sh 끝부분에 추가 (Phase 2 서비스 disable 직전):
```bash
# ── Disable systemd generators (sandbox Protocol error 우회) ──
info "Disabling systemd generators (sandbox compatibility)..."
mkdir -p /usr/lib/systemd/system-generators.bak
mv /usr/lib/systemd/system-generators/* /usr/lib/systemd/system-generators.bak/ 2>/dev/null || true
info "Generators moved to system-generators.bak/"

# fstab-generator 없이 swap을 활성화하는 서비스 생성
info "Creating static swap service..."
cat > /etc/systemd/system/swap-enable.service <<'SWAPEOF'
[Unit]
Description=Enable swap partitions
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/sbin/swapon -a
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SWAPEOF
systemctl enable swap-enable.service
```

### 2. NVR 환경에서 generator 없이 동작하는 이유
| 기능 | generator | 대체 수단 |
|------|-----------|----------|
| fstab 마운트 | systemd-fstab-generator | root: 커널 cmdline, swap: swap-enable.service, boot: noauto |
| 네트워크 | netplan generator | netplan-generate.service (부팅 시 `netplan generate` 실행) |
| 콘솔 로그인 | systemd-getty-generator | autologin 설정 (getty@tty1.service.d/) |
| 기타 | cryptsetup, tpm2, verity 등 | NVR에서 사용 안 함 |

### 2-1. netplan 유지 이유

DNVR 앱(ipconfig.cpp)이 `/etc/netplan/*.yaml` 생성 + `netplan apply` 호출로 네트워크 설정.
generator 대신 `netplan-generate.service`가 부팅 시 `netplan generate`를 실행하여 networkd 설정 파일 생성.
런타임 `netplan apply`는 generator가 아닌 CLI 직접 호출이므로 sandbox 무관.

### 3. configure.sh에도 추가된 보험 설정 (효과는 없었지만 유지):
```bash
# /etc/systemd/system.conf.d/no-sandbox.conf
[Manager]
ManagerEnvironment=SYSTEMD_SECCOMP=0
```

```
# grub.cfg 커널 파라미터
linux /vmlinuz-linux root=UUID=... rw panic=10 systemd.setenv=SYSTEMD_SECCOMP=0
```

## make_dom 적용 시
make_dom의 setup_phase2.sh 끝부분(nvr-setup.service disable 직전)에 동일한 코드 추가.
단, make_dom에는 recovery_dom 전용 코드(failover, watchdog 등)는 불필요.
