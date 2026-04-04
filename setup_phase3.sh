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
cp -r /mnt/root/.config /root/
check ".config copy failed"
cp /mnt/etc/ld.so.conf.d/tgt.conf /etc/ld.so.conf.d/
check "tgt.conf copy failed"

# ── Copy NVR libraries ──
info "Copying NVR libraries..."
cd /usr/lib
set +e

cp -P /mnt/usr/lib/libtbb.so* .
cp -P /mnt/usr/lib/libIlmImf-2_3.so.24* .
cp -P /mnt/usr/lib/libImath-2_3.so.24* .
cp -P /mnt/usr/lib/libHalf.so* .
cp -P /mnt/usr/lib/libIex-2_3.so.24* .
cp -P /mnt/usr/lib/libIexMath-2_3.so.24* .
cp -P /mnt/usr/lib/libIlmThread-2_3.so.24* .
cp -P /mnt/usr/lib/libhdf5.so* .
cp -P /mnt/usr/lib/libvtkInteractionStyle* .
cp -P /mnt/usr/lib/libvtkFiltersExtraction* .
cp -P /mnt/usr/lib/libvtkRenderingLOD* .
cp -P /mnt/usr/lib/libvtkIOPLY* .
cp -P /mnt/usr/lib/libvtkFiltersTexture* .
cp -P /mnt/usr/lib/libvtkIOExport* .
cp -P /mnt/usr/lib/libvtkRenderingGL2PSOpenGL2* .
cp -P /mnt/usr/lib/libvtkIOGeometry* .
cp -P /mnt/usr/lib/libvtkImagingCore* .
cp -P /mnt/usr/lib/libvtkRenderingFreeType* .
cp -P /mnt/usr/lib/libvtkRenderingOpenGL2* .
cp -P /mnt/usr/lib/libvtkRenderingCore* .
cp -P /mnt/usr/lib/libvtkFiltersSources* .
cp -P /mnt/usr/lib/libvtkFiltersGeneral* .
cp -P /mnt/usr/lib/libvtkFiltersCore* .
cp -P /mnt/usr/lib/libvtkIOImage* .
cp -P /mnt/usr/lib/libvtkIOCore* .
cp -P /mnt/usr/lib/libvtkCommonExecutionModel* .
cp -P /mnt/usr/lib/libvtkCommonDataModel* .
cp -P /mnt/usr/lib/libvtkCommonTransforms* .
cp -P /mnt/usr/lib/libvtkCommonMath* .
cp -P /mnt/usr/lib/libvtkCommonCore* .
cp -P /mnt/usr/lib/libz.* .
cp -P /mnt/usr/lib/libsz.so* .
cp -P /mnt/usr/lib/libvtkFiltersStatistics* .
cp -P /mnt/usr/lib/libvtkFiltersModeling* .
cp -P /mnt/usr/lib/libvtkCommonMisc* .
cp -P /mnt/usr/lib/libvtksys.so* .
cp -P /mnt/usr/lib/libvtkIOXML* .
cp -P /mnt/usr/lib/libvtkRenderingContext2D* .
cp -P /mnt/usr/lib/libvtkFiltersGeometry* .
cp -P /mnt/usr/lib/libvtkgl2ps.so* .
cp -P /mnt/usr/lib/libvtkCommonSystem* .
cp -P /mnt/usr/lib/libGLEW.so* .
cp -P /mnt/usr/lib/libvtkCommonColor* .
cp -P /mnt/usr/lib/libvtkCommonComputationalGeometry* .
cp -P /mnt/usr/lib/libvtkDICOMParser.so* .
cp -P /mnt/usr/lib/libvtkmetaio.so* .
cp -P /mnt/usr/lib/libaec.so* .
cp -P /mnt/usr/lib/libvtkImagingFourier* .

info "Copying ffmpeg, media, and codec libraries..."
cp -P /mnt/usr/lib/libdc1394.so* .
cp -P /mnt/usr/lib/libavcodec.so* .
cp -P /mnt/usr/lib/libavutil.so* .
cp -P /mnt/usr/lib/libavformat.so* .
cp -P /mnt/usr/lib/libswscale.so* .
cp -P /mnt/usr/lib/libswresample.so* .
cp -P /mnt/usr/lib/libvpx.so* .
cp -P /mnt/usr/lib/librav1e.so* .
cp -P /mnt/usr/lib/libSvtAv1Enc.so* .
cp -P /mnt/usr/lib/libtheoraenc.so* .
cp -P /mnt/usr/lib/libtheoradec.so* .
cp -P /mnt/usr/lib/libx264.so* .
cp -P /mnt/usr/lib/libx265.so* .
cp -P /mnt/usr/lib/libmfx.so* .
cp -P /mnt/usr/lib/libxml2.so* .
cp -P /mnt/usr/lib/libbluray.so* .
cp -P /mnt/usr/lib/libicuuc.so* .
cp -P /mnt/usr/lib/libicudata.so* .

info "Copying OpenCV libraries..."
cp -P /mnt/usr/lib/libopencv_* .

cd /
set -e

# ── Unmount old DOM ──
umount /mnt
info "Old DOM unmounted"

# ── Compatibility symlinks ──
info "Creating compatibility symlinks..."
cd /usr/lib
LIBTIFF_REAL=$(ls libtiff.so.*.*.* 2>/dev/null | head -1)
[ -n "$LIBTIFF_REAL" ] && ln -sf "$LIBTIFF_REAL" libtiff.so.5 && info "libtiff.so.5 -> $LIBTIFF_REAL" || warn "libtiff not found"

LIBJASPER_REAL=$(ls libjasper.so.*.*.* 2>/dev/null | head -1)
[ -n "$LIBJASPER_REAL" ] && ln -sf "$LIBJASPER_REAL" libjasper.so.4 && info "libjasper.so.4 -> $LIBJASPER_REAL" || warn "libjasper not found"

LIBDC_REAL=$(ls libdc1394.so.*.*.* 2>/dev/null | head -1)
[ -n "$LIBDC_REAL" ] && ln -sf "$LIBDC_REAL" libdc1394.so.25 && info "libdc1394.so.25 -> $LIBDC_REAL" || warn "libdc1394 not found"
cd /

# ── ldconfig ──
ldconfig
check "ldconfig failed"

# ── ecryptfs mount setup ──
info "Setting up ecryptfs mount..."
cat > /root/tgtmnt.sh <<EOF
#!/bin/bash
mount -t ecryptfs \\
    -o key=passphrase:passwd=${ECRYPTFS_PASS},ecryptfs_cipher=aes,ecryptfs_key_bytes=16,ecryptfs_passthrough=y,ecryptfs_enable_filename_crypto=yes,ecryptfs_sig=${ECRYPTFS_SIG},ecryptfs_fnek_sig=${ECRYPTFS_SIG} \\
    /root/tgt /root/tgtdnvr
EOF
chmod 700 /root/tgtmnt.sh
info "ecryptfs mount script created"

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
        --exclude=/root/tgtdnvr

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

# ── Done ──
info "=========================================="
info " Phase 3 complete! Installation finished."
info " Remove USB and reboot."
info " "
info " After reboot:"
info "   Ctrl+F12 to verify tgtdnvr mount"
info "   Ready for dd image backup"
info "   After dd: run post-dd-uuid-regen.sh"
info "=========================================="

beep -f 1500 -l 500 2>/dev/null || true
