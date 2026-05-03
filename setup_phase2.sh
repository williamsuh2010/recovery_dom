#!/bin/bash

source /root/recovery_dom/nvr.conf

LOGFILE="/tmp/phase2.log"
exec > >(tee -a "$LOGFILE") 2>&1

set -uo pipefail

info()  { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
check() {
    if [ $? -ne 0 ]; then
        error "$1"
        error "Fix the issue and re-run: bash /root/recovery_dom/setup_phase2.sh"
        exit 1
    fi
}
is_enabled() {
    case "${1:-0}" in
        1|yes|true|on|YES|TRUE|ON) return 0 ;;
        *) return 1 ;;
    esac
}
apply_tta_console_lockdown() {
    if ! is_enabled "${TTA_CERTIFICATION:-0}"; then
        return
    fi

    info "Applying TTA local console lockdown..."

    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-tta-serverflags.conf <<'EOF'
Section "ServerFlags"
    Option "DontVTSwitch" "true"
    Option "DontZap" "true"
EndSection
EOF

    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/10-tta-console-lockdown.conf <<'EOF'
[Login]
NAutoVTs=1
ReserveVT=1
EOF

    for tty in 2 3 4 5 6; do
        systemctl disable "getty@tty${tty}.service" 2>/dev/null || true
        systemctl mask "getty@tty${tty}.service" 2>/dev/null || true
    done
    systemctl mask autovt@.service 2>/dev/null || true

    if is_enabled "${TTA_CERTIFICATION_DEBUG:-0}"; then
        info "TTA debug mode: sshd and local terminal packages remain enabled for verification."
    else
        for pkg in termite xterm alacritty foot konsole gnome-terminal xfce4-terminal; do
            pacman -Rns --noconfirm "$pkg" 2>/dev/null || true
        done
        systemctl disable --now sshd 2>/dev/null || true
        systemctl mask sshd 2>/dev/null || true
        info "TTA final mode: sshd and local terminal packages disabled."
    fi
}
install_dashboard_node_support() {
    if ! is_enabled "${ENABLE_DASHBOARD_NODE:-0}"; then
        return
    fi

    info "Installing Dashboard Node support..."
    pacman -S --noconfirm --needed docker docker-compose curl
    check "Dashboard Node package installation failed"

    systemctl enable docker

    mkdir -p "${DASHBOARD_NODE_DIR:-/opt/nvr-dashboard}"
    mkdir -p /var/lib/nvr-dashboard
    mkdir -p /var/log/nvr-dashboard

    cat > /etc/systemd/system/nvr-dashboard-node.service <<EOF
[Unit]
Description=NVR Dashboard Node Stack
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
WorkingDirectory=${DASHBOARD_NODE_DIR:-/opt/nvr-dashboard}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    info "Dashboard Node support installed."
    info "Copy dashboard project files to ${DASHBOARD_NODE_DIR:-/opt/nvr-dashboard}"
    info "Enable after files are ready: systemctl enable --now nvr-dashboard-node.service"
}

info "========== Phase 2 start =========="
info "$(date)"

TERMINAL_PACKAGES="xterm"
if is_enabled "${TTA_CERTIFICATION:-0}" && ! is_enabled "${TTA_CERTIFICATION_DEBUG:-0}"; then
    TERMINAL_PACKAGES=""
    info "TTA final mode: terminal packages will not be installed."
elif is_enabled "${TTA_CERTIFICATION:-0}" && is_enabled "${TTA_CERTIFICATION_DEBUG:-0}"; then
    info "TTA debug mode: xterm will be installed and termite will be built."
fi

# ── Disable failover during installation ──
# Phase 2/3 중에는 DNVR이 없으므로 failover health check가 동작하면 안 됨
# 워치독은 configure.sh에서 이미 RuntimeWatchdogSec=0으로 설정됨 (Phase 3에서 활성화)
info "Disabling failover services during installation..."
systemctl stop failover-success.service 2>/dev/null || true
systemctl mask failover-success.service 2>/dev/null || true

# GRUB boot_ok=1 선제 마킹 (만약의 재부팅 시 슬롯 전환 방지)
info "Pre-marking boot_ok=1 to prevent slot switch..."
mount /boot 2>/dev/null || true
if [ -f /boot/grub/grubenv ]; then
    grub-editenv /boot/grub/grubenv set boot_ok=1
    info "boot_ok=1 set"
fi
umount /boot 2>/dev/null || true

