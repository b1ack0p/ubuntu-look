#!/bin/bash
# =============================================================================
# Title       : ubuntu-look.sh
# Description : Transform a Debian GNOME desktop into an authentic Ubuntu look.
#               Wallpaper and icon/GTK/sound theme track the latest official
#               Ubuntu release; the shell theme + dock/appindicator extensions
#               pin to the newest release compatible with your GNOME Shell.
#               Installs genuine Yaru theme, Ubuntu fonts, official wallpapers,
#               ubuntu-dock, and applies all Ubuntu GNOME defaults — including
#               extension enabling — via a dconf system profile so everything
#               takes effect on the FIRST run (no second run after reboot).
#               Visuals only: no extra apps, no Snap/Flatpak/AppImage, and
#               your dock favorites are left alone.
#
# Original    : DeltaLima
#               https://github.com/DeltaLima/make-debian-look-like-ubuntu
#
# How to run  :
#   1. Save this file, e.g.  ~/ubuntu-look.sh
#   2. Open a terminal (make sure you are NOT root and you ARE in the
#      'sudo' group).
#   3. Make it executable:
#          chmod +x ~/ubuntu-look.sh
#   4. Run it:
#          ~/ubuntu-look.sh
#      Or without making it executable:
#          bash ~/ubuntu-look.sh
#   5. Confirm with 'y' when prompted, enter your sudo password when
#      asked, and wait for the SUMMARY box at the end.
#   6. Follow the SUMMARY instructions (log out / reboot as needed).
#
#   Re-runs are safe — already-installed packages and settings already
#   in place are skipped automatically.
#
# Partial run : Run only one stage, e.g.:
#                   bash ubuntu-look.sh 2-desktop-gnome
#               Valid stages: 0-base  1-desktop-base  2-desktop-gnome
#
# Override    : Force a specific Ubuntu codename for the theme repo:
#                   UBUNTU_CODENAME=resolute bash ubuntu-look.sh
#
# Requires    : Debian 12+ with GNOME desktop, user in 'sudo' group,
#               working internet connection.
# =============================================================================

arguments="$@"

declare -A packages

# Core tools: Plymouth splash, apt/key helpers, dconf compiler (for system profile)
packages[0-base]="plymouth plymouth-themes curl wget gnupg ca-certificates dconf-cli"

# Ubuntu fonts + wallpapers. ubuntu-wallpapers tracks the latest official
# release only, via the floating pin below (LTS or not).
packages[1-desktop-base]="fonts-ubuntu fonts-ubuntu-console
desktop-base gnome-backgrounds
ubuntu-wallpapers"

# GNOME Shell extensions + full Yaru theme stack. tiling-assistant is
# Ubuntu's built-in tiling extension (default since 24.04); ptyxis is
# Ubuntu's default terminal since 24.10.
packages[2-desktop-gnome]="gnome-shell-extensions
gnome-shell-extension-desktop-icons-ng
gnome-shell-extension-ubuntu-dock
gnome-shell-extension-ubuntu-tiling-assistant
gnome-shell-extension-appindicator
gnome-shell-extension-manager
yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound
humanity-icon-theme
ptyxis"

# Ubuntu release to pull Yaru theme + Ubuntu fonts from. yaru-theme-gnome-shell
# is pinned to a gnome-shell major version, so the codename must be verified
# compatible first (see resolve_ubuntu_codename()). Override with
# UBUNTU_CODENAME=<name>.
UBUNTU_CODENAME="${UBUNTU_CODENAME:-auto}"
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu"

# Static list of released Ubuntu codenames to try when resolving a
# gnome-shell-compatible codename (theme/extensions) — see
# discover_ubuntu_codenames(), which extends this dynamically at runtime.
FALLBACK_CODENAMES="focal jammy noble plucky questing resolute"

# Bump whenever pin/source content changes, so re-runs detect stale config.
PIN_VERSION="v12-2026-08-03"

# Extensions that make up the Ubuntu look. Single source of truth for the
# dconf profile, the live-session enable loop, and the verification loop.
SHELL_EXTENSIONS="ubuntu-appindicators@ubuntu.com ubuntu-dock@ubuntu.com ding@rastersoft.com tiling-assistant@ubuntu.com user-theme@gnome-shell-extensions.gcampax.github.com"

# One-time pre-install snapshot + running manifests, so uninstall.sh can undo
# exactly what THIS script did and restore whatever was there before it ran.
BACKUP_DIR="$HOME/.ubuntu-look-backup"
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
INSTALLED_MANIFEST="${BACKUP_DIR}/installed-by-script.txt"
REMOVED_MANIFEST="${BACKUP_DIR}/removed-by-script.txt"

# dconf system profile paths (system defaults, no running session required)
DCONF_PROFILE_DIR="/etc/dconf/db/local.d"
DCONF_PROFILE_FILE="${DCONF_PROFILE_DIR}/10-ubuntu-look"
DCONF_USER_PROFILE="/etc/dconf/profile/user"

# -----------------------------------------------------------------------------
# Status tracking
# -----------------------------------------------------------------------------
declare -a STATUS_INSTALLED=()
declare -a STATUS_ALREADY=()
declare -a STATUS_CHANGES=()
declare -a STATUS_NOCHANGE=()
GSETTINGS_CHANGED=0
GSETTINGS_UNCHANGED=0
REBOOT_NEEDED=0
RELOGIN_NEEDED=0
STEP=0

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
message() {
  case $1 in
    warn)   MESSAGE_TYPE="${YELLOW}WARN${ENDCOLOR}"  ;;
    error)  MESSAGE_TYPE="${RED}ERROR${ENDCOLOR}"    ;;
    info|*) MESSAGE_TYPE="${GREEN}INFO${ENDCOLOR}"   ;;
  esac
  if [ "$1" = "info" ] || [ "$1" = "warn" ] || [ "$1" = "error" ]; then
    MESSAGE=$2
  else
    MESSAGE=$1
  fi
  echo -e "[${MESSAGE_TYPE}] $MESSAGE"
}

error() { message error "$1"; exit 1; }

confirm_continue() {
  message warn "Type '${GREEN}y${ENDCOLOR}' or '${GREEN}yes${ENDCOLOR}' and hit [ENTER] to continue"
  read -r -p "[y/N?] " continue
  if [ "${continue,,}" != "y" ] && [ "${continue,,}" != "yes" ]; then
    message error "Aborted."
    exit 1
  fi
}

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

missing_packages() {
  local missing=""
  for pkg in $1; do
    is_installed "$pkg" || missing="$missing $pkg"
  done
  echo "$missing" | xargs
}

installed_packages() {
  local got=""
  for pkg in $1; do
    is_installed "$pkg" && got="$got $pkg"
  done
  echo "$got" | xargs
}

# Filter a list to only packages actually available in the apt cache.
available_packages() {
  local avail=""
  for pkg in $1; do
    apt-cache show "$pkg" >/dev/null 2>&1 && avail="$avail $pkg"
  done
  echo "$avail" | xargs
}

# Render SHELL_EXTENSIONS (space-separated) as a dconf/GVariant string array:
# ['a', 'b', 'c'].
shell_extensions_dconf_array() {
  local out="" first=1 e
  for e in $SHELL_EXTENSIONS; do
    [ $first -eq 1 ] && first=0 || out="${out}, "
    out="${out}'${e}'"
  done
  echo "[${out}]"
}

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
  echo -e "${YELLOW}  STEP ${STEP}: $1${ENDCOLOR}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
}

