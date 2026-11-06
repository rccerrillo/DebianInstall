#!/usr/bin/env bash
# =============================================================================
# 01-debian-install.sh
# Debian sid on one NVMe: LUKS (PBKDF2, GRUB-readable) + btrfs + Snapper-ready
# subvolumes, /boot inside the encrypted root, shim + GRUB (Secure Boot),
# one passphrase per boot (keyfile in the initramfs), zram, big Terminus font.
#
# Run from a Debian LIVE USB session, as root:
#   sudo -i
#   ./01-debian-install.sh            # full install (default)
#   ./01-debian-install.sh check      # unlock + mount the installed system, run checks
#   ./01-debian-install.sh mount      # unlock + mount it at /mnt for a rescue chroot
#
# Layout:
#   p1  1 GiB  FAT32 ESP            -> /boot/efi   (shim + GRUB only)
#   p2  rest   LUKS -> cryptroot    -> btrfs
#        @                -> /            (includes /boot; snapshotted)
#        @home            -> /home
#        @snapshots       -> /.snapshots
#        @var_log         -> /var/log
#        @var_cache       -> /var/cache
#        @libvirt_images  -> /var/lib/libvirt/images  (chattr +C, no CoW)
#
# Intel graphics: this script installs only the base firmware, and boots with
# i915.enable_guc=0 so the iGPU works without firmware-intel-graphics.
# 02-debian-postinstall.sh step 3b then installs firmware-intel-graphics on
# its own (behind a snapshot) and can turn GuC back on. Installing it together
# with the VA-API driver froze boot (white dash) twice, so they stay separate.
#
# After the reboot, log in on the TTY, connect with 'nmtui', then run
# 02-debian-postinstall.sh as your normal user.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Settings (defaults; most are asked for interactively)
# -----------------------------------------------------------------------------
MNT=/mnt
MAPPER=cryptroot
SUITE=sid
MIRROR=http://deb.debian.org/debian
ESP_SIZE=1G
PBKDF_ITER_MS=1500          # keeps GRUB's (slow) PBKDF2 unlock to a few seconds
BTRFS_OPTS=noatime,compress=zstd:1,space_cache=v2
CONSOLE_FONTFACE=Terminus
CONSOLE_FONTSIZE=16x32
# i915.enable_guc=0: without firmware-intel-graphics, the sid kernel's i915
# can't load GuC firmware and declares the iGPU "wedged" (llvmpipe + flicker).
# Turning GuC off keeps first boot working; post-install step 3b can remove it.
# No 'quiet' so you can see where boot stops.
KERNEL_CMDLINE="intel_iommu=on iommu=pt i915.enable_guc=0"
LOG=/root/01-debian-install.log

# Subvolume -> mountpoint (order matters: @ first)
SUBVOLS=(@ @home @snapshots @var_log @var_cache @libvirt_images)
declare -A SUBVOL_MNT=(
  [@]=/
  [@home]=/home
  [@snapshots]=/.snapshots
  [@var_log]=/var/log
  [@var_cache]=/var/cache
  [@libvirt_images]=/var/lib/libvirt/images
)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

yesno() {
  local prompt=$1 default=${2:-n} reply hint
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$prompt $hint " reply || true
  reply=${reply:-$default}
  [[ ${reply,,} == y* ]]
}

ask() {   # ask VAR "Prompt" "default"
  local __var=$1 prompt=$2 default=${3:-} reply
  read -r -p "$prompt${default:+ [$default]}: " reply || true
  printf -v "$__var" '%s' "${reply:-$default}"
}

# Partition device name: nvme0n1 -> nvme0n1p1, sda -> sda1
part() { [[ $1 =~ [0-9]$ ]] && echo "${1}p$2" || echo "${1}$2"; }

