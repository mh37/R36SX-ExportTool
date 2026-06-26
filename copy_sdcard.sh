#!/usr/bin/env bash
# =============================================================================
# copy_sdcard.sh — Copy all files from a USB SD card reader to a local folder.
#
# Handles cards with missing/corrupt MBR, non-zero filesystem offsets,
# and multiple filesystem types (FAT32, FAT16, exFAT, NTFS).
#
# Usage:  sudo bash copy_sdcard.sh [OPTIONS]
# =============================================================================

set -uo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
    CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
else
    RED=''; YEL=''; GRN=''; CYN=''; BLD=''; RST=''
fi

info()   { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()     { echo -e "${GRN}[ OK ]${RST}  $*"; }
warn()   { echo -e "${YEL}[WARN]${RST}  $*"; }
die()    { echo -e "${RED}[ERR ]${RST}  $*" >&2; exit 1; }
header() { echo -e "\n${BLD}${CYN}══ $* ══${RST}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
DEVICE=""
DEST=""
DRY_RUN=0
YES=0
SCAN_MB=200
MOUNT_POINT="/mnt/sdcard_copy_$$"
REAL_USER="${SUDO_USER:-${USER:-$(logname 2>/dev/null || echo root)}}"
REAL_HOME=$(eval echo "~$REAL_USER")
LOG_FILE="/tmp/copy_sdcard_$$.log"
MTOOLSRC_FILE="/tmp/.mtoolsrc_$$"
MOUNTED=0

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        warn "Unmounting $MOUNT_POINT ..."
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    rm -f "$MTOOLSRC_FILE"
}
trap cleanup EXIT

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BLD}Usage:${RST}  sudo bash copy_sdcard.sh [OPTIONS]

${BLD}Options:${RST}
  -d, --device PATH    Block device to read from (default: auto-detected)
  -o, --dest   PATH    Destination folder        (default: ~/sdcard_backup)
  -s, --scan   MB      MB to scan for FS offset  (default: $SCAN_MB)
  -y, --yes            Skip confirmation prompt
  --dry-run            Detect and mount only — do not copy
  -h, --help           Show this help

${BLD}Examples:${RST}
  sudo bash copy_sdcard.sh
  sudo bash copy_sdcard.sh --device /dev/sdb --dest /mnt/backup
  sudo bash copy_sdcard.sh --dry-run

${BLD}Notes:${RST}
  - Must be run with sudo (needs raw device access and mount)
  - Supports FAT32, FAT16, exFAT, NTFS (even without a valid MBR/partition table)
  - Errors are logged to: $LOG_FILE
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) DEVICE="$2";  shift 2 ;;
        -o|--dest)   DEST="$2";    shift 2 ;;
        -s|--scan)   SCAN_MB="$2"; shift 2 ;;
        -y|--yes)    YES=1;        shift   ;;
        --dry-run)   DRY_RUN=1;    shift   ;;
        -h|--help)   usage ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$(id -u)" -ne 0 ]] && die "This script must be run with sudo."

# ── Dependency check ──────────────────────────────────────────────────────────
header "Checking dependencies"
MISSING=()
for cmd in dd xxd grep awk lsblk rsync python3; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
command -v mtools &>/dev/null \
    || warn "mtools not installed — fallback copy unavailable (apt install mtools)"
command -v ntfs-3g &>/dev/null \
    || warn "ntfs-3g not installed — NTFS support limited (apt install ntfs-3g)"
