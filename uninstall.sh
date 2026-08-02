#!/bin/bash
# =============================================================================
# Title       : uninstall.sh
# Description : Reverse everything ubuntu-look.sh installed or changed, and
#               restore your pre-install state where possible: packages
#               ubuntu-look.sh actually installed (tracked in
#               ~/.ubuntu-look-backup/installed-by-script.txt), the Ubuntu
#               apt repo/pin/keyring, the dconf system profile, GNOME
#               settings (from the one-time dconf dump ubuntu-look.sh takes
#               on its first run), GTK CSS/gtkrc, the Yaru light/dark sync
#               service, Ptyxis's Ubuntu palette + default-terminal wiring,
#               GRUB/Plymouth, /etc/environment, and /etc/apt/sources.list.
#
#               If ubuntu-look.sh was run before it gained the backup/
#               manifest feature, no snapshot will exist — this script falls
#               back to best-effort detection/removal in that case and says
#               so at every step where it's guessing rather than restoring.
#
# How to run  :   bash uninstall.sh
# Requires    : the same system ubuntu-look.sh was run on, user in 'sudo' group.
# =============================================================================

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

message() {
  case $1 in
    warn)   MT="${YELLOW}WARN${ENDCOLOR}" ;;
    error)  MT="${RED}ERROR${ENDCOLOR}"   ;;
    info|*) MT="${GREEN}INFO${ENDCOLOR}"  ;;
  esac
  shift
  echo -e "[${MT}] $*"
}

error() { message error "$@"; exit 1; }

confirm() {
  message warn "Type '${GREEN}y${ENDCOLOR}' or '${GREEN}yes${ENDCOLOR}' and hit [ENTER] to continue"
  read -r -p "[y/N?] " c
  [ "${c,,}" != "y" ] && [ "${c,,}" != "yes" ] && { message error "Aborted."; exit 1; }
}

step() {
  echo ""
  echo -e "${YELLOW}━━━ $1${ENDCOLOR}"
}

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

declare -a DONE=()
declare -a SKIPPED=()
declare -a GUESSED=()

[ "$(whoami)" = "root" ] && error "Do not run as root. Run as a normal user in the 'sudo' group."
groups | grep -q sudo || error "User $USER is not in the 'sudo' group."

###############################################################################
# Locate the pre-install snapshot + manifests ubuntu-look.sh may have left
###############################################################################

BACKUP_DIR="$HOME/.ubuntu-look-backup"
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
INSTALLED_MANIFEST="${BACKUP_DIR}/installed-by-script.txt"
REMOVED_MANIFEST="${BACKUP_DIR}/removed-by-script.txt"

HAVE_SNAPSHOT=0
[ -d "$BACKUP_ORIGINAL" ] && HAVE_SNAPSHOT=1

DCONF_PROFILE_FILE="/etc/dconf/db/local.d/10-ubuntu-look"
DCONF_USER_PROFILE="/etc/dconf/profile/user"
UBUNTU_KEYRING="/etc/apt/keyrings/ubuntu-archive.gpg"
UBUNTU_LIST="/etc/apt/sources.list.d/ubuntu-themes.list"
UBUNTU_PIN="/etc/apt/preferences.d/ubuntu-themes"

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
echo -e "${YELLOW}       ubuntu-look UNINSTALL${ENDCOLOR}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
echo ""
if [ $HAVE_SNAPSHOT -eq 1 ]; then
  echo -e "${GREEN}Pre-install snapshot found:${ENDCOLOR} ${BACKUP_ORIGINAL}"
  echo "  Your GNOME settings, GTK config, GRUB, /etc/environment, and apt"
  echo "  sources.list from before ubuntu-look.sh ever ran will be restored."
else
  echo -e "${YELLOW}No pre-install snapshot found${ENDCOLOR} (ubuntu-look.sh predates the backup"
  echo "  feature, or this is a different user/machine). Falling back to"
  echo "  best-effort detection: files ubuntu-look.sh writes are recognized by"
  echo "  content/name and removed; settings are reset to sane defaults"
  echo "  instead of restored to your exact prior values."