# ── Wait for network ──
info "Waiting for network (up to 5 min)..."
NETWORK_OK=0
for i in $(seq 1 150); do
    if ping -c 1 -W 1 ${DNS1} > /dev/null 2>&1; then
        info "Network connected (attempt $i)"
        NETWORK_OK=1
        break
    fi
    sleep 2
done
if [ "$NETWORK_OK" -ne 1 ]; then
    error "Network connection failed after 5 min"
    error "Login as root and run manually:"
    error "  bash /root/recovery_dom/setup_phase2.sh"
    exit 1
fi

# ── DNS ──
info "Setting DNS servers..."
cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF

# ── Verify DNS ──
info "Verifying DNS resolution..."
for i in $(seq 1 10); do
    if ping -c 1 -W 2 archlinux.org > /dev/null 2>&1; then
        info "DNS resolution OK"
        break
    fi
    sleep 2
done
ping -c 1 -W 2 archlinux.org > /dev/null 2>&1 || {
    error "DNS resolution failed. Check /etc/resolv.conf"
    error "Login as root and run manually:"
    error "  bash /root/recovery_dom/setup_phase2.sh"
    exit 1
}

# ── Set Arch archive snapshot mirror (freeze package versions) ──
if [ -n "${AWESOME_SNAPSHOT}" ]; then
    info "Using Arch archive snapshot: ${AWESOME_SNAPSHOT}"
    echo "Server = https://archive.archlinux.org/repos/${AWESOME_SNAPSHOT}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
    pacman -Syy --noconfirm
fi

# ── System update + install packages ──
info "Updating system and installing packages... (10~20 min)"
pacman -Syu --noconfirm
check "System update (pacman -Syu) failed"

pacman -S --noconfirm --needed \
    xorg-server xorg-xinit awesome \
    libva intel-media-driver libva-intel-driver \
    vlc opencv xorg-xrandr \
    qt5 \
    terminus-font noto-fonts-cjk ttf-dejavu \
    openssh x11vnc xfsprogs git ${TERMINAL_PACKAGES} beep rsync \
    ecryptfs-utils alsa-utils \
    ibus \
    fcitx5 fcitx5-hangul fcitx5-qt fcitx5-configtool \
    wget dnsutils smartmontools \
    net-tools inetutils ntfs-3g tcpdump netplan \
    zeromq nlohmann-json cppzmq \
    mpv chromium
check "Package installation failed"

install_dashboard_node_support

# ── Enable sshd ──
info "Enabling services..."
systemctl enable sshd

# ── Create directories ──
mkdir -p /root/tgt
mkdir -p /root/tgtdnvr
mkdir -p /var/lib/recovery

# ── netplan setup ──
info "Setting up netplan..."
mkdir -p /etc/netplan
cp /root/recovery_dom/enp1s0.yaml /etc/netplan/
check "netplan config copy failed"

# configure.sh에서 만든 20-wired.network 제거 (netplan과 충돌 방지)
# 이후 네트워크는 netplan이 관리
rm -f /etc/systemd/network/20-wired.network
info "Removed 20-wired.network (netplan takes over)"

# ── ecryptfs sig-cache ──
mkdir -p /root/.ecryptfs
echo "${ECRYPTFS_SIG}" > /root/.ecryptfs/sig-cache.txt
info "ecryptfs sig-cache pre-registered: ${ECRYPTFS_SIG}"

# ── Autologin ──
info "Setting up root autologin..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# ── Environment (fcitx) ──
cp /root/recovery_dom/config/environment /etc/environment
check "environment file copy failed"

# ── Install OpenSSL 1.1 ──
info "Installing OpenSSL 1.1 compat library..."
cd /root/recovery_dom/openssl
if [ -f openssl-1.1-1.1.1.w-1-x86_64.pkg.tar.zst ]; then
    unzstd -f openssl-1.1-1.1.1.w-1-x86_64.pkg.tar.zst
    tar -xf openssl-1.1-1.1.1.w-1-x86_64.pkg.tar
    cp -f usr/lib/libcrypto.so.1.1 /usr/lib/libcrypto.so.1.1
    cp -f usr/lib/libssl.so.1.1 /usr/lib/libssl.so.1.1
    rm -rf usr openssl-1.1-1.1.1.w-1-x86_64.pkg.tar
    check "OpenSSL 1.1 install failed"
else
    warn "OpenSSL 1.1 package not found, skipping"