# Try gsettings if a D-Bus session is available (immediate effect on running desktop).
# Most settings are also written to the dconf system profile (see write_dconf_profile),
# so they apply on first login even without a session.
gset() {
  local schema="$1" key="$2" value="$3"
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && return 0
  local before after
  before="$(gsettings get "$schema" "$key" 2>/dev/null)" || return 0
  gsettings set "$schema" "$key" "$value" 2>/dev/null || return 0
  after="$(gsettings get "$schema" "$key" 2>/dev/null)"
  if [ "$before" != "$after" ]; then
    GSETTINGS_CHANGED=$((GSETTINGS_CHANGED + 1))
    RELOGIN_NEEDED=1
  else
    GSETTINGS_UNCHANGED=$((GSETTINGS_UNCHANGED + 1))
  fi
}

# Current Ubuntu releases from distro-info-data, unioned with
# FALLBACK_CODENAMES (never narrowed — archive.ubuntu.com keeps serving EOL
# releases that older gnome-shell versions may still need).
discover_ubuntu_codenames() {
  local dynamic=""
  if command -v ubuntu-distro-info >/dev/null 2>&1; then
    dynamic="$(ubuntu-distro-info --supported 2>/dev/null | tr '\n' ' ')"
  fi
  echo "$FALLBACK_CODENAMES $dynamic" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ' | xargs
}

# Newest Ubuntu codename whose $1 package installs cleanly here, verified via
# a real simulated install (avoids a hand-maintained compatibility table).
#
# $2 ("1"): also require "Inst $1 " in the simulated output, not just
# "no Remv" — needed when Debian ships the same package (e.g. ptyxis), where
# a clean simulate can mean "already installed from Debian, nothing to do".
#
# $3: fallback value if no codename simulates cleanly.
resolve_ubuntu_pkg_codename() {
  local pkg="$1" require_inst="${2:-0}" fallback="${3:-}"
  local newest_first cn ver sim
  newest_first="$(echo "$WALLPAPER_CODENAMES" | tr ' ' '\n' | tac)"
  for cn in $newest_first; do
    # Progress goes to stderr so it doesn't pollute the codename on stdout.
    message "  checking ${pkg} on ${cn}..." >&2
    ver="$(apt-cache madison "$pkg" 2>/dev/null \
      | awk -F'|' -v c="$cn" '$3 ~ c { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }')"
    [ -z "$ver" ] && continue
    sim="$(apt-get install -s "${pkg}=${ver}" 2>&1)"
    echo "$sim" | grep -q '^Remv ' && continue
    if [ "$require_inst" = "1" ]; then
      echo "$sim" | grep -q "^Inst ${pkg} " || continue
    fi
    echo "$cn"
    return 0
  done
  echo "$fallback"
}

# yaru-theme-gnome-shell is pinned to a gnome-shell major version; "noble" is
# a safe LTS fallback if nothing simulates cleanly (e.g. offline).
resolve_ubuntu_codename() { resolve_ubuntu_pkg_codename yaru-theme-gnome-shell 0 noble; }

# Debian's own ptyxis build is often version-newer than the Ubuntu one, and
# Pin-Priority 990 never overrides an already-installed newer version — the
# "Inst ptyxis" check confirms a real switch is possible before pinning it at
# 1001. Echoes "" if no Ubuntu ptyxis build installs here; callers then leave
# ptyxis unpinned.
resolve_ptyxis_codename() { resolve_ubuntu_pkg_codename ptyxis 1 ""; }

# Auto-detect the running Debian suite from /etc/os-release.
detect_debian_codename() {
  # shellcheck source=/dev/null
  ( . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-trixie}" ) || echo "trixie"
}

# Write the dconf system profile file.
# This is the KEY fix for "needs two runs": it uses the dconf system database
# rather than per-session gsettings calls, so settings and extension enabling
# take effect on first login even when the script ran without a GNOME session.
write_dconf_profile() {
  local wp_light="$1" wp_dark="$2"

  # Only emit background/screensaver keys if the wallpaper file exists
  # (it may not, if 2-desktop-gnome ran before 1-desktop-base ever installed
  # ubuntu-wallpapers).
  local bg_block=""
  if [ -n "$wp_light" ] && [ -f "$wp_light" ]; then
    bg_block="
[org/gnome/desktop/background]
show-desktop-icons=true
picture-uri='file://${wp_light}'
picture-uri-dark='file://${wp_dark}'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file://${wp_light}'"
  else
    message warn "wallpaper file not found (${wp_light:-none}) — skipping background/screensaver keys"
    message warn "run 'bash ubuntu-look.sh 1-desktop-base' (or a full run) first to install ubuntu-wallpapers"
  fi

  # Ensure the dconf system db directory exists
  sudo mkdir -p "$DCONF_PROFILE_DIR"

  # Set up /etc/dconf/profile/user so GNOME reads the system db.
  # Format: one db per line; user db first, then system db.
  if [ ! -f "$DCONF_USER_PROFILE" ] || ! grep -q "system-db:local" "$DCONF_USER_PROFILE"; then
    printf 'user-db:user\nsystem-db:local\n' | sudo tee "$DCONF_USER_PROFILE" > /dev/null
    STATUS_CHANGES+=("Created /etc/dconf/profile/user (system db enabled)")
  fi

  # Build the profile content
  local new_profile
  new_profile="$(cat << EOF
# ubuntu-look.sh — Ubuntu GNOME defaults (auto-generated, safe to delete)
# Provides system-wide defaults; users can override in their own dconf.

[org/gnome/shell]
enabled-extensions=$(shell_extensions_dconf_array)
disable-user-extensions=false
always-show-log-out=true
start-in-overview=false

[org/gnome/desktop/interface]
color-scheme='default'
gtk-theme='Yaru'
icon-theme='Yaru'
cursor-theme='Yaru'
font-name='Ubuntu Sans 11'
monospace-font-name='Ubuntu Sans Mono 11'
document-font-name='Sans 11'
font-antialiasing='rgba'
font-hinting='slight'
enable-hot-corners=false
accent-color='orange'
${bg_block}

[org/gnome/desktop/wm/preferences]
button-layout=':minimize,maximize,close'
titlebar-uses-system-font=false
action-middle-click-titlebar='lower'
titlebar-font='Ubuntu Sans Bold 11'

[org/gnome/desktop/sound]
theme-name='Yaru'
input-feedback-sounds=true

[org/gnome/mutter]
attach-modal-dialogs=true
edge-tiling=true
dynamic-workspaces=true
workspaces-only-on-primary=true
focus-change-on-pointer-rest=true

[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
click-method='default'

# Mirrors gnome-shell-extension-ubuntu-dock's own gschema override, which
# only takes effect on a real Ubuntu session. Debian has no equivalent, so
# these values are reapplied here to match Ubuntu's dock behavior.
[org/gnome/shell/extensions/dash-to-dock]
dock-position='LEFT'
dock-fixed=true
intellihide=true
intellihide-mode='ALL_WINDOWS'
icon-size-fixed=true
custom-theme-shrink=true
running-indicator-style='DOTS'
extend-height=true
scroll-action='switch-workspace'
click-action='focus-or-appspread'
shift-click-action='launch'
middle-click-action='launch'
shift-middle-click-action='minimize'
disable-overview-on-startup=true
show-mounts-only-mounted=false
show-mounts-network=true

[org/gnome/nautilus/icon-view]
default-zoom-level='small'

[org/gnome/nautilus/preferences]
open-folder-on-dnd-hover=false

[org/gtk/settings/file-chooser]
sort-directories-first=true
startup-mode='cwd'
EOF
)"

  local tmp
  tmp="$(mktemp)"
  echo "$new_profile" > "$tmp"

  if [ ! -f "$DCONF_PROFILE_FILE" ] || ! cmp -s "$tmp" "$DCONF_PROFILE_FILE"; then
    sudo cp "$tmp" "$DCONF_PROFILE_FILE"
    sudo dconf update
    STATUS_CHANGES+=("dconf system profile written → $DCONF_PROFILE_FILE")
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("dconf system profile already current")
  fi
  rm -f "$tmp"

  # mktemp's file is 0600 and cp (no -p) carries that mode over, leaving even
  # the owner unable to read the profile without sudo. Enforced unconditionally
  # so an existing install self-heals without needing a rewrite.
  if [ -f "$DCONF_PROFILE_FILE" ]; then
    sudo chmod 0644 "$DCONF_PROFILE_FILE"
  fi
}

