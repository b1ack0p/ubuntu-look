#!/bin/bash
# =============================================================================
# Title       : ubuntu-look.sh
# Description : Transform a Debian GNOME desktop into an authentic Ubuntu look.
#               Installs genuine Yaru theme, Ubuntu fonts, official wallpapers,
#               ubuntu-dock, and applies all Ubuntu GNOME defaults — including
#               extension enabling — via a dconf system profile so everything
#               takes effect on the FIRST run (no second run after reboot).
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
#                   UBUNTU_CODENAME=plucky bash ubuntu-look.sh
#
# Requires    : Debian 12+ with GNOME desktop, user in 'sudo' group,
#               working internet connection.
# =============================================================================

arguments="$@"

declare -A packages

# Core tools: Plymouth splash, apt/key helpers, dconf compiler (for system profile)
packages[0-base]="plymouth plymouth-themes curl wget gnupg ca-certificates dconf-cli"

# Ubuntu fonts + wallpapers.
# desktop-base    = official Debian release wallpapers (current Debian default themes)
# gnome-backgrounds = GNOME's own curated wallpaper collection (ships with GNOME)
# ubuntu-wallpapers + per-release packs = all Ubuntu wallpapers across releases
# (per-release packs are resolved + appended after Ubuntu codename auto-detect)
packages[1-desktop-base]="fonts-ubuntu fonts-ubuntu-console
desktop-base gnome-backgrounds
ubuntu-wallpapers"

# Gnome-shell extensions + full Yaru theme stack.
# gnome-shell-extension-ubuntu-dock = Canonical's official Ubuntu fork of dash-to-dock.
# humanity-icon-theme                = fallback icon set Ubuntu ships alongside Yaru.
packages[2-desktop-gnome]="gnome-shell-extensions
gnome-shell-extension-desktop-icons-ng
gnome-shell-extension-ubuntu-dock
gnome-shell-extension-appindicator
gnome-shell-extension-manager
yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound
humanity-icon-theme"

# Ubuntu release to pull Yaru theme + Ubuntu fonts from.
# yaru-theme-gnome-shell has a hard "Breaks: gnome-shell (<< N~)" pin, so the
# wrong codename causes apt to refuse the install.  We auto-pick to match the
# running gnome-shell major version.  Override with UBUNTU_CODENAME=<name>.
UBUNTU_CODENAME="${UBUNTU_CODENAME:-auto}"
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu"

# Ubuntu releases for which we add entries in ubuntu-themes.list (sources only).
# ubuntu-wallpapers-* packages to install are discovered dynamically after apt
# update, so this list does NOT need to enumerate every Ubuntu release.
# The auto-detected theme codename is added to this list at runtime if not present.
WALLPAPER_CODENAMES="focal jammy noble plucky questing"

# Bump this whenever the pin/source content changes so re-runs detect stale config.
PIN_VERSION="v6-2026-06-22"

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

missing_packages() {
  local missing=""
  for pkg in $1; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing="$missing $pkg"
  done
  echo "$missing" | xargs
}

installed_packages() {
  local got=""
  for pkg in $1; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" && got="$got $pkg"
  done
  echo "$got" | xargs
}

# Filter a list to only packages actually available in the apt cache.
# Used for optional packages (e.g. wallpaper packs) that may not exist in all repos.
available_packages() {
  local avail=""
  for pkg in $1; do
    apt-cache show "$pkg" >/dev/null 2>&1 && avail="$avail $pkg"
  done
  echo "$avail" | xargs
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

# Auto-detect running gnome-shell major version → Ubuntu codename.
# yaru-theme-gnome-shell is pinned to a specific gnome-shell major, so the
# codename must match what the user's gnome-shell actually is.
detect_ubuntu_codename() {
  local v
  command -v gnome-shell >/dev/null 2>&1 || { echo "noble"; return; }
  v="$(gnome-shell --version 2>/dev/null | awk '{print $3}' | cut -d. -f1)"
  case "$v" in
    50|51)    echo "questing" ;;  # Ubuntu 25.10 / 26.04 transition
    48|49)    echo "plucky"   ;;  # Ubuntu 25.04
    46|47)    echo "noble"    ;;  # Ubuntu 24.04 LTS
    *)        echo "noble"    ;;  # unknown — fall back to LTS
  esac
}

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
enabled-extensions=['ubuntu-appindicators@ubuntu.com', 'ubuntu-dock@ubuntu.com', 'ding@rastersoft.com', 'user-theme@gnome-shell-extensions.gcampax.github.com']
disable-user-extensions=false
always-show-log-out=true
start-in-overview=false

