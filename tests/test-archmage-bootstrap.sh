#!/usr/bin/env bash
# =============================================================================
#  test-archmage-bootstrap.sh — Loop Device Test Harness
#
#  Builds a fake LUKS+LVM+BTRFS/ext4 stack on loopback files that mirrors
#  archmage-bootstrap.sh's expectations, so you can validate the format/mount
#  logic without touching real hardware.
#
#  Run with: sudo ./test-archmage-bootstrap.sh
#  Clean up with: sudo ./test-archmage-bootstrap.sh clean
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/archmage-test"
IMG="${WORKDIR}/fake-luks-partition.img"
IMG_SIZE_MB=2048          # 2G fake "p5" — plenty for root(512M)+var(256M)+home(remaining)
LOOP_DEV=""

LUKS_NAME="archmage-test"
VG_NAME="volgroup0-test"
LUKS_PASS="testpass123"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'
log()  { echo -e "\n${GRN}[+]${RST} $*"; }
info() { echo -e "  ${CYN}[i]${RST} $*"; }
die()  { echo -e "\n${RED}[✗]${RST} $*" >&2; exit 1; }

[[ ${EUID} -ne 0 ]] && die "Must be run as root (loop devices, cryptsetup, mounts)."

# ── CLEANUP MODE ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "clean" ]]; then
    log "Cleaning up test environment"
    umount -R "${WORKDIR}/mnt" 2>/dev/null || true
    [[ -e "/dev/mapper/${LUKS_NAME}" ]] && {
        vgchange -an "${VG_NAME}" 2>/dev/null || true
        cryptsetup luksClose "${LUKS_NAME}" 2>/dev/null || true
    }
    _existing_loop=$(losetup -j "${IMG}" 2>/dev/null | cut -d: -f1 || true)
    [[ -n "${_existing_loop}" ]] && losetup -d "${_existing_loop}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
    info "Cleaned: ${WORKDIR}, loop device, LUKS mapping, VG."
    exit 0
fi

# ── SETUP ─────────────────────────────────────────────────────────────────
log "STEP 1 — Creating sparse image + loop device"
mkdir -p "${WORKDIR}/mnt"
rm -f "${IMG}"
truncate -s "${IMG_SIZE_MB}M" "${IMG}"
LOOP_DEV=$(losetup -f --show "${IMG}")
info "Loop device: ${LOOP_DEV}"

log "STEP 2 — Formatting as LUKS"
echo -n "${LUKS_PASS}" | cryptsetup luksFormat -q "${LOOP_DEV}" -
echo -n "${LUKS_PASS}" | cryptsetup luksOpen "${LOOP_DEV}" "${LUKS_NAME}" -
info "Opened: /dev/mapper/${LUKS_NAME}"

log "STEP 3 — Creating LVM (PV → VG → 3 LVs)"
pvcreate -ff -y "/dev/mapper/${LUKS_NAME}"
vgcreate "${VG_NAME}" "/dev/mapper/${LUKS_NAME}"
lvcreate -L 512M -n root "${VG_NAME}"
lvcreate -L 256M -n var  "${VG_NAME}"
lvcreate -l 100%FREE -n home "${VG_NAME}"
info "LVs created: root (512M), var (256M), home (remaining)"

log "STEP 4 — Pre-populating home with a marker file (simulates existing data)"
mkfs.btrfs -f -q -L home "/dev/mapper/${VG_NAME}-home"
mount "/dev/mapper/${VG_NAME}-home" "${WORKDIR}/mnt"
btrfs subvolume create "${WORKDIR}/mnt/@home" >/dev/null
mount -o subvol=@home "/dev/mapper/${VG_NAME}-home" "${WORKDIR}/mnt" 2>/dev/null || true
echo "DO NOT DELETE ME — home preservation test marker" > "${WORKDIR}/mnt/marker.txt" 2>/dev/null || true
umount -R "${WORKDIR}/mnt"

echo
echo -e "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  Fake stack ready. Point your bootstrap script's config at:${RST}"
echo -e "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo
echo "  LUKS_DEV=\"${LOOP_DEV}\""
echo "  LUKS_NAME=\"${LUKS_NAME}\"   (already open — script will detect this)"
echo "  VG_NAME=\"${VG_NAME}\""
echo "  LV_ROOT=\"/dev/mapper/${VG_NAME}-root\""
echo "  LV_VAR=\"/dev/mapper/${VG_NAME}-var\""
echo "  LV_HOME=\"/dev/mapper/${VG_NAME}-home\""
echo
echo -e "  ${YEL}Notes:${RST}"
echo "    • EFI_PART step will fail (no fake EFI partition) — comment out"
echo "      Step 8's boot mount + Step 9 pacstrap when testing format/mount only."
echo "    • After running, check: mount | grep ${WORKDIR}/mnt"
echo "    • Verify home survived: ls ${WORKDIR}/mnt/home/  (should show marker.txt)"
echo "    • Verify root/var were wiped and recreated (mkfs labels reset)"
echo
echo -e "  ${CYN}When done:${RST} sudo ./test-archmage-bootstrap.sh clean"
echo