# Pretty end-of-run report (fires on clean exit and on early exit 1).
print_summary() {
  local rc=$?
  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  echo -e "${GREEN}                        SUMMARY${ENDCOLOR}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"

  [ ${#STATUS_INSTALLED[@]} -gt 0 ] && {
    echo -e "${GREEN}Installed this run (${#STATUS_INSTALLED[@]}):${ENDCOLOR}"
    printf '   + %s\n' "${STATUS_INSTALLED[@]}"
  }
  [ ${#STATUS_ALREADY[@]} -gt 0 ] && {
    echo -e "${YELLOW}Already installed (${#STATUS_ALREADY[@]}):${ENDCOLOR}"
    printf '   = %s\n' "${STATUS_ALREADY[@]}"
  }
  [ ${#STATUS_CHANGES[@]} -gt 0 ] && {
    echo -e "${GREEN}Configuration changes:${ENDCOLOR}"
    printf '   + %s\n' "${STATUS_CHANGES[@]}"
  }
  [ ${#STATUS_NOCHANGE[@]} -gt 0 ] && {
    echo -e "${YELLOW}Already in place (no change):${ENDCOLOR}"
    printf '   = %s\n' "${STATUS_NOCHANGE[@]}"
  }

  echo ""
  echo -e "GNOME settings (live): ${GREEN}${GSETTINGS_CHANGED} changed${ENDCOLOR}, ${YELLOW}${GSETTINGS_UNCHANGED} already correct${ENDCOLOR}"
  echo ""

  if [ $rc -ne 0 ]; then
    echo -e "${RED}✗  Script exited with errors (rc=$rc). See ERROR line above.${ENDCOLOR}"
  elif [ $REBOOT_NEEDED -eq 1 ]; then
    echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for GRUB / Plymouth changes."
    echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
  elif [ $RELOGIN_NEEDED -eq 1 ]; then
    echo -e "${YELLOW}⚠  Log out and back in${ENDCOLOR} so the new theme + extensions fully apply."
    echo -e "   (dconf system profile is already compiled — one login is all it takes.)"
  else
    echo -e "${GREEN}✓  Nothing changed — system was already in Ubuntu-look state.${ENDCOLOR}"
  fi
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
}
trap print_summary EXIT

###############################################################################
# Pre-flight checks
###############################################################################

[ "$(whoami)" = "root" ] && error "Do not run as root. Run as a normal user in the 'sudo' group."

if [ -z "$arguments" ]; then
  package_categories="${!packages[@]}"
else
  package_categories="$*"
fi
package_categories="$(echo "$package_categories" | xargs -n1 | sort | xargs)"

message "Welcome to ${GREEN}ubuntu-look${ENDCOLOR} — make Debian GNOME look like Ubuntu!"
message ""
message "Applies Ubuntu look-and-feel for user ${YELLOW}${USER}${ENDCOLOR}."
message "Safe to re-run. Steps: ${YELLOW}${package_categories}${ENDCOLOR}"
message ""
message warn "GTK theme, wallpaper, and dconf settings are overwritten without"
message warn "prompting — back up custom values first if needed."
message ""
confirm_continue

groups | grep -q sudo || error "User $USER is not in the 'sudo' group.
  Fix: su -c '/usr/sbin/usermod -aG sudo ${USER}' && reboot"

###############################################################################
# One-time snapshot of pre-existing state, for uninstall.sh
###############################################################################
# Only ever taken once (first run) — a later re-run must NOT overwrite this
# with a state that already has ubuntu-look's own changes applied, or
# uninstall.sh would have nothing real to restore.

backup_snapshot_file() {
  local src="$1" dest="$2"
  [ -f "$src" ] || return 0
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest" 2>/dev/null || true
}

###############################################################################
# Guard: don't silently treat an already-modified system as "pristine" just
# because ~/.ubuntu-look-backup is missing — e.g. it was deleted per
# uninstall.sh's own cleanup instructions while some changes were still in
# place. If that happens, the "first run" snapshot below would permanently
# bake those leftover changes in as the thing uninstall.sh restores back to.
###############################################################################
if [ ! -d "$BACKUP_ORIGINAL" ]; then
  _taint_signs=""
  for _p in yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound \
            humanity-icon-theme gnome-shell-extension-ubuntu-dock \
            gnome-shell-extension-ubuntu-tiling-assistant ptyxis; do
    is_installed "$_p" && _taint_signs="$_taint_signs $_p"
  done
  if [ -n "$_taint_signs" ]; then
    message warn "No pre-install snapshot found, but this system already shows signs of a"
    message warn "previous ubuntu-look.sh run (installed:${_taint_signs})."
    message warn "This usually means ~/.ubuntu-look-backup was deleted while changes were"
    message warn "still in place. The snapshot this run is about to take will NOT be a true"
    message warn "pre-ubuntu-look baseline — uninstall.sh will only ever be able to restore"
    message warn "back to THIS (already-modified) state, not your original setup."
    confirm_continue
  fi
fi

FIRST_RUN=0
if [ ! -d "$BACKUP_ORIGINAL" ]; then
  FIRST_RUN=1
  message "first run — saving your pre-existing config to ${BACKUP_ORIGINAL} (for uninstall.sh)"
  mkdir -p "$BACKUP_ORIGINAL"

  cp /etc/apt/sources.list "${BACKUP_ORIGINAL}/sources.list" 2>/dev/null || true
  sudo cp /etc/default/grub "${BACKUP_ORIGINAL}/grub" 2>/dev/null || true
  cp /etc/environment "${BACKUP_ORIGINAL}/environment" 2>/dev/null || true

  backup_snapshot_file "$HOME/.config/gtk-3.0/gtk.css" "${BACKUP_ORIGINAL}/gtk-3.0-gtk.css"
  backup_snapshot_file "$HOME/.config/gtk-4.0/gtk.css" "${BACKUP_ORIGINAL}/gtk-4.0-gtk.css"
  backup_snapshot_file "$HOME/.config/gtk-3.0/settings.ini" "${BACKUP_ORIGINAL}/gtk-3.0-settings.ini"
  backup_snapshot_file "$HOME/.config/gtk-4.0/settings.ini" "${BACKUP_ORIGINAL}/gtk-4.0-settings.ini"
  backup_snapshot_file "$HOME/.gtkrc-2.0" "${BACKUP_ORIGINAL}/gtkrc-2.0"
  backup_snapshot_file "$HOME/.config/xdg-terminals.list" "${BACKUP_ORIGINAL}/xdg-terminals.list"
  backup_snapshot_file "$HOME/.config/ubuntu-xdg-terminals.list" "${BACKUP_ORIGINAL}/ubuntu-xdg-terminals.list"

  # Exact pre-install default-terminal state, so uninstall.sh can restore your
  # actual prior terminal preference (e.g. gnome-terminal) instead of
  # resetting to a generic schema default after switching to Ptyxis.
  {
    _dt_exec="$(dconf read /org/gnome/desktop/default-applications/terminal/exec 2>/dev/null | tr -d \')"
    _dt_exec_arg="$(dconf read /org/gnome/desktop/default-applications/terminal/exec-arg 2>/dev/null | tr -d \')"
    if [ -n "$_dt_exec" ] || [ -n "$_dt_exec_arg" ]; then
      echo "had_override=1"
      echo "exec=${_dt_exec}"
      echo "exec_arg=${_dt_exec_arg}"
    else
      echo "had_override=0"
    fi
  } > "${BACKUP_ORIGINAL}/default-terminal-override.txt"

  if command -v update-alternatives >/dev/null 2>&1 && update-alternatives --query x-terminal-emulator >/dev/null 2>&1; then
    {
      if update-alternatives --query x-terminal-emulator 2>/dev/null | grep -q '^Status: manual$'; then
        echo "status=manual"
        echo "target=$(readlink -f /etc/alternatives/x-terminal-emulator 2>/dev/null)"
      else
        echo "status=auto"
      fi
    } > "${BACKUP_ORIGINAL}/x-terminal-emulator-alternative.txt"
  fi

  if command -v plymouth-get-default-theme >/dev/null 2>&1; then
    plymouth-get-default-theme 2>/dev/null > "${BACKUP_ORIGINAL}/plymouth-theme.txt" || true
  fi

  # Existing Ptyxis default profile's palette/label, if Ptyxis was already
  # configured before this script ever touches it.
  _pre_ptyxis_uuid="$(dconf read /org/gnome/Ptyxis/default-profile-uuid 2>/dev/null | tr -d \')"
  if [ -n "$_pre_ptyxis_uuid" ]; then
    {
      echo "uuid=${_pre_ptyxis_uuid}"
      echo "palette=$(dconf read "/org/gnome/Ptyxis/Profiles/${_pre_ptyxis_uuid}/palette" 2>/dev/null | tr -d \')"
      echo "label=$(dconf read "/org/gnome/Ptyxis/Profiles/${_pre_ptyxis_uuid}/label" 2>/dev/null | tr -d \')"
    } > "${BACKUP_ORIGINAL}/ptyxis-profile.txt"
  fi

  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dconf >/dev/null 2>&1; then
    dconf dump / > "${BACKUP_ORIGINAL}/dconf-dump.ini" 2>/dev/null || true
  fi

  dpkg-query -W -f='${Package}\n' 2>/dev/null | sort > "${BACKUP_ORIGINAL}/packages-before.txt"
  touch "$INSTALLED_MANIFEST" "$REMOVED_MANIFEST"
  echo "ubuntu-look.sh pre-install snapshot — $(date -Iseconds)" > "${BACKUP_ORIGINAL}/INFO"
  STATUS_CHANGES+=("Pre-install snapshot saved → ${BACKUP_ORIGINAL}")
else
  message "pre-existing config already backed up (from first run) → ${BACKUP_ORIGINAL}"
  STATUS_NOCHANGE+=("Pre-install snapshot already exists")
fi

###############################################################################
# Step: Debian sources.list
###############################################################################

step "Check Debian sources.list (contrib + non-free)"
DEBIAN_CODENAME="$(detect_debian_codename)"

if ! grep -q "contrib" /etc/apt/sources.list || ! grep -Eq " non-free( |$)" /etc/apt/sources.list; then
  message warn "Adding contrib + non-free to /etc/apt/sources.list (Debian ${DEBIAN_CODENAME})"
  confirm_continue
  sudo cp /etc/apt/sources.list "/etc/apt/sources.list.$(date '+%s').bak"
  cat << EOF | sudo tee /etc/apt/sources.list
deb http://deb.debian.org/debian/ ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ ${DEBIAN_CODENAME} main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
EOF
  STATUS_CHANGES+=("Debian sources.list rewritten (${DEBIAN_CODENAME}, contrib + non-free)")
else
  message "sources.list already has contrib + non-free"
  STATUS_NOCHANGE+=("Debian sources.list (contrib + non-free present)")
fi

###############################################################################
# Step: Ubuntu apt repo — broad candidate sources (themes / fonts / wallpapers)
###############################################################################

step "Configure Ubuntu archive candidate sources"

_missing_prereqs="$(missing_packages "gnupg curl ca-certificates distro-info")"
if [ -n "$_missing_prereqs" ]; then
  sudo apt-get update -qq
  for prereq in $_missing_prereqs; do
    sudo apt-get install -y "$prereq" || error "Failed to install prerequisite: $prereq"
    STATUS_INSTALLED+=("$prereq (prereq)")
  done
fi

# Always re-discover the candidate list — distro-info-data updates
# independently of this script, so a newly-released Ubuntu version becomes a
# candidate automatically, with no script edit ever required.
WALLPAPER_CODENAMES="$(discover_ubuntu_codenames)"

# A manually forced codename (UBUNTU_CODENAME=xyz) still needs its own source
# entry even if distro-info no longer/doesn't yet consider it "supported".
if [ "$UBUNTU_CODENAME" != "auto" ] && ! echo "$WALLPAPER_CODENAMES" | grep -qw "$UBUNTU_CODENAME"; then
  WALLPAPER_CODENAMES="$WALLPAPER_CODENAMES $UBUNTU_CODENAME"
fi

UBUNTU_KEYRING=/etc/apt/keyrings/ubuntu-archive.gpg
UBUNTU_LIST=/etc/apt/sources.list.d/ubuntu-themes.list
UBUNTU_PIN=/etc/apt/preferences.d/ubuntu-themes

NEED_SOURCES_REWRITE=0
if [ ! -f "$UBUNTU_LIST" ] || [ ! -f "$UBUNTU_KEYRING" ] || ! grep -qF "# codenames: ${WALLPAPER_CODENAMES}" "$UBUNTU_LIST"; then
  NEED_SOURCES_REWRITE=1
fi

if [ $NEED_SOURCES_REWRITE -eq 1 ]; then
  message "configuring Ubuntu archive candidates: ${WALLPAPER_CODENAMES}"
  sudo install -d -m 0755 /etc/apt/keyrings

  if ! sudo test -s "$UBUNTU_KEYRING"; then
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF6ECB3762474EDA9D21B7022871920D1991BC93C" \
      | sudo gpg --dearmor -o "$UBUNTU_KEYRING" || error "Failed to fetch Ubuntu signing key"
    sudo chmod 0644 "$UBUNTU_KEYRING"
  fi

  {
    echo "# Ubuntu — Yaru theme + wallpaper (released codenames tried for compatibility)"
    echo "# Strictly apt-pinned — see ${UBUNTU_PIN}. This marker line lets re-runs"
    echo "# detect when a new Ubuntu release should be added automatically:"
    echo "# codenames: ${WALLPAPER_CODENAMES}"
    echo ""
    for _c in $WALLPAPER_CODENAMES; do
      echo "deb [signed-by=${UBUNTU_KEYRING}] ${UBUNTU_MIRROR} ${_c} main universe"
      echo "deb [signed-by=${UBUNTU_KEYRING}] ${UBUNTU_MIRROR} ${_c}-updates main universe"
    done
  } | sudo tee "$UBUNTU_LIST" > /dev/null
  STATUS_CHANGES+=("Ubuntu apt sources written (candidates: ${WALLPAPER_CODENAMES})")
else
  message "Ubuntu candidate sources already current"
  STATUS_NOCHANGE+=("Ubuntu apt sources already current")
fi

###############################################################################
# Step: apt update (needed before we can query real package versions/compat)
###############################################################################

step "Refresh package lists"
sudo apt-get update || error "apt update failed"

###############################################################################
# Step: resolve the gnome-shell-compatible Ubuntu theme codename + apply pin
###############################################################################

step "Resolve Ubuntu theme codename"

if [ "$UBUNTU_CODENAME" = "auto" ]; then
  UBUNTU_CODENAME="$(resolve_ubuntu_codename)"
  GS_VER="$(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')"
  message "auto-detected Ubuntu codename ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} (${GS_VER}) — verified via simulated install"
fi

PTYXIS_CODENAME="$(resolve_ptyxis_codename)"
if [ -n "$PTYXIS_CODENAME" ]; then
  message "Ubuntu's own ptyxis build (${GREEN}${PTYXIS_CODENAME}${ENDCOLOR}) installs cleanly here — will be preferred over Debian's"
else
  message warn "no Ubuntu ptyxis build is installable on this system (dependency too new) — keeping Debian's ptyxis"
fi

NEED_PIN_REWRITE=0
if [ ! -f "$UBUNTU_PIN" ]; then
  NEED_PIN_REWRITE=1
elif ! grep -q "# pin-version: ${PIN_VERSION}" "$UBUNTU_PIN"; then
  message warn "Ubuntu theme pin is from an older script version — rewriting"
  NEED_PIN_REWRITE=1
elif ! grep -q "n=${UBUNTU_CODENAME}\$" "$UBUNTU_PIN"; then
  message warn "a newer compatible Ubuntu release is now available (${UBUNTU_CODENAME}) — rewriting theme pin"
  NEED_PIN_REWRITE=1
elif [ -n "$PTYXIS_CODENAME" ] && ! grep -qE "^Package: ptyxis\$" "$UBUNTU_PIN"; then
  message warn "Ubuntu ptyxis is now installable (${PTYXIS_CODENAME}) — rewriting pin"
  NEED_PIN_REWRITE=1
elif [ -n "$PTYXIS_CODENAME" ] && ! awk '/^Package: ptyxis$/{getline; print; exit}' "$UBUNTU_PIN" | grep -q "n=${PTYXIS_CODENAME}\$"; then
  message warn "a newer installable ptyxis codename is available (${PTYXIS_CODENAME}) — rewriting pin"
  NEED_PIN_REWRITE=1
elif [ -z "$PTYXIS_CODENAME" ] && grep -qE "^Package: ptyxis\$" "$UBUNTU_PIN"; then
  message warn "Ubuntu ptyxis is no longer installable here — rewriting pin to drop it"
  NEED_PIN_REWRITE=1
fi

if [ $NEED_PIN_REWRITE -eq 1 ]; then
  # Priority -1 blocks all Ubuntu packages by default; the whitelist below
  # allows only theme/icon/font/wallpaper packages and their Ubuntu-only deps.
  PTYXIS_PIN_BLOCK=""
  if [ -n "$PTYXIS_CODENAME" ]; then
    PTYXIS_PIN_BLOCK="
# Priority 1001 (not 990) is required: Debian's ptyxis is often version-newer
# than the Ubuntu build, and 990 never overrides an already-installed newer
# version. Verified installable in resolve_ptyxis_codename() before pinning.
Package: ptyxis
Pin: release o=Ubuntu, n=${PTYXIS_CODENAME}
Pin-Priority: 1001
"
  fi
  cat << EOF | sudo tee "$UBUNTU_PIN" > /dev/null
# pin-version: ${PIN_VERSION}
Package: *
Pin: release o=Ubuntu
Pin-Priority: -1

# Coupled to the running gnome-shell major version — must match the
# verified-compatible codename, or a hold can result.
Package: yaru-theme-gnome-shell gnome-shell-extension-ubuntu-*
Pin: release o=Ubuntu, n=${UBUNTU_CODENAME}
Pin-Priority: 990

# No gnome-shell coupling — float to the newest release across all
# configured Ubuntu sources instead of the conservative theme codename.
Package: yaru-theme-gtk yaru-theme-icon yaru-theme-sound fonts-ubuntu* humanity-icon-theme suru-icon-theme session-migration user-session-migration
Pin: release o=Ubuntu
Pin-Priority: 990
${PTYXIS_PIN_BLOCK}
# Latest release's default wallpaper only — no per-release packs. The
# ubuntu-wallpapers metapackage Depends on a per-codename pack (e.g.
# ubuntu-wallpapers-resolute) that must be pinned too, or apt can't satisfy
# the dependency and the whole install aborts.
Package: ubuntu-wallpapers ubuntu-wallpapers-*
Pin: release o=Ubuntu
Pin-Priority: 990
EOF
  STATUS_CHANGES+=("Ubuntu theme pin applied (${UBUNTU_CODENAME}${PTYXIS_CODENAME:+, ptyxis: $PTYXIS_CODENAME})")
else
  message "Ubuntu theme pin already current (${UBUNTU_CODENAME})"
  STATUS_NOCHANGE+=("Ubuntu theme pin already current")
fi

###############################################################################
# Step: apt upgrade
###############################################################################

step "Upgrade installed packages"
upgradable_before="$(apt list --upgradable 2>/dev/null | grep -c '/')"
if [ "$upgradable_before" -gt 0 ]; then
  message "upgrading ${upgradable_before} package(s)..."
  sudo apt-get upgrade -y || error "apt upgrade failed"
  STATUS_CHANGES+=("Upgraded ${upgradable_before} package(s)")
  RELOGIN_NEEDED=1
else
  message "nothing to upgrade"
  STATUS_NOCHANGE+=("apt upgrade: nothing to upgrade")
fi

###############################################################################
# Step: Install packages per category + post-install tasks
###############################################################################

for category in $package_categories; do
  step "Install + configure: ${category}"

  # Filter to only packages that exist in the apt cache, so an optional
  # package missing from a particular repo doesn't fail the whole category.
  available="$(available_packages "${packages[$category]}")"
  to_install="$(missing_packages "$available")"
  already="$(installed_packages "$available")"
  for p in $already; do STATUS_ALREADY+=("$p"); done

  if [ -z "$to_install" ]; then
    message "all packages in ${category} already installed"
  else
    message "installing: ${GREEN}${to_install}${ENDCOLOR}"
    # shellcheck disable=SC2086
    sudo apt-get install -y $to_install || error "apt install failed for: $to_install"
    for p in $to_install; do STATUS_INSTALLED+=("$p"); done
    RELOGIN_NEEDED=1
  fi

  case $category in
    # -------------------------------------------------------------------------
    0-base)
      # GRUB: enable splash for Plymouth. Only done on the very first run —
      # once set, the user owns this file. A later run must not re-enforce
      # "quiet splash" over a value the user deliberately changed afterward.
      if [ "$FIRST_RUN" -eq 1 ]; then
        # Anchored to line-start so a commented-out line is never mistaken for
        # an active setting.
        if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' /etc/default/grub; then
          message "setting GRUB_CMDLINE_LINUX_DEFAULT='quiet splash'"
          if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            # An active assignment already exists — update it in place.
            sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' \
              /etc/default/grub || error "Failed to update /etc/default/grub"
          elif grep -q '^#GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            # Stock Debian ships this line commented out. Uncomment it in place
            # rather than appending a second, active line further down the file —
            # /etc/default/grub is sourced top-to-bottom, so a duplicate active
            # line would silently shadow this one and make it un-editable.
            sudo sed -i 's/^#GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' \
              /etc/default/grub || error "Failed to update /etc/default/grub"
          else
            echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' | sudo tee -a /etc/default/grub > /dev/null \
              || error "Failed to update /etc/default/grub"
          fi
          sudo update-grub
          STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"")
          REBOOT_NEEDED=1
        else
          STATUS_NOCHANGE+=("/etc/default/grub already 'quiet splash'")
        fi
      else
        STATUS_NOCHANGE+=("/etc/default/grub left as-is (only set on first run — edit it yourself afterward)")
      fi

      # Plymouth theme: use 'spinner' (ships with plymouth-themes on Debian)
      if command -v plymouth-set-default-theme >/dev/null 2>&1; then
        current_theme="$(plymouth-get-default-theme 2>/dev/null || echo '')"
        if [ "$current_theme" != "spinner" ]; then
          sudo plymouth-set-default-theme spinner
          sudo update-initramfs -u -k all 2>/dev/null || sudo update-initramfs -u
          STATUS_CHANGES+=("Plymouth theme set to 'spinner'")
          REBOOT_NEEDED=1
        else
          STATUS_NOCHANGE+=("Plymouth theme already 'spinner'")
        fi
      fi
      ;;

    # -------------------------------------------------------------------------
    1-desktop-base)
      # HiDPI cursor size fix for Qt apps
      if ! grep -q "XCURSOR_SIZE" /etc/environment; then
        echo "XCURSOR_SIZE=24" | sudo tee -a /etc/environment > /dev/null
        STATUS_CHANGES+=("/etc/environment += XCURSOR_SIZE=24")
        RELOGIN_NEEDED=1
      else
        STATUS_NOCHANGE+=("/etc/environment XCURSOR_SIZE already present")
      fi
      ;;

    # -------------------------------------------------------------------------
    2-desktop-gnome)
      # ubuntu-wallpapers overwrites these canonical filenames each release
      # cycle, so they always track the latest release via the floating pin.
      WP_LIGHT=/usr/share/backgrounds/warty-final-ubuntu.png
      WP_DARK=/usr/share/backgrounds/ubuntu-wallpaper-d.png
      [ -f "$WP_DARK" ] || WP_DARK="$WP_LIGHT"

      # dconf system profile: settings + extension enabling take effect on
      # first login, even without a GNOME session.
      message "writing dconf system profile (extensions + GNOME defaults)"
      write_dconf_profile "$WP_LIGHT" "$WP_DARK"

      # No session bus (e.g. run from SSH/tmux) — fall back to the systemd
      # user bus so the live gsettings apply below still reaches this user.
      if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        message "no session bus in env — using ${DBUS_SESSION_BUS_ADDRESS}"
      fi

      # If we have a live GNOME session, also apply immediately via gsettings
      if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        message "live session detected — applying settings immediately via gsettings"

        gset org.gnome.shell disable-user-extensions false
        gset org.gnome.shell always-show-log-out true
        gset org.gnome.shell start-in-overview false

        # Enable extensions in the running shell
        for ext in $SHELL_EXTENSIONS; do
          gnome-extensions enable "$ext" 2>/dev/null || true
        done

        # Verify each one actually landed in the enabled list. "enable" can
        # silently no-op — e.g. a stale disable left over from uninstall.sh,
        # or gnome-shell not having rescanned a just-installed extension yet —
        # leaving the dock/indicators missing with no error printed anywhere.
        ENABLED_NOW="$(gnome-extensions list --enabled 2>/dev/null)"
        for ext in $SHELL_EXTENSIONS; do
          if ! echo "$ENABLED_NOW" | grep -qx "$ext"; then
            message warn "extension ${ext} did not activate — log out and back in, then re-run this script"
            STATUS_CHANGES+=("WARNING: ${ext} not active — log out/in and re-run")
            RELOGIN_NEEDED=1
          fi
        done

        # 'default' (light) matches upstream Ubuntu's out-of-the-box setting.
        gset org.gnome.desktop.interface color-scheme 'default'
        gset org.gnome.desktop.interface accent-color 'orange'
        gset org.gnome.desktop.interface icon-theme 'Yaru'
        gset org.gnome.desktop.interface cursor-theme 'Yaru'
        gset org.gnome.desktop.interface font-name 'Ubuntu Sans 11'
        gset org.gnome.desktop.interface monospace-font-name 'Ubuntu Sans Mono 11'
        gset org.gnome.desktop.interface document-font-name 'Sans 11'
        gset org.gnome.desktop.interface font-antialiasing 'rgba'
        gset org.gnome.desktop.interface font-hinting 'slight'
        gset org.gnome.desktop.interface enable-hot-corners false
        gset org.gnome.desktop.wm.preferences button-layout ':minimize,maximize,close'
        gset org.gnome.desktop.wm.preferences titlebar-uses-system-font false
        gset org.gnome.desktop.wm.preferences action-middle-click-titlebar 'lower'
        gset org.gnome.desktop.wm.preferences titlebar-font 'Ubuntu Sans Bold 11'
        gset org.gnome.desktop.sound theme-name 'Yaru'
        gset org.gnome.desktop.sound input-feedback-sounds true
        gset org.gnome.mutter attach-modal-dialogs true
        gset org.gnome.mutter edge-tiling true
        gset org.gnome.mutter dynamic-workspaces true
        gset org.gnome.mutter workspaces-only-on-primary true
        gset org.gnome.mutter focus-change-on-pointer-rest true
        gset org.gnome.desktop.peripherals.touchpad tap-to-click true
        gset org.gnome.desktop.peripherals.touchpad click-method 'default'
        gset org.gnome.shell.extensions.dash-to-dock dock-position 'LEFT'
        gset org.gnome.shell.extensions.dash-to-dock dock-fixed true
        gset org.gnome.shell.extensions.dash-to-dock intellihide true
        gset org.gnome.shell.extensions.dash-to-dock intellihide-mode 'ALL_WINDOWS'
        gset org.gnome.shell.extensions.dash-to-dock icon-size-fixed true
        gset org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true
        gset org.gnome.shell.extensions.dash-to-dock running-indicator-style 'DOTS'
        gset org.gnome.shell.extensions.dash-to-dock extend-height true
        gset org.gnome.shell.extensions.dash-to-dock scroll-action 'switch-workspace'
        gset org.gnome.shell.extensions.dash-to-dock click-action 'focus-or-appspread'
        gset org.gnome.shell.extensions.dash-to-dock shift-click-action 'launch'
        gset org.gnome.shell.extensions.dash-to-dock middle-click-action 'launch'
        gset org.gnome.shell.extensions.dash-to-dock shift-middle-click-action 'minimize'
        gset org.gnome.shell.extensions.dash-to-dock disable-overview-on-startup true
        gset org.gnome.shell.extensions.dash-to-dock show-mounts-only-mounted false
        gset org.gnome.shell.extensions.dash-to-dock show-mounts-network true
        gset org.gnome.nautilus.icon-view default-zoom-level 'small'
        gset org.gnome.nautilus.preferences open-folder-on-dnd-hover false
        gset org.gtk.Settings.FileChooser sort-directories-first true
        gset org.gtk.Settings.FileChooser startup-mode 'cwd'

        if [ -f "$WP_LIGHT" ]; then
          gset org.gnome.desktop.background picture-uri      "file://${WP_LIGHT}"
          gset org.gnome.desktop.background picture-uri-dark "file://${WP_DARK}"
          gset org.gnome.desktop.background picture-options  'zoom'
          gset org.gnome.desktop.screensaver picture-uri     "file://${WP_LIGHT}"
        fi
      else
        message warn "No D-Bus session detected — settings written to dconf profile only."
        message warn "Log out and back in to apply theme, extensions, and wallpaper."
      fi

      # ------------------------------------------------------------------
      # Yaru light/dark auto-switch service
      # Watches color-scheme and keeps gtk-theme + user-theme in sync.
      # Ubuntu handles this with a session daemon; we replicate it here.
      # ------------------------------------------------------------------
      message "installing Yaru light/dark auto-switch service"
      mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

      cat << 'EOF' > "$HOME/.local/bin/yaru-color-scheme-sync.sh"