FAILS=0
check() {  # check "description" command...
  local desc=$1; shift
  if "$@" &>/dev/null; then ok "$desc"; else warn "FAIL: $desc"; FAILS=$((FAILS+1)); fi
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root: 'sudo -i' first, then run this script."; }

# -----------------------------------------------------------------------------
# Mount / unmount the target (used by install, check and mount)
# -----------------------------------------------------------------------------
mount_target() {
  local dev=/dev/mapper/$MAPPER sv mp opts
  mountpoint -q "$MNT" && return 0
  for sv in "${SUBVOLS[@]}"; do
    mp=$MNT${SUBVOL_MNT[$sv]}
    mkdir -p "$mp"
    opts="$BTRFS_OPTS,subvol=/$sv"
    [[ $sv == @libvirt_images ]] && opts="noatime,subvol=/$sv"   # no compression on VM images
    mount -o "$opts" "$dev" "$mp"
  done
  mkdir -p "$MNT/boot/efi"
  mount "$ESP" "$MNT/boot/efi"
}

umount_target() {
  sync
  umount -R "$MNT" 2>/dev/null || true
  cryptsetup close "$MAPPER" 2>/dev/null || true
}

find_disk_parts() {
  ESP=$(part "$DISK" 1)
  LUKSPART=$(part "$DISK" 2)
  [[ -b $ESP && -b $LUKSPART ]] || die "Expected $ESP and $LUKSPART to exist."
}

open_luks() {
  [[ -e /dev/mapper/$MAPPER ]] && return 0
  cryptsetup open --allow-discards "$LUKSPART" "$MAPPER"
}

pick_disk() {
  echo
  lsblk -d -e 7,11 -o NAME,SIZE,MODEL,TRAN
  echo
  local default
  default=$(lsblk -dn -e 7,11 -o NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print "/dev/"$1; exit}')
  ask DISK "Target disk" "${default:-/dev/nvme0n1}"
  [[ -b $DISK ]] || die "$DISK is not a block device."
}

# -----------------------------------------------------------------------------
# Post-install checks (also used by the 'check' subcommand)
# -----------------------------------------------------------------------------
run_checks() {
  FAILS=0
  local kver
  info "Checking the installed system"
  check "ESP has shimx64.efi"                    test -f "$MNT/boot/efi/EFI/debian/shimx64.efi"
  check "ESP has grubx64.efi"                    test -f "$MNT/boot/efi/EFI/debian/grubx64.efi"
  check "ESP grub.cfg unlocks LUKS (cryptomount)" grep -q cryptomount "$MNT/boot/efi/EFI/debian/grub.cfg"
  check "GRUB_ENABLE_CRYPTODISK=y set"           grep -q '^GRUB_ENABLE_CRYPTODISK=y' "$MNT/etc/default/grub"
  check "Kernel cmdline has intel_iommu=on"      grep -q 'intel_iommu=on' "$MNT/boot/grub/grub.cfg"
  check "Kernel cmdline has i915.enable_guc=0"   grep -q 'i915.enable_guc=0' "$MNT/boot/grub/grub.cfg"
  check "GRUB root is the @ subvolume"           grep -q 'rootflags=subvol=@' "$MNT/boot/grub/grub.cfg"
  check "/etc/crypttab uses the keyfile"         grep -q '/etc/keys/root.key' "$MNT/etc/crypttab"
  check "Keyfile exists and is 0400"             bash -c "[[ \$(stat -c %a '$MNT/etc/keys/root.key') == 400 ]]"
  check "KEYFILE_PATTERN set for initramfs"      grep -q 'KEYFILE_PATTERN=' "$MNT/etc/cryptsetup-initramfs/conf-hook"
  check "initramfs UMASK=0077"                   grep -q '^UMASK=0077' "$MNT/etc/initramfs-tools/initramfs.conf"
  for kver in "$MNT"/boot/initrd.img-*; do
    [[ -e $kver ]] || continue
    check "Keyfile inside $(basename "$kver")"   bash -c "lsinitramfs '$kver' | grep -qE 'cryptroot/keyfiles/.+\\.key'"
    check "$(basename "$kver") is mode 600"      bash -c "[[ \$(stat -c %a '$kver') == 600 ]]"
  done
  check "fstab mounts by subvol= name"           grep -q 'subvol=/@[[:space:],]' "$MNT/etc/fstab"
  check "fstab has no subvolid= (rollback-safe)" bash -c "! grep -q subvolid= '$MNT/etc/fstab'"
  check "VM image dir is No_COW (+C)"            bash -c "lsattr -d '$MNT/var/lib/libvirt/images' | awk '{print \$1}' | grep -q C"
  check "Persistent journal dir exists"          test -d "$MNT/var/log/journal"
  check "Console font is $CONSOLE_FONTFACE $CONSOLE_FONTSIZE" \
        grep -q "FONTSIZE=\"$CONSOLE_FONTSIZE\"" "$MNT/etc/default/console-setup"
  check "zram swap configured"                   grep -q '^ALGO=zstd' "$MNT/etc/default/zramswap"
  check "UEFI boot entry points at shim"         bash -c "efibootmgr -v | grep -qi shimx64"
  check "apt suite is $SUITE"                    grep -q "Suites: $SUITE" "$MNT/etc/apt/sources.list.d/debian.sources"
  echo
  if ((FAILS)); then
    warn "$FAILS check(s) failed. Fix them (or paste this output) before rebooting."
  else
    ok "All checks passed"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Subcommands: check / mount
# -----------------------------------------------------------------------------
cmd_check_or_mount() {
  need_root
  pick_disk
  find_disk_parts
  open_luks
  mount_target
  if [[ $1 == check ]]; then
    run_checks
    if yesno "Unmount and close the disk now?" y; then umount_target; fi
  else
    ok "Mounted at $MNT. Enter it with: arch-chroot $MNT"
    ok "When done: umount -R $MNT && cryptsetup close $MAPPER"
  fi
}

# =============================================================================
# Full install
# =============================================================================
cmd_install() {
  need_root
  exec > >(tee -a "$LOG") 2>&1
  info "Debian sid encrypted btrfs install (log: $LOG)"

  [[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode. Turn off CSM/Legacy boot in firmware."
  getent hosts deb.debian.org >/dev/null || die "No network/DNS. Connect first (nmtui or the network applet)."

  # ---------------------------------------------------------------------------
  # 0. Questions up front, then it runs unattended (except the user password)
  # ---------------------------------------------------------------------------
  pick_disk
  local HOST USERNAME TZONE PASS PASS2 HEADER_DIR
  ask HOST     "Hostname" ""
  [[ $HOST =~ ^[a-zA-Z0-9-]+$ ]] || die "Hostname must be letters, digits and dashes."
  ask USERNAME "Username" "robert"
  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."
  ask TZONE    "Time zone" "America/Phoenix"
  [[ -e /usr/share/zoneinfo/$TZONE ]] || die "Unknown time zone: $TZONE"
  ask HEADER_DIR "Folder to save the LUKS header backup (ideally a 2nd USB stick)" "/root"
  mkdir -p "$HEADER_DIR"

  while true; do
    read -r -s -p "LUKS passphrase (you'll type it at every boot): " PASS; echo
    read -r -s -p "Repeat passphrase: " PASS2; echo
    [[ -n $PASS && $PASS == "$PASS2" ]] && break
    warn "Empty or not matching. Try again."
  done
  unset PASS2

  echo
  warn "This ERASES EVERYTHING on $DISK:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK"
  local confirm
  read -r -p "Type the disk name ($DISK) to confirm: " confirm
  [[ $confirm == "$DISK" ]] || die "Not confirmed. Nothing was changed."

  # ---------------------------------------------------------------------------
  # 1. Live-session tools
  # ---------------------------------------------------------------------------
  info "Step 1: Installing tools in the live session"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    debootstrap arch-install-scripts gdisk btrfs-progs cryptsetup dosfstools binutils e2fsprogs
  ok "Live tools ready"

  # ---------------------------------------------------------------------------
  # 2. Can Debian's signed GRUB read LUKS2? Decide the LUKS version.
  # ---------------------------------------------------------------------------
  info "Step 2: Checking LUKS2 support in Debian's signed GRUB"
  local LUKS_TYPE=luks1 tmpd
  tmpd=$(mktemp -d)
  if (cd "$tmpd" && apt-get download grub-efi-amd64-signed >/dev/null 2>&1 \
        && dpkg-deb -x grub-efi-amd64-signed_*.deb g \
        && strings g/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed | grep -qi luks2); then
    LUKS_TYPE=luks2
    ok "Signed GRUB includes luks2 -> using LUKS2 (PBKDF2)"
  else
    warn "Couldn't confirm luks2 in signed GRUB -> using LUKS1 (equally secure with PBKDF2)"
  fi
  rm -rf "$tmpd"

  # ---------------------------------------------------------------------------
  # 3. Partition, encrypt, btrfs + subvolumes
  # ---------------------------------------------------------------------------
  info "Step 3: Partitioning $DISK"
  umount -R "$MNT" 2>/dev/null || true
  cryptsetup close "$MAPPER" 2>/dev/null || true
  swapoff -a || true
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:+"$ESP_SIZE" -t1:ef00 -c1:EFI \
         -n2:0:0           -t2:8309 -c2:cryptroot "$DISK"
  partprobe "$DISK" || true
  udevadm settle
  find_disk_parts
  mkfs.fat -F32 -n EFI "$ESP"
  ok "Partitions created"

  info "Encrypting $LUKSPART ($LUKS_TYPE, PBKDF2, ${PBKDF_ITER_MS} ms)"
  local fmt=(cryptsetup luksFormat --batch-mode --type "$LUKS_TYPE" --hash sha256 --iter-time "$PBKDF_ITER_MS")
  [[ $LUKS_TYPE == luks2 ]] && fmt+=(--pbkdf pbkdf2)
  printf '%s' "$PASS" | "${fmt[@]}" --key-file=- "$LUKSPART"
  printf '%s' "$PASS" | cryptsetup open --allow-discards --key-file=- "$LUKSPART" "$MAPPER"
  ok "LUKS container open as /dev/mapper/$MAPPER"

  local HDR
  HDR="$HEADER_DIR/luks-header-$HOST-$(date +%Y%m%d).img"
  cryptsetup luksHeaderBackup "$LUKSPART" --header-backup-file "$HDR"
  ok "LUKS header backed up to $HDR"

  info "Creating btrfs and subvolumes"
  mkfs.btrfs -f -L debian "/dev/mapper/$MAPPER"
  mount "/dev/mapper/$MAPPER" "$MNT"
  local sv
  for sv in "${SUBVOLS[@]}"; do btrfs subvolume create "$MNT/$sv"; done
  umount "$MNT"
  mount_target
  chattr +C "$MNT/var/lib/libvirt/images"     # must be set while the dir is empty
  ok "Subvolumes mounted; VM image dir set to No_COW"

  # ---------------------------------------------------------------------------
  # 4. Debootstrap sid + fstab
  # ---------------------------------------------------------------------------
  info "Step 4: debootstrap $SUITE (takes a few minutes)"
  debootstrap --arch=amd64 "$SUITE" "$MNT" "$MIRROR"
  genfstab -U "$MNT" >> "$MNT/etc/fstab"
  sed -i 's/subvolid=[0-9]*,//; s/,subvolid=[0-9]*//' "$MNT/etc/fstab"
  ok "Base system installed, fstab written (subvol= names only)"

  # ---------------------------------------------------------------------------
  # 5. Keyfile so the passphrase is typed once (created from the live side,
  #    so the passphrase never enters the chroot)
  # ---------------------------------------------------------------------------
  info "Step 5: Adding the initramfs keyfile"
  install -d -m 0700 "$MNT/etc/keys"
  dd if=/dev/urandom of="$MNT/etc/keys/root.key" bs=64 count=1 status=none
  chmod 0400 "$MNT/etc/keys/root.key"
  local addkey=(cryptsetup luksAddKey --batch-mode --key-file=- "$LUKSPART" "$MNT/etc/keys/root.key")
  if [[ $LUKS_TYPE == luks2 ]]; then
    addkey+=(--pbkdf pbkdf2 --pbkdf-force-iterations 1000)
  else
    addkey+=(--iter-time 1)
  fi
  printf '%s' "$PASS" | "${addkey[@]}"
  unset PASS
  local LUKS_UUID
  LUKS_UUID=$(blkid -s UUID -o value "$LUKSPART")
  echo "$MAPPER UUID=$LUKS_UUID /etc/keys/root.key luks,discard,key-slot=1" > "$MNT/etc/crypttab"
  ok "Keyfile in slot 1, crypttab written"

  # ---------------------------------------------------------------------------
  # 6. Configure inside the chroot
  # ---------------------------------------------------------------------------
  info "Step 6: Configuring the system (chroot)"
  cat > "$MNT/root/chroot-setup.sh" <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

# Hostname
echo "$HOST" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n\n::1 localhost ip6-localhost ip6-loopback\n' "$HOST" > /etc/hosts

# apt sources: sid, all components (firmware lives in non-free-firmware)
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
apt-get update

# Pre-answer debconf so nothing pops up a dialog
debconf-set-selections <<EOF
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
locales locales/default_environment_locale select en_US.UTF-8
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/modelcode string pc105
console-setup console-setup/charmap47 select UTF-8
console-setup console-setup/codeset47 select Guess optimal character set
console-setup console-setup/fontface47 select $FONTFACE
console-setup console-setup/fontsize-fb47 select $FONTSIZE
console-setup console-setup/fontsize-text47 select $FONTSIZE
EOF

# Locale + time zone
apt-get install -y locales tzdata
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
echo "$TZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata
ok "Locale en_US.UTF-8, time zone $TZONE"

# Big Terminus console font, set BEFORE the kernel so the first initramfs has it
apt-get install -y console-setup keyboard-configuration kbd
sed -i -e "s/^FONTFACE=.*/FONTFACE=\"$FONTFACE\"/" \
       -e "s/^FONTSIZE=.*/FONTSIZE=\"$FONTSIZE\"/" /etc/default/console-setup
grep -q '^FONTFACE=' /etc/default/console-setup || echo "FONTFACE=\"$FONTFACE\"" >> /etc/default/console-setup
grep -q '^FONTSIZE=' /etc/default/console-setup || echo "FONTSIZE=\"$FONTSIZE\"" >> /etc/default/console-setup
ok "Console font $FONTFACE $FONTSIZE"

# Persistent journal, so a failed boot leaves logs behind
mkdir -p /var/log/journal

# cryptsetup + keyfile in the initramfs (crypttab already written)
apt-get install -y cryptsetup cryptsetup-initramfs btrfs-progs
grep -q '^KEYFILE_PATTERN=' /etc/cryptsetup-initramfs/conf-hook \
  || echo 'KEYFILE_PATTERN="/etc/keys/*.key"' >> /etc/cryptsetup-initramfs/conf-hook
grep -q '^UMASK=0077' /etc/initramfs-tools/initramfs.conf \
  || echo 'UMASK=0077' >> /etc/initramfs-tools/initramfs.conf

# Kernel, base firmware, microcode, GRUB + shim (Secure Boot)
# NOTE: firmware-intel-graphics is added later by post-install step 3b.
apt-get install -y linux-image-amd64 firmware-linux intel-microcode \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr

grep -q '^GRUB_ENABLE_CRYPTODISK=' /etc/default/grub \
  && sed -i 's/^GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub \
  || echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"/" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
update-initramfs -u -k all
update-grub
ok "Kernel, initramfs and GRUB installed"

# Swap, network, sudo, helpers
apt-get install -y sudo network-manager zram-tools mokutil btrfs-progs \
  bash-completion ca-certificates curl nano less
sed -i 's/^#\?ALGO=.*/ALGO=zstd/; s/^#\?PERCENT=.*/PERCENT=25/' /etc/default/zramswap
grep -q '^ALGO=' /etc/default/zramswap    || echo 'ALGO=zstd'  >> /etc/default/zramswap
grep -q '^PERCENT=' /etc/default/zramswap || echo 'PERCENT=25' >> /etc/default/zramswap
systemctl enable NetworkManager zramswap 2>/dev/null || true
ok "zram, NetworkManager, sudo"

# User
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "$USERNAME"
fi
echo
echo "Set the login password for $USERNAME:"
until passwd "$USERNAME"; do echo "Try again."; done
passwd -l root >/dev/null
ok "User $USERNAME created (sudo); root login locked"
CHROOT
  chmod 700 "$MNT/root/chroot-setup.sh"

  arch-chroot "$MNT" /usr/bin/env \
    HOST="$HOST" USERNAME="$USERNAME" TZONE="$TZONE" SUITE="$SUITE" MIRROR="$MIRROR" \
    FONTFACE="$CONSOLE_FONTFACE" FONTSIZE="$CONSOLE_FONTSIZE" CMDLINE="$KERNEL_CMDLINE" \
    bash /root/chroot-setup.sh
  rm -f "$MNT/root/chroot-setup.sh"

  # Hand the post-install script to the new user if it sits next to this one
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f $here/02-debian-postinstall.sh ]]; then
    install -m 0755 "$here/02-debian-postinstall.sh" "$MNT/home/$USERNAME/02-debian-postinstall.sh"
    arch-chroot "$MNT" chown "$USERNAME:$USERNAME" "/home/$USERNAME/02-debian-postinstall.sh"
    ok "Copied 02-debian-postinstall.sh to /home/$USERNAME"
  else
    warn "02-debian-postinstall.sh not found next to this script; download it after first boot."
  fi
  cp "$LOG" "$MNT/var/log/01-debian-install.log" 2>/dev/null || true

  # ---------------------------------------------------------------------------
  # 7. Verify
  # ---------------------------------------------------------------------------
  run_checks

  echo
  warn "LUKS header backup: $HDR"
  warn "Copy it somewhere OFF this machine (vault / USB) before you reboot."
  [[ $HEADER_DIR == /root* ]] && warn "/root in a live session is RAM: it is gone after reboot."
  cat <<EOF

Next:
  1. Copy the LUKS header backup off this machine.
  2. Reboot, remove the USB. GRUB asks for the passphrase ONCE (a few seconds
     pause after you type it is normal), then Linux boots with no 2nd prompt.
  3. Log in as $USERNAME on the TTY. Connect to the network: nmtui
  4. Check:  journalctl -b | grep -i $MAPPER     (unlocked by keyfile)
  5. Firmware: turn Secure Boot ON (standard mode, factory keys), boot again:
             mokutil --sb-state                   -> SecureBoot enabled
  6. Run:    ~/02-debian-postinstall.sh

If something won't boot: boot this USB again, 'sudo -i', then
  ./01-debian-install.sh mount     and     arch-chroot $MNT
EOF
  if yesno "Unmount, close the disk and reboot now?" n; then
    umount_target
    systemctl reboot
  fi
}

# -----------------------------------------------------------------------------
case "${1:-install}" in
  install)      cmd_install ;;
  check|mount)  cmd_check_or_mount "$1" ;;
  *) echo "Usage: $0 [install|check|mount]" >&2; exit 2 ;;
esac
