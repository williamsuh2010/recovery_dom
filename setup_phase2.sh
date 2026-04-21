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

info "========== Phase 2 start =========="
info "$(date)"

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
    openssh x11vnc xfsprogs git xterm beep \
    ecryptfs-utils alsa-utils \
    fcitx5 fcitx5-hangul fcitx5-qt fcitx5-configtool \
    wget dnsutils smartmontools \
    net-tools inetutils ntfs-3g tcpdump \
    zeromq nlohmann-json cppzmq \
    mpv chromium
check "Package installation failed"

# ── Enable sshd ──
info "Enabling services..."
systemctl enable sshd

# ── Create directories ──
mkdir -p /root/tgt
mkdir -p /root/tgtdnvr
mkdir -p /var/lib/recovery

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

rm -rf /tmp/termite
rm -rf /home/${USER_NAME}/termite 2>/dev/null

# ── Remove sudo ──
pacman -R --noconfirm sudo || true

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

# ── Blacklist intel_oc_wdt (legacy /dev/watchdog must bind to iTCO_wdt) ──
# Kernel 6.19+ loads intel_oc_wdt as watchdog0; the app opens /dev/watchdog
# (misc 10:130) without magic-close, triggering hardware reset on app exit.
# Blacklisting makes iTCO_wdt the primary watchdog, matching prior devices.
cat > /etc/modprobe.d/blacklist-intel_oc_wdt.conf <<'WDTEOF'
blacklist intel_oc_wdt
WDTEOF

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