#!/bin/bash
# Keeps Yaru gtk-theme + user-theme variant in sync with color-scheme.
apply() {
  local scheme
  scheme="$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d \')"
  if [ "$scheme" = "prefer-dark" ]; then
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
    gsettings set org.gnome.shell.extensions.user-theme name 'Yaru-dark' 2>/dev/null || true
  else
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru'
    gsettings set org.gnome.shell.extensions.user-theme name 'Yaru' 2>/dev/null || true
  fi
}
apply
gsettings monitor org.gnome.desktop.interface color-scheme | while read -r _; do apply; done
EOF
      chmod +x "$HOME/.local/bin/yaru-color-scheme-sync.sh"

      cat << 'EOF' > "$HOME/.config/systemd/user/yaru-color-scheme-sync.service"
[Unit]
Description=Yaru light/dark variant follower
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/yaru-color-scheme-sync.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

      systemctl --user daemon-reload 2>/dev/null || true
      if systemctl --user enable --now yaru-color-scheme-sync.service 2>/dev/null; then
        STATUS_CHANGES+=("Yaru light/dark auto-switch service enabled")
        RELOGIN_NEEDED=1
      else
        message warn "Could not enable yaru-color-scheme-sync.service (no graphical session yet)"
        message warn "It will activate on next login via WantedBy=graphical-session.target"
      fi

      # Apply current color-scheme immediately if session available
      if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        current_scheme="$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d \')"
        if [ "$current_scheme" = "prefer-dark" ]; then
          message "color-scheme is prefer-dark → applying Yaru-dark"
          gset org.gnome.desktop.interface gtk-theme 'Yaru-dark'
          gset org.gnome.shell.extensions.user-theme name 'Yaru-dark'
        else
          message "color-scheme is light → applying Yaru"
          gset org.gnome.desktop.interface gtk-theme 'Yaru'
          gset org.gnome.shell.extensions.user-theme name 'Yaru'
        fi
      fi

      # Remove stale forced-dark settings written by older script versions
      for f in "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"; do
        [ -f "$f" ] || continue
        grep -q "^gtk-application-prefer-dark-theme=1" "$f" || continue
        sed -i '/^gtk-application-prefer-dark-theme=1$/d' "$f"
        if [ "$(grep -v '^\[Settings\]$' "$f" | tr -d '[:space:]')" = "" ]; then
          rm -f "$f"
        fi
        STATUS_CHANGES+=("Removed legacy gtk-application-prefer-dark-theme=1 from $(basename "$(dirname "$f")")")
        RELOGIN_NEEDED=1
      done

      # GTK 3/4 CSS — Ubuntu orange accent (#E95420)
      message "writing gtk-3.0 / gtk-4.0 Ubuntu-orange accent CSS"
      mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
      GTK_CSS_NEW="$(mktemp)"
      cat << 'EOF' > "$GTK_CSS_NEW"