fi
echo ""
echo "This will:"
echo "  1. Disable ubuntu-dock / appindicators / tiling-assistant extensions"
echo "  2. Restore (or reset) GNOME settings"
echo "  3. Remove the dconf system profile"
echo "  4. Remove the Yaru light/dark sync service"
echo "  5. Restore (or remove) GTK CSS / gtkrc-2.0"
echo "  6. Remove Ptyxis's Ubuntu palette + default-terminal wiring"
echo "  7. Restore /etc/environment, GRUB, Plymouth theme"
echo "  8. Remove the Ubuntu apt repo, pin, and keyring"
echo "  9. Restore /etc/apt/sources.list"
echo "  10. Remove packages ubuntu-look.sh installed (Ubuntu wallpaper packs +"
echo "      tracked packages, or a conservative guess list if untracked)"
echo ""
confirm

###############################################################################
step_disable_extensions() {
  step "Disabling Ubuntu-specific extensions..."
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  fi
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gnome-extensions >/dev/null 2>&1; then
    for ext in ubuntu-dock@ubuntu.com ubuntu-appindicators@ubuntu.com tiling-assistant@ubuntu.com; do
      gnome-extensions disable "$ext" 2>/dev/null || true
    done
    DONE+=("Disabled ubuntu-dock / ubuntu-appindicators / tiling-assistant")
  else
    SKIPPED+=("No live session — extensions will simply not load after package removal")
  fi
}

###############################################################################
step_restore_gnome_settings() {
  step "Restoring GNOME settings..."
  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ]; then
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dconf >/dev/null 2>&1; then
      dconf load / < "${BACKUP_ORIGINAL}/dconf-dump.ini" 2>/dev/null \
        && DONE+=("GNOME settings restored from pre-install snapshot") \
        || SKIPPED+=("dconf load failed — settings not restored")
    else
      SKIPPED+=("No live D-Bus session — dconf snapshot not applied (will not self-apply later)")
    fi
  else
    GUESSED+=("No dconf snapshot available — GNOME settings left as ubuntu-look.sh set them, apart from the specific resets below")
  fi
}

###############################################################################
step_remove_dconf_profile() {
  step "Removing dconf system profile..."
  if [ -f "$DCONF_PROFILE_FILE" ]; then
    sudo rm -f "$DCONF_PROFILE_FILE"
    DONE+=("Removed ${DCONF_PROFILE_FILE}")
  fi
  if [ -f "$DCONF_USER_PROFILE" ] && grep -q "^system-db:local$" "$DCONF_USER_PROFILE"; then
    if [ "$(tr -d '[:space:]' < "$DCONF_USER_PROFILE")" = "user-db:usersystem-db:local" ]; then
      sudo rm -f "$DCONF_USER_PROFILE"
      DONE+=("Removed ${DCONF_USER_PROFILE} (only contained our system-db entry)")
    else
      sudo sed -i '/^system-db:local$/d' "$DCONF_USER_PROFILE"
      DONE+=("Removed the system-db:local line from ${DCONF_USER_PROFILE} (kept your other entries)")
    fi
    sudo dconf update 2>/dev/null || true
  fi
}

###############################################################################
step_remove_color_scheme_service() {
  step "Removing Yaru light/dark sync service..."
  if [ -f "$HOME/.config/systemd/user/yaru-color-scheme-sync.service" ] || [ -f "$HOME/.local/bin/yaru-color-scheme-sync.sh" ]; then
    systemctl --user disable --now yaru-color-scheme-sync.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/yaru-color-scheme-sync.service" "$HOME/.local/bin/yaru-color-scheme-sync.sh"
    systemctl --user daemon-reload 2>/dev/null || true
    DONE+=("Removed Yaru light/dark sync service")
  fi
}

