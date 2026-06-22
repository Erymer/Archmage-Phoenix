#!/usr/bin/env bash
# =============================================================================
#  archmage-bootstrap.sh — Arch Linux Reinstall Bootstrap
#
#  Disk layout (nvme0n1):
#    p4  /boot                  vfat   1G     ← PRESERVED
#    p5  LUKS (archmage)        120G
#        └─ volgroup0
#           ├─ root  /          btrfs  40G    ← WIPED
#           ├─ var   /var       ext4   5G     ← WIPED
#           └─ home  /home      btrfs  74.2G  ← PRESERVED
# =============================================================================
set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
LUKS_DEV="/dev/nvme0n1p5"
LUKS_NAME="archmage"
VG_NAME="volgroup0"
EFI_PART="/dev/nvme0n1p4"

LV_ROOT="/dev/mapper/${VG_NAME}-root"
LV_VAR="/dev/mapper/${VG_NAME}-var"
LV_HOME="/dev/mapper/${VG_NAME}-home"

MNT="/mnt"

# BTRFS subvolumes created on root. "@" → /  |  "@snapshots" → /.snapshots
BTRFS_ROOT_SUBVOLS=("@" "@snapshots")
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2,ssd,discard=async"

# Subvolume to mount from the home LV.
# Leave empty ("") to auto-detect, or hard-code: "@home", "home", etc.
HOME_SUBVOL=""

# Base packages. Add your own — ucode (intel-ucode/amd-ucode) goes here too.
BASE_PKGS=(
    base base-devel
    linux linux-firmware linux-headers
    lvm2 cryptsetup
    btrfs-progs e2fsprogs dosfstools
    networkmanager
    vim sudo
)

# ── HELPERS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; RST='\033[0m'
log()  { echo -e "\n${GRN}[+]${RST} $*"; }
info() { echo -e "  ${CYN}[i]${RST} $*"; }
warn() { echo -e "  ${YEL}[!]${RST} $*"; }
die()  { echo -e "\n${RED}[✗]${RST} $*" >&2; exit 1; }
hr()   { echo -e "${YEL}──────────────────────────────────────────────────${RST}"; }

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────
[[ ${EUID} -ne 0 ]] && die "Must be run as root."

for cmd in cryptsetup vgchange mkfs.btrfs mkfs.ext4 btrfs pacstrap genfstab arch-chroot; do
    command -v "$cmd" &>/dev/null || die "Missing: '${cmd}' — booted into the Arch live ISO?"
done

# ── STEP 1 — LUKS ─────────────────────────────────────────────────────────────
hr; log "STEP 1 — LUKS"
if [[ -e "/dev/mapper/${LUKS_NAME}" ]]; then
    info "Container already open: /dev/mapper/${LUKS_NAME}"
else
    log "Opening ${LUKS_DEV} as '${LUKS_NAME}' ..."
    cryptsetup luksOpen "${LUKS_DEV}" "${LUKS_NAME}"
fi

# ── STEP 2 — LVM ──────────────────────────────────────────────────────────────
hr; log "STEP 2 — LVM"
vgchange -ay "${VG_NAME}"
for lv in "${LV_ROOT}" "${LV_VAR}" "${LV_HOME}"; do
    [[ -b "$lv" ]] || die "LV not found: ${lv}"
    info "Verified: ${lv}"
done

# ── STEP 3 — HOME SUBVOLUME DETECTION ────────────────────────────────────────
hr; log "STEP 3 — Home BTRFS subvolume"
if [[ -z "${HOME_SUBVOL}" ]]; then
    log "Auto-detecting subvolume on ${LV_HOME} ..."
    _tmp=$(mktemp -d)
    if mount -o ro "${LV_HOME}" "${_tmp}" 2>/dev/null; then
        _svols=$(btrfs subvolume list "${_tmp}" 2>/dev/null | awk '{print $NF}' || true)
        umount "${_tmp}"
    else
        warn "Could not mount ${LV_HOME} read-only to probe. Mounting top-level."
        _svols=""
    fi
    rmdir "${_tmp}"

    if echo "${_svols}" | grep -qx "@home"; then
        HOME_SUBVOL="@home"
    elif echo "${_svols}" | grep -qx "home"; then
        HOME_SUBVOL="home"
    elif [[ -n "${_svols}" ]]; then
        warn "Subvolumes found but no obvious match: ${_svols}"
        warn "Mounting top-level. Edit HOME_SUBVOL in config if this is wrong."
    fi
fi

if [[ -n "${HOME_SUBVOL}" ]]; then
    info "Home subvolume: ${HOME_SUBVOL}"
else
    info "Mounting home at BTRFS top-level (no subvolume)."
fi

# ── STEP 4 — CONFIRMATION ─────────────────────────────────────────────────────
hr
echo
echo -e "  ${RED}┌─────────────────────────────────────────────────┐${RST}"
echo -e "  ${RED}│         ⚠   DESTRUCTIVE OPERATION   ⚠          │${RST}"
echo -e "  ${RED}└─────────────────────────────────────────────────┘${RST}"
echo
echo -e "  ${RED}WILL BE FORMATTED (data lost forever):${RST}"
echo -e "    ${RED}✗${RST}  ${LV_ROOT}  →  btrfs  (subvols: ${BTRFS_ROOT_SUBVOLS[*]})"
echo -e "    ${RED}✗${RST}  ${LV_VAR}    →  ext4"
echo
echo -e "  ${GRN}WILL BE PRESERVED (not touched):${RST}"
echo -e "    ${GRN}✓${RST}  ${LV_HOME}  →  btrfs"
echo -e "    ${GRN}✓${RST}  ${EFI_PART}          →  vfat  (Linux /boot — EFI entries kept)"
echo
read -rp "  Type DESTROY to proceed (Ctrl+C to abort): " _confirm
echo
[[ "${_confirm}" == "DESTROY" ]] || die "Confirmation failed. Aborted."