/* Ubuntu Orange = #E95420 (Yaru "default" accent) */

/* GNOME 47+ named accent slots */
@define-color accent_color            #E95420;
@define-color accent_bg_color         #E95420;
@define-color accent_fg_color         #ffffff;

/* Legacy selection slots */
@define-color theme_selected_bg_color           #E95420;
@define-color theme_selected_fg_color           #ffffff;
@define-color theme_unfocused_selected_bg_color #E95420;
@define-color theme_unfocused_selected_fg_color #ffffff;

/* Suggested action buttons */
@define-color suggested_action_bg_color #E95420;
@define-color suggested_action_fg_color #ffffff;

/* Focus ring */
@define-color focus_color #E95420;
EOF
      for target in "$HOME/.config/gtk-3.0/gtk.css" "$HOME/.config/gtk-4.0/gtk.css"; do
        if [ ! -f "$target" ] || ! cmp -s "$GTK_CSS_NEW" "$target"; then
          cp "$GTK_CSS_NEW" "$target"
          STATUS_CHANGES+=("$(basename "$(dirname "$target")")/gtk.css written (Ubuntu orange)")
          RELOGIN_NEEDED=1
        else
          STATUS_NOCHANGE+=("$(basename "$(dirname "$target")")/gtk.css already current")
        fi
      done
      rm -f "$GTK_CSS_NEW"

      # GTK 2 legacy apps (synaptic, gimp 2.10, etc.)
      GTKRC2="$HOME/.gtkrc-2.0"
      touch "$GTKRC2"
      if ! grep -q "^gtk-color-scheme" "$GTKRC2"; then
        printf 'gtk-color-scheme = "selected_bg_color:#E95420\\nselected_fg_color:#FFFFFF"\n' >> "$GTKRC2"
        STATUS_CHANGES+=("~/.gtkrc-2.0 += Ubuntu-orange selection colors")
        RELOGIN_NEEDED=1
      else
        STATUS_NOCHANGE+=("~/.gtkrc-2.0 already has gtk-color-scheme")
      fi

      # ------------------------------------------------------------------
      # Ptyxis: Ubuntu's default terminal since 24.10. Selects the built-in
      # Ubuntu palette and makes Ptyxis the system default terminal.
      # ------------------------------------------------------------------
      if command -v ptyxis >/dev/null 2>&1; then
        # missing_packages() only checks "is it installed", so a Debian-origin
        # ptyxis is never re-queued by the pin alone. Compare versions
        # explicitly and switch if they differ.
        _ptyxis_installed_ver="$(dpkg-query -W -f='${Version}' ptyxis 2>/dev/null)"
        _ptyxis_candidate_ver="$(apt-cache policy ptyxis 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
        if [ -n "$_ptyxis_candidate_ver" ] && [ "$_ptyxis_installed_ver" != "$_ptyxis_candidate_ver" ]; then
          message "switching ptyxis ${_ptyxis_installed_ver} → ${_ptyxis_candidate_ver} (Ubuntu ${PTYXIS_CODENAME})"
          if sudo apt-get install -y --allow-downgrades "ptyxis=${_ptyxis_candidate_ver}" >/dev/null 2>&1; then
            STATUS_CHANGES+=("ptyxis switched to Ubuntu build ${_ptyxis_candidate_ver} (${PTYXIS_CODENAME})")
            RELOGIN_NEEDED=1
          else
            message warn "failed to switch ptyxis to the Ubuntu build — keeping ${_ptyxis_installed_ver}"
          fi
        fi

        # Ptyxis ships a built-in "Ubuntu" palette (48.x+); a custom file with
        # the same id would create a visible duplicate entry. Remove any such
        # leftover from older script versions.
        PTYXIS_STALE_PALETTE_FILE="$HOME/.local/share/org.gnome.Ptyxis/palettes/Ubuntu.palette"
        if [ -f "$PTYXIS_STALE_PALETTE_FILE" ]; then
          rm -f "$PTYXIS_STALE_PALETTE_FILE"
          STATUS_CHANGES+=("Removed duplicate custom Ubuntu Ptyxis palette (built-in one is used instead)")
        fi

        message "selecting Ptyxis's built-in Ubuntu palette"

        # Ptyxis profiles live at /org/gnome/Ptyxis/Profiles/<uuid>/ (relocatable
        # schema). Reuse the existing default profile if there is one; otherwise
        # create one so the palette is set before Ptyxis is ever launched.
        PTYXIS_UUID="$(dconf read /org/gnome/Ptyxis/default-profile-uuid 2>/dev/null | tr -d \')"
        [ -z "$PTYXIS_UUID" ] && PTYXIS_UUID="$(gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d \')"
        if [ -n "$PTYXIS_UUID" ]; then
          PTYXIS_CUR_PALETTE="$(dconf read "/org/gnome/Ptyxis/Profiles/${PTYXIS_UUID}/palette" 2>/dev/null | tr -d \')"
          if [ "$PTYXIS_CUR_PALETTE" != "Ubuntu" ]; then
            for _key in palette label; do
              dconf write "/org/gnome/Ptyxis/Profiles/${PTYXIS_UUID}/${_key}" "'Ubuntu'" 2>/dev/null || true
            done
            STATUS_CHANGES+=("Ptyxis: Ubuntu palette applied to profile ${PTYXIS_UUID}")
            RELOGIN_NEEDED=1
          else
            STATUS_NOCHANGE+=("Ptyxis: profile ${PTYXIS_UUID} already uses Ubuntu palette")
          fi
        else
          PTYXIS_NEW_UUID="$(python3 -c 'import uuid; print(uuid.uuid4().hex)' 2>/dev/null || uuidgen 2>/dev/null | tr -d '-' || echo "ptyxis-$(date +%s)")"
          dconf write /org/gnome/Ptyxis/default-profile-uuid "'${PTYXIS_NEW_UUID}'"
          dconf write /org/gnome/Ptyxis/profile-uuids "['${PTYXIS_NEW_UUID}']"
          dconf write "/org/gnome/Ptyxis/Profiles/${PTYXIS_NEW_UUID}/palette" "'Ubuntu'"
          dconf write "/org/gnome/Ptyxis/Profiles/${PTYXIS_NEW_UUID}/label" "'Ubuntu'"
          STATUS_CHANGES+=("Ptyxis: created profile ${PTYXIS_NEW_UUID} with Ubuntu palette")
          RELOGIN_NEEDED=1
        fi

        # Clean up the non-functional Nautilus Script a previous run of this
        # script may have left behind (Scripts menu doesn't exist in nautilus
        # 43+, so this file could never have done anything).
        NAUTILUS_STALE_SCRIPT="$HOME/.local/share/nautilus/scripts/Open Terminal Here"
        if [ -f "$NAUTILUS_STALE_SCRIPT" ]; then
          rm -f "$NAUTILUS_STALE_SCRIPT"
          STATUS_CHANGES+=("Removed non-functional Nautilus Script: 'Open Terminal Here'")
        fi

        # nautilus-extension-gnome-terminal is hardcoded to gnome-terminal
        # over D-Bus and cannot be pointed at Ptyxis. Remove it; replaced
        # below with a Nautilus extension that launches Ptyxis instead.
        if is_installed nautilus-extension-gnome-terminal; then
          if sudo apt-get remove -y nautilus-extension-gnome-terminal 2>/dev/null; then
            STATUS_CHANGES+=("Removed nautilus-extension-gnome-terminal (hardcoded to gnome-terminal, conflicts with Ptyxis)")
            mkdir -p "$BACKUP_DIR"
            echo "nautilus-extension-gnome-terminal" >> "$REMOVED_MANIFEST"
            sort -u -o "$REMOVED_MANIFEST" "$REMOVED_MANIFEST"
            RELOGIN_NEEDED=1
          else
            message warn "failed to remove nautilus-extension-gnome-terminal"
          fi
        fi

        # python3-nautilus (Nautilus.MenuProvider) is the supported way to add
        # right-click menu items in GTK4 Nautilus.
        if ! is_installed python3-nautilus; then
          if sudo apt-get install -y python3-nautilus 2>/dev/null; then
            STATUS_CHANGES+=("Installed python3-nautilus (for the Ptyxis right-click extension)")
            STATUS_INSTALLED+=("python3-nautilus")
          else
            message warn "failed to install python3-nautilus — Nautilus right-click won't get a terminal entry"
          fi
        else
          STATUS_NOCHANGE+=("python3-nautilus already installed")
        fi

        if is_installed python3-nautilus; then
          NAUTILUS_EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
          NAUTILUS_EXT_FILE="${NAUTILUS_EXT_DIR}/ubuntu_look_ptyxis.py"
          mkdir -p "$NAUTILUS_EXT_DIR"
          NAUTILUS_EXT_NEW="$(mktemp)"
          cat << 'EOF' > "$NAUTILUS_EXT_NEW"