###############################################################################
step_restore_gtk() {
  step "Restoring GTK CSS / gtkrc-2.0..."
  local pairs=(
    "gtk-3.0-gtk.css:$HOME/.config/gtk-3.0/gtk.css"
    "gtk-4.0-gtk.css:$HOME/.config/gtk-4.0/gtk.css"
    "gtk-3.0-settings.ini:$HOME/.config/gtk-3.0/settings.ini"
    "gtk-4.0-settings.ini:$HOME/.config/gtk-4.0/settings.ini"
    "gtkrc-2.0:$HOME/.gtkrc-2.0"
  )
  local pair backup_name target
  for pair in "${pairs[@]}"; do
    backup_name="${pair%%:*}"
    target="${pair#*:}"
    if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/${backup_name}" ]; then
      cp "${BACKUP_ORIGINAL}/${backup_name}" "$target"
      DONE+=("Restored $(basename "$target") from snapshot")
    elif [ -f "$target" ] && grep -q "E95420" "$target" 2>/dev/null; then
      rm -f "$target"
      GUESSED+=("Removed $(basename "$(dirname "$target")")/$(basename "$target") (contained our orange accent, no snapshot to restore)")
    fi
  done
}

###############################################################################
step_ptyxis() {
  step "Removing Ptyxis Ubuntu palette + default-terminal wiring..."
  rm -f "$HOME/.local/share/org.gnome.Ptyxis/palettes/Ubuntu.palette"

  local NAUTILUS_TERM_SCRIPT="$HOME/.local/share/nautilus/scripts/Open Terminal Here"
  if [ -f "$NAUTILUS_TERM_SCRIPT" ]; then
    rm -f "$NAUTILUS_TERM_SCRIPT"
    DONE+=("Removed Nautilus 'Open Terminal Here' script")
  fi

  local NAUTILUS_PTYXIS_EXT="$HOME/.local/share/nautilus-python/extensions/ubuntu_look_ptyxis.py"
  if [ -f "$NAUTILUS_PTYXIS_EXT" ]; then
    rm -f "$NAUTILUS_PTYXIS_EXT"
    DONE+=("Removed Nautilus 'Open Terminal Here' → Ptyxis extension")
  fi

  if [ -f "$REMOVED_MANIFEST" ] && grep -qx "nautilus-extension-gnome-terminal" "$REMOVED_MANIFEST" 2>/dev/null; then
    sudo apt-get install -y nautilus-extension-gnome-terminal 2>/dev/null \
      && DONE+=("Reinstalled nautilus-extension-gnome-terminal (ubuntu-look.sh had removed it)")
  fi

  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/ptyxis-profile.txt" ]; then
    # shellcheck disable=SC1090
    ( . "${BACKUP_ORIGINAL}/ptyxis-profile.txt" 2>/dev/null
      if [ -n "${uuid:-}" ]; then
        dconf write "/org/gnome/Ptyxis/Profiles/${uuid}/palette" "'${palette:-}'" 2>/dev/null || true
        dconf write "/org/gnome/Ptyxis/Profiles/${uuid}/label" "'${label:-}'" 2>/dev/null || true
      fi
    )
    DONE+=("Restored Ptyxis profile's original palette/label")
  else
    local CUR_UUID CUR_PALETTE
    CUR_UUID="$(dconf read /org/gnome/Ptyxis/default-profile-uuid 2>/dev/null | tr -d \')"
    if [ -n "$CUR_UUID" ]; then
      CUR_PALETTE="$(dconf read "/org/gnome/Ptyxis/Profiles/${CUR_UUID}/palette" 2>/dev/null | tr -d \')"
      if [ "$CUR_PALETTE" = "Ubuntu" ]; then
        dconf reset "/org/gnome/Ptyxis/Profiles/${CUR_UUID}/palette" 2>/dev/null || true
        GUESSED+=("Reset Ptyxis profile's palette to default (no snapshot of its prior value)")
      fi
    fi
  fi

  if command -v update-alternatives >/dev/null 2>&1; then
    sudo update-alternatives --auto x-terminal-emulator 2>/dev/null || true
    DONE+=("x-terminal-emulator alternative reset to auto")
  fi

  local xlist target
  for xlist in xdg-terminals.list ubuntu-xdg-terminals.list; do
    target="$HOME/.config/${xlist}"
    if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/${xlist}" ]; then
      cp "${BACKUP_ORIGINAL}/${xlist}" "$target"
      DONE+=("Restored ~/.config/${xlist}")
    elif [ -f "$target" ] && grep -qs 'org.gnome.Ptyxis' "$target" 2>/dev/null; then
      rm -f "$target"
      GUESSED+=("Removed ~/.config/${xlist} (pointed at Ptyxis, no snapshot to restore)")
    fi
  done

  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    gsettings reset org.gnome.desktop.default-applications.terminal exec 2>/dev/null || true
    gsettings reset org.gnome.desktop.default-applications.terminal exec-arg 2>/dev/null || true
  fi
}