[org/gnome/desktop/interface]
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

[org/gnome/desktop/background]
show-desktop-icons=true
picture-uri='file://${wp_light}'
picture-uri-dark='file://${wp_dark}'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file://${wp_light}'

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

[org/gnome/shell/extensions/dash-to-dock]
autohide-in-fullscreen=false
transparency-mode='FIXED'
background-color='#0c0c0c'
custom-background-color=true
background-opacity=0.64
click-action='focus-or-previews'
custom-theme-shrink=true
dash-max-icon-size=42
dock-fixed=true
dock-position='LEFT'
extend-height=true
show-apps-at-top=true
running-indicator-style='DOTS'
icon-size-fixed=true

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
# Resolve Ubuntu codename
###############################################################################

if [ "$UBUNTU_CODENAME" = "auto" ]; then
  UBUNTU_CODENAME="$(detect_ubuntu_codename)"
  GS_VER="$(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')"
  message "auto-detected Ubuntu codename ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} (${GS_VER})"
fi

# Ensure the auto-detected theme codename has a source entry.
if ! echo "$WALLPAPER_CODENAMES" | grep -qw "$UBUNTU_CODENAME"; then
  WALLPAPER_CODENAMES="$WALLPAPER_CODENAMES $UBUNTU_CODENAME"
fi
# ubuntu-wallpapers-* packages are discovered dynamically after apt update below.

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
# Step: Ubuntu apt repo (themes / fonts only, strictly pinned)
###############################################################################

step "Configure Ubuntu archive (Yaru theme: ${UBUNTU_CODENAME} | wallpapers: all releases)"

for prereq in gnupg curl ca-certificates; do
  dpkg-query -W -f='${Status}' "$prereq" 2>/dev/null | grep -q "install ok installed" && continue
  sudo apt-get update -qq
  sudo apt-get install -y "$prereq" || error "Failed to install prerequisite: $prereq"
  STATUS_INSTALLED+=("$prereq (prereq)")
done

UBUNTU_KEYRING=/etc/apt/keyrings/ubuntu-archive.gpg
UBUNTU_LIST=/etc/apt/sources.list.d/ubuntu-themes.list
UBUNTU_PIN=/etc/apt/preferences.d/ubuntu-themes

NEED_REPO_REWRITE=0
if [ ! -f "$UBUNTU_LIST" ] || [ ! -f "$UBUNTU_KEYRING" ] || [ ! -f "$UBUNTU_PIN" ]; then
  NEED_REPO_REWRITE=1
elif ! grep -q "# pin-version: ${PIN_VERSION}" "$UBUNTU_PIN"; then
  message warn "Ubuntu repo config is from an older script version — rewriting"
  NEED_REPO_REWRITE=1
fi

