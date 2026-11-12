#!/usr/bin/env bash
# =============================================================================
# 02-debian-postinstall.sh
# Post-install for the Debian sid encrypted-btrfs desktop built by
# 01-debian-install.sh. Ported from kubuntu-postinstall.sh, plus the
# Debian/btrfs pieces (Snapper, grub-btrfs, minimal KDE, VFIO).
#
# Run as your NORMAL USER from the TTY after first boot, once you're online
# (nmtui). It asks yes/no before each step and takes a Snapper snapshot
# before every step that changes the system, so any step can be rolled back
# from the GRUB snapshot menu.
#
#    1. System update
#    2. Snapper + grub-btrfs (snapshots in the GRUB menu) + Btrfs Assistant GUI
#    3. Minimal KDE Plasma (+ optional extras)
#   3b. Intel graphics firmware (+ optional: turn GuC back on)
#    4. Core utilities + printing
#    5. Network tools
#    6. Sync & VPN: Syncthing, Tailscale, Mullvad
#    7. Virtualization: QEMU/KVM/libvirt, OVMF, swtpm, SMB, hugepages
#    8. GPU passthrough: NVIDIA card -> vfio-pci (auto-detected)
#    9. Flatpak + Flathub + apps
#   10. Brave Origin + RealVNC Viewer
#   11. Backup tools
#   12. UFW firewall (deny in / allow out + KDE Connect, Syncthing, Tailscale, libvirt)
#   13. apt-listbugs
#
# Intel graphics: the installer boots with i915.enable_guc=0 so the iGPU works
# without extra firmware. Mesa goes in with KDE (step 3). Step 3b installs
# firmware-intel-graphics ON ITS OWN, behind a snapshot. It's proven to work
# on this hardware, with or without GuC. NOT installed: intel-media-va-driver-non-free,
# a suspect in the two earlier white-dash boot freezes.
#
# Logs: ~/debian-postinstall.log
# =============================================================================
set -euo pipefail