###############################################################################
step_restore_environment() {
  step "Restoring /etc/environment..."
  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/environment" ]; then
    sudo cp "${BACKUP_ORIGINAL}/environment" /etc/environment
    DONE+=("/etc/environment restored from snapshot")
  elif grep -q "^XCURSOR_SIZE=24$" /etc/environment 2>/dev/null; then
    sudo sed -i '/^XCURSOR_SIZE=24$/d' /etc/environment
    GUESSED+=("Removed XCURSOR_SIZE=24 from /etc/environment (no snapshot to restore)")
  fi
}

###############################################################################
step_restore_grub() {
  step "Restoring GRUB..."
  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/grub" ]; then
    sudo cp "${BACKUP_ORIGINAL}/grub" /etc/default/grub
    sudo update-grub
    DONE+=("GRUB restored from snapshot")
  elif grep -q 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' /etc/default/grub 2>/dev/null; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/' /etc/default/grub
    sudo update-grub
    GUESSED+=("GRUB splash flag removed (no snapshot; assumed 'quiet' as the prior state)")
  fi
}

###############################################################################
step_restore_plymouth() {
  step "Restoring Plymouth theme..."
  if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/plymouth-theme.txt" ]; then
      local _theme
      _theme="$(cat "${BACKUP_ORIGINAL}/plymouth-theme.txt" 2>/dev/null)"
      if [ -n "$_theme" ] && [ "$(plymouth-get-default-theme 2>/dev/null)" != "$_theme" ]; then
        sudo plymouth-set-default-theme "$_theme"
        sudo update-initramfs -u -k all 2>/dev/null || sudo update-initramfs -u
        DONE+=("Plymouth theme restored to '${_theme}'")
      fi
    else
      SKIPPED+=("No Plymouth snapshot — theme left as 'spinner' (can't know your original theme name)")
    fi
  fi
}

###############################################################################
step_remove_ubuntu_repo() {
  step "Removing Ubuntu apt repo/pin/keyring..."
  local changed=0
  [ -f "$UBUNTU_LIST" ] && { sudo rm -f "$UBUNTU_LIST"; changed=1; }
  [ -f "$UBUNTU_PIN" ] && { sudo rm -f "$UBUNTU_PIN"; changed=1; }
  [ -f "$UBUNTU_KEYRING" ] && { sudo rm -f "$UBUNTU_KEYRING"; changed=1; }
  [ $changed -eq 1 ] && DONE+=("Removed Ubuntu apt sources/pin/keyring")
}

###############################################################################
step_restore_sources_list() {
  step "Restoring /etc/apt/sources.list..."
  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/sources.list" ]; then
    sudo cp "${BACKUP_ORIGINAL}/sources.list" /etc/apt/sources.list
    DONE+=("/etc/apt/sources.list restored from snapshot")
    return
  fi
  local bak
  for bak in /etc/apt/sources.list.*.bak; do
    [ -f "$bak" ] || continue
    sudo cp "$bak" /etc/apt/sources.list
    GUESSED+=("/etc/apt/sources.list restored from ${bak} (no snapshot; used the newest auto-backup instead)")
    return
  done
  SKIPPED+=("No sources.list snapshot or auto-backup found — left as-is (still has contrib/non-free)")
}

