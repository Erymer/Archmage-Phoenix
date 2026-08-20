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
# Production — comment these out when testing with the loop device harness
LUKS_DEV="/dev/nvme0n1p5"
LUKS_NAME="archmage"
VG_NAME="volgroup0"
EFI_PART="/dev/nvme0n1p4"

# Test — uncomment these and comment out the production block above
# LUKS_DEV="/dev/loop0"
# LUKS_NAME="archmage-test"
# VG_NAME="volgroup0test"
# EFI_PART=""

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

# Base packages. Both ucode packages are included — only the correct one
# will be loaded at boot based on the CPU detected by mkinitcpio.
BASE_PKGS=(
    base base-devel
    linux linux-firmware linux-headers
    linux-lts linux-lts-headers
    lvm2 cryptsetup
    btrfs-progs e2fsprogs dosfstools
    networkmanager
    vim sudo zsh
    intel-ucode amd-ucode
    polkit efibootmgr mtools
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

# Production: includes pacstrap, genfstab, arch-chroot
for cmd in cryptsetup vgchange mkfs.btrfs mkfs.ext4 btrfs pacstrap genfstab arch-chroot; do
    command -v "$cmd" &>/dev/null || die "Missing: '${cmd}' — booted into the Arch live ISO?"
done

# Testing: comment out the loop above and use this instead
# for cmd in cryptsetup vgchange mkfs.btrfs mkfs.ext4 btrfs; do
#     command -v "$cmd" &>/dev/null || die "Missing: '${cmd}'"
# done

# ── STEP 1 — LUKS ─────────────────────────────────────────────────────────────
hr; log "STEP 1 — LUKS"
if [[ -e "/dev/mapper/${LUKS_NAME}" ]]; then
    info "Container already open: /dev/mapper/${LUKS_NAME}"
else
    log "Opening ${LUKS_DEV} as '${LUKS_NAME}' ..."
    cryptsetup luksOpen "${LUKS_DEV}" "${LUKS_NAME}"
fi

# Retrieve UUID here so it's available for crypttab, boot entries, and the
# DONE summary — even if Steps 10–16 are commented out during testing.
LUKS_UUID=$(cryptsetup luksUUID "${LUKS_DEV}")
info "LUKS UUID: ${LUKS_UUID}"

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

# ── Comment out the EFI mount and Steps 9–16 when using the loop device harness

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

echo "${LUKS_NAME}  UUID=${LUKS_UUID}  none  luks" >> "${MNT}/etc/crypttab"
info "Written: ${MNT}/etc/crypttab"

# ── STEP 11 — TIME ZONE ───────────────────────────────────────────────────────
hr; log "STEP 11 — Time zone"
arch-chroot "${MNT}" ln -sf /usr/share/zoneinfo/Mexico/General /etc/localtime
arch-chroot "${MNT}" hwclock --systohc
info "Time zone set: Mexico/General"

# ── STEP 12 — LOCALE ──────────────────────────────────────────────────────────
hr; log "STEP 12 — Locale"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${MNT}/etc/locale.gen"
echo "LANG=en_US.UTF-8" > "${MNT}/etc/locale.conf"
arch-chroot "${MNT}" locale-gen
info "Locale: en_US.UTF-8"

# ── STEP 13 — HOSTNAME + NETWORK ──────────────────────────────────────────────
hr; log "STEP 13 — Hostname + network"
read -rp "  Enter hostname: " HOST_NAME
echo "${HOST_NAME}" > "${MNT}/etc/hostname"
cat > "${MNT}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain  ${HOST_NAME}
EOF
arch-chroot "${MNT}" systemctl enable NetworkManager
info "Hostname: ${HOST_NAME}"
info "NetworkManager enabled"

# ── STEP 14 — MKINITCPIO ──────────────────────────────────────────────────────
hr; log "STEP 14 — mkinitcpio"
sed -i -E 's/^HOOKS=\(.+\)/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)/' \
    "${MNT}/etc/mkinitcpio.conf"
arch-chroot "${MNT}" mkinitcpio -P
info "Initramfs built"

# ── STEP 15 — USERS ───────────────────────────────────────────────────────────
hr; log "STEP 15 — Users"

# Auto-detect the username from the preserved home directory instead of
# asking — a typed name that doesn't match the existing directory would
# leave the new account pointing at an empty home instead of the real data.
_home_dirs=()
for d in "${MNT}"/home/*/; do
    [[ -d "$d" ]] || continue
    _name=$(basename "$d")
    [[ "${_name}" == "lost+found" ]] && continue
    _home_dirs+=("${_name}")
done

if [[ ${#_home_dirs[@]} -eq 1 ]]; then
    USERNAME="${_home_dirs[0]}"
    info "Detected existing home directory: ${USERNAME}"
    read -rp "  Use '${USERNAME}' as the username? [Y/n] " _confirm_user
    [[ "${_confirm_user,,}" == "n" ]] && read -rp "  Enter username: " USERNAME
elif [[ ${#_home_dirs[@]} -gt 1 ]]; then
    warn "Multiple directories found under /home: ${_home_dirs[*]}"
    read -rp "  Enter username to use (must match one of the above): " USERNAME
else
    warn "No existing directories under /home — this looks like a fresh volume."
    read -rp "  Enter username: " USERNAME
fi

# --no-create-home means a missing directory here is NOT created for you —
# the account would end up with no home at all until you make one manually.
[[ -d "${MNT}/home/${USERNAME}" ]] || warn "No directory at /home/${USERNAME} — with --no-create-home it won't be auto-created. mkdir it before first login, or the account will have no home."

# TODO a way to confirm that the password was written correctly, like double input 
read -rsp "  Password for ${USERNAME}: " USER_PASSWD; echo
read -rsp "  Password for root: " ROOT_PASSWD; echo

# --no-create-home preserves existing data under /home/${USERNAME} from the
# home LV. The directory itself is not touched. Note: the new user will be
# assigned UID 1000. If your previous install used a different UID, file
# ownership will be mismatched — fix with:
#   chown -R 1000:1000 /mnt/home/${USERNAME}
arch-chroot "${MNT}" useradd \
    --no-create-home \
    --home-dir "/home/${USERNAME}" \
    --groups wheel \
    --shell /bin/zsh \
    "${USERNAME}"

printf '%s:%s\n' "${USERNAME}" "${USER_PASSWD}" | arch-chroot "${MNT}" chpasswd
printf '%s:%s\n' "root"        "${ROOT_PASSWD}" | arch-chroot "${MNT}" chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' \
    "${MNT}/etc/sudoers"
info "User '${USERNAME}' created and added to wheel"

# ── STEP 16 — BOOTLOADER (systemd-boot) ───────────────────────────────────────
hr; log "STEP 16 — systemd-boot"
# /boot is mounted but never formatted — existing loader.conf and boot entries
# survive intact. The LUKS UUID and LV paths are unchanged, so no entries need
# rewriting. Only update the EFI binary in case the freshly installed systemd
# package is newer than what's currently in /boot/EFI/.
arch-chroot "${MNT}" bootctl update
info "systemd-boot EFI binary updated"

# ── DONE ──────────────────────────────────────────────────────────────────────
hr
echo
echo -e "${GRN}  Bootstrap complete!${RST}"
echo
echo -e "  ${YEL}Verify before rebooting:${RST}"
echo -e "    cat ${MNT}/boot/loader/entries/arch.conf   ← check UUID + root path"
echo -e "    cat ${MNT}/etc/fstab                        ← check all mount points"
echo -e "    cat ${MNT}/etc/crypttab                     ← check LUKS UUID"
echo -e "    ls  ${MNT}/home/${USERNAME:-<user>}/         ← confirm home data survived"
echo
echo -e "  ${YEL}When satisfied:${RST}  umount -R ${MNT} && reboot"
echo