# Installed by ubuntu-look.sh — adds "Open Terminal Here" to Nautilus's
# right-click menu, launching Ptyxis in the folder being viewed.
from gi.repository import GLib, GObject, Nautilus


class UbuntuLookOpenPtyxisHere(GObject.GObject, Nautilus.MenuProvider):
    def _menu_item(self, item_id, path):
        item = Nautilus.MenuItem(
            name=item_id,
            label="Open Terminal Here",
            icon="org.gnome.Ptyxis",
        )
        item.connect("activate", self._launch, path)
        return item

    def _launch(self, _menu_item, path):
        GLib.spawn_async(
            ["ptyxis", "--new-window", "--working-directory=" + path],
            flags=GLib.SpawnFlags.SEARCH_PATH,
        )

    def get_background_items(self, folder):
        path = folder.get_location().get_path()
        if not path:
            return []
        return [self._menu_item("UbuntuLookOpenPtyxisHere::background", path)]

    def get_file_items(self, files):
        if len(files) != 1 or not files[0].is_directory():
            return []
        path = files[0].get_location().get_path()
        if not path:
            return []
        return [self._menu_item("UbuntuLookOpenPtyxisHere::selection", path)]
EOF
          if [ ! -f "$NAUTILUS_EXT_FILE" ] || ! cmp -s "$NAUTILUS_EXT_NEW" "$NAUTILUS_EXT_FILE"; then
            cp "$NAUTILUS_EXT_NEW" "$NAUTILUS_EXT_FILE"
            STATUS_CHANGES+=("Nautilus extension installed: 'Open Terminal Here' → Ptyxis (right-click ▸ Open Terminal Here)")
            RELOGIN_NEEDED=1
          else
            STATUS_NOCHANGE+=("Nautilus Ptyxis extension already current")
          fi
          rm -f "$NAUTILUS_EXT_NEW"
        fi

        if command -v update-alternatives >/dev/null 2>&1; then
          _ptyxis_bin="$(command -v ptyxis)"
          _alt_current="$(readlink -f /etc/alternatives/x-terminal-emulator 2>/dev/null || true)"
          sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator "$_ptyxis_bin" 30 2>/dev/null || true
          if [ "$_alt_current" != "$_ptyxis_bin" ]; then
            sudo update-alternatives --set x-terminal-emulator "$_ptyxis_bin" 2>/dev/null || true
            STATUS_CHANGES+=("x-terminal-emulator alternative set to ptyxis")
            RELOGIN_NEEDED=1
          else
            STATUS_NOCHANGE+=("x-terminal-emulator alternative already ptyxis")
          fi
        fi

        # xdg-terminal-exec (used by newer terminal-launching apps) checks
        # <desktop>-xdg-terminals.list before the generic xdg-terminals.list, in
        # $XDG_CONFIG_HOME then $XDG_DATA_HOME/DIRS — write both so it resolves
        # to Ptyxis regardless of $XDG_CURRENT_DESKTOP.
        mkdir -p "$HOME/.config"
        for _xlist in xdg-terminals.list ubuntu-xdg-terminals.list; do
          _xf="$HOME/.config/${_xlist}"
          if [ ! -f "$_xf" ] || ! grep -qs '^org.gnome.Ptyxis' "$_xf"; then
            printf '%s\n' 'org.gnome.Ptyxis.desktop:new-window' 'org.gnome.Ptyxis.desktop' > "$_xf"
            STATUS_CHANGES+=("Ptyxis: wrote ~/.config/${_xlist}")
            RELOGIN_NEEDED=1
          else
            STATUS_NOCHANGE+=("Ptyxis: ~/.config/${_xlist} already has Ptyxis")
          fi
        done
      else
        message warn "Ptyxis not installed — skipping terminal configuration"
      fi
      ;;
  esac
done

# Record every package this run actually installed (not just "present"), so
# uninstall.sh can remove exactly what ubuntu-look.sh added — never a package
# that happened to already be on the system for unrelated reasons.
if [ ${#STATUS_INSTALLED[@]} -gt 0 ]; then
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "${STATUS_INSTALLED[@]}" | sed -E 's/ \(prereq\)$//' >> "$INSTALLED_MANIFEST"
  sort -u -o "$INSTALLED_MANIFEST" "$INSTALLED_MANIFEST"
fi

message "${GREEN}All steps finished. See SUMMARY below.${ENDCOLOR}"