# ── STEP 5 — UNMOUNT ──────────────────────────────────────────────────────────
hr; log "STEP 5 — Unmounting ${MNT}"
if mountpoint -q "${MNT}" 2>/dev/null; then
    umount -R "${MNT}"
    info "Unmounted recursively: ${MNT}"
else
    info "Nothing mounted at ${MNT} — clean slate."
fi

# ── STEP 6 — FORMAT ROOT ──────────────────────────────────────────────────────
hr; log "STEP 6 — Formatting ${LV_ROOT} → btrfs"
mkfs.btrfs -f -L root "${LV_ROOT}"

log "Creating BTRFS subvolumes ..."
mount "${LV_ROOT}" "${MNT}"
for subvol in "${BTRFS_ROOT_SUBVOLS[@]}"; do
    btrfs subvolume create "${MNT}/${subvol}"
    info "Created: ${subvol}"
done
umount "${MNT}"

# ── STEP 7 — FORMAT VAR ───────────────────────────────────────────────────────
hr; log "STEP 7 — Formatting ${LV_VAR} → ext4"
mkfs.ext4 -L var "${LV_VAR}"

# ── STEP 8 — MOUNT ────────────────────────────────────────────────────────────
hr; log "STEP 8 — Mounting filesystems"

mount -o "${BTRFS_OPTS},subvol=@" "${LV_ROOT}" "${MNT}"
info "/              ← ${LV_ROOT}  (subvol=@)"

mkdir -p "${MNT}/.snapshots"
mount -o "${BTRFS_OPTS},subvol=@snapshots" "${LV_ROOT}" "${MNT}/.snapshots"
info "/.snapshots    ← ${LV_ROOT}  (subvol=@snapshots)"

mkdir -p "${MNT}/var"
mount "${LV_VAR}" "${MNT}/var"
info "/var           ← ${LV_VAR}"

mkdir -p "${MNT}/home"
if [[ -n "${HOME_SUBVOL}" ]]; then
    mount -o "${BTRFS_OPTS},subvol=${HOME_SUBVOL}" "${LV_HOME}" "${MNT}/home"
    info "/home          ← ${LV_HOME}  (subvol=${HOME_SUBVOL})"
else
    mount -o "${BTRFS_OPTS}" "${LV_HOME}" "${MNT}/home"
    info "/home          ← ${LV_HOME}  (top-level)"
fi

mkdir -p "${MNT}/boot"
mount "${EFI_PART}" "${MNT}/boot"
info "/boot          ← ${EFI_PART}"

# ── STEP 9 — PACSTRAP ─────────────────────────────────────────────────────────
hr; log "STEP 9 — pacstrap"
pacstrap -K "${MNT}" "${BASE_PKGS[@]}"

# ── STEP 10 — FSTAB + CRYPTTAB ───────────────────────────────────────────────
hr; log "STEP 10 — fstab + crypttab"

genfstab -U "${MNT}" >> "${MNT}/etc/fstab"
info "Written: ${MNT}/etc/fstab"

LUKS_UUID=$(cryptsetup luksUUID "${LUKS_DEV}")
echo "${LUKS_NAME}  UUID=${LUKS_UUID}  none  luks" >> "${MNT}/etc/crypttab"
info "Written: ${MNT}/etc/crypttab"
info "LUKS UUID: ${LUKS_UUID}"

# ── DONE ──────────────────────────────────────────────────────────────────────
hr
echo
echo -e "${GRN}  Bootstrap complete. System is ready for chroot configuration.${RST}"
echo
echo -e "  ${YEL}Chroot checklist:${RST}"
echo -e "    1.  locale-gen, /etc/locale.conf, /etc/hostname, /etc/hosts"
echo -e "    2.  ln -sf /usr/share/zoneinfo/<Region>/<City> /etc/localtime && hwclock --systohc"
echo -e "    3.  passwd  |  useradd -mG wheel <user>  |  visudo"
echo -e "    4.  Add ucode: pacman -S intel-ucode  OR  amd-ucode"
echo -e "    5.  mkinitcpio.conf — HOOKS must include 'encrypt' and 'lvm2':"
echo -e "          HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems fsck)"
echo -e "        Then run: mkinitcpio -P"
echo -e "    6.  GRUB — append to GRUB_CMDLINE_LINUX in /etc/default/grub:"
echo -e "          cryptdevice=UUID=${LUKS_UUID}:${LUKS_NAME} root=${LV_ROOT}"
echo -e "        Then: grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH"
echo -e "              grub-mkconfig -o /boot/grub/grub.cfg"
echo -e "        (or: bootctl install  if using systemd-boot)"
echo
read -rp "  Drop into arch-chroot /mnt now? [y/N] " _chroot
echo
if [[ "${_chroot,,}" == "y" ]]; then
    arch-chroot "${MNT}"
fi