if [ $NEED_REPO_REWRITE -eq 1 ]; then
  message "configuring Ubuntu archive (theme: ${UBUNTU_CODENAME} | wallpapers: ${WALLPAPER_CODENAMES})"
  sudo install -d -m 0755 /etc/apt/keyrings

  if ! sudo test -s "$UBUNTU_KEYRING"; then
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF6ECB3762474EDA9D21B7022871920D1991BC93C" \
      | sudo gpg --dearmor -o "$UBUNTU_KEYRING" || error "Failed to fetch Ubuntu signing key"
    sudo chmod 0644 "$UBUNTU_KEYRING"
  fi

  # Build source list: one entry per wallpaper codename + the theme codename
  # (deduped).  All codenames share the same signing key.
  {
    echo "# Ubuntu — Yaru theme (${UBUNTU_CODENAME}) + wallpapers (all releases)"
    echo "# Strictly apt-pinned — only theme/font/wallpaper packages are allowed."
    echo "# See: ${UBUNTU_PIN}"
    echo ""
    # Collect unique codenames: wallpaper set + theme codename
    printed=""
    for _c in $WALLPAPER_CODENAMES $UBUNTU_CODENAME; do
      echo "$printed" | grep -qw "$_c" && continue
      printed="$printed $_c"
      echo "deb [signed-by=${UBUNTU_KEYRING}] ${UBUNTU_MIRROR} ${_c} main universe"
      echo "deb [signed-by=${UBUNTU_KEYRING}] ${UBUNTU_MIRROR} ${_c}-updates main universe"
    done
  } | sudo tee "$UBUNTU_LIST" > /dev/null

  # Priority -1 blocks everything from Ubuntu by default.
  # The whitelist explicitly allows only theme/icon/font/wallpaper packages and
  # their Ubuntu-only deps (e.g. session-migration pulled by yaru-theme-gtk).
  cat << EOF | sudo tee "$UBUNTU_PIN" > /dev/null
# pin-version: ${PIN_VERSION}
Package: *
Pin: release o=Ubuntu
Pin-Priority: -1

# Theme and GNOME-shell-extension packages must come only from the matching
# Ubuntu codename, otherwise a newer release's yaru-theme-gnome-shell may
# require a gnome-shell version Debian does not provide, causing a hold.
Package: yaru-theme-* fonts-ubuntu* humanity-icon-theme suru-icon-theme gnome-shell-extension-ubuntu-* session-migration
Pin: release o=Ubuntu, n=${UBUNTU_CODENAME}
Pin-Priority: 990

# Wallpapers have no hard dependency on gnome-shell, so they are safe to pull
# from any Ubuntu release — this lets us install wallpaper packs across all
# releases (focal … questing) without creating version conflicts.
Package: ubuntu-wallpapers*
Pin: release o=Ubuntu
Pin-Priority: 990
EOF
  STATUS_CHANGES+=("Ubuntu apt source written (theme: ${UBUNTU_CODENAME}, wallpapers: all releases)")
else
  message "Ubuntu themes repo already configured"
  STATUS_NOCHANGE+=("Ubuntu apt source already current")
fi

###############################################################################
# Step: apt update + upgrade
###############################################################################

step "Refresh package lists"
sudo apt-get update || error "apt update failed"

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

# Discover ALL available ubuntu-wallpapers-* packages (every Ubuntu release ever
# packaged — from karmic 9.10 through the latest — plus lts-legacy) and append
# them to the 1-desktop-base install list.  available_packages() in the install
# loop silently skips any that aren't in the cache.
_all_wp="$(apt-cache pkgnames 2>/dev/null | grep '^ubuntu-wallpapers' | sort | tr '\n' ' ')"
packages[1-desktop-base]="${packages[1-desktop-base]} ${_all_wp}"

###############################################################################
# Step: Install packages per category + post-install tasks
###############################################################################