LOG="$HOME/debian-postinstall.log"
SNAPPER_CFG=root

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ->\033[0m %s\n' "$*"; }
have() { command -v "$1" &>/dev/null; }

yesno() {
  local prompt=$1 default=${2:-n} reply hint
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$prompt $hint " reply || true
  reply=${reply:-$default}
  [[ ${reply,,} == y* ]]
}

# apt without dialogs; apt-listbugs stays quiet inside the script
APT=(sudo env DEBIAN_FRONTEND=noninteractive APT_LISTBUGS_FRONTEND=none apt-get -y
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Wait for the network (DNS) before downloads; let the user fix it if needed
wait_net() {

  for _ in {1..30}; do
    getent hosts deb.debian.org >/dev/null && return 0
    sleep 2
  done
  warn "No network. Fix it in another terminal (nmtui, or:"
  warn "  nmcli networking off && nmcli networking on), then press Enter."
  read -r _ || true
  getent hosts deb.debian.org >/dev/null
}

# retry CMD...  (3 tries, waiting for the network between them)
retry() {
  local n=1
  until "$@"; do
    ((n >= 3)) && return 1
    warn "Command failed (try $n/3): $*"
    wait_net || true
    n=$((n+1))
  done
}

# Install only packages that exist in the repos, so one renamed package
# doesn't abort the whole transaction (sid renames things).
apt_install() {
  local avail=() missing=() p
  for p in "$@"; do
    if apt-cache show "$p" &>/dev/null; then avail+=("$p"); else missing+=("$p"); fi
  done
  ((${#missing[@]})) && warn "Not in the repos, skipping: ${missing[*]}"
  if ((${#avail[@]})); then
    wait_net
    retry "${APT[@]}" install "${avail[@]}"
  fi
}

apt_install_norec() {
  local avail=() missing=() p
  for p in "$@"; do
    if apt-cache show "$p" &>/dev/null; then avail+=("$p"); else missing+=("$p"); fi
  done
  ((${#missing[@]})) && warn "Not in the repos, skipping: ${missing[*]}"
  if ((${#avail[@]})); then
    wait_net
    retry "${APT[@]}" install --no-install-recommends "${avail[@]}"
  fi
}

# Snapshot before a step (no-op until Snapper is set up in step 2)
snap() {
  if have snapper && sudo snapper -c "$SNAPPER_CFG" get-config &>/dev/null; then
    sudo snapper -c "$SNAPPER_CFG" create -c number --userdata important=yes -d "$1" && ok "Snapshot: $1"
  fi
}

# Any change to the initramfs must keep the LUKS keyfile in it, or the next
# boot asks for the passphrase twice (or not at all if something is off).
rebuild_initramfs() {
  sudo update-initramfs -u -k all
  local img bad=0
  for img in /boot/initrd.img-*; do
    if sudo lsinitramfs "$img" | grep -qE 'cryptroot/keyfiles/.+\.key'; then
      ok "Keyfile present in $(basename "$img")"
    else
      warn "Keyfile MISSING from $(basename "$img")"; bad=1
    fi
  done
  ((bad == 0)) || warn "Check /etc/crypttab and /etc/cryptsetup-initramfs/conf-hook before rebooting!"
}

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root. It uses sudo when needed." >&2
  exit 1
fi

exec > >(tee -a "$LOG") 2>&1
info "Debian sid post-install (log: $LOG)"
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

wait_net

# =============================================================================
# 1. System update
# =============================================================================
info "Step 1: Updating the system"
retry sudo apt-get update
retry "${APT[@]}" upgrade --with-new-pkgs
# full-upgrade only if it removes nothing (sid transitions can propose removals)
if sudo apt-get -s full-upgrade | grep -q '^Remv'; then
  warn "sid is mid-transition; holding back these (full-upgrade would remove them):"
  sudo apt-get -s full-upgrade | awk '/^Remv/ {print "      " $2}'
  warn "Run 'sudo apt full-upgrade' by hand in a few days, once sid settles."
else
  retry "${APT[@]}" full-upgrade
fi
apt_install curl ca-certificates gnupg git make gawk inotify-tools \
            pciutils usbutils lsb-release
ok "System up to date"

if have mokutil; then
  if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    ok "Secure Boot is enabled"
  else
    warn "Secure Boot is OFF. Turn it on in firmware (standard mode, factory keys) when convenient."
  fi
fi

# =============================================================================
# 2. Snapper + grub-btrfs
# =============================================================================
if yesno "Step 2: set up Snapper and grub-btrfs (snapshots in the GRUB menu)?" y; then
  info "Installing Snapper and Btrfs Assistant"
  apt_install snapper btrfs-progs btrfs-assistant   # btrfs-assistant: Qt GUI for Snapper/subvolumes

  if ! sudo snapper -c "$SNAPPER_CFG" get-config &>/dev/null; then
    # snapper create-config insists on creating its own nested .snapshots
    # subvolume; swap our @snapshots subvolume back in afterwards.
    sudo umount /.snapshots 2>/dev/null || true
    sudo rmdir /.snapshots 2>/dev/null || true
    sudo snapper -c "$SNAPPER_CFG" create-config /
    sudo btrfs subvolume delete /.snapshots
    sudo mkdir /.snapshots
    sudo mount -a
    sudo chmod 750 /.snapshots
    findmnt -no SOURCE /.snapshots | grep -q '@snapshots' \
      && ok "/.snapshots is the @snapshots subvolume" \
      || warn "/.snapshots is not mounted from @snapshots; check /etc/fstab"
  else
    ok "Snapper config '$SNAPPER_CFG' already exists"
  fi

  sudo snapper -c "$SNAPPER_CFG" set-config ALLOW_GROUPS=sudo SYNC_ACL=yes \
    TIMELINE_CREATE=yes TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=2 TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 \
    NUMBER_LIMIT=20 NUMBER_LIMIT_IMPORTANT=10
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  if compgen -G '/etc/apt/apt.conf.d/*snapper*' >/dev/null; then
    ok "Snapper apt hook present (pre/post snapshots on every apt run)"
  else
    warn "No Snapper apt hook found in /etc/apt/apt.conf.d/"
  fi

  info "Installing grub-btrfs"
  if dpkg -s grub-btrfs &>/dev/null || [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
    ok "grub-btrfs already installed"
  elif apt-cache show grub-btrfs &>/dev/null; then
    apt_install grub-btrfs
  else
    warn "grub-btrfs isn't in Debian's repos; installing from upstream"
    if [[ ! -d /opt/grub-btrfs ]]; then
      retry sudo git clone --depth 1 https://github.com/Antynea/grub-btrfs.git /opt/grub-btrfs
    else
      sudo git -C /opt/grub-btrfs pull --ff-only || true
    fi
    sudo make -C /opt/grub-btrfs install
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable --now grub-btrfsd.service \
    && ok "grub-btrfsd watching /.snapshots" \
    || warn "Couldn't start grub-btrfsd; check: systemctl status grub-btrfsd"

  sudo snapper -c "$SNAPPER_CFG" create -c number --userdata important=yes -d "baseline (post-install start)"
  sudo update-grub
  ok "Snapper + grub-btrfs ready"
fi

# =============================================================================
# 3. Minimal KDE Plasma (+ optional extras)
# =============================================================================
if yesno "Step 3: install minimal KDE Plasma?" y; then
  snap "pre-KDE"
  info "Installing minimal KDE Plasma (no recommends)"
  KDE_PKGS=(
    plasma-desktop plasma-workspace kwin-wayland   # shell, panel, compositor
    sddm sddm-theme-breeze                         # login screen
    plasma-nm                                      # network applet
    plasma-pa pipewire-audio wireplumber           # sound + volume applet
    konsole dolphin                                # terminal, file manager
    systemsettings kscreen powerdevil              # settings, displays, power
    power-profiles-daemon                          # Power Save / Balanced / Performance modes
    kde-config-screenlocker kscreenlocker-dev      # Screen Locking page in System Settings
    xdg-desktop-portal-kde polkit-kde-agent-1      # file pickers, admin prompts
    breeze fonts-noto-core                         # theme, fonts
    libgl1-mesa-dri libegl-mesa0 libglx-mesa0      # Mesa OpenGL/EGL (userspace only)
    mesa-vulkan-drivers
    kwalletmanager libpam-kwallet5                 # wallet unlocks at SDDM login (no Brave prompts)
    ksshaskpass openssh-client                     # SSH key passphrase from KDE Wallet
  )
  apt_install_norec "${KDE_PKGS[@]}"
  sudo systemctl enable sddm.service
  sudo systemctl set-default graphical.target
  ok "Plasma installed; SDDM starts on next boot"

  # KDE Wallet auto-unlock: pam_kwallet5 opens 'kdewallet' with your login
  # password at SDDM, so Brave and other apps don't prompt for it.
  if grep -q 'pam_kwallet5' /etc/pam.d/sddm 2>/dev/null; then
    ok "pam_kwallet5 is in SDDM's PAM stack (wallet unlocks at login)"
  elif [[ -f /etc/pam.d/sddm ]]; then
    warn "Adding pam_kwallet5 to /etc/pam.d/sddm"
    sudo sed -i '/^@include common-auth/a -auth   optional        pam_kwallet5.so' /etc/pam.d/sddm
    sudo sed -i '/^@include common-session/a -session optional        pam_kwallet5.so auto_start' /etc/pam.d/sddm
    grep -q 'pam_kwallet5' /etc/pam.d/sddm && ok "pam_kwallet5 added to SDDM" \
      || warn "Couldn't add pam_kwallet5; check /etc/pam.d/sddm"
  fi

  # SSH agent + KDE Wallet. Debian's openssh-client already provides a
  # per-session agent (ssh-agent.socket -> $XDG_RUNTIME_DIR/openssh_agent),
  # so we only add: ksshaskpass for the passphrase (stored in KDE Wallet)
  # and an autostart that loads the key at login. Don't create a custom
  # ssh-agent.service: it shadows Debian's and every ssh/git call hangs.
  info "Setting up SSH key unlock via KDE Wallet"
  mkdir -p "$HOME/.config/environment.d" "$HOME/.config/autostart" "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  rm -f "$HOME/.config/systemd/user/ssh-agent.service"   # remove any old custom unit
  cat > "$HOME/.config/environment.d/ssh.conf" <<'EOF'
SSH_ASKPASS=/usr/bin/ksshaskpass
SSH_ASKPASS_REQUIRE=prefer
EOF
  cat > "$HOME/.config/autostart/ssh-add.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SSH key (from KDE Wallet)
Exec=sh -c 'ssh-add -q < /dev/null'
X-KDE-autostart-phase=2
EOF
  if ! grep -qs AddKeysToAgent "$HOME/.ssh/config"; then
    printf 'Host *\n    AddKeysToAgent yes\n' >> "$HOME/.ssh/config"
  fi
  chmod 600 "$HOME/.ssh/config"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable ssh-agent.socket 2>/dev/null \
    && ok "Debian's ssh-agent.socket enabled; key passphrase comes from KDE Wallet" \
    || warn "After logging in to Plasma, check: systemctl --user status ssh-agent.socket"

  if yesno "  Also install the KDE extras (Dolphin plugins, Gwenview, Spectacle, KDE Connect, Discover)?" y; then
    KDE_EXTRAS=(
      dolphin-plugins          # Git/SVN status, mount ISO, etc. in Dolphin
      gwenview                 # image viewer
      kde-spectacle            # screenshots
      kdeconnect               # phone integration (ports opened in step 12)
      plasma-discover packagekit plasma-discover-backend-flatpak   # software center
      bluedevil                # Bluetooth
      ark kate                 # archives, text editor
      plasma-systemmonitor
      kde-config-sddm          # login-screen settings page
      plasma-firewall          # Firewall page in System Settings (manages UFW)
      print-manager            # Printers page in System Settings
    )
    apt_install_norec "${KDE_EXTRAS[@]}"
    ok "KDE extras installed"
  fi
fi

# =============================================================================
# 3b. Intel graphics firmware (DMC, GuC, HuC) + optional GuC enable
# =============================================================================
if yesno "Step 3b: install the Intel graphics firmware (firmware-intel-graphics)?" y; then
  snap "pre-intel-firmware"
  info "Installing firmware-intel-graphics (on its own)"
  apt_install firmware-intel-graphics
  rebuild_initramfs
  ok "Intel firmware installed. With i915.enable_guc=0 still set, the DMC"
  ok "firmware loads after reboot (display power management)."

  if grep -q 'i915.enable_guc=0' /etc/default/grub; then
    warn "GuC is currently disabled (i915.enable_guc=0)."
    warn "With the firmware in place GuC worked on this hardware, but if the next"
    warn "boot hangs at a white dash: GRUB -> snapshots -> 'pre-enable-guc'."
    if yesno "  Turn GuC back on (remove i915.enable_guc=0)?" n; then
      snap "pre-enable-guc"
      sudo sed -i 's/ i915.enable_guc=0//' /etc/default/grub
      sudo update-grub
      ok "GuC enabled from next boot. Check after reboot: sudo dmesg | grep -i guc"
    else
      ok "Keeping i915.enable_guc=0 (safe default). To test GuC once: at GRUB press 'e',"
      ok "delete i915.enable_guc=0 from the 'linux' line, Ctrl+X."
    fi
  fi
fi

# =============================================================================
# 4. Core utilities + printing
# =============================================================================
if yesno "Step 4: install core utilities and printing?" y; then
  snap "pre-core-utils"
  info "Installing core utilities and printing"
  CORE_PKGS=(
    plocate                  # fast 'locate'
    man-db manpages
    wget git rclone rsync
    unzip zip 7zip
    htop btop tree jq fastfetch
    fonts-terminus fonts-terminus-otb   # Terminus for Konsole too

    # Printing
    cups cups-filters cups-browsed
    printer-driver-cups-pdf  # print-to-PDF
    printer-driver-gutenprint
    ghostscript
    print-manager

    # Network printer discovery
    avahi-daemon libnss-mdns
  )
  apt_install "${CORE_PKGS[@]}"
  sudo systemctl enable --now cups.service avahi-daemon.service 2>/dev/null || true
  sudo systemctl enable --now plocate-updatedb.timer 2>/dev/null || true
  sudo usermod -aG lpadmin "$USER"
  ok "Core utilities and printing installed"
fi

# =============================================================================
# 5. Network tools
# =============================================================================
if yesno "Step 5: install network tools?" y; then
  snap "pre-network-tools"
  info "Installing network tools"
  NET_PKGS=(
    bind9-dnsutils bind9-host         # dig, nslookup, host
    iputils-ping iputils-tracepath iputils-arping
    inetutils-telnet
    net-tools                         # ifconfig, netstat (legacy)
    traceroute mtr-tiny
    nmap tcpdump iperf3 ethtool whois
    netcat-openbsd
  )
  apt_install "${NET_PKGS[@]}"
  ok "Network tools installed"
fi

# =============================================================================
# 6. Sync & VPN: Syncthing, Tailscale, Mullvad
# =============================================================================
if yesno "Step 6: install Syncthing, Tailscale and Mullvad VPN?" y; then
  snap "pre-sync-vpn"

  info "Installing Syncthing"
  apt_install syncthing
  systemctl --user enable syncthing.service 2>/dev/null \
    && ok "Syncthing enabled as a user service (http://127.0.0.1:8384 after login)" \
    || warn "Enable it after logging in to Plasma: systemctl --user enable --now syncthing"

  info "Installing Tailscale"
  if have tailscale; then
    ok "Tailscale already installed"
  elif wait_net && curl -fsSL https://tailscale.com/install.sh | sh; then
    ok "Tailscale installed"
  else
    warn "Tailscale install failed. Retry with: curl -fsSL https://tailscale.com/install.sh | sh"
  fi
  have tailscale && sudo systemctl enable tailscaled.service

  info "Installing Mullvad VPN"
  if ! dpkg -s mullvad-vpn &>/dev/null; then
    retry sudo curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
      https://repository.mullvad.net/deb/mullvad-keyring.asc
    echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$(dpkg --print-architecture)] https://repository.mullvad.net/deb/stable stable main" \
      | sudo tee /etc/apt/sources.list.d/mullvad.list >/dev/null
    retry sudo apt-get update
  fi
  apt_install mullvad-vpn
  if dpkg -s mullvad-vpn &>/dev/null; then
    sudo systemctl enable mullvad-daemon.service
    ok "Mullvad VPN installed (daemon starts on next boot)"
  fi
fi

# =============================================================================
# 7. Virtualization: QEMU / KVM / libvirt + TPM + SMB + hugepages
# =============================================================================
if yesno "Step 7: install the virtualization stack?" y; then
  snap "pre-virtualization"
  info "Installing virtualization stack"
  VIRT_PKGS=(
    qemu-system-x86 qemu-utils
    libvirt-daemon-system libvirt-clients
    virt-manager virt-viewer virtinst
    ovmf                     # UEFI + Secure Boot firmware for Win11
    swtpm swtpm-tools        # TPM 2.0 for Win11
    dnsmasq-base
    virtiofsd
    bridge-utils
    cpu-checker              # kvm-ok

    # SMB / CIFS
    samba smbclient cifs-utils kio-extras
  )
  apt_install "${VIRT_PKGS[@]}"

  info "Configuring virtualization"
  [[ -e /dev/kvm ]] && ok "KVM is available" \
    || warn "/dev/kvm missing: enable Intel VT-x and VT-d in firmware"
  sudo systemctl enable --now libvirtd.service 2>/dev/null || true
  sudo usermod -aG libvirt,kvm "$USER"

  mkdir -p "$HOME/.config/libvirt"
  grep -qs '^uri_default' "$HOME/.config/libvirt/libvirt.conf" \
    || echo 'uri_default = "qemu:///system"' >> "$HOME/.config/libvirt/libvirt.conf"

  # Move libvirt's NAT network off 192.168.122.x if the LAN already uses it
  if sudo virsh net-info default &>/dev/null; then
    if ip -4 route | grep -v virbr | grep -q '192\.168\.122\.'; then
      warn "Your LAN uses 192.168.122.0/24; moving libvirt's network to 192.168.123.0/24"
      sudo virsh net-destroy default 2>/dev/null || true
      sudo virsh net-dumpxml default | sed 's/192\.168\.122\./192.168.123./g' > /tmp/default-net.xml
      sudo virsh net-define /tmp/default-net.xml && rm -f /tmp/default-net.xml
    fi
    sudo virsh net-autostart default >/dev/null
    sudo virsh net-start default 2>/dev/null || true
    ok "libvirt 'default' network active and set to autostart"
  fi

  # Samba server off until you configure shares
  sudo systemctl disable --now smbd.service nmbd.service 2>/dev/null || true

  # VM disk images must live on the No_COW subvolume
  if lsattr -d /var/lib/libvirt/images 2>/dev/null | awk '{print $1}' | grep -q C; then
    ok "/var/lib/libvirt/images is No_COW (+C)"
  else
    warn "/var/lib/libvirt/images is NOT No_COW. If it's empty: sudo chattr +C /var/lib/libvirt/images"
  fi

  # Hugepages for the Win11 VM
  MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  if yesno "  Reserve hugepages for the Win11 VM? (this RAM is set aside permanently)" y; then
    read -r -p "  VM memory in GiB [16] (host has ~${MEM_GB} GiB): " HP_GB || true
    HP_GB=${HP_GB:-16}
    if [[ $HP_GB =~ ^[0-9]+$ ]] && ((HP_GB > 0 && HP_GB < MEM_GB - 8)); then
      echo "vm.nr_hugepages = $((HP_GB * 512))" | sudo tee /etc/sysctl.d/40-hugepages.conf >/dev/null
      sudo sysctl --system >/dev/null
      ok "Hugepages: $((HP_GB * 512)) x 2 MiB = ${HP_GB} GiB ($(awk '/HugePages_Total/ {print $2}' /proc/meminfo) allocated now; all after reboot)"
    else
      warn "Skipped: enter a whole number leaving at least 8 GiB for the host."
    fi
  fi
  ok "Virtualization configured (Samba server left disabled)"
fi

# =============================================================================
# 8. GPU passthrough: NVIDIA -> vfio-pci
# =============================================================================
if yesno "Step 8: bind the NVIDIA card to vfio-pci for passthrough?" y; then
  info "Detecting NVIDIA devices"
  mapfile -t NV_LINES < <(lspci -Dnn -d 10de: || true)
  if ((${#NV_LINES[@]} == 0)); then
    warn "No NVIDIA devices found; skipping."
  else
    printf '    %s\n' "${NV_LINES[@]}"
    NV_IDS=$(printf '%s\n' "${NV_LINES[@]}" | grep -o '\[10de:[0-9a-f]\{4\}\]' | tr -d '[]' | sort -u | paste -sd, -)

    # Warn if the NVIDIA card is the boot display (should be the iGPU)
    for line in "${NV_LINES[@]}"; do
      addr=${line%% *}
      if [[ $(cat "/sys/bus/pci/devices/$addr/boot_vga" 2>/dev/null) == 1 ]]; then
        warn "$addr is the BOOT display. Set the iGPU as primary in firmware and"
        warn "plug the monitor into the motherboard, or you'll get no host display."
      fi
    done

    if [[ -z $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; then
      warn "IOMMU is not active. Check VT-d in firmware and intel_iommu=on in /proc/cmdline."
    else
      for line in "${NV_LINES[@]}"; do
        addr=${line%% *}
        grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$addr/iommu_group")" 2>/dev/null || echo '?')
        ok "$addr is in IOMMU group $grp"
      done
    fi

    if yesno "  Bind these IDs to vfio-pci: $NV_IDS ?" y; then
      snap "pre-vfio"
      sudo tee /etc/modprobe.d/vfio.conf >/dev/null <<EOF
# T1000 (and its audio function) reserved for the Win11 VM
options vfio-pci ids=$NV_IDS
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
      for m in vfio vfio_iommu_type1 vfio_pci; do
        grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" | sudo tee -a /etc/initramfs-tools/modules >/dev/null
      done
      rebuild_initramfs
      ok "vfio-pci binding set; after reboot check: lspci -nnk -d 10de:"
    fi
  fi
fi

# =============================================================================
# 9. Flatpak apps
# =============================================================================
if yesno "Step 9: install Flatpak and apps?" y; then
  snap "pre-flatpak"
  info "Installing Flatpak"
  apt_install flatpak
  dpkg -s plasma-discover &>/dev/null && apt_install_norec plasma-discover-backend-flatpak
  retry sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

  FLATPAKS=(
    com.github.tchx84.Flatseal              # Flatpak permissions editor
    io.github.flattool.Warehouse            # Flatpak manager
    io.github.giantpinkrobots.flatsweep     # leftover cleaner
    com.microsoft.Edge
    com.ticktick.TickTick
    net.cozic.joplin_desktop
    org.fkoehler.KTailctl                   # Tailscale GUI for KDE
    org.gnome.Calculator
    org.kde.kamoso                          # webcam
    org.libreoffice.LibreOffice
    org.mozilla.Thunderbird
    us.zoom.Zoom
    org.gtk.Gtk3theme.Breeze                # Breeze for GTK Flatpaks
  )
  info "Installing Flatpak apps"
  wait_net
  retry sudo flatpak install -y --noninteractive --system flathub "${FLATPAKS[@]}"
  ok "Flatpak apps installed"
fi

# =============================================================================
# 10. Vendor apps: Brave Origin, RealVNC Viewer
# =============================================================================
if yesno "Step 10: install Brave Origin and RealVNC Viewer?" y; then
  snap "pre-vendor-apps"
  info "Installing Brave Origin (official Brave installer)"
  if dpkg -s brave-origin &>/dev/null; then
    ok "Brave Origin already installed"
  elif wait_net && curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh; then
    ok "Brave Origin installed"
  else
    warn "Brave Origin install failed. Retry: curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh"
  fi

  info "Installing RealVNC Viewer"
  if dpkg -s realvnc-vnc-viewer &>/dev/null; then
    ok "RealVNC Viewer already installed"
  else
    shopt -s nullglob
    VNC_DEBS=("$HOME"/Downloads/VNC-Viewer-*-Linux-x64.deb "$HOME"/VNC-Viewer-*-Linux-x64.deb)
    shopt -u nullglob
    if ((${#VNC_DEBS[@]})); then
      VNC_DEB=$(printf '%s\n' "${VNC_DEBS[@]}" | sort -V | tail -n1)
      retry "${APT[@]}" install "$VNC_DEB"
      ok "RealVNC Viewer installed from $(basename "$VNC_DEB")"
    else
      warn "No VNC-Viewer-*-Linux-x64.deb in ~/Downloads. Get the DEB x64 from"
      warn "  https://www.realvnc.com/en/connect/download/viewer/linux/"
      warn "then: sudo apt install ~/Downloads/VNC-Viewer-*-Linux-x64.deb"
    fi
  fi
fi

# =============================================================================
# 11. Backup tools
# =============================================================================
if yesno "Step 11: install backup tools?" y; then
  snap "pre-backup-tools"
  info "Installing backup tools"
  # No Timeshift: Snapper already handles system snapshots on btrfs, and
  # running both against the same subvolumes causes conflicts.
  BACKUP_PKGS=(
    restic                  # encrypted, deduplicated backups
    borgbackup borgmatic    # Borg + config-driven runs
    vorta                   # Qt GUI for Borg
    rsync rclone
    btrfs-progs             # btrfs send/receive for snapshot backups
    partclone clonezilla    # imaging
  )
  apt_install "${BACKUP_PKGS[@]}"
  ok "Backup tools installed"
fi

# =============================================================================
# 12. UFW firewall
# =============================================================================
if yesno "Step 12: set up the UFW firewall?" y; then
  snap "pre-ufw"
  info "Configuring UFW"
  apt_install ufw
  sudo ufw default deny incoming
  sudo ufw default allow outgoing

  sudo ufw allow 1714:1764/tcp comment 'KDE Connect'
  sudo ufw allow 1714:1764/udp comment 'KDE Connect'
  ok "KDE Connect ports 1714-1764 open"

  if have syncthing; then
    sudo ufw allow 22000/tcp comment 'Syncthing'
    sudo ufw allow 22000/udp comment 'Syncthing'
    sudo ufw allow 21027/udp comment 'Syncthing discovery'
    ok "Syncthing ports open"
  fi

  if have tailscale; then
    sudo ufw allow in on tailscale0 comment 'Tailscale'
    ok "Inbound on tailscale0 allowed (Tailscale ACLs still apply)"
  fi

  if have virsh; then
    # libvirt NAT network (virbr0): DHCP + DNS from the host, and routing
    sudo ufw allow in on virbr0 to any port 67 proto udp comment 'libvirt DHCP'
    sudo ufw allow in on virbr0 to any port 53 comment 'libvirt DNS'
    sudo ufw route allow in on virbr0 comment 'libvirt NAT'
    sudo ufw route allow out on virbr0 comment 'libvirt NAT'
    ok "libvirt virbr0 rules added (bridged br0 VMs aren't filtered by UFW)"
  fi

  sudo ufw --force enable
  sudo systemctl enable --now ufw.service
  sudo ufw status verbose
  ok "UFW enabled"
fi

# =============================================================================
# 13. apt-listbugs (last, so it can't block the vendor installers above)
# =============================================================================
if yesno "Step 13: install apt-listbugs (warns about known sid bugs before upgrades)?" y; then
  apt_install apt-listbugs
  ok "apt-listbugs installed: 'sudo apt full-upgrade' now lists RC bugs and lets you pin"
fi

# =============================================================================
# Checks
# =============================================================================
info "Final checks"
FAILS=0
chk() { local d=$1; shift; if "$@" &>/dev/null; then ok "$d"; else warn "FAIL: $d"; FAILS=$((FAILS+1)); fi; }
chk "Root is the @ subvolume"            bash -c "findmnt -no SOURCE / | grep -q '\[/@\]'"
chk "Keyfile in current initramfs"       bash -c "sudo lsinitramfs /boot/initrd.img-\$(uname -r) | grep -qE 'cryptroot/keyfiles/.+\\.key'"
dpkg -s firmware-intel-graphics &>/dev/null && chk "firmware-intel-graphics in initramfs" bash -c "sudo lsinitramfs /boot/initrd.img-\$(uname -r) | grep -q 'i915/.*dmc'"
chk "Intel GPU not wedged"               bash -c "! sudo dmesg | grep -qi 'declaring it wedged'"
have snapper  && chk "Snapper config '$SNAPPER_CFG'"       sudo snapper -c "$SNAPPER_CFG" get-config
have snapper  && chk "grub-btrfsd running"                 systemctl is-active grub-btrfsd
dpkg -s sddm &>/dev/null && chk "SDDM enabled"             systemctl is-enabled sddm
have virsh    && chk "libvirtd active"                     systemctl is-active libvirtd
[[ -f /etc/modprobe.d/vfio.conf ]] && chk "vfio.conf present" test -s /etc/modprobe.d/vfio.conf
dpkg -s sddm &>/dev/null && chk "KDE Wallet unlocks at login (pam_kwallet5)" grep -q pam_kwallet5 /etc/pam.d/sddm
[[ -f $HOME/.config/autostart/ssh-add.desktop ]] && chk "No custom ssh-agent.service shadowing Debian's" test ! -e "$HOME/.config/systemd/user/ssh-agent.service"
have ufw      && chk "UFW active"                          bash -c "sudo ufw status | grep -q 'Status: active'"
((FAILS)) && warn "$FAILS check(s) failed; see above and $LOG" || ok "All checks passed"

# Lean Hyper-V block that fixed the Win11 boot loop on the other PC
cat > "$HOME/win11-hyperv-block.xml" <<'EOF'
<!-- Paste into the Win11 VM's <features> (virsh edit). Leave out
     reenlightenment and stimer/direct: they caused the repair-loop boot.
     Keep VMX exposed (no vmx 'disable' line) so VBS/Credential Guard work. -->
<hyperv mode="custom">
  <relaxed state="on"/>
  <vapic state="on"/>
  <spinlocks state="on" retries="8191"/>
  <vpindex state="on"/>
  <runtime state="on"/>
  <synic state="on"/>
  <stimer state="on"/>
  <frequencies state="on"/>
  <tlbflush state="on"/>
  <ipi state="on"/>
  <avic state="on"/>
</hyperv>
<!-- Also add:  <memoryBacking><hugepages/></memoryBacking> -->
EOF
ok "Saved ~/win11-hyperv-block.xml for the VM"

echo
ok "Post-install complete."
cat <<'EOF'

Next steps:
  * Graphics: in Plasma, check the renderer says "Mesa Intel" (not llvmpipe):
      qdbus6 org.kde.KWin /KWin supportInformation | grep -i renderer
    and that the firmware loaded:  sudo dmesg | grep -iE 'dmc|guc'
    If boot hangs at a white dash: GRUB -> snapshots -> "pre-intel-firmware",
    then restore it with Btrfs Assistant.
  * KDE Wallet: let the first app create the wallet named 'kdewallet', type
    Blowfish (not GPG), password = your LOGIN password. It then opens
    automatically at every SDDM login. (Doesn't work with autologin; if you
    change your login password, change the wallet's in KWallet Manager too.)
  * SSH keys: if you have one (~/.ssh/id_ed25519), the first Plasma login
    asks for its passphrase. Tick "Remember password"; after that the key
    loads silently every login. Check with: ssh-add -l
  * Reboot: SDDM starts, group changes (libvirt, kvm, lpadmin) take effect,
    hugepages and vfio-pci binding apply.
  * After reboot:
      lspci -nnk -d 10de:        -> "Kernel driver in use: vfio-pci"
      grep Huge /proc/meminfo    -> HugePages_Total as reserved
      snapper list               -> snapshots; also in GRUB's snapshot menu
  * Tailscale:   sudo tailscale up
                 sudo tailscale set --operator=$USER   (KTailctl without root)
  * Mullvad:     mullvad account login <account-number>
  * Syncthing:   http://127.0.0.1:8384  (systemctl --user enable --now syncthing if not running)
  * Win11 VM:    virt-manager -> UEFI with Secure Boot, TPM 2.0 (CRB), VirtIO disk
                 in /var/lib/libvirt/images, add both NVIDIA PCI functions,
                 then apply ~/win11-hyperv-block.xml. Pin vCPUs to P-cores
                 (check 'lscpu -e'), emulator/iothreads to E-cores.
  * Samba:       server disabled; edit /etc/samba/smb.conf, then
                 sudo systemctl enable --now smbd
  * Backups:     restic or Borg for data; Snapper covers system rollback.
  * Rollback:    boot a snapshot from GRUB to test it, then make it permanent
                 with Btrfs Assistant (Snapper tab -> Restore) or the doc's section 5.

Note: Mullvad and Tailscale can conflict over routing/DNS when both are
connected. Mullvad's "Local network sharing" may be needed for VM <-> LAN.
EOF
if yesno "Reboot now?" y; then
  sudo systemctl reboot
fi