[[ ${#MISSING[@]} -gt 0 ]] && die "Missing required tools: ${MISSING[*]}"
ok "All required tools found."

# ── Auto-detect USB storage device ───────────────────────────────────────────
header "Device detection"

detect_usb_device() {
    lsblk -dno NAME,TRAN,TYPE 2>/dev/null \
        | awk '$2=="usb" && $3=="disk" {print "/dev/"$1}' \
        | head -1
}

if [[ -z "$DEVICE" ]]; then
    DEVICE=$(detect_usb_device)
    if [[ -z "$DEVICE" ]]; then
        ROOT_DEV=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)
        DEVICE=$(lsblk -dno NAME,TYPE 2>/dev/null \
            | awk '$2=="disk" {print "/dev/"$1}' \
            | grep -v "nvme\|mmcblk${ROOT_DEV:+\|}${ROOT_DEV}" \
            | head -1)
    fi
    [[ -z "$DEVICE" ]] && die "Could not auto-detect a USB storage device. Use --device."
    info "Auto-detected device: ${BLD}$DEVICE${RST}"
else
    info "Using specified device: ${BLD}$DEVICE${RST}"
fi

[[ ! -b "$DEVICE" ]] && die "$DEVICE is not a block device."

DISK_SIZE=$(lsblk -dno SIZE  "$DEVICE" 2>/dev/null || echo "unknown")
DISK_MODEL=$(lsblk -dno MODEL "$DEVICE" 2>/dev/null | xargs || echo "unknown")
ok "Device: $DEVICE  |  Model: $DISK_MODEL  |  Size: $DISK_SIZE"

# ── Destination ───────────────────────────────────────────────────────────────
[[ -z "$DEST" ]] && DEST="$REAL_HOME/sdcard_backup"
info "Destination: ${BLD}$DEST${RST}"

if [[ -d "$DEST" && "$YES" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    EXISTING=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "?")
    echo -e "${YEL}Destination already exists ($EXISTING used). Merge/overwrite? [y/N]${RST} "
    read -r answer
    [[ "$answer" != [yY] ]] && { info "Aborted."; exit 0; }
fi

# ── Scan for filesystem signatures ───────────────────────────────────────────
header "Scanning $DEVICE for filesystem signatures (first ${SCAN_MB}MB)"

find_fs_offsets() {
    local raw
    raw=$(dd if="$DEVICE" bs=1M count="$SCAN_MB" 2>/dev/null)
    # FAT32 OEM/type string at boot sector offset 82
    echo "$raw" | grep -boa "FAT32   " 2>/dev/null \
        | awk -F: '{o=$1-82; if(o>=0 && o%512==0) print "fat32:"o}'
    # FAT16 type string at boot sector offset 82
    echo "$raw" | grep -boa "FAT16   " 2>/dev/null \
        | awk -F: '{o=$1-82; if(o>=0 && o%512==0) print "fat16:"o}'
    # FAT12 type string at boot sector offset 82
    echo "$raw" | grep -boa "FAT12   " 2>/dev/null \
        | awk -F: '{o=$1-82; if(o>=0 && o%512==0) print "fat12:"o}'
    # NTFS OEM name at boot sector offset 3
    echo "$raw" | grep -boa "NTFS    " 2>/dev/null \
        | awk -F: '{o=$1-3;  if(o>=0 && o%512==0) print "ntfs:"o}'
    # exFAT OEM name at boot sector offset 3
    echo "$raw" | grep -boa "EXFAT   " 2>/dev/null \
        | awk -F: '{o=$1-3;  if(o>=0 && o%512==0) print "exfat:"o}'
}

CANDIDATES=$(find_fs_offsets | sort -t: -k2 -un)

if [[ -z "$CANDIDATES" ]]; then
    die "No recognisable filesystem found in first ${SCAN_MB}MB.\n" \
        "  Try --scan 500 for a wider search.\n" \
        "  The card may be encrypted (BitLocker/VeraCrypt) or corrupted."
fi

info "Found candidates:"
while IFS=: read -r fs off; do
    echo "       ${fs^^} at byte offset $off (sector $(( off / 512 )))"
done <<< "$CANDIDATES"

# ── Validate FAT candidates with Python ──────────────────────────────────────
header "Validating candidates"

validate_fat() {
    local offset="$1"
    python3 - "$DEVICE" "$offset" 2>/dev/null <<'PYEOF'
import sys, struct
dev, off = sys.argv[1], int(sys.argv[2])
with open(dev, 'rb') as f:
    f.seek(off)
    bs = f.read(512)
if len(bs) < 90:
    sys.exit(1)
# Jump instruction
if bs[0] not in (0xEB, 0xE9):
    sys.exit(1)
# Bytes per sector
bps = struct.unpack_from('<H', bs, 11)[0]
if bps not in (512, 1024, 2048, 4096):
    sys.exit(1)
# Media byte
media = bs[21]
if media < 0xF0:
    sys.exit(1)
# Reserved sectors
rsvd = struct.unpack_from('<H', bs, 14)[0]
if rsvd == 0:
    sys.exit(1)
# Number of FATs
if bs[16] not in (1, 2):
    sys.exit(1)
# FAT size (FAT16 field, 0 for FAT32)
fat_sz16 = struct.unpack_from('<H', bs, 22)[0]
fat_sz32 = struct.unpack_from('<I', bs, 36)[0] if fat_sz16 == 0 else 0
fat_sz   = fat_sz32 if fat_sz16 == 0 else fat_sz16
if fat_sz == 0:
    sys.exit(1)
# Read first byte of FAT1 and compare to declared media byte
fat_off = off + rsvd * bps
with open(dev, 'rb') as f:
    f.seek(fat_off)
    b = f.read(1)
if not b or b[0] != media:
    sys.exit(1)
sys.exit(0)
PYEOF
}

GOOD_ENTRY=""
while IFS=: read -r fs off; do
    echo -n "       Checking ${fs^^} at offset $off ... "
    case "$fs" in
        fat32|fat16|fat12)
            if validate_fat "$off"; then
                ok "VALID (FAT table confirmed)"
                GOOD_ENTRY="$fs:$off"; break
            else
                warn "FAT table mismatch — skipping"
            fi ;;
        ntfs|exfat)
            ok "OEM signature found"
            GOOD_ENTRY="$fs:$off"; break ;;
    esac
done <<< "$CANDIDATES"

# ── Brute-force mtools fallback if strict validation failed ──────────────────
if [[ -z "$GOOD_ENTRY" ]] && command -v mtools &>/dev/null; then
    warn "Strict validation failed — attempting mtools brute-force..."
    while IFS=: read -r fs off; do
        printf 'drive x: file="%s" offset=%s\n' "$DEVICE" "$off" > "$MTOOLSRC_FILE"
        result=$(MTOOLSRC="$MTOOLSRC_FILE" mdir x: 2>&1 | head -3 || true)
        if ! grep -qi "error\|cannot\|invalid\|bad" <<< "$result"; then
            ok "mtools can read ${fs^^} at offset $off"
            GOOD_ENTRY="$fs:$off"; break
        fi
    done <<< "$CANDIDATES"
fi

[[ -z "$GOOD_ENTRY" ]] \
    && die "Could not validate any filesystem. Card may be encrypted or severely corrupted."

FS_TYPE="${GOOD_ENTRY%%:*}"
FS_OFFSET="${GOOD_ENTRY##*:}"
ok "Selected: ${BLD}${FS_TYPE^^}${RST} at byte offset ${BLD}$FS_OFFSET${RST}"

[[ "$DRY_RUN" -eq 1 ]] && { ok "Dry-run complete. No files copied."; exit 0; }

# ── Mount ─────────────────────────────────────────────────────────────────────
header "Mounting filesystem (read-only)"
mkdir -p "$MOUNT_POINT"
UID_GID="uid=$(id -u "$REAL_USER"),gid=$(id -g "$REAL_USER")"

case "$FS_TYPE" in
    fat32|fat16|fat12)
        mount -t vfat \
            -o "ro,offset=$FS_OFFSET,$UID_GID,errors=continue" \
            "$DEVICE" "$MOUNT_POINT" 2>>"$LOG_FILE" && MOUNTED=1 || true ;;
    exfat)
        modprobe exfat 2>/dev/null || true
        mount -t exfat \
            -o "ro,offset=$FS_OFFSET,$UID_GID" \
            "$DEVICE" "$MOUNT_POINT" 2>>"$LOG_FILE" && MOUNTED=1 || true ;;
    ntfs)
        if command -v ntfs-3g &>/dev/null; then
            ntfs-3g \
                -o "ro,offset=$FS_OFFSET,uid=$(id -u "$REAL_USER"),gid=$(id -g "$REAL_USER")" \
                "$DEVICE" "$MOUNT_POINT" 2>>"$LOG_FILE" && MOUNTED=1 || true
        else
            mount -t ntfs \
                -o "ro,offset=$FS_OFFSET,$UID_GID" \
                "$DEVICE" "$MOUNT_POINT" 2>>"$LOG_FILE" && MOUNTED=1 || true
        fi ;;