###############################################################################
step_remove_packages() {
  step "Removing packages..."

  # ubuntu-wallpapers (and any ubuntu-wallpapers-<codename> pack left over
  # from an older script version) only exists because of the Ubuntu archive
  # this script added, so it's always safe to purge all matches.
  local wp_list
  wp_list="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep '^ubuntu-wallpapers' || true)"
  if [ -n "$wp_list" ]; then
    # shellcheck disable=SC2086
    sudo apt-get purge -y $wp_list 2>/dev/null || true
    DONE+=("Purged $(echo "$wp_list" | wc -l) ubuntu-wallpapers package(s)")
  fi

  local list=""
  if [ -f "$INSTALLED_MANIFEST" ] && [ -s "$INSTALLED_MANIFEST" ]; then
    for pkg in $(cat "$INSTALLED_MANIFEST"); do
      is_installed "$pkg" && list="$list $pkg"
    done
    if [ -n "$list" ]; then
      # shellcheck disable=SC2086
      sudo apt-get purge -y $list 2>/dev/null || true
      DONE+=("Purged tracked packages:${list}")
    fi
  else
    message warn "No package manifest found (ubuntu-look.sh predates it)."
    message warn "Falling back to a conservative guess list — packages generic enough to"
    message warn "plausibly predate ubuntu-look.sh (curl, gnupg, fonts, gnome-shell-extensions,"
    message warn "gnome-shell-extension-manager, desktop-base, dconf-cli, plymouth, distro-info)"
    message warn "are deliberately EXCLUDED from this list to avoid removing something you"
    message warn "actually wanted independent of this script."
    local fallback="yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound
      gnome-shell-extension-ubuntu-dock gnome-shell-extension-ubuntu-tiling-assistant
      gnome-shell-extension-appindicator gnome-shell-extension-desktop-icons-ng
      humanity-icon-theme ptyxis"
    confirm
    for pkg in $fallback; do
      is_installed "$pkg" && list="$list $pkg"
    done
    if [ -n "$list" ]; then
      # shellcheck disable=SC2086
      sudo apt-get purge -y $list 2>/dev/null || true
      GUESSED+=("Purged guessed packages:${list}")
    fi
  fi

  sudo apt-get autoremove -y 2>/dev/null || true
}

###############################################################################
step_disable_extensions
step_restore_gnome_settings
step_remove_dconf_profile
step_remove_color_scheme_service
step_restore_gtk
step_ptyxis
step_restore_environment
step_restore_grub
step_restore_plymouth
step_remove_ubuntu_repo
step_restore_sources_list
step_remove_packages

sudo apt-get update -qq 2>/dev/null || true

echo ""
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
echo -e "${GREEN}                    UNINSTALL SUMMARY${ENDCOLOR}"
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
[ ${#DONE[@]} -gt 0 ] && { echo -e "${GREEN}Restored/removed:${ENDCOLOR}"; printf '   + %s\n' "${DONE[@]}"; }
[ ${#GUESSED[@]} -gt 0 ] && { echo -e "${YELLOW}Best-effort (no snapshot to restore exactly):${ENDCOLOR}"; printf '   ? %s\n' "${GUESSED[@]}"; }
[ ${#SKIPPED[@]} -gt 0 ] && { echo -e "${YELLOW}Skipped:${ENDCOLOR}"; printf '   - %s\n' "${SKIPPED[@]}"; }
echo ""
if [ -d "$BACKUP_DIR" ]; then
  message "Snapshot/manifests kept at ${BACKUP_DIR} — remove manually: rm -rf ${BACKUP_DIR}"
fi
echo -e "${YELLOW}Log out and back in for all changes to take effect.${ENDCOLOR}"
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