fi
cd /root

# ── ulimit ──
info "Setting ulimit..."
if ! grep -q "pam_limits.so" /etc/pam.d/su; then
    echo "session    required   pam_limits.so" >> /etc/pam.d/su
fi

if is_enabled "${TTA_CERTIFICATION:-0}" && ! is_enabled "${TTA_CERTIFICATION_DEBUG:-0}"; then
    info "TTA final mode: skipping termite terminal build."
else
    # ── Build termite from AUR ──
    info "Building termite from AUR..."
    pacman -S --noconfirm --needed vte-common vte3 gtk3 pcre2
    check "termite dependency install failed"

    sed -i 's/^%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

    info "Importing GPG key for termite..."
    su - ${USER_NAME} -c "gpg --keyserver keyserver.ubuntu.com --recv-keys 91C559DBE4C9123B" || warn "GPG key import failed, continuing..."

    su - ${USER_NAME} -c "
        cd /tmp
        git clone https://aur.archlinux.org/termite.git
        cd termite
        makepkg -sic --noconfirm
    "
    if ! command -v termite > /dev/null 2>&1; then
        error "termite build FAILED. Terminal will not work without termite."
        error "Fix the issue and re-run: bash /root/recovery_dom/setup_phase2.sh"
        exit 1
    fi
    info "termite installed successfully"
fi

rm -rf /tmp/termite
rm -rf /home/${USER_NAME}/termite 2>/dev/null

# ── Remove sudo and dependencies (not needed in production) ──
pacman -Rns --noconfirm opendoas 2>/dev/null || true
pacman -R --noconfirm sudo 2>/dev/null || true

# ── Verify failover scripts are installed ──
info "Verifying failover scripts..."
for script in failover-preboot.sh failover-success.sh sync-root.sh upgrade-sync-d.sh check-smart.sh switch-slot.sh; do
    [ -f "/usr/local/sbin/$script" ] || warn "$script missing from /usr/local/sbin/"
done

# ── Verify services are enabled ──
info "Verifying services..."
systemctl is-enabled failover-prepare.service || warn "failover-prepare.service not enabled"
systemctl is-enabled failover-success.service || warn "failover-success.service not enabled"
systemctl is-enabled sync-root-b.timer || warn "sync-root-b.timer not enabled"
systemctl is-enabled sync-root-c.timer || warn "sync-root-c.timer not enabled"
systemctl is-enabled check-smart.timer || warn "check-smart.timer not enabled"

# ── NOTE: 워치독/failover 원복은 Phase 3(setup_phase3.sh) 완료 후에 수행 ──
# Phase 2에서는 boot_ok=1, 워치독=0, failover masked 상태를 유지
# Phase 3에서 슬롯 클론 완료 후 원복함

# ── Disable systemd generators (sandbox Protocol error 우회) ──
# generator sandbox 생성 시 EPROTO 발생하는 하드웨어 호환성 문제 대응
# generator가 없으면 systemd가 sandbox를 시도하지 않음
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

# netplan generator 없이 netplan을 서비스로 실행
# DNVR 앱이 /etc/netplan/*.yaml 생성 + netplan apply 호출하므로 netplan 유지 필수
info "Creating netplan-generate service..."
cat > /etc/systemd/system/netplan-generate.service <<'NPEOF'
[Unit]
Description=Generate networkd config from netplan
DefaultDependencies=no
Before=systemd-networkd.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/netplan generate
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NPEOF
systemctl enable netplan-generate.service

# ── Blacklist intel_oc_wdt (legacy /dev/watchdog must bind to iTCO_wdt) ──
# Kernel 6.19+ loads intel_oc_wdt as watchdog0; the app opens /dev/watchdog
# (misc 10:130) without magic-close, triggering hardware reset on app exit.
# Blacklisting makes iTCO_wdt the primary watchdog, matching prior devices.
cat > /etc/modprobe.d/blacklist-intel_oc_wdt.conf <<'WDTEOF'
blacklist intel_oc_wdt
WDTEOF

apply_tta_console_lockdown

# ── Disable Phase 2 service ──
systemctl disable nvr-setup.service

# ── Done ──
info "=========================================="
info " Phase 2 complete!"
info " Plug in the old DOM USB and run:"
info " /root/recovery_dom/setup_phase3.sh"
info "=========================================="

for i in 1 2 3; do
    beep -f 1000 -l 300 2>/dev/null || true
    sleep 0.5
done