esac

# ── Copy ──────────────────────────────────────────────────────────────────────
header "Copying files"
mkdir -p "$DEST"
chown "$REAL_USER":"$REAL_USER" "$DEST" 2>/dev/null || true

if [[ "$MOUNTED" -eq 1 ]]; then
    ok "Mounted at $MOUNT_POINT"
    info "Copying to $DEST — this may take a while for large cards..."
    rsync -a --info=progress2 --stats \
        --no-perms --no-owner --no-group \
        --modify-window=1 \
        "$MOUNT_POINT/" "$DEST/" 2>&1 | tee -a "$LOG_FILE" || {
        RC=$?
        # Code 23 = partial transfer (attributes), 24 = vanished source file — both non-fatal
        if [[ $RC -eq 23 || $RC -eq 24 ]]; then
            warn "rsync code $RC: some file attributes could not be set (normal for FAT/NTFS)"
            warn "Details in: $LOG_FILE"
        else
            die "rsync failed with exit code $RC. See $LOG_FILE for details."
        fi
    }
    umount "$MOUNT_POINT" && MOUNTED=0

elif command -v mtools &>/dev/null; then
    warn "Kernel mount failed — falling back to mtools"
    printf 'drive x: file="%s" offset=%s\n' "$DEVICE" "$FS_OFFSET" > "$MTOOLSRC_FILE"
    info "Copying recursively via mcopy..."
    MTOOLSRC="$MTOOLSRC_FILE" mcopy -snmv 'x:/*' "$DEST/" 2>&1 \
        | tee -a "$LOG_FILE" \
        || warn "mcopy completed with some errors (see $LOG_FILE)"
    rm -f "$MTOOLSRC_FILE"

else
    die "Cannot mount and mtools not available.\n  Install with: apt install mtools"
fi

chown -R "$REAL_USER":"$REAL_USER" "$DEST" 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────────
header "Done"
TOTAL=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "?")
COUNT=$(find "$DEST" -type f 2>/dev/null | wc -l || echo "?")
ok "Files copied : $COUNT"
ok "Total size   : $TOTAL"
ok "Destination  : $DEST"
ok "Log file     : $LOG_FILE"
echo ""
ls -lh "$DEST" 2>/dev/null | head -20