for category in $package_categories; do
  step "Install + configure: ${category}"

  # Filter the full list to only packages that exist in the apt cache.
  # This lets us list optional packages (e.g. ubuntu-wallpapers-focal) without
  # failing when a particular Ubuntu repo doesn't carry them.
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
      # GRUB: enable splash for Plymouth
      if ! grep -q 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' /etc/default/grub; then
        message "setting GRUB_CMDLINE_LINUX_DEFAULT='quiet splash'"
        sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' \
          /etc/default/grub || error "Failed to update /etc/default/grub"
        sudo update-grub
        STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"")
        REBOOT_NEEDED=1
      else
        STATUS_NOCHANGE+=("/etc/default/grub already 'quiet splash'")
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
      # Resolve wallpaper paths (for dconf profile and live gsettings)
      WP_LIGHT="$(ls -1 /usr/share/backgrounds/*Full*Light*.png 2>/dev/null | sort -V | tail -1)"
      WP_DARK="$(ls -1 /usr/share/backgrounds/*Full*Dark*.png 2>/dev/null | sort -V | tail -1)"
      WP_LIGHT="${WP_LIGHT:-/usr/share/backgrounds/warty-final-ubuntu.png}"
      WP_DARK="${WP_DARK:-$WP_LIGHT}"

      # ------------------------------------------------------------------
      # Write dconf system profile (the fix for "needs two runs"):
      # Settings here take effect on first login without any GNOME session,
      # including extension enabling via enabled-extensions list.
      # ------------------------------------------------------------------
      message "writing dconf system profile (extensions + GNOME defaults)"
      write_dconf_profile "$WP_LIGHT" "$WP_DARK"

      # If we have a live GNOME session, also apply immediately via gsettings
      if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        message "live session detected — applying settings immediately via gsettings"

        gset org.gnome.shell disable-user-extensions false
        gset org.gnome.shell always-show-log-out true
        gset org.gnome.shell start-in-overview false

        # Enable extensions in the running shell
        for ext in \
          ubuntu-appindicators@ubuntu.com \
          ubuntu-dock@ubuntu.com \
          ding@rastersoft.com \
          user-theme@gnome-shell-extensions.gcampax.github.com
        do
          gnome-extensions enable "$ext" 2>/dev/null || true
        done

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
        gset org.gnome.shell.extensions.dash-to-dock autohide-in-fullscreen false
        gset org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED'
        gset org.gnome.shell.extensions.dash-to-dock background-color '#0c0c0c'
        gset org.gnome.shell.extensions.dash-to-dock custom-background-color true
        gset org.gnome.shell.extensions.dash-to-dock background-opacity 0.64
        gset org.gnome.shell.extensions.dash-to-dock click-action 'focus-or-previews'
        gset org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true
        gset org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 42
        gset org.gnome.shell.extensions.dash-to-dock dock-fixed true
        gset org.gnome.shell.extensions.dash-to-dock dock-position 'LEFT'
        gset org.gnome.shell.extensions.dash-to-dock extend-height true
        gset org.gnome.shell.extensions.dash-to-dock show-apps-at-top true
        gset org.gnome.shell.extensions.dash-to-dock running-indicator-style 'DOTS'
        gset org.gnome.shell.extensions.dash-to-dock icon-size-fixed true
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

      # Apply wallpaper path to summary regardless
      [ -f "$WP_LIGHT" ] && STATUS_CHANGES+=("Wallpaper: $(basename "$WP_LIGHT")")

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

      # gnome-terminal Ubuntu purple profile (only if schema exists)
      if command -v gnome-terminal >/dev/null 2>&1 \
         && gsettings list-schemas 2>/dev/null | grep -q "^org.gnome.Terminal.ProfilesList$" \
         && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        message "applying Ubuntu purple gnome-terminal colors to default profile"
        gset org.gnome.Terminal.Legacy.Settings theme-variant 'dark'
        TERM_PROFILE_UUID="$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d \')"
        if [ -n "$TERM_PROFILE_UUID" ]; then
          TERM_PATH="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${TERM_PROFILE_UUID}/"
          gset "$TERM_PATH" use-theme-colors false
          gset "$TERM_PATH" background-color '#300A24'
          gset "$TERM_PATH" foreground-color '#FFFFFF'
          gset "$TERM_PATH" use-theme-transparency false
        fi
      fi
      ;;
  esac
done

message "${GREEN}All steps finished. See SUMMARY below.${ENDCOLOR}"
