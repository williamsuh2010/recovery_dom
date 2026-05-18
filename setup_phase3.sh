#!/bin/bash
set -uo pipefail

source /root/recovery_dom/nvr.conf

info()  { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }
check() {
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31m[FAIL]\033[0m $1"
        read -p "Continue anyway? (yes/no): " ans
        [ "$ans" = "yes" ] || exit 1
    fi
}

# ── Log ──
LOGFILE="/tmp/phase3.log"
exec > >(tee -a "$LOGFILE") 2>&1

info "========== Phase 3 start =========="
info "$(date)"

# ── Detect old DOM ──
detect_old_dom() {
    local root_dev root_disk

    root_dev=$(awk '$2=="/" {print $1}' /proc/mounts | tail -1)
    root_disk=$(lsblk -rpno PKNAME "$root_dev" 2>/dev/null | head -1)
    info "Current root: ${root_dev} (disk: ${root_disk})" >&2

    info "--- lsblk full output ---" >&2
    lsblk -o NAME,TYPE,FSTYPE,SIZE >&2 2>&1
    info "--- end lsblk ---" >&2

    local parts=( $(lsblk -rpno NAME,TYPE | awk '$2=="part" {print $1}') )
    info "All partitions found: ${parts[*]}" >&2

    for part in "${parts[@]}"; do
        local disk fstype
        disk=$(lsblk -rpno PKNAME "$part" 2>/dev/null | head -1)
        fstype=$(lsblk -rpno FSTYPE "$part" 2>/dev/null | head -1)
        info "  Checking: ${part} (disk: ${disk}, fstype: ${fstype})" >&2

        if [ "$disk" = "$root_disk" ]; then
            info "    -> SKIP (same as root disk)" >&2
            continue
        fi

        if [[ "$part" =~ [^0-9]3$ ]]; then
            info "    -> MATCH (partition #3 on different disk)" >&2
            echo "$part"
            return
        else
            info "    -> SKIP (not partition #3)" >&2
        fi
    done
    info "No matching partition found" >&2
    return 1
}

OLD_DOM=$(detect_old_dom) || error "Old DOM not found. Check if USB is plugged in."
info "Old DOM found: ${OLD_DOM}"

# ── Mount old DOM ──
mkdir -p /mnt
mount "$OLD_DOM" /mnt
check "Old DOM mount failed"
info "Old DOM mounted at /mnt"

# ── Copy config files ──
info "Copying config files..."
cp /mnt/etc/X11/xinit/xinitrc /etc/X11/xinit/xinitrc
check "xinitrc copy failed"
cp /mnt/bin/tgtmnt /bin/
check "tgtmnt copy failed"
cp /mnt/root/.bash_profile /root/
check ".bash_profile copy failed"

# 옛 DOM 종류에 따라 .bash_profile 이 tgtmnt 또는 tgtmnt2 를 호출할 수 있음.
# tgtmnt2 로 통일 (단어 경계 \b 로 tgtmnt2 → tgtmnt22 사고 방지).
sed -i 's/\btgtmnt\b/tgtmnt2/g' /root/.bash_profile
info ".bash_profile normalized to call tgtmnt2"

# Add ldconfig after tgtmnt2 in .bash_profile (refresh cache after ecryptfs mount)
if ! grep -q "ldconfig" /root/.bash_profile; then
    sed -i '/tgtmnt2/a\        ldconfig' /root/.bash_profile
    info "Added ldconfig after tgtmnt2 in .bash_profile"
fi

# atomic 업그레이드 self-heal 호출 보장 (옛 DOM 의 .bash_profile 에 이 줄이 없을 수 있음).
# sed a\ 가 tgtmnt2 직후에 삽입하므로 최종 순서는 tgtmnt2 → dnvr-apply-config.sh → ldconfig.
# 스크립트 자체에 mountpoint/xinitrc 안전장치가 있어 legacy 환경에선 자동 ABORT.
if ! grep -q "dnvr-apply-config" /root/.bash_profile; then
    sed -i '/tgtmnt2/a\        /root/tgtdnvr/dnvr-apply-config.sh' /root/.bash_profile
    info "Added dnvr-apply-config.sh call after tgtmnt2 in .bash_profile"
fi
cp -r /mnt/root/.config /root/
check ".config copy failed"
cp /mnt/etc/ld.so.conf.d/tgt.conf /etc/ld.so.conf.d/
check "tgt.conf copy failed"

# ── ecryptfs mount setup (must happen before library copy) ──
info "Setting up ecryptfs mount..."

# Verify sig-cache exists (created in Phase 2)
info "Checking ecryptfs sig-cache..."
if [ -f /root/.ecryptfs/sig-cache.txt ]; then
    info "sig-cache.txt found: $(cat /root/.ecryptfs/sig-cache.txt)"
else
    warn "sig-cache.txt NOT found! Creating now..."
    mkdir -p /root/.ecryptfs
    echo "${ECRYPTFS_SIG}" > /root/.ecryptfs/sig-cache.txt
    info "sig-cache.txt created: ${ECRYPTFS_SIG}"
fi

# Create tgtmnt.sh
cat > /root/tgtmnt.sh <<EOF
#!/bin/bash
mount -t ecryptfs \\
    -o key=passphrase:passwd=${ECRYPTFS_PASS},ecryptfs_cipher=aes,ecryptfs_key_bytes=16,ecryptfs_passthrough=y,ecryptfs_enable_filename_crypto=yes,ecryptfs_sig=${ECRYPTFS_SIG},ecryptfs_fnek_sig=${ECRYPTFS_SIG} \\
    /root/tgt /root/tgtdnvr
EOF
chmod 700 /root/tgtmnt.sh
info "ecryptfs mount script created at /root/tgtmnt.sh"

# Mount ecryptfs (required for library copy to /root/tgtdnvr/lib)
info "Mounting ecryptfs..."
info "  mount -t ecryptfs -o key=passphrase:passwd=***,ecryptfs_cipher=aes,ecryptfs_key_bytes=16,... /root/tgt /root/tgtdnvr"
mount -t ecryptfs \
    -o key=passphrase:passwd=${ECRYPTFS_PASS},ecryptfs_cipher=aes,ecryptfs_key_bytes=16,ecryptfs_passthrough=y,ecryptfs_enable_filename_crypto=yes,ecryptfs_sig=${ECRYPTFS_SIG},ecryptfs_fnek_sig=${ECRYPTFS_SIG} \
    /root/tgt /root/tgtdnvr
MOUNT_RC=$?
info "  mount exit code: ${MOUNT_RC}"

if mount | grep -q "/root/tgtdnvr"; then
    info "ecryptfs mount SUCCESS"
    info "  $(mount | grep /root/tgtdnvr)"
    info "  $(df -h /root/tgtdnvr | tail -1)"
else
    warn "ecryptfs mount FAILED (exit code: ${MOUNT_RC})"
    info "  dmesg tail:"
    dmesg | tail -5
    info "  sig-cache contents: $(cat /root/.ecryptfs/sig-cache.txt 2>/dev/null || echo 'NOT FOUND')"
    read -p "Continue without ecryptfs? (yes/no): " ans
    [ "$ans" = "yes" ] || exit 1
fi

# ── Create lib directory for NVR libraries ──
mkdir -p /root/tgtdnvr/lib
LIBDEST=/root/tgtdnvr/lib

# ── Copy NVR libraries to /root/tgtdnvr/lib ──
info "Copying NVR libraries to ${LIBDEST}..."
set +e  # Some libraries may not exist on old DOM, allow errors

cp -P /mnt/usr/lib/libtbb.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libIlmImf-2_3.so.24* ${LIBDEST}/
cp -P /mnt/usr/lib/libImath-2_3.so.24* ${LIBDEST}/
cp -P /mnt/usr/lib/libHalf.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libIex-2_3.so.24* ${LIBDEST}/
cp -P /mnt/usr/lib/libIexMath-2_3.so.24* ${LIBDEST}/
cp -P /mnt/usr/lib/libIlmThread-2_3.so.24* ${LIBDEST}/
cp -P /mnt/usr/lib/libhdf5.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkInteractionStyle* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersExtraction* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkRenderingLOD* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkIOPLY* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersTexture* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkIOExport* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkRenderingGL2PSOpenGL2* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkIOGeometry* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkImagingCore* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkRenderingFreeType* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkRenderingOpenGL2* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkRenderingCore* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersSources* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersGeneral* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersCore* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkIOImage* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkIOCore* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonExecutionModel* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonDataModel* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonTransforms* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonMath* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonCore* ${LIBDEST}/
cp -P /mnt/usr/lib/libz.* ${LIBDEST}/
cp -P /mnt/usr/lib/libsz.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersStatistics* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersModeling* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonMisc* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtksys.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkIOXML* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkRenderingContext2D* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkFiltersGeometry* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkgl2ps.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonSystem* ${LIBDEST}/
cp -P /mnt/usr/lib/libGLEW.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonColor* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkCommonComputationalGeometry* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkDICOMParser.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkmetaio.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libaec.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvtkImagingFourier* ${LIBDEST}/

# ── Copy ffmpeg/media libraries (old versions required by opencv 4.1) ──
info "Copying ffmpeg, media, and codec libraries to ${LIBDEST}..."
cp -P /mnt/usr/lib/libdc1394.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libavcodec.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libavutil.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libavformat.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libswscale.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libswresample.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libvpx.so* ${LIBDEST}/
cp -P /mnt/usr/lib/librav1e.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libSvtAv1Enc.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libtheoraenc.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libtheoradec.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libx264.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libx265.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libmfx.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libxml2.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libbluray.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libicuuc.so* ${LIBDEST}/
cp -P /mnt/usr/lib/libicudata.so* ${LIBDEST}/

# ── Copy OpenCV libraries ──
info "Copying OpenCV libraries to ${LIBDEST}..."
cp -P /mnt/usr/lib/libopencv_* ${LIBDEST}/

# ── Copy system libraries needed by NVR (installed via pacman) ──
info "Copying system libraries (libtiff, libjasper) to ${LIBDEST}..."
cp -P /usr/lib/libtiff.so* ${LIBDEST}/
cp -P /usr/lib/libjasper.so* ${LIBDEST}/

# ── Create compatibility symlinks in /root/tgtdnvr/lib ──
info "Creating compatibility symlinks in ${LIBDEST}..."
cd ${LIBDEST}
LIBTIFF_REAL=$(ls libtiff.so.*.*.* 2>/dev/null | head -1)
[ -n "$LIBTIFF_REAL" ] && ln -sf "$LIBTIFF_REAL" libtiff.so.5 && info "libtiff.so.5 -> $LIBTIFF_REAL" || warn "libtiff not found"

LIBJASPER_REAL=$(ls libjasper.so.*.*.* 2>/dev/null | head -1)
[ -n "$LIBJASPER_REAL" ] && ln -sf "$LIBJASPER_REAL" libjasper.so.4 && info "libjasper.so.4 -> $LIBJASPER_REAL" || warn "libjasper not found"

LIBDC_REAL=$(ls libdc1394.so.*.*.* 2>/dev/null | head -1)
[ -n "$LIBDC_REAL" ] && ln -sf "$LIBDC_REAL" libdc1394.so.25 && info "libdc1394.so.25 -> $LIBDC_REAL" || warn "libdc1394 not found"

info "Library count in ${LIBDEST}: $(ls -1 ${LIBDEST}/ | wc -l) files"
cd /

# ── tgtmnt2 binary 를 ecryptfs 저장소에도 배치 ──
# /usr/bin/tgtmnt2 는 Phase 2 가 이미 배치. 여기서는 ecryptfs 마운트 (/root/tgtdnvr)
# 안에도 사본을 둠 → 첫 부팅 시 tgtmnt2 가 v_current/ 로 마이그레이션 → 이후
# 업그레이드/apply-config 가 이 사본을 참조해 /usr/bin/tgtmnt2 를 동기화 가능.
if [ -f /root/recovery_dom/tgtmnt2 ]; then
    cp /root/recovery_dom/tgtmnt2 /root/tgtdnvr/tgtmnt2
    chmod 755 /root/tgtdnvr/tgtmnt2
    info "tgtmnt2 placed in encrypted store: /root/tgtdnvr/tgtmnt2"
else
    warn "tgtmnt2 binary not found at /root/recovery_dom/tgtmnt2 (Phase 2 should have caught this)"
fi

# ── Unmount old DOM ──
umount /mnt
info "Old DOM unmounted"

# ── Update ldconfig ──
set -e
ldconfig
check "ldconfig failed"

# ── Copy popup.sh ──
info "Copying popup.sh..."
mkdir -p /etc/X11/xinit/xinitrc.d
if [ -f /root/recovery_dom/popup.sh ]; then
    cp /root/recovery_dom/popup.sh /etc/X11/xinit/xinitrc.d/popup.sh
    chmod +x /etc/X11/xinit/xinitrc.d/popup.sh
else
    warn "popup.sh not found, skipping"
fi

# ── Create tgtdvr directory ──
mkdir -p /tgtdvr

# ══════════════════════════════════════════
# ── Clone root_A to root_B, root_C, root_D ──
# ══════════════════════════════════════════
info "Cloning root_A to backup slots..."

SLOT_CONF="/etc/recovery/slot-uuids.conf"
if [ ! -f "$SLOT_CONF" ]; then
    error "slot-uuids.conf not found! Cannot clone slots."
fi
source "$SLOT_CONF"

clone_slot() {
    local SLOT_NAME="$1"
    local SLOT_UUID="$2"

    local TARGET_DEV=$(blkid -U "$SLOT_UUID" 2>/dev/null)
    if [ -z "$TARGET_DEV" ]; then
        warn "Cannot find device for $SLOT_NAME (UUID=$SLOT_UUID), skipping"
        return 1
    fi

    info "Cloning to root_${SLOT_NAME} ($TARGET_DEV)..."
    local MNT="/mnt/root_${SLOT_NAME,,}"
    mkdir -p "$MNT"
    mount "$TARGET_DEV" "$MNT"

    rsync -aAX --delete / "$MNT/" \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/tmp \
        --exclude=/run \
        --exclude=/mnt \
        --exclude=/root/tgtdnvr \
        --exclude=/root/tgt_dec

    umount "$MNT"
    rmdir "$MNT" 2>/dev/null
    info "root_${SLOT_NAME} clone complete"
}

clone_slot "B" "$ROOT_B_UUID"
clone_slot "C" "$ROOT_C_UUID"
clone_slot "D" "$ROOT_D_UUID"

info "All slots cloned."

# ── NOTE: recovery_dom is NOT deleted (unlike make_dom) ──
# Kept for post-dd-uuid-regen.sh and reference

# ══════════════════════════════════════════
# ── Restore failover/watchdog (Phase 2에서 비활성화한 것 원복) ──
# ══════════════════════════════════════════
info "Restoring failover services and watchdog..."

# failover-success.service unmask
systemctl unmask failover-success.service 2>/dev/null || true
info "failover-success.service unmasked"

# 워치독 원복
if [ -f /etc/systemd/system.conf ]; then
    sed -i 's/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=20/' /etc/systemd/system.conf
    info "Watchdog restored to 20s (effective after reboot)"
fi

# boot_ok=1 유지 (첫 부팅이 slot A에서 시작하도록)
# GRUB 로직: boot_ok=1이면 현재 슬롯 유지, 0이면 다음 슬롯으로 전환
# 부팅 시 GRUB이 boot_ok=0으로 리셋 → DNVR 정상이면 failover-success가 1로 복원
mount /boot 2>/dev/null || true
if [ -f /boot/grub/grubenv ]; then
    grub-editenv /boot/grub/grubenv set boot_try=A boot_ok=1 retry_round=0
    info "grubenv: boot_try=A, boot_ok=1 (first boot will stay on slot A)"
fi
umount /boot 2>/dev/null || true

# ── install_mode 플래그 활성화 ──
# 설치 완료 후 운영자가 DNVR 앱 설치/검증 작업하는 동안 슬롯 페일오버 무력화.
# 모든 작업 끝나면 운영자가 /usr/local/sbin/finalize-install.sh 실행 → production.
mkdir -p /etc/recovery
touch /etc/recovery/install_mode
info "install_mode flag SET — slot failover DISABLED until 'finalize-install.sh' is run"

# ── Done ──
info "=========================================="
info " Phase 3 complete! Installation finished."
info " Remove USB and reboot."
info " "
info " After reboot:"
info "   Ctrl+F12 to verify tgtdnvr mount"
info "   Ready for dd image backup"
info "   After dd: run post-dd-uuid-regen.sh"
info " "
info " ==========================================="
info "  INSTALL MODE ACTIVE — slot failover OFF"
info " ==========================================="
info "  Install/test DNVR app freely. Reboots are safe (no slot advance)."
info "  When all setup work is complete, run:"
info "    /usr/local/sbin/finalize-install.sh"
info "  This switches to production (enables slot failover protection)."
info "=========================================="

beep -f 1500 -l 500 2>/dev/null || true
