#!/bin/bash
# =============================================================================
# Title       : ubuntu-look.sh
# Description : Applies the current Ubuntu desktop appearance to Debian GNOME:
#               Yaru theme, Ubuntu fonts, official wallpapers, ubuntu-dock and
#               the Ubuntu GNOME defaults, through a dconf system profile.
#               Visuals only; no additional applications are installed.
#
#               No release name is hardcoded. Ubuntu releases are read from the
#               archive dists/ index on each run and ordered by version, so a
#               new release is adopted the day it is published. Themes coupled
#               to a gnome-shell major version are pinned to the newest release
#               a simulated install proves compatible.
#
# Original    : DeltaLima
#               https://github.com/DeltaLima/make-debian-look-like-ubuntu
#
# Usage       : bash ubuntu-look.sh                     full run
#               bash ubuntu-look.sh 2-desktop-gnome     single stage
#               Stages: 0-base  1-desktop-base  2-desktop-gnome
#               Safe to re-run.
#
# Overrides   : UBUNTU_CODENAME=<name>    force one Ubuntu release
#               UBUNTU_INCLUDE_DEVEL=1    include the unreleased series
#               UBUNTU_BOOT_SPLASH=0      remove the boot splash again
#               PLYMOUTH_THEME=<name>     boot splash theme (default bgrt)
#               UBUNTU_LOOK_LOG=0         do not write a run log
#
# Undo        : bash uninstall.sh
#
# Requires    : Debian with GNOME, user in the 'sudo' group, internet access.
# =============================================================================

# -----------------------------------------------------------------------------
# Record the run.
#
# Re-executes once under tee so the terminal keeps its colours while a
# colour-stripped copy is written to $HOME/<script>-<date>.log. The re-exec,
# rather than a redirect, guarantees the summary printed on exit reaches the
# file. UBUNTU_LOOK_LOG=0 disables it.
# -----------------------------------------------------------------------------
if [ "${UBUNTU_LOOK_LOG:-1}" != "0" ] && [ -z "${UBUNTU_LOOK_LOGGING:-}" ]; then
  _self="${BASH_SOURCE[0]}"
  _log_file="${HOME}/ubuntu-look-$(date +%Y%m%d-%H%M%S).log"

  # Carry the current shell options across, so -u and friends still apply.
  _opts=()
  case "$-" in *u*) _opts+=(-u) ;; esac
  case "$-" in *e*) _opts+=(-e) ;; esac
  case "$-" in *x*) _opts+=(-x) ;; esac

  export UBUNTU_LOOK_LOGGING=1
  echo "Recording this run to ${_log_file}"
  bash "${_opts[@]}" "$_self" "$@" 2>&1 \
    | tee >(sed -r 's/\x1b\[[0-9;]*[mK]//g' > "$_log_file")
  _rc=${PIPESTATUS[0]}
  echo "Log written to ${_log_file}"
  exit "$_rc"
fi

# Debian leaves the sbin directories off a normal user's PATH, but
# update-grub, update-initramfs and the plymouth tools live there. Without
# this, every "command -v" for them reports missing on a system that has them
# installed, and the boot splash is skipped silently. Appended, so a binary in
# /usr/bin still wins; sudo uses its own secure_path and is unaffected.
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" ;;
esac

# Facts the log needs before anything else runs.
{
  echo "### $(basename "${BASH_SOURCE[0]}")  $(sha256sum "${BASH_SOURCE[0]}" 2>/dev/null | cut -c1-16)"
  echo "### date    : $(date -Iseconds)"
  echo "### args    : ${*:-<none>}"
  echo "### system  : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "### gnome   : $(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')"
  echo "### session : ${XDG_SESSION_TYPE:-?} / ${XDG_CURRENT_DESKTOP:-?}"
  echo "### dbus    : $([ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && echo present || echo absent)"
  echo "### kernel  : $(uname -r) / $(dpkg --print-architecture 2>/dev/null || uname -m)"
  # A pipeline exits 0 even with no output, so the fallback is applied here.
  # Debian ships no mutter binary with GNOME — gnome-shell carries libmutter —
  # so the package version is what identifies the compositor there.
  _wm="$(mutter --version 2>/dev/null | head -1)"
  [ -n "$_wm" ] ||
    _wm="$(dpkg-query -W -f='${Package} ${Version}\n' 'libmutter-*' 2>/dev/null | head -1)"
  echo "### wm      : ${_wm:-unknown}"
  # Two pins are in play: the shell theme has to match the running gnome-shell,
  # while the GTK theme, fonts and wallpapers float to the newest release. Both
  # are reported. Versions come from apt's cached Release files, so no network.
  _rel_version() {
    [ -n "$1" ] || return 0
    sed -n 's/^Version: //p' /var/lib/apt/lists/*_dists_"$1"_InRelease 2>/dev/null | head -1
  }
  _pinned="$(sed -n 's/^Pin: release o=Ubuntu, n=//p' /etc/apt/preferences.d/ubuntu-themes 2>/dev/null | head -1)"
  _float="$(apt-cache policy yaru-theme-gtk 2>/dev/null |
    awk '/^ \*\*\*/{f=1;next} f&&/:\/\//{print $3; exit}')"
  _float="${_float%%/*}"
  _pv="$(_rel_version "$_pinned")"
  _fv="$(_rel_version "$_float")"
  _u1="${_pv:+${_pv} (${_pinned})}"; _u1="${_u1:-${_pinned}}"
  _u2="${_fv:+${_fv} (${_float})}"; _u2="${_u2:-${_float}}"
  echo "### shell   : ${_u1:+ubuntu }${_u1:-none pinned yet}"
  echo "### themes  : ${_u2:+ubuntu }${_u2:-not installed yet}"
  echo ""
}


set -u

arguments="$*"

# id -un always answers; $USER is unset under su and in minimal
# environments, which aborts outright when the script runs with set -u.
RUN_USER="$(id -un)"

declare -A packages

# Core tools: Plymouth splash + the dconf compiler for the system profile.
# curl/gnupg/ca-certificates are installed earlier as prerequisites, so they
# are deliberately not repeated here.
packages[0-base]="dconf-cli"

# Ubuntu fonts and wallpapers. ubuntu-wallpapers is a metapackage; it pulls in
# the release's full wallpaper pack, which populates GNOME's background picker.
packages[1-desktop-base]="fonts-ubuntu ubuntu-wallpapers"

# GNOME Shell extensions + full Yaru theme stack. tiling-assistant is
# Ubuntu's built-in tiling extension, default since 24.04.
packages[2-desktop-gnome]="gnome-shell-extension-user-theme
gnome-shell-extension-desktop-icons-ng
gnome-shell-extension-ubuntu-dock
gnome-shell-extension-ubuntu-tiling-assistant
gnome-shell-extension-appindicator
yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound"

# Ubuntu release supplying the Yaru theme and fonts. yaru-theme-gnome-shell is
# tied to a gnome-shell major version, so the codename is verified compatible
# first; see resolve_ubuntu_codename().
UBUNTU_CODENAME="${UBUNTU_CODENAME:-auto}"
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu"

# Ubuntu boots with "quiet splash" and Plymouth. This is the only setting that
# affects boot, so its changes are recorded and UBUNTU_BOOT_SPLASH=0 reverts
# exactly those.
UBUNTU_BOOT_SPLASH="${UBUNTU_BOOT_SPLASH:-1}"

# Ubuntu's own boot splash theme, and Debian ships it too: a black background,
# the firmware's logo where the firmware supplies one and the distribution's
# where it does not, and a spinner below. Nothing of Ubuntu's is drawn -- on
# Debian the images come from Debian's spinner theme.
PLYMOUTH_THEME="${PLYMOUTH_THEME:-bgrt}"

# Plymouth is only worth installing when that splash is actually wanted —
# without "splash" on the kernel command line its theme is never shown.
[ "$UBUNTU_BOOT_SPLASH" != "0" ] && packages[0-base]="plymouth plymouth-themes ${packages[0-base]}"

# Set to 1 to also consider the Ubuntu release that is still in development.
# Off by default — see discover_ubuntu_codenames() for why.
UBUNTU_INCLUDE_DEVEL="${UBUNTU_INCLUDE_DEVEL:-0}"

# Last-resort seed for discover_ubuntu_codenames(), used only when the
# archive's own dists/ index can't be read (proxy, or a mirror without a
# directory listing). Normal runs never consult this list.
FALLBACK_CODENAMES="noble plucky questing resolute"

# Number of recent Ubuntu releases configured as candidate sources. Each suite
# adds a full Packages index to every apt update. Four covers current Debian
# stable with one release of margin either side.
MAX_UBUNTU_CANDIDATES=4

# Ubuntu Archive Automatic Signing Key. If Ubuntu ever rotates it, the
# NO_PUBKEY recovery in apt_update() fetches whatever the archive moved to.
UBUNTU_ARCHIVE_KEY="F6ECB3762474EDA9D21B7022871920D1991BC93C"

# Bump whenever pin/source content changes, so re-runs detect stale config.
PIN_VERSION="v15-2026-08-29"

# Extensions that make up the Ubuntu look. Single source of truth for the
# dconf profile, the live-session enable loop, and the verification loop.
SHELL_EXTENSIONS="ubuntu-appindicators@ubuntu.com ubuntu-dock@ubuntu.com ding@rastersoft.com tiling-assistant@ubuntu.com user-theme@gnome-shell-extensions.gcampax.github.com"

# One-time pre-install snapshot and the install manifest, so uninstall.sh can undo
# exactly what this script did and restore the previous state.
BACKUP_DIR="$HOME/.ubuntu-look-backup"
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
INSTALLED_MANIFEST="${BACKUP_DIR}/installed-by-script.txt"

# dconf system profile paths (system defaults, no running session required)
DCONF_PROFILE_DIR="/etc/dconf/db/local.d"
DCONF_PROFILE_FILE="${DCONF_PROFILE_DIR}/10-ubuntu-look"
DCONF_USER_PROFILE="/etc/dconf/profile/user"

# Ubuntu archive wiring
UBUNTU_KEYRING=/etc/apt/keyrings/ubuntu-archive.gpg
UBUNTU_LIST=/etc/apt/sources.list.d/ubuntu-themes.list
UBUNTU_PIN=/etc/apt/preferences.d/ubuntu-themes

# -----------------------------------------------------------------------------
# Status tracking
# -----------------------------------------------------------------------------
declare -a STATUS_INSTALLED=()
declare -a STATUS_ALREADY=()
# Every package the stages name, flattened, for log_final_state().
ALL_STAGE_PACKAGES="$(printf '%s ' "${packages[@]}" | xargs -n1 | sort -u | xargs)"

declare -a STATUS_CHANGES=()
declare -a STATUS_NOCHANGE=()
declare -a STATUS_FAILED=()
declare -a STATUS_EXT_FAILED=()
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
    warn)   MESSAGE_TYPE="${YELLOW}WARN${ENDCOLOR}"  ; shift ;;
    error)  MESSAGE_TYPE="${RED}ERROR${ENDCOLOR}"    ; shift ;;
    info)   MESSAGE_TYPE="${GREEN}INFO${ENDCOLOR}"   ; shift ;;
    *)      MESSAGE_TYPE="${GREEN}INFO${ENDCOLOR}"   ;;
  esac
  echo -e "[${MESSAGE_TYPE}] $*"
}

error() { message error "$1"; exit 1; }

confirm_continue() {
  message warn "Type '${GREEN}y${ENDCOLOR}' or '${GREEN}yes${ENDCOLOR}' and hit [ENTER] to continue"
  local reply
  echo "[y/N?] "
  read -r reply
  if [ "${reply,,}" != "y" ] && [ "${reply,,}" != "yes" ]; then
    message error "Aborted."
    exit 1
  fi
}

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Every package dpkg reports as actually installed, sorted. Deliberately not
# "every package dpkg knows about": one removed but never purged stays in the
# database in the 'rc' state, and counting that as present would tell the
# uninstall the package predates this script and exempt it for good. Same
# definition as is_installed() above, so the two can never disagree.
installed_package_list() {
  dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
    | awk '$2 == "install" && $4 == "installed" { print $1 }' | sort
}

missing_packages() {
  local missing="" pkg
  for pkg in $1; do
    is_installed "$pkg" || missing="$missing $pkg"
  done
  echo "$missing" | xargs
}

installed_packages() {
  local got="" pkg
  for pkg in $1; do
    is_installed "$pkg" && got="$got $pkg"
  done
  echo "$got" | xargs
}

# Filter a list to only packages actually available in the apt cache.
available_packages() {
  local avail="" pkg
  for pkg in $1; do
    apt-cache show "$pkg" >/dev/null 2>&1 && avail="$avail $pkg"
  done
  echo "$avail" | xargs
}

# Copy $1 over $2 only when the content differs. Returns 0 when the file was
# written, 1 when it was already identical.
install_if_changed() {
  [ -f "$2" ] && cmp -s "$1" "$2" && return 1
  # -D creates the parent dir; -m 0644 replaces mktemp's owner-only 0600.
  install -Dm 0644 "$1" "$2"
}

# Render a space-separated list as a dconf/GVariant string array:
# ['a', 'b', 'c'].
gvariant_string_array() {
  local out="" first=1 e
  for e in $1; do
    [ $first -eq 1 ] && first=0 || out="${out}, "
    out="${out}'${e}'"
  done
  # An empty array must carry its type: dconf cannot infer one from a bare []
  # and rejects the write, which is how clearing a key came to fail silently.
  [ -z "$out" ] && { echo "@as []"; return 0; }
  echo "[${out}]"
}

shell_extensions_dconf_array() { gvariant_string_array "$SHELL_EXTENSIONS"; }

# Convert a dconf string array to a space-separated list. dconf prints an empty
# array as "@as []"; the type prefix is stripped so it is not read as an item.
# dconf read prints nothing and exits 0 for a key that is not set, so a
# fallback written as "|| echo unset" never fires and the line comes out blank.
dconf_show() {
  local v
  v="$(dconf read "$1" 2>/dev/null)"
  printf '%s' "${v:-${2:-unset}}"
}

dconf_array_items() {
  dconf read "$1" 2>/dev/null \
    | sed 's/^@[a-z]* //' \
    | tr -d "[]' " | tr ',' ' '
}

# Enable the extensions in the user dconf database: the system profile supplies
# only a default, and 'gnome-extensions enable' does not reach extensions the
# running shell has not rescanned. Existing entries are kept.
# An extension uuid is name@domain, so anything without a name in front of the
# @ is not one. This also drops the literal "@as" that an earlier version of
# dconf_array_items could leave behind, instead of writing it back each run.
extension_uuids() {
  local e out=""
  for e in $(dconf_array_items "$1"); do
    case "$e" in ?*@?*) out="$out $e" ;; esac
  done
  echo "$out"
}

enable_shell_extensions() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 0
  command -v dconf >/dev/null 2>&1 || return 0

  local merged keep="" e
  merged="$(echo "$(extension_uuids /org/gnome/shell/enabled-extensions) $SHELL_EXTENSIONS" \
            | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  dconf write /org/gnome/shell/enabled-extensions "$(gvariant_string_array "$merged")" 2>/dev/null || return 0

  for e in $(extension_uuids /org/gnome/shell/disabled-extensions); do
    case " $SHELL_EXTENSIONS " in *" $e "*) ;; *) keep="$keep $e" ;; esac
  done
  dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$keep")" 2>/dev/null || true
}

# The dock belongs to the user, so this script pins nothing to it. An earlier
# version did, and the snapshot is what says which favourites were the user's:
# the key goes back to the value it held before this script first ran. Done
# once, so anything pinned by hand since stays where it is.
restore_dock_favourites() {
  local marker="${BACKUP_ORIGINAL}/favourites-restored"
  local dump="${BACKUP_ORIGINAL}/dconf-dump.ini"
  [ -f "$marker" ] && return 0
  [ -f "$dump" ] || return 0
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 0
  command -v dconf >/dev/null 2>&1 || return 0

  local was now
  was="$(awk -v grp='[org/gnome/shell]' -v key=favorite-apps '
      $0 == grp { ingrp = 1; next }
      /^\[/     { ingrp = 0 }
      ingrp && index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
    ' "$dump" 2>/dev/null)"
  now="$(dconf read /org/gnome/shell/favorite-apps 2>/dev/null)"

  if [ "$(printf '%s' "$was" | tr -d '[:space:]')" \
     != "$(printf '%s' "$now" | tr -d '[:space:]')" ]; then
    if [ -n "$was" ]; then
      dconf write /org/gnome/shell/favorite-apps "$was" 2>/dev/null || return 0
    else
      # No value recorded means the key was unset and the dock followed
      # GNOME's own defaults; unsetting it puts that back.
      dconf reset /org/gnome/shell/favorite-apps 2>/dev/null || return 0
    fi
    STATUS_CHANGES+=("Dock favourites put back to what they were before this script first ran")
    RELOGIN_NEEDED=1
  fi
  : > "$marker"
}

# -----------------------------------------------------------------------------
# Boot splash: Ubuntu's "quiet splash" and Plymouth. Both directions record the
# words added to the kernel command line and the previous Plymouth theme, so
# revert_boot_splash() undoes exactly those. UBUNTU_BOOT_SPLASH=0 and
# uninstall.sh use the same record.
# -----------------------------------------------------------------------------
GRUB_ADDED_FILE_NAME="grub-cmdline-added.txt"
PLYMOUTH_BEFORE_FILE_NAME="plymouth-theme-before.txt"


# The theme Plymouth is currently set to.
#
# Debian ships plymouth-set-default-theme but no plymouth-get-default-theme;
# called with no arguments the setter prints the current theme. Fedora and
# Ubuntu ship the getter, so try that first. Reading it is what tells an
# already-applied theme from one that still has to be set.
plymouth_current_theme() {
  local t=""
  if command -v plymouth-get-default-theme >/dev/null 2>&1; then
    t="$(plymouth-get-default-theme 2>/dev/null)"
  fi
  if [ -z "$t" ] && command -v plymouth-set-default-theme >/dev/null 2>&1; then
    t="$(plymouth-set-default-theme 2>/dev/null)"
  fi
  printf '%s' "$t"
}

# Current GRUB_CMDLINE_LINUX_DEFAULT value, and where it came from.
# Prints "<where> <value>": an active assignment wins over the commented-out
# one Debian ships; "absent" means the file has neither.
read_grub_cmdline() {
  local line
  line="$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null)"
  if [ -n "$line" ]; then
    printf 'active '
  else
    line="$(grep -m1 '^#[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null)"
    [ -n "$line" ] && printf 'commented ' || { printf 'absent \n'; return 0; }
  fi
  line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
  printf '%s\n' "$line"
}

# Put $1 on the line $2 says to rewrite, leaving the rest of the file alone.
# Exactly one line changes: /etc/default/grub is sourced top to bottom, so a
# second active assignment would silently shadow the first.
write_grub_cmdline() {
  local val="$1" tmp
  tmp="$(mktemp)"
  awk -v val="$val" '
    BEGIN { swapped = 0 }
    !swapped && /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
      print "GRUB_CMDLINE_LINUX_DEFAULT=\"" val "\""; swapped = 1; next
    }
    { print }
    END { if (!swapped) print "GRUB_CMDLINE_LINUX_DEFAULT=\"" val "\"" }
  ' /etc/default/grub > "$tmp"

  if [ ! -s "$tmp" ] || ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$tmp"; then
    rm -f "$tmp"
    message warn "the /etc/default/grub rewrite did not come out right — leaving it alone"
    return 1
  fi
  sudo cp "$tmp" /etc/default/grub || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  sudo update-grub
}

apply_boot_splash() {
  local where val new opt added="" before="" kept_out=""
  where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"
  # A commented line is not in force, so it counts as no line at all. It is
  # left commented and a line of our own is added below, which is what lets
  # the uninstall put the machine back exactly as it was.
  case "$where" in absent|commented) val="" ;; esac

  # What this script has already put on the command line. A word listed there
  # and no longer on the line was removed deliberately; putting it back would
  # overrule the user on their own bootloader.
  before="$(tr '
' ' ' 2>/dev/null < "${BACKUP_ORIGINAL}/${GRUB_ADDED_FILE_NAME}")"

  # Add whichever of Ubuntu's two words is missing; never replace the line.
  # A machine can depend on what is already there (nomodeset, resume=UUID=...,
  # an iommu flag, a serial console) and overwriting it can stop it booting.
  new="$val"
  for opt in quiet splash; do
    case " $new " in
      *" $opt "*) continue ;;
    esac
    # Recorded as put there by an earlier run and gone now: taken off by hand.
    # The bootloader is the user's, and a word they removed stays removed.
    case " $before " in
      *" $opt "*) kept_out="${kept_out:+${kept_out} }${opt}"; continue ;;
    esac
    new="${new:+${new} }${opt}"; added="${added:+${added} }${opt}"
  done

  [ -n "$kept_out" ] && STATUS_NOCHANGE+=("'${kept_out}' left off the kernel command line -- you took it off after the install")

  if [ -z "$added" ]; then
    [ -z "$kept_out" ] && STATUS_NOCHANGE+=("/etc/default/grub already boots with 'quiet splash'")
  else
    message "adding '${added}' to GRUB_CMDLINE_LINUX_DEFAULT"
    if write_grub_cmdline "$new"; then
      mkdir -p "$BACKUP_ORIGINAL"
      printf '%s\n' "$added" >> "${BACKUP_ORIGINAL}/${GRUB_ADDED_FILE_NAME}"
      STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"")
      REBOOT_NEEDED=1
    else
      STATUS_FAILED+=("/etc/default/grub could not be updated")
      return 0
    fi
  fi

  # Ubuntu boots with the bgrt theme and Debian carries the same one, so
  # setting it gives Ubuntu's boot splash drawn with Debian's own artwork. The
  # theme in force is recorded, which is what lets the uninstall put it back
  # and what says, on a later run, that the theme in use is no longer ours.
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("No Plymouth on this system -- boot splash theme left alone")
    return 0
  fi

  local before_file="${BACKUP_ORIGINAL}/${PLYMOUTH_BEFORE_FILE_NAME}"
  local current
  current="$(plymouth_current_theme)"

  if [ -z "$current" ]; then
    # With nothing to put back, the change could not be undone.
    STATUS_NOCHANGE+=("Could not read the current boot splash theme -- left as it is")
  elif [ "$current" = "$PLYMOUTH_THEME" ]; then
    STATUS_NOCHANGE+=("Boot splash theme already '${PLYMOUTH_THEME}'")
  elif [ -f "$before_file" ]; then
    STATUS_NOCHANGE+=("Boot splash theme left as you set it ('${current}')")
  elif ! plymouth-set-default-theme -l 2>/dev/null | grep -qx "$PLYMOUTH_THEME"; then
    STATUS_NOCHANGE+=("Boot splash theme '${PLYMOUTH_THEME}' is not installed -- left as it is")
  else
    message "setting the boot splash theme to '${PLYMOUTH_THEME}'"
    mkdir -p "$BACKUP_ORIGINAL"
    printf '%s\n' "$current" > "$before_file"
    if sudo plymouth-set-default-theme "$PLYMOUTH_THEME"; then
      if sudo update-initramfs -u -k all 2>/dev/null || sudo update-initramfs -u; then
        STATUS_CHANGES+=("Boot splash theme set to '${PLYMOUTH_THEME}' (was '${current}')")
      else
        STATUS_FAILED+=("Boot splash theme changed, but the initramfs rebuild failed -- run: sudo update-initramfs -u")
      fi
      REBOOT_NEEDED=1
    else
      rm -f "$before_file"
      message warn "could not set the boot splash theme to '${PLYMOUTH_THEME}'"
    fi
  fi
}

revert_boot_splash() {
  local added_file="${BACKUP_ORIGINAL}/${GRUB_ADDED_FILE_NAME}"
  local before_file="${BACKUP_ORIGINAL}/${PLYMOUTH_BEFORE_FILE_NAME}"
  local where val added word new kept dropped=0

  if [ -f "$added_file" ]; then
    added="$(tr '\n' ' ' < "$added_file")"
    where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"

    # Drop only the recorded words; everything else stays, in order.
    kept=""
    for word in $val; do
      case " $added " in
        *" $word "*) dropped=1 ;;
        *) kept="${kept:+${kept} }${word}" ;;
      esac
    done

    # On what was actually dropped, not on the two strings differing: a
    # difference of spacing alone would rewrite the file and report a removal
    # that never happened. uninstall.sh decides the same way.
    if [ $dropped -eq 1 ] && [ "$where" = active ]; then
      message "removing '${added% }' from GRUB_CMDLINE_LINUX_DEFAULT (UBUNTU_BOOT_SPLASH=0)"
      new="$kept"
      if write_grub_cmdline "$new"; then
        rm -f "$added_file"
        STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"")
        REBOOT_NEEDED=1
      fi
    else
      rm -f "$added_file"
      STATUS_NOCHANGE+=("/etc/default/grub no longer carries what this script added")
    fi
  else
    STATUS_NOCHANGE+=("Bootloader untouched — this script never added anything to it")
  fi

  # The record existing is what says this script set the theme and there is
  # something to put back.
  if command -v plymouth-set-default-theme >/dev/null 2>&1 && [ -f "$before_file" ]; then
    local was current
    was="$(cat "$before_file" 2>/dev/null)"
    current="$(plymouth_current_theme)"
    if [ -n "$was" ] && [ "$was" != "$current" ]; then
      sudo plymouth-set-default-theme "$was"
      if sudo update-initramfs -u -k all 2>/dev/null || sudo update-initramfs -u; then
        STATUS_CHANGES+=("Plymouth theme restored to '${was}'")
      else
        STATUS_FAILED+=("Boot splash theme changed, but the initramfs rebuild failed -- run: sudo update-initramfs -u")
      fi
      REBOOT_NEEDED=1
    fi
    # Removed either way, as the kernel command line above is: this run has
    # undone what there was to undo, and a record left behind would tell a
    # later run that the theme in use is not this script's to set.
    rm -f "$before_file"
  fi
}


# Enable the extensions in the next session, once.
#
# GNOME Shell scans its extension directories at session start and cannot be
# restarted on Wayland, so extensions installed afterwards cannot be enabled in
# the same session. A one-shot autostart entry does it at the next login and
# then removes itself.
install_extension_autostart() {
  local dir="$HOME/.local/share/ubuntu-look"
  local script="${dir}/enable-extensions.sh"
  local desktop="$HOME/.config/autostart/ubuntu-look-enable-extensions.desktop"

  # Nothing to schedule when the running session already has all of them on.
  # Writing the entry regardless would report a change on every re-run and ask
  # for a re-login that is not needed.
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gnome-extensions >/dev/null 2>&1; then
    local e all_on=1
    for e in $SHELL_EXTENSIONS; do
      gnome-extensions info "$e" 2>/dev/null | grep -q 'State: ACTIVE' || { all_on=0; break; }
    done
    if [ $all_on -eq 1 ]; then
      rm -f "$desktop" "$script"
      rmdir "$dir" 2>/dev/null || true
      STATUS_NOCHANGE+=("Extensions are already on — no autostart entry needed")
      return 0
    fi
  fi

  local tmp
  tmp="$(mktemp)"

  cat << EOF > "$tmp"
#!/bin/bash
# One-shot, written by ubuntu-look.sh. Runs once in a fresh session and then
# removes itself — see install_extension_autostart() for why it is needed.
SHELL_EXTENSIONS="${SHELL_EXTENSIONS}"

# Wait for the shell to be able to answer about an extension, rather than
# guessing at a delay: the moment it can, the extensions go on. A fixed sleep
# either fires too early on a slow machine or holds up a fast one. Gives up
# after 30 seconds and tries anyway.
for _i in \$(seq 1 30); do
  for _e in \$SHELL_EXTENSIONS; do
    gnome-extensions info "\$_e" >/dev/null 2>&1 && break 2
  done
  sleep 1
done

# Enable through gnome-shell, which moves the uuid between the two lists in one
# step. Writing dconf as well would enable the extension twice, and a second
# enable() registers the panel indicator again and fails.
for e in \$SHELL_EXTENSIONS; do
  gnome-extensions enable "\$e" 2>/dev/null || true
done

# Fallback only: if anything is still parked in disabled-extensions, take it
# out by hand. In a fresh session the loop above normally covers it.
keep=""
still=0
for e in \$(dconf read /org/gnome/shell/disabled-extensions 2>/dev/null \\
            | sed 's/^@[a-z]* //' | tr -d "[]' " | tr ',' ' '); do
  case " \$SHELL_EXTENSIONS " in
    *" \$e "*) still=1 ;;
    *)          keep="\${keep}'\$e'," ;;
  esac
done
if [ "\$still" = 1 ]; then
  # if/else rather than "&& ... || ...": a write of the kept list that
  # failed would fall through to the empty one and drop the extensions
  # the user disabled for themselves.
  if [ -n "\$keep" ]; then
    dconf write /org/gnome/shell/disabled-extensions "[\${keep%,}]" 2>/dev/null || true
  else
    dconf write /org/gnome/shell/disabled-extensions "@as []" 2>/dev/null || true
  fi
fi

rm -f "${desktop}" "${script}"
EOF
  install -Dm 0755 "$tmp" "$script"

  cat << EOF > "$tmp"
[Desktop Entry]
Type=Application
Name=ubuntu-look: enable extensions
Comment=Switches on the Ubuntu extensions once, then removes itself
Exec=${script}
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
  install -Dm 0644 "$tmp" "$desktop"
  rm -f "$tmp"

  STATUS_CHANGES+=("Extensions will be switched on at your next login (one-shot, self-removing)")
  RELOGIN_NEEDED=1
}

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
  echo -e "${YELLOW}  STEP ${STEP}: $1${ENDCOLOR}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
}

# Try gsettings if a D-Bus session is available (immediate effect on running
# desktop). The same values also go into the dconf system profile (see
# write_dconf_profile), so they apply on first login even without a session.
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

# -----------------------------------------------------------------------------
# Ubuntu GNOME defaults. One row per setting: "<dconf path>|<key>|<value>", in
# GVariant text, which suits both the dconf keyfile and 'gsettings set'. Rows
# must stay grouped by path; the profile writer emits one [group] header per
# contiguous block.
# -----------------------------------------------------------------------------

# Written to the system profile only. enable_shell_extensions() merges the
# extension list into whatever the user already has rather than replacing it,
# and the shell theme is applied once below with the variant that matches the
# colour scheme -- applying the table's value first would set the light theme
# and then correct it, reloading the shell's stylesheet twice.
DCONF_ONLY_KEYS=" enabled-extensions name "

# dconf path → gsettings schema id. The two are the same string apart from the
# GTK file-chooser schemas, whose dconf path does not mirror their schema id.
schema_for_path() {
  case "$1" in
    org/gtk/settings/file-chooser)      echo "org.gtk.Settings.FileChooser" ;;
    org/gtk/gtk4/settings/file-chooser) echo "org.gtk.gtk4.Settings.FileChooser" ;;
    *)                                  echo "${1//\//.}" ;;
  esac
}

GNOME_SETTINGS=(
  "org/gnome/shell|enabled-extensions|$(shell_extensions_dconf_array)"
  "org/gnome/shell|always-show-log-out|true"

  "org/gnome/desktop/interface|gtk-theme|'Yaru'"
  "org/gnome/desktop/interface|accent-color|'orange'"
  "org/gnome/desktop/interface|icon-theme|'Yaru'"
  "org/gnome/desktop/interface|cursor-theme|'Yaru'"
  "org/gnome/desktop/interface|font-name|'Ubuntu Sans 11'"
  "org/gnome/desktop/interface|monospace-font-name|'Ubuntu Sans Mono 11'"
  "org/gnome/desktop/interface|document-font-name|'Sans 11'"
  "org/gnome/desktop/interface|font-antialiasing|'rgba'"
  "org/gnome/desktop/interface|enable-hot-corners|false"
  # The one key here that Ubuntu does not override. The two ship different
  # schema defaults for it -- false on Ubuntu, true on Debian -- so this
  # reproduces a behaviour rather than repeating a value.
  "org/gnome/desktop/interface|gtk-enable-primary-paste|false"

  "org/gnome/desktop/wm/preferences|button-layout|':minimize,maximize,close'"
  "org/gnome/desktop/wm/preferences|titlebar-uses-system-font|false"
  "org/gnome/desktop/wm/preferences|action-middle-click-titlebar|'lower'"
  "org/gnome/desktop/wm/preferences|titlebar-font|'Ubuntu Sans Bold 11'"

  # Ubuntu's keybindings: Alt+Tab moves between windows and Super+Tab between
  # applications, the reverse of the GNOME default.
  "org/gnome/desktop/wm/keybindings|switch-applications|['<Super>Tab']"
  "org/gnome/desktop/wm/keybindings|switch-applications-backward|['<Shift><Super>Tab']"
  "org/gnome/desktop/wm/keybindings|switch-windows|['<Alt>Tab']"
  "org/gnome/desktop/wm/keybindings|switch-windows-backward|['<Shift><Alt>Tab']"
  "org/gnome/desktop/wm/keybindings|show-desktop|['<Primary><Super>d', '<Primary><Alt>d', '<Super>d']"

  "org/gnome/desktop/sound|theme-name|'Yaru'"
  "org/gnome/desktop/sound|input-feedback-sounds|true"

  "org/gnome/desktop/peripherals/touchpad|click-method|'default'"

  # Mirrors gnome-shell-extension-ubuntu-dock's own gschema override, which
  # only takes effect on a real Ubuntu session. Debian has no equivalent, so
  # these values are reapplied here to match Ubuntu's dock behavior.
  "org/gnome/shell/extensions/dash-to-dock|dock-position|'LEFT'"
  "org/gnome/shell/extensions/dash-to-dock|dock-fixed|true"
  "org/gnome/shell/extensions/dash-to-dock|intellihide-mode|'ALL_WINDOWS'"
  "org/gnome/shell/extensions/dash-to-dock|icon-size-fixed|true"
  "org/gnome/shell/extensions/dash-to-dock|custom-theme-shrink|true"
  "org/gnome/shell/extensions/dash-to-dock|running-indicator-style|'DOTS'"
  "org/gnome/shell/extensions/dash-to-dock|extend-height|true"
  "org/gnome/shell/extensions/dash-to-dock|scroll-action|'switch-workspace'"
  "org/gnome/shell/extensions/dash-to-dock|click-action|'focus-or-appspread'"
  "org/gnome/shell/extensions/dash-to-dock|shift-click-action|'launch'"
  "org/gnome/shell/extensions/dash-to-dock|shift-middle-click-action|'minimize'"
  "org/gnome/shell/extensions/dash-to-dock|disable-overview-on-startup|true"
  "org/gnome/shell/extensions/dash-to-dock|show-mounts-only-mounted|false"
  "org/gnome/shell/extensions/dash-to-dock|show-mounts-network|true"

  # Desktop icons. Ubuntu arranges them from the bottom right and keeps the
  # trash and mounted volumes off the desktop.
  "org/gnome/shell/extensions/ding|start-corner|'bottom-right'"
  "org/gnome/shell/extensions/ding|show-trash|false"
  "org/gnome/shell/extensions/ding|show-volumes|false"
  "org/gnome/shell/extensions/ding|arrangeorder|'DESCENDINGNAME'"

  "org/gnome/shell/extensions/user-theme|name|'Yaru'"

  # Yaru orange, as the tiling assistant ships it on Ubuntu.


  "org/gnome/nautilus/icon-view|default-zoom-level|'small'"
  "org/gnome/nautilus/preferences|open-folder-on-dnd-hover|false"

  "org/gtk/settings/file-chooser|sort-directories-first|true"
  "org/gtk/settings/file-chooser|startup-mode|'cwd'"
)

# Render GNOME_SETTINGS as dconf keyfile groups.
render_dconf_groups() {
  local line last_path="" path key value
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    if [ "$path" != "$last_path" ]; then
      [ -n "$last_path" ] && echo ""
      echo "[${path}]"
      last_path="$path"
    fi
    echo "${key}=${value}"
  done
}

# Apply GNOME_SETTINGS to the running session (no-op without a D-Bus session).
apply_live_settings() {
  local line path key value
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    case "$DCONF_ONLY_KEYS" in *" $key "*) continue ;; esac
    gset "$(schema_for_path "$path")" "$key" "$value"
  done
}

# One published Ubuntu release as "<version> <state>", state being "stable" or
# "devel"; empty when the mirror does not publish it, which also drops
# unpublished candidates. The state comes from Valid-Until, which only the
# in-development suite carries, so a release is recognised the day it ships.
ubuntu_release_info() {
  curl -fsS -m 15 -r 0-2047 "${UBUNTU_MIRROR}/dists/${1}/Release" 2>/dev/null \
    | awk '
        /^Version:/     { v = $2 }
        /^Valid-Until:/ { unreleased = 1 }
        END { if (v != "") print v, (unreleased ? "devel" : "stable") }'
}

# The newest MAX_UBUNTU_CANDIDATES Ubuntu releases currently served, oldest to
# newest. Read from the archive dists/ index and ordered by each release's
# Version field, so a new release becomes a candidate the day it is published.
# distro-info-data is not used: on a stable Debian it is frozen at Debian's own
# release date.
discover_ubuntu_codenames() {
  local names cn info ver state versioned=""

  # Only released series are considered. The in-development one carries a higher
  # version and would otherwise win the floating pin with a pre-release Yaru; it
  # becomes a candidate on its release day. UBUNTU_INCLUDE_DEVEL=1 opts in early.

  names="$(curl -fsS -m 30 "${UBUNTU_MIRROR}/dists/" 2>/dev/null \
    | grep -oiE 'href="[^"?]+/"' \
    | sed -E 's|.*href="([^"]+)/"|\1|' \
    | grep -E '^[a-z]+$' | grep -vx devel | sort -u)"
  # No usable listing (a proxy, or a mirror with autoindex off) — fall back to
  # the static seed; the Release probe below still validates every name.
  [ -z "$names" ] && names="$FALLBACK_CODENAMES"

  for cn in $names; do
    info="$(ubuntu_release_info "$cn")"
    [ -z "$info" ] && continue
    ver="${info%% *}"
    state="${info##* }"
    if [ "$state" = "devel" ] && [ "$UBUNTU_INCLUDE_DEVEL" != "1" ]; then
      message "  skipping '${cn}' (${ver}) - not released yet; UBUNTU_INCLUDE_DEVEL=1 to use it" >&2
      continue
    fi
    versioned="${versioned}${ver} ${cn}
"
  done

  printf '%s' "$versioned" | sort -V | tail -n "$MAX_UBUNTU_CANDIDATES" \
    | awk '{print $2}' | tr '\n' ' ' | xargs
}

# Append a key to the Ubuntu keyring (dearmored keyrings concatenate cleanly).
add_ubuntu_key() {
  local tmp rc=1
  tmp="$(mktemp)"
  if curl -fsSL -m 30 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${1}" \
       | gpg --dearmor > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    sudo install -d -m 0755 "$(dirname "$UBUNTU_KEYRING")"
    sudo tee -a "$UBUNTU_KEYRING" < "$tmp" > /dev/null
    sudo chmod 0644 "$UBUNTU_KEYRING"
    rc=0
  fi
  rm -f "$tmp"
  return $rc
}

# apt-get update, recovering automatically from a rotated archive key: a new
# Ubuntu release signed with a key this script does not know about would
# otherwise fail the run with NO_PUBKEY and need a manual fix.
apt_update() {
  local log rc ids id
  log="$(mktemp)"
  # Streamed through tee rather than captured: with several Ubuntu suites
  # configured this takes a while, and a silent minute looks like a hang.
  sudo apt-get update 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  ids="$(grep -oE 'NO_PUBKEY [0-9A-Fa-f]{8,}' "$log" | awk '{print $2}' | sort -u)"
  rm -f "$log"

  # Anything that is not an unknown signing key stays the caller's problem —
  # apt's own exit status must survive, or a failed update passes for success.
  [ -z "$ids" ] && return "$rc"

  message warn "Ubuntu archive is signed with an unknown key — fetching ${ids}"
  for id in $ids; do
    add_ubuntu_key "$id" || return 1
  done
  sudo apt-get update
}

# Newest Ubuntu codename whose $1 package installs cleanly here, verified by a
# simulated install.
#
#   $2=1  require "Inst $1 " in the simulation, not just a clean run; needed
#         where Debian ships the same package.
#   $3    fallback when no codename simulates cleanly.
#   $4=1  require an Ubuntu delta in the version. Releases that re-sync Debian's
#         package unchanged would otherwise downgrade the system.
resolve_ubuntu_pkg_codename() {
  local pkg="$1" require_inst="${2:-0}" fallback="${3:-}" require_delta="${4:-0}"
  local newest_first cn ver sim
  newest_first="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | tr ' ' '\n' | tac)"
  for cn in $newest_first; do
    ver="$(apt-cache madison "$pkg" 2>/dev/null \
      | awk -F'|' -v c="$cn" '$3 ~ c { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }')"
    [ -z "$ver" ] && continue
    if [ "$require_delta" = "1" ]; then
      case "$ver" in *ubuntu*) ;; *) continue ;; esac
    fi
    # Progress goes to stderr so it doesn't pollute the codename on stdout.
    message "  checking ${pkg} on ${cn} (${ver})..." >&2
    # A non-zero exit means unmet dependencies (e.g. a gnome-shell too new) —
    # checking only for "Remv" would accept that as compatible.
    sim="$(apt-get install -s "${pkg}=${ver}" 2>&1)" || continue
    echo "$sim" | grep -q '^Remv ' && continue
    if [ "$require_inst" = "1" ]; then
      echo "$sim" | grep -q "^Inst ${pkg} " || continue
    fi
    echo "$cn"
    return 0
  done
  echo "$fallback"
}

# yaru-theme-gnome-shell is pinned to a gnome-shell major version. If nothing
# simulates cleanly, fall back to the oldest configured candidate — the most
# conservative choice available, and never a release name frozen into this
# script. The package itself is then likely to be skipped at install time.
resolve_ubuntu_codename() {
  resolve_ubuntu_pkg_codename yaru-theme-gnome-shell 0 \
    "$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $1}')"
}


# Write the dconf system profile. Using the system database rather than
# per-session gsettings calls makes the settings and extension enabling take
# effect on first login, even when the script ran without a GNOME session.
write_dconf_profile() {
  local wp_light="$1" wp_dark="$2"

  # Only emit background/screensaver keys if the wallpaper file exists
  # (it may not, if 2-desktop-gnome ran before 1-desktop-base ever installed
  # ubuntu-wallpapers).
  local bg_block=""
  if [ -n "$wp_light" ] && [ -f "$wp_light" ]; then
    bg_block="
[org/gnome/desktop/background]
picture-uri='file://${wp_light}'
picture-uri-dark='file://${wp_dark}'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file://${wp_light}'"
  else
    message warn "wallpaper file not found (${wp_light:-none}) — skipping background/screensaver keys"
    message warn "run 'bash ubuntu-look.sh 1-desktop-base' (or a full run) first to install ubuntu-wallpapers"
  fi

  # Set up /etc/dconf/profile/user so GNOME reads the system db.
  # Format: one db per line; user db first, then system db.
  if [ ! -f "$DCONF_USER_PROFILE" ] || ! grep -q "system-db:local" "$DCONF_USER_PROFILE"; then
    sudo install -d -m 0755 "$(dirname "$DCONF_USER_PROFILE")"
    printf 'user-db:user\nsystem-db:local\n' | sudo tee "$DCONF_USER_PROFILE" > /dev/null
    STATUS_CHANGES+=("Created /etc/dconf/profile/user (system db enabled)")
  fi

  local tmp
  tmp="$(mktemp)"
  {
    echo "# ubuntu-look.sh — Ubuntu GNOME defaults (auto-generated, safe to delete)"
    echo "# Provides system-wide defaults; users can override in their own dconf."
    echo ""
    render_dconf_groups
    echo "$bg_block"
  } > "$tmp"

  if [ ! -f "$DCONF_PROFILE_FILE" ] || ! cmp -s "$tmp" "$DCONF_PROFILE_FILE"; then
    sudo install -d -m 0755 "$DCONF_PROFILE_DIR"
    # 0644, not mktemp's 0600 — otherwise not even the owner can read it.
    sudo install -m 0644 "$tmp" "$DCONF_PROFILE_FILE"
    sudo dconf update
    STATUS_CHANGES+=("dconf system profile written → $DCONF_PROFILE_FILE")
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("dconf system profile already current")
  fi
  rm -f "$tmp"
}

# Pretty end-of-run report (fires on clean exit and on early exit 1).

# The state the log needs to be actionable on its own: what is installed, what
# the pin resolved to, and whether the extensions and terminal actually took.
log_final_state() {
  local p e state

  echo ""
  echo "--- state after this run ---"
  for p in $ALL_STAGE_PACKAGES; do
    printf '  %-46s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo 'not installed')"
  done

  echo "  pin            : $(grep -m1 '^Pin: release o=Ubuntu, n=' "$UBUNTU_PIN" 2>/dev/null || echo 'none')"
  echo "  enabled-ext    : $(dconf_show /org/gnome/shell/enabled-extensions)"
  echo "  disabled-ext   : $(dconf_show /org/gnome/shell/disabled-extensions)"
  for e in $SHELL_EXTENSIONS; do
    # An extension not yet loaded prints nothing; the pipeline still exits 0.
    state="$(gnome-extensions info "$e" 2>/dev/null | awk -F': ' '/State/{print $2}')"
    printf '  %-46s %s\n' "$e" "${state:-unknown}"
  done

  echo "  plymouth theme : $(plymouth_current_theme)"
  echo "  kernel cmdline : $(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null || echo none)"
  echo "  gtk-theme      : $(dconf_show /org/gnome/desktop/interface/gtk-theme)"
  echo "  term profile   : $(dconf_show /org/gnome/terminal/legacy/profiles:/default)"
  echo "  icon-theme     : $(dconf_show /org/gnome/desktop/interface/icon-theme)"
  echo "  wallpaper      : $(dconf_show /org/gnome/desktop/background/picture-uri)"
  echo "  favorite-apps  : $(dconf_show /org/gnome/shell/favorite-apps)"
  echo "--- end of state ---"
}

# Theme the login screen.
#
# The greeter runs as its own user and reads the gdm dconf profile, so the
# settings above do not reach it. Ubuntu themes it through a GNOME-Greeter
# override; the equivalent here is a gdm database file. Only the theme, cursor
# and fonts are set: no logo and no distribution branding, which stays Debian's.
GDM_PROFILE_DIR="/etc/dconf/db/gdm.d"
GDM_PROFILE_FILE="${GDM_PROFILE_DIR}/10-ubuntu-look"

write_gdm_profile() {
  local wp_light="${1:-}" wp_dark="${2:-}"

  # Ubuntu's gdm ships this profile; Debian's does not, and without it the
  # database below is never read -- the greeter falls back to the defaults and
  # nothing written here reaches it. Created the way write_dconf_profile
  # creates the user profile, and recorded, so the uninstall removes only a
  # file this script put there.
  local created="${BACKUP_ORIGINAL}/gdm-profile-created"
  if [ ! -f /etc/dconf/profile/gdm ]; then
    sudo install -d -m 0755 /etc/dconf/profile
    printf 'user-db:user\nsystem-db:gdm\n' | sudo tee /etc/dconf/profile/gdm > /dev/null
    mkdir -p "$BACKUP_ORIGINAL"
    : > "$created"
    STATUS_CHANGES+=("Created /etc/dconf/profile/gdm so the login screen reads its database")
  fi

  # Ubuntu sets these on the greeter as well as the session. A shell that does
  # not read them for the login screen simply ignores them.
  local bg_block=""
  if [ -n "$wp_light" ] && [ -f "$wp_light" ]; then
    bg_block="
[org/gnome/desktop/background]
picture-uri='file://${wp_light}'
picture-uri-dark='file://${wp_dark}'
show-desktop-icons=false"
  fi

  local tmp
  tmp="$(mktemp)"
  cat << EOF > "$tmp"
# ubuntu-look.sh - login screen theme. Safe to delete.
[org/gnome/desktop/interface]
gtk-theme='Yaru'
icon-theme='Yaru'
cursor-theme='Yaru'
font-name='Ubuntu Sans 11'
monospace-font-name='Ubuntu Sans Mono 11'
font-antialiasing='rgba'
${bg_block}
EOF

  if sudo cmp -s "$tmp" "$GDM_PROFILE_FILE" 2>/dev/null; then
    rm -f "$tmp"
    STATUS_NOCHANGE+=("Login screen theme already current")
    return 0
  fi

  sudo install -Dm 0644 "$tmp" "$GDM_PROFILE_FILE"
  rm -f "$tmp"
  sudo dconf update
  STATUS_CHANGES+=("Login screen themed → ${GDM_PROFILE_FILE}")
}

# Ubuntu's own desktop-icons build.
#
# The two builds draw the desktop selection rectangle from different theme
# colours: Debian's is orange under Yaru, Ubuntu's grey. Ubuntu ships its build
# inside gnome-shell-ubuntu-extensions, which cannot be installed here -- it
# needs gnome-shell 49 and conflicts with the extension packages used. Only the
# desktop-icons part is unpacked, into the user extension directory that
# gnome-shell prefers. Debian's package is left installed and untouched.
UBUNTU_DING_PKG="gnome-shell-ubuntu-extensions"
UBUNTU_DING_UUID="ding@rastersoft.com"
UBUNTU_DING_DIR="$HOME/.local/share/gnome-shell/extensions/ding@rastersoft.com"
UBUNTU_DING_SCHEMA_DIR="$HOME/.local/share/glib-2.0/schemas"
UBUNTU_DING_SCHEMA="org.gnome.shell.extensions.ding.gschema.xml"
UBUNTU_DING_RECORD="${BACKUP_DIR}/ubuntu-ding-version.txt"

# Newest version of the bundle any configured repository offers. madison lists
# them all regardless of the pin, which holds this package at -1 so apt can
# never select it for installation; policy would answer "(none)" for the same
# reason. Ordered by version, so the newest wins wherever it is served from.
ubuntu_ding_version() {
  apt-cache madison "$UBUNTU_DING_PKG" 2>/dev/null \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' \
    | sort -V | tail -1
}

# Where version $1 can be fetched from. apt knows the exact URI, but it is
# being asked about a package it has pinned out of consideration, so its answer
# is taken when it gives one and the archive's own pool layout supplies it when
# it does not.

# Put the extension from the unpacked package at $1 in place, at version $2.
# The caller has already decided there is something to install.
place_ubuntu_ding() {
  local root="$1" ver="$2"
  local src="${root}/usr/share/gnome-shell/extensions/${UBUNTU_DING_UUID}"

  [ -d "$src" ] || {
    STATUS_FAILED+=("${UBUNTU_DING_PKG} carries no ${UBUNTU_DING_UUID} — Debian's desktop icons stay in use")
    return 1
  }

  # The extension names the gnome-shell versions it supports. Honouring that is
  # what keeps a future Ubuntu build, which may have dropped this one, from
  # being put somewhere it cannot load.
  local shell_major
  shell_major="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  if [ -z "$shell_major" ] || ! grep -o '"shell-version"[^]]*]' "${src}/metadata.json" 2>/dev/null \
       | grep -q "\"${shell_major}\""; then
    STATUS_NOCHANGE+=("Ubuntu's desktop-icons build does not list gnome-shell ${shell_major:-?} — Debian's stays in use")
    return 1
  fi

  rm -rf "$UBUNTU_DING_DIR"
  mkdir -p "$(dirname "$UBUNTU_DING_DIR")"
  cp -r "$src" "$UBUNTU_DING_DIR"

  # The extension runs the desktop as a separate process, so a copy that is
  # short of it loads fine and then dies and is relaunched, over and over, with
  # the icons blinking in and out. Check what actually has to be there.
  local f
  for f in metadata.json extension.js app/ding.js; do
    [ -f "${UBUNTU_DING_DIR}/${f}" ] && continue
    rm -rf "$UBUNTU_DING_DIR"
    STATUS_FAILED+=("Ubuntu's desktop-icons build came out incomplete (no ${f}) — Debian's stays in use")
    return 1
  done

  # Ubuntu's build defines keys Debian's schema may not carry, so its own goes
  # in beside it, where a user schema directory takes precedence. Without a
  # schema it can resolve the extension fails to start and the desktop is left
  # with no icons, so anything short of a compiled schema is rolled back.
  local schema_src="${root}/usr/share/glib-2.0/schemas/${UBUNTU_DING_SCHEMA}"
  if [ ! -f "$schema_src" ] \
     || ! mkdir -p "$UBUNTU_DING_SCHEMA_DIR" \
     || ! cp "$schema_src" "${UBUNTU_DING_SCHEMA_DIR}/" \
     || ! glib-compile-schemas "$UBUNTU_DING_SCHEMA_DIR" 2>/dev/null; then
    rm -rf "$UBUNTU_DING_DIR"
    rm -f "${UBUNTU_DING_SCHEMA_DIR}/${UBUNTU_DING_SCHEMA}"
    # Recompiled without it, or the compiled copy would keep handing Debian's
    # own build a schema written for a different version of the extension.
    glib-compile-schemas "$UBUNTU_DING_SCHEMA_DIR" 2>/dev/null || true
    STATUS_FAILED+=("Ubuntu's desktop-icons build needs its settings schema and it did not compile — Debian's stays in use")
    return 1
  fi

  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "$ver" > "$UBUNTU_DING_RECORD"
  STATUS_CHANGES+=("Desktop icons now use Ubuntu's own build (${ver}) — selection rectangle included")
  RELOGIN_NEEDED=1
  return 0
}

# True when the extension at $1 is already in place, or when the directory
# holds something this script did not put there.
ubuntu_ding_settled() {
  local ver="$1"
  if [ -d "$UBUNTU_DING_DIR" ] && [ ! -f "$UBUNTU_DING_RECORD" ]; then
    STATUS_NOCHANGE+=("A desktop-icons extension is already installed in your home directory — left alone")
    return 0
  fi
  if [ -d "$UBUNTU_DING_DIR" ] && [ "$(cat "$UBUNTU_DING_RECORD" 2>/dev/null)" = "$ver" ]; then
    STATUS_NOCHANGE+=("Ubuntu's desktop-icons build already current (${ver})")
    return 0
  fi
  return 1
}

install_ubuntu_ding() {
  command -v glib-compile-schemas >/dev/null 2>&1 || {
    STATUS_NOCHANGE+=("glib-compile-schemas not available — Debian's desktop icons stay in use")
    return 0
  }

  local ver tmp
  ver="$(ubuntu_ding_version)"
  if [ -z "$ver" ]; then
    STATUS_NOCHANGE+=("Ubuntu's desktop-icons build is not offered by any configured repository")
    return 0
  fi

  ubuntu_ding_settled "$ver" && return 0

  tmp="$(mktemp -d)"

  # Through apt, which checks the package against the SHA256 in the signed
  # index. The archive is plain HTTP and a direct fetch verifies nothing, and
  # what this unpacks is run by gnome-shell.
  local deb=""
  if ( cd "$tmp" && apt-get download "${UBUNTU_DING_PKG}=${ver}" >/dev/null 2>&1 ); then
    deb="$(ls -1 "${tmp}"/*.deb 2>/dev/null | head -1)"
  fi
  if [ -z "$deb" ] || ! dpkg-deb -x "$deb" "${tmp}/x" 2>/dev/null; then
    rm -rf "$tmp"
    STATUS_FAILED+=("Ubuntu's desktop-icons build could not be fetched — Debian's stays in use")
    return 0
  fi

  place_ubuntu_ding "${tmp}/x" "$ver" || true
  rm -rf "$tmp"
}

# Keep the shell theme on the variant the colour scheme calls for.
#
# Yaru ships Yaru and Yaru-dark as two shell themes and nothing updates
# user-theme when the scheme changes. Ubuntu needs no equivalent: its session
# mode names a theme resource carrying both. Waits on the setting rather than
# polling, and writes only when the name is wrong.
install_shell_theme_follower() {
  local script="$HOME/.local/bin/yaru-shell-theme.sh"
  local unit="$HOME/.config/systemd/user/yaru-shell-theme.service"
  local tmp changed=0
  tmp="$(mktemp)"

  cat << 'EOF' > "$tmp"
#!/bin/bash
# Written by ubuntu-look.sh. Follows color-scheme with the matching Yaru shell
# theme; woken only when that setting changes. Safe to delete.
apply() {
  local want now
  now="$(gsettings get org.gnome.shell.extensions.user-theme name 2>/dev/null | tr -d "'")"
  # Only the two variants this script sets are moved between. A shell theme the
  # user has chosen for themselves is not something to switch out from under
  # them, so anything else is left exactly as it is.
  case "$now" in Yaru|Yaru-dark) ;; *) return ;; esac
  case "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)" in
    *prefer-dark*) want='Yaru-dark' ;;
    *)             want='Yaru' ;;
  esac
  [ "$now" = "$want" ] && return
  gsettings set org.gnome.shell.extensions.user-theme name "$want" 2>/dev/null || true
}
apply
gsettings monitor org.gnome.desktop.interface color-scheme | while read -r _; do apply; done
EOF
  install_if_changed "$tmp" "$script" && changed=1
  chmod +x "$script" 2>/dev/null || true

  # The GJS copy a later version wrote, which removed no flicker and is gone.
  if [ -f "$HOME/.local/bin/yaru-shell-theme.js" ]; then
    rm -f "$HOME/.local/bin/yaru-shell-theme.js"
    changed=1
  fi

  cat << 'EOF' > "$tmp"
[Unit]
Description=Yaru shell theme follows the colour scheme
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/yaru-shell-theme.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
  if install_if_changed "$tmp" "$unit"; then
    changed=1
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  rm -f "$tmp"

  if [ $changed -eq 1 ] \
     || ! systemctl --user is-enabled --quiet yaru-shell-theme.service 2>/dev/null; then
    if systemctl --user enable --now yaru-shell-theme.service 2>/dev/null; then
      # "enable --now" leaves a running copy of an older script in place.
      [ $changed -eq 1 ] &&
        systemctl --user try-restart yaru-shell-theme.service 2>/dev/null
      STATUS_CHANGES+=("Shell theme now follows the colour scheme")
      RELOGIN_NEEDED=1
    else
      message warn "could not start the shell theme follower — it will come up at the next login"
    fi
  else
    STATUS_NOCHANGE+=("Shell theme follower already in place")
  fi
}

# Ubuntu and Debian ship different terminals. Rather than change which terminal
# the system uses, Ubuntu's own colours go into a gnome-terminal profile named
# Ubuntu, which becomes the default. Profiles the user already has are left
# exactly as they are: this one is added to the list, and uninstall.sh puts the
# default back to the one gnome-terminal picks for itself.
#
# The colours are Ubuntu's own terminal palette, dark variant.
TERMINAL_PROFILES="/org/gnome/terminal/legacy/profiles:"
TERMINAL_PROFILE_RECORD="${BACKUP_DIR}/terminal-profile.txt"
TERMINAL_BACKGROUND="#300A24"
TERMINAL_FOREGROUND="#FFFFFF"
TERMINAL_PALETTE="['#1B1B1B', '#CC1A12', '#4E9A06', '#C4A000', '#3667A6', '#7F5985', '#06989A', '#D5D5D5', '#838383', '#F93632', '#8AE234', '#FCE94F', '#729FCF', '#AD7FA8', '#34E2E2', '#EEEEEC']"

install_terminal_profile() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || ! command -v dconf >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("No live session -- terminal colours left for the next run")
    return 0
  fi
  if ! command -v gnome-terminal >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("gnome-terminal is not installed — terminal colours left alone")
    return 0
  fi

  local uuid
  uuid="$(sed -n 's/^uuid=//p' "$TERMINAL_PROFILE_RECORD" 2>/dev/null)"

  # First time: make a profile of our own. The uuid is recorded, so a re-run
  # edits that same profile rather than adding another one beside it.
  if [ -z "$uuid" ]; then
    uuid="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || uuidgen 2>/dev/null)"
    if [ -z "$uuid" ]; then
      STATUS_FAILED+=("Could not generate a terminal profile id (need python3 or uuidgen)")
      return 0
    fi
    mkdir -p "$BACKUP_DIR"
    printf 'uuid=%s\n' "$uuid" > "$TERMINAL_PROFILE_RECORD"
  fi

  local base="${TERMINAL_PROFILES}/:${uuid}" changed=0 key val
  for key in "visible-name|'Ubuntu'" \
             "use-theme-colors|false" \
             "background-color|'${TERMINAL_BACKGROUND}'" \
             "foreground-color|'${TERMINAL_FOREGROUND}'" \
             "palette|${TERMINAL_PALETTE}"; do
    val="${key#*|}"; key="${key%%|*}"
    # Compared with the spacing removed: dconf reads a value back in its own
    # normal form, and a difference of spaces alone would rewrite the profile
    # on every run and report a change that never happened.
    if [ "$(dconf read "${base}/${key}" 2>/dev/null | tr -d '[:space:]')"        != "$(printf '%s' "$val" | tr -d '[:space:]')" ]; then
      dconf write "${base}/${key}" "$val" 2>/dev/null && changed=1
    fi
  done

  # Appended, so every profile already there keeps its place.
  local list
  list="$(dconf_array_items "${TERMINAL_PROFILES}/list")"
  case " $list " in
    *" $uuid "*) ;;
    *) dconf write "${TERMINAL_PROFILES}/list" \
         "$(gvariant_string_array "${list:+${list} }${uuid}")" 2>/dev/null && changed=1 ;;
  esac

  if [ "$(dconf read "${TERMINAL_PROFILES}/default" 2>/dev/null | tr -d \')" != "$uuid" ]; then
    dconf write "${TERMINAL_PROFILES}/default" "'${uuid}'" 2>/dev/null && changed=1
  fi

  if [ $changed -eq 1 ]; then
    STATUS_CHANGES+=("Terminal: Ubuntu profile applied and made the default")
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("Terminal: Ubuntu profile already current")
  fi
}

# The distribution's mark on the Show Applications button.
#
# The dock asks for view-app-grid-<session mode>-symbolic. Yaru ships the
# "ubuntu" one; a Debian session's mode is "user", for which no icon exists and
# the generic grid is drawn. Supplying that name from the Debian logo already on
# the system overrides nothing -- Yaru does not define it.
APP_GRID_ICON="$HOME/.local/share/icons/hicolor/scalable/actions/view-app-grid-user-symbolic.svg"

# How much of the icon's canvas the artwork covers. Ubuntu's own is 0.742 (95
# of its 128 units), which leaves a symbolic icon looking smaller than the
# application icons beside it on the dock; this is set fuller on purpose so the
# button carries the same weight as its neighbours.
APP_GRID_INK_FRACTION=0.98

# Write $1 to $2 with its viewBox widened until the artwork covers
# APP_GRID_INK_FRACTION of the canvas, so the button carries the same weight as
# the icons around it. The drawn extent is measured by rendering, which holds
# for any source file. Returns non-zero when the image cannot be read, leaving
# the caller to copy it unchanged.
normalise_app_grid_icon() {
  python3 - "$1" "$2" "$APP_GRID_INK_FRACTION" << 'PYEOF' 2>/dev/null
import re
import sys

src, dest, frac = sys.argv[1], sys.argv[2], float(sys.argv[3])
data = open(src, encoding="utf-8", errors="replace").read()

m = re.search(r'viewBox="([^"]*)"', data)
if not m:
    raise SystemExit(1)
box = [float(v) for v in m.group(1).replace(",", " ").split()]
if len(box) != 4 or box[2] <= 0 or box[3] <= 0:
    raise SystemExit(1)

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

pb = GdkPixbuf.Pixbuf.new_from_file_at_size(src, 128, 128)
w, h = pb.get_width(), pb.get_height()
stride, chan = pb.get_rowstride(), pb.get_n_channels()
px = pb.get_pixels()

xs, ys = [], []
for y in range(h):
    row = y * stride
    for x in range(w):
        o = row + x * chan
        if (px[o + 3] if chan == 4 else 255) > 10:
            xs.append(x)
            ys.append(y)
if not xs:
    raise SystemExit(1)

# The drawn extent, back in the source's own coordinates.
sx, sy = box[2] / w, box[3] / h
x0, x1 = box[0] + min(xs) * sx, box[0] + (max(xs) + 1) * sx
y0, y1 = box[1] + min(ys) * sy, box[1] + (max(ys) + 1) * sy

side = max(x1 - x0, y1 - y0) / frac
new = "%.3f %.3f %.3f %.3f" % ((x0 + x1 - side) / 2, (y0 + y1 - side) / 2, side, side)
open(dest, "w", encoding="utf-8").write(data[: m.start(1)] + new + data[m.end(1):])
PYEOF
}

install_app_grid_icon() {
  local src="" c
  for c in /usr/share/desktop-base/debian-logos/logo.svg \
           /usr/share/desktop-base/debian-logos/openlogo-nd.svg \
           /usr/share/desktop-base/debian-logos/openlogo.svg \
           /usr/share/desktop-base/debian-logos/logo-debian.svg \
           /usr/share/icons/hicolor/scalable/apps/debian-logo.svg \
           /usr/share/icons/hicolor/scalable/places/debian-swirl.svg; do
    [ -f "$c" ] && { src="$c"; break; }
  done

  # Fall back to whatever logo the system does carry, preferring one without
  # lettering, since a symbolic icon is drawn as a single flat shape.
  if [ -z "$src" ]; then
    src="$(find /usr/share/desktop-base /usr/share/icons/hicolor/scalable \
                -maxdepth 4 -iname '*logo*.svg' 2>/dev/null \
           | grep -viE 'text|version' | head -1)"
  fi

  if [ -z "$src" ]; then
    STATUS_NOCHANGE+=("No Debian logo on this system — Show Applications keeps the generic grid")
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  normalise_app_grid_icon "$src" "$tmp" || cp "$src" "$tmp"

  if install_if_changed "$tmp" "$APP_GRID_ICON"; then
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    STATUS_CHANGES+=("Show Applications button now uses $(basename "$src")")
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("Show Applications button icon already current")
  fi
  rm -f "$tmp"
}

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
  [ ${#STATUS_FAILED[@]} -gt 0 ] && {
    echo -e "${RED}Could not be installed on this system (${#STATUS_FAILED[@]}):${ENDCOLOR}"
    printf '   ! %s\n' "${STATUS_FAILED[@]}"
    echo -e "   ${YELLOW}No Ubuntu build of these is compatible with this Debian — everything else was applied.${ENDCOLOR}"
  }
  [ ${#STATUS_EXT_FAILED[@]} -gt 0 ] && {
    echo -e "${RED}Extensions the setting did not reach (${#STATUS_EXT_FAILED[@]}):${ENDCOLOR}"
    printf '   ! %s\n' "${STATUS_EXT_FAILED[@]}"
    echo -e "   ${YELLOW}Writing enabled-extensions needs a live GNOME session; run this from your desktop, not over SSH.${ENDCOLOR}"
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
  if [ $((GSETTINGS_CHANGED + GSETTINGS_UNCHANGED)) -gt 0 ]; then
    echo -e "GNOME settings (live): ${GREEN}${GSETTINGS_CHANGED} changed${ENDCOLOR}, ${YELLOW}${GSETTINGS_UNCHANGED} already correct${ENDCOLOR}"
    echo ""
  fi

  log_final_state

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

[ "$(id -u)" -eq 0 ] && error "Do not run as root. Run as a normal user in the 'sudo' group."

if [ -z "$arguments" ]; then
  package_categories="${!packages[@]}"
else
  package_categories="$arguments"
fi
package_categories="$(echo "$package_categories" | xargs -n1 | sort -u | xargs)"

for category in $package_categories; do
  [ -n "${packages[$category]:-}" ] || error "Unknown stage '${category}'.
  Valid stages: $(echo "${!packages[@]}" | xargs -n1 | sort | xargs)"
done

message "Welcome to ${GREEN}ubuntu-look${ENDCOLOR} — make Debian GNOME look like Ubuntu!"
message ""
message "Applies Ubuntu look-and-feel for user ${YELLOW}${RUN_USER}${ENDCOLOR}."
message "Safe to re-run. Steps: ${YELLOW}${package_categories}${ENDCOLOR}"
message ""
message warn "GTK theme, wallpaper, and dconf settings are overwritten without"
message warn "prompting — back up custom values first if needed."
message ""
confirm_continue

id -nG | tr ' ' '\n' | grep -qx sudo || error "User $RUN_USER is not in the 'sudo' group.
  Fix: su -c '/usr/sbin/usermod -aG sudo ${RUN_USER}' && reboot"

###############################################################################
# One-time snapshot of pre-existing state, for uninstall.sh
###############################################################################
# Taken once, on the first run. A re-run must not overwrite it with a state
# that already carries this script's changes.

# A run started from SSH/tmux has no session bus in its environment, but the
# user's systemd bus is usually still there. Adopt it before the snapshot
# below: `dconf dump /` is the only record of the wallpaper and every other
# setting uninstall.sh puts back, and it is taken exactly once, on first run.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

backup_snapshot_file() {
  local src="$1" dest="$2"
  [ -f "$src" ] || return 0
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest" 2>/dev/null || true
}

if [ ! -d "$BACKUP_ORIGINAL" ]; then
  message "first run — saving your pre-existing config to ${BACKUP_ORIGINAL} (for uninstall.sh)"
  mkdir -p "$BACKUP_ORIGINAL"

  sudo cp /etc/default/grub "${BACKUP_ORIGINAL}/grub" 2>/dev/null || true
  cp /etc/environment "${BACKUP_ORIGINAL}/environment" 2>/dev/null || true

  backup_snapshot_file "$HOME/.config/gtk-3.0/gtk.css" "${BACKUP_ORIGINAL}/gtk-3.0-gtk.css"
  backup_snapshot_file "$HOME/.config/gtk-4.0/gtk.css" "${BACKUP_ORIGINAL}/gtk-4.0-gtk.css"
  backup_snapshot_file "$HOME/.config/gtk-3.0/settings.ini" "${BACKUP_ORIGINAL}/gtk-3.0-settings.ini"
  backup_snapshot_file "$HOME/.config/gtk-4.0/settings.ini" "${BACKUP_ORIGINAL}/gtk-4.0-settings.ini"
  backup_snapshot_file "$HOME/.gtkrc-2.0" "${BACKUP_ORIGINAL}/gtkrc-2.0"
  backup_snapshot_file "$HOME/.local/share/applications/org.gnome.Software.desktop" "${BACKUP_ORIGINAL}/org.gnome.Software.desktop"


  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dconf >/dev/null 2>&1; then
    dconf dump / > "${BACKUP_ORIGINAL}/dconf-dump.ini" 2>/dev/null || true
  fi

  installed_package_list > "${BACKUP_ORIGINAL}/packages-before.txt"
  touch "$INSTALLED_MANIFEST"
  echo "ubuntu-look.sh pre-install snapshot — $(date -Iseconds)" > "${BACKUP_ORIGINAL}/INFO"
  STATUS_CHANGES+=("Pre-install snapshot saved → ${BACKUP_ORIGINAL}")
else
  message "pre-existing config already backed up (from first run) → ${BACKUP_ORIGINAL}"
  STATUS_NOCHANGE+=("Pre-install snapshot already exists")
fi

###############################################################################
# Step: Ubuntu apt repo — broad candidate sources (themes / fonts / wallpapers)
###############################################################################

step "Configure Ubuntu archive candidate sources"

_missing_prereqs="$(missing_packages "gnupg curl ca-certificates")"
if [ -n "$_missing_prereqs" ]; then
  sudo apt-get update -qq
  for prereq in $_missing_prereqs; do
    sudo apt-get install -y "$prereq" || error "Failed to install prerequisite: $prereq"
    # Not added to STATUS_INSTALLED: that list becomes the uninstall manifest,
    # and curl, gnupg and ca-certificates are generic system tools whose removal
    # would break apt.
    STATUS_CHANGES+=("Installed prerequisite: $prereq (kept on uninstall)")
  done
fi

# Re-read the archive on every run, so a newly published Ubuntu becomes a
# candidate the day it appears — no script edit, no distro-info-data update.
message "reading published Ubuntu releases from ${UBUNTU_MIRROR}..."
UBUNTU_CANDIDATE_CODENAMES="$(discover_ubuntu_codenames)"
[ -z "$UBUNTU_CANDIDATE_CODENAMES" ] \
  && error "No Ubuntu release reachable at ${UBUNTU_MIRROR} — check your internet connection."

# A manually forced codename (UBUNTU_CODENAME=xyz) still needs its own source
# entry even when it falls outside the newest-N window.
if [ "$UBUNTU_CODENAME" != "auto" ] && ! echo "$UBUNTU_CANDIDATE_CODENAMES" | grep -qw "$UBUNTU_CODENAME"; then
  [ -n "$(ubuntu_release_info "$UBUNTU_CODENAME")" ] \
    || error "UBUNTU_CODENAME=${UBUNTU_CODENAME} is not published on ${UBUNTU_MIRROR}"
  UBUNTU_CANDIDATE_CODENAMES="$UBUNTU_CANDIDATE_CODENAMES $UBUNTU_CODENAME"
fi
message "Ubuntu releases in play (oldest to newest): ${GREEN}${UBUNTU_CANDIDATE_CODENAMES}${ENDCOLOR}"

if [ ! -f "$UBUNTU_LIST" ] || ! sudo test -s "$UBUNTU_KEYRING" \
   || ! grep -qF "# codenames: ${UBUNTU_CANDIDATE_CODENAMES}" "$UBUNTU_LIST"; then
  message "configuring Ubuntu archive candidates: ${UBUNTU_CANDIDATE_CODENAMES}"
  sudo install -d -m 0755 /etc/apt/keyrings

  sudo test -s "$UBUNTU_KEYRING" \
    || add_ubuntu_key "$UBUNTU_ARCHIVE_KEY" \
    || error "Failed to fetch the Ubuntu archive signing key"

  {
    echo "# Ubuntu — Yaru theme + wallpaper (released codenames tried for compatibility)"
    echo "# Strictly apt-pinned — see ${UBUNTU_PIN}. This marker line lets re-runs"
    echo "# detect when a new Ubuntu release should be added automatically:"
    echo "# codenames: ${UBUNTU_CANDIDATE_CODENAMES}"
    echo ""
    for _c in $UBUNTU_CANDIDATE_CODENAMES; do
      echo "deb [signed-by=${UBUNTU_KEYRING}] ${UBUNTU_MIRROR} ${_c} main universe"
      echo "deb [signed-by=${UBUNTU_KEYRING}] ${UBUNTU_MIRROR} ${_c}-updates main universe"
    done
  } | sudo tee "$UBUNTU_LIST" > /dev/null
  STATUS_CHANGES+=("Ubuntu apt sources written (candidates: ${UBUNTU_CANDIDATE_CODENAMES})")
else
  message "Ubuntu candidate sources already current"
  STATUS_NOCHANGE+=("Ubuntu apt sources already current")
fi

###############################################################################
# Step: apt update (required before querying package versions)
###############################################################################

step "Refresh package lists"
apt_update || error "apt update failed"

###############################################################################
# Step: resolve the gnome-shell-compatible Ubuntu theme codename + apply pin
###############################################################################

step "Resolve Ubuntu theme codename"

if [ "$UBUNTU_CODENAME" = "auto" ]; then
  UBUNTU_CODENAME="$(resolve_ubuntu_codename)"
  message "auto-detected Ubuntu codename ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} ($(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')) — verified via simulated install"
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
fi

if [ $NEED_PIN_REWRITE -eq 1 ]; then
  # Priority -1 blocks all Ubuntu packages by default; the whitelist below
  # allows only theme/icon/font/wallpaper packages and their Ubuntu-only deps.
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

# Not coupled to gnome-shell: float to the newest release across all configured
# Ubuntu sources. The glob on ubuntu-wallpapers* is required, because the
# metapackage depends on the per-release wallpaper pack; whitelisting only the
# metapackage leaves that dependency at priority -1 and nothing installs.
Package: yaru-theme-gtk yaru-theme-icon yaru-theme-sound fonts-ubuntu* suru-icon-theme session-migration ubuntu-wallpapers*
Pin: release o=Ubuntu
Pin-Priority: 990
EOF
  STATUS_CHANGES+=("Ubuntu theme pin applied (${UBUNTU_CODENAME})")
else
  message "Ubuntu theme pin already current (${UBUNTU_CODENAME})"
  STATUS_NOCHANGE+=("Ubuntu theme pin already current")
fi

###############################################################################
# Step: apt upgrade
###############################################################################

step "Upgrade installed packages"
upgradable_before="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')"
if [ "$upgradable_before" -gt 0 ]; then
  message "upgrading ${upgradable_before} package(s)..."
  # Not fatal: a held package or an unrelated third-party repo must not stop
  # the Ubuntu look, and every install below is checked anyway.
  if sudo apt-get upgrade -y; then
    STATUS_CHANGES+=("Upgraded ${upgradable_before} package(s)")
    RELOGIN_NEEDED=1
  else
    message warn "apt upgrade failed — continuing; the theming steps do not depend on it"
    STATUS_FAILED+=("system upgrade (apt-get upgrade returned an error)")
  fi
else
  message "nothing to upgrade"
  STATUS_NOCHANGE+=("apt upgrade: nothing to upgrade")
fi

###############################################################################
# Step: Install packages per category + post-install tasks
###############################################################################

# Everything installed from here on belongs to this run, dependencies included.
# The stage list alone is not enough for the uninstall: apt pulls in packages of
# its own (ubuntu-wallpapers-<release> and the like) and those have to be named
# too, or they are left behind and every later run records them as pre-existing.
PKGS_BEFORE_RUN="$(mktemp)"
installed_package_list > "$PKGS_BEFORE_RUN"

for category in $package_categories; do
  step "Install + configure: ${category}"

  # Filter to only packages that exist in the apt cache, so an optional
  # package missing from a particular repo doesn't fail the whole category.
  available="$(available_packages "${packages[$category]}")"

  # Anything the stage asked for that no configured repository offers. Without
  # this it would simply vanish from the list with nothing said.
  for p in ${packages[$category]}; do
    case " $available " in
      *" $p "*) ;;
      *) STATUS_FAILED+=("$p (not offered by any configured repository)")
         message warn "${p} is not available from any configured repository — skipped" ;;
    esac
  done

  to_install="$(missing_packages "$available")"
  already="$(installed_packages "$available")"
  for p in $already; do STATUS_ALREADY+=("$p"); done

  if [ -z "$to_install" ]; then
    message "all packages in ${category} already installed"
  else
    message "installing: ${GREEN}${to_install}${ENDCOLOR}"

    # Ask apt what it would actually do before letting it do it. A theming
    # script has no business removing packages, so a batch that would remove
    # something is never run as a batch.
    # shellcheck disable=SC2086
    _batch_removes="$(apt-get -s install $to_install 2>/dev/null | awk '/^Remv /{print $2}' | xargs)"
    if [ -n "$_batch_removes" ]; then
      message warn "installing this stage as one batch would REMOVE: ${_batch_removes}"
      message warn "not doing that — falling back to one package at a time"
    else
      # One package with unsatisfiable dependencies must not stop the rest, so a
      # failed batch is retried package by package below.
      # shellcheck disable=SC2086
      sudo apt-get install -y $to_install \
        || message warn "batch install failed — retrying one package at a time"
    fi

    _installed_any=0
    for p in $to_install; do
      if is_installed "$p"; then
        STATUS_INSTALLED+=("$p")
        _installed_any=1
        continue
      fi
      # Same question, per package: anything that still wants to take another
      # package away is left uninstalled rather than allowed through.
      _p_removes="$(apt-get -s install "$p" 2>/dev/null | awk '/^Remv /{print $2}' | xargs)"
      if [ -n "$_p_removes" ]; then
        STATUS_FAILED+=("$p (would have removed: ${_p_removes})")
        message warn "${p} would remove ${_p_removes} — skipped, nothing was touched"
      elif sudo apt-get install -y "$p"; then
        STATUS_INSTALLED+=("$p")
        _installed_any=1
      else
        STATUS_FAILED+=("$p")
        message warn "${p} cannot be installed on this system — skipped"
      fi
    done
    # Only ask for a re-login if something actually landed.
    [ $_installed_any -eq 1 ] && RELOGIN_NEEDED=1
  fi

  case $category in
    # -------------------------------------------------------------------------
    0-base)
      # Ubuntu boots with "quiet splash" and Plymouth. UBUNTU_BOOT_SPLASH=0
      # reverts exactly what was applied; see apply_boot_splash() and
      # revert_boot_splash().
      if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; then
        # A machine that boots without GRUB has nothing to configure here, and
        # writing a config for a bootloader it does not use would be worse than
        # useless. Say so and move on rather than failing the install.
        STATUS_NOCHANGE+=("No GRUB on this system — boot splash left alone")
      elif [ "$UBUNTU_BOOT_SPLASH" = "0" ]; then
        revert_boot_splash
      else
        apply_boot_splash
      fi
      ;;

    # -------------------------------------------------------------------------
    1-desktop-base)
      # Fonts and wallpapers only: the packages are the whole of this stage.
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

      # With a live GNOME session, also apply immediately via gsettings
      if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        message "live session detected — applying settings immediately via gsettings"

        # Applied before the enable loop below so disable-user-extensions=false
        # is already in effect when the extensions are switched on.
        apply_live_settings

        # Ask the running shell first — this is what makes an already-known
        # extension light up immediately, without a re-login.
        for ext in $SHELL_EXTENSIONS; do
          gnome-extensions enable "$ext" 2>/dev/null || true
        done

        # Then write the enabled list to the user database ourselves. This is
        # the step that actually sticks: see enable_shell_extensions().
        enable_shell_extensions

        # Verify against the user database rather than the running shell. A
        # package installed a moment ago is not in the shell's extension list
        # until the next login, so 'gnome-extensions list --enabled' would
        # report a false failure for every one of them.
        ENABLED_NOW="$(dconf read /org/gnome/shell/enabled-extensions 2>/dev/null)"
        for ext in $SHELL_EXTENSIONS; do
          case "$ENABLED_NOW" in
            *"'${ext}'"*) ;;
            *) message warn "the enabled-extensions setting did not take for ${ext}"
               STATUS_EXT_FAILED+=("${ext}")
               RELOGIN_NEEDED=1 ;;
          esac
        done

        # Yaru ships the shell theme as two themes rather than one that follows
        # the colour scheme, and on Debian the shell theme is whatever
        # user-theme names. Ubuntu has no such key: Yaru is built into its
        # shell, which switches internally. So the variant is chosen here from
        # the scheme in force, and written once -- a scheme changed later needs
        # this run again, or the one-line command the README gives.
        if [ "$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null | tr -d "'")" = "prefer-dark" ]; then
          gset org.gnome.shell.extensions.user-theme name 'Yaru-dark'
        else
          gset org.gnome.shell.extensions.user-theme name 'Yaru'
        fi

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

      # An earlier version installed a service that watched color-scheme and
      # rewrote the theme behind it. Ubuntu ships no such thing -- its own
      # override sets gtk-theme once and leaves it -- so rather than keep a
      # process running for it, one left over is taken back out.
      if [ -f "$HOME/.config/systemd/user/yaru-color-scheme-sync.service" ] ||
         [ -f "$HOME/.local/bin/yaru-color-scheme-sync.sh" ]; then
        systemctl --user disable --now yaru-color-scheme-sync.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/yaru-color-scheme-sync.service" \
              "$HOME/.local/bin/yaru-color-scheme-sync.sh"
        systemctl --user daemon-reload 2>/dev/null || true
        STATUS_CHANGES+=("Removed the theme-follower service an earlier version installed")
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

      message "keeping the shell theme with the colour scheme"
      install_shell_theme_follower

      restore_dock_favourites

      # An earlier version removed a package of Debian's to make room for a
      # Files entry of its own. That entry is Debian's and belongs here, so
      # whatever this script's lineage took out is put back and the record
      # cleared. Nothing is named: the record says what to restore.
      _removed_record="${BACKUP_DIR}/removed-by-script.txt"
      if [ -f "$_removed_record" ]; then
        _restored_all=1
        while read -r _rpkg; do
          [ -n "$_rpkg" ] || continue
          is_installed "$_rpkg" && continue
          if sudo apt-get install -y "$_rpkg" >/dev/null 2>&1; then
            STATUS_CHANGES+=("Reinstalled ${_rpkg}, which an earlier version had removed")
          else
            _restored_all=0
          fi
        done < "$_removed_record"
        [ $_restored_all -eq 1 ] && rm -f "$_removed_record"
      fi

      message "applying Ubuntu's terminal colours"
      install_terminal_profile

      message "installing Ubuntu's own desktop-icons build"
      install_ubuntu_ding

      message "setting the Show Applications button icon"
      install_app_grid_icon

      message "theming the login screen"
      write_gdm_profile "$WP_LIGHT" "$WP_DARK"

      # GTK CSS.
      #
      # Ubuntu writes no user GTK files at all: no gtk.css, no gtkrc-2.0. The
      # look comes from the Yaru theme and the accent-color key. Anything an
      # earlier version of this script left in those files is taken back out,
      # and the user's own is restored from the snapshot where there is one.
      _gtk3_css="$HOME/.config/gtk-3.0/gtk.css"
      if [ -f "$_gtk3_css" ] && grep -q "ubuntu-look\.sh" "$_gtk3_css" 2>/dev/null; then
        if [ -f "${BACKUP_ORIGINAL}/gtk-3.0-gtk.css" ]; then
          cp "${BACKUP_ORIGINAL}/gtk-3.0-gtk.css" "$_gtk3_css"
          STATUS_CHANGES+=("Restored your own gtk-3.0/gtk.css; this script writes none")
        else
          rm -f "$_gtk3_css"
          STATUS_CHANGES+=("Removed the gtk-3.0/gtk.css an earlier version wrote; Ubuntu writes none")
        fi
        RELOGIN_NEEDED=1
      fi

      # Take back the accent overrides earlier versions wrote. Only files that
      # are recognisably theirs are touched.
      _gtk4_css="$HOME/.config/gtk-4.0/gtk.css"
      if [ -f "$_gtk4_css" ] && grep -q "E95420" "$_gtk4_css" 2>/dev/null \
         && grep -q "accent_bg_color" "$_gtk4_css" 2>/dev/null; then
        rm -f "$_gtk4_css"
        STATUS_CHANGES+=("Removed the gtk-4.0/gtk.css accent override an earlier version wrote")
        RELOGIN_NEEDED=1
      fi

      GTKRC2="$HOME/.gtkrc-2.0"
      if [ -f "$GTKRC2" ] && grep -q "selected_bg_color:#E95420" "$GTKRC2" 2>/dev/null; then
        sed -i '/selected_bg_color:#E95420/d' "$GTKRC2"
        [ -s "$GTKRC2" ] || rm -f "$GTKRC2"
        STATUS_CHANGES+=("Removed the ~/.gtkrc-2.0 accent line an earlier version wrote")
        RELOGIN_NEEDED=1
      else
        STATUS_NOCHANGE+=("~/.gtkrc-2.0 left alone, as on Ubuntu")
      fi

      # Software store icon. Ubuntu's store is App Center, whose icon Yaru ships
      # as 'app-center'; Yaru's org.gnome.Software icon is a GNOME icon. The
      # launcher is re-pointed with a user-level desktop override, which takes
      # precedence over /usr/share/applications without modifying it.
      SOFTWARE_DESKTOP_SYS=/usr/share/applications/org.gnome.Software.desktop
      SOFTWARE_DESKTOP_USER="$HOME/.local/share/applications/org.gnome.Software.desktop"
      if [ ! -f "$SOFTWARE_DESKTOP_SYS" ]; then
        STATUS_NOCHANGE+=("GNOME Software not installed — store icon left alone")
      elif ! ls /usr/share/icons/Yaru/*/apps/app-center.png >/dev/null 2>&1; then
        message warn "Yaru ships no 'app-center' icon — leaving the store icon alone"
      else
        message "pointing the software store at Ubuntu's App Center icon"
        SOFTWARE_TMP="$(mktemp)"
        sed 's/^Icon=.*/Icon=app-center/' "$SOFTWARE_DESKTOP_SYS" > "$SOFTWARE_TMP"
        if install_if_changed "$SOFTWARE_TMP" "$SOFTWARE_DESKTOP_USER"; then
          update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
          STATUS_CHANGES+=("Software store icon set to Ubuntu's App Center icon")
          RELOGIN_NEEDED=1
        else
          STATUS_NOCHANGE+=("Software store icon already Ubuntu's App Center icon")
        fi
        rm -f "$SOFTWARE_TMP"
      fi

      ;;
  esac
done

install_extension_autostart

# Record every package this run actually installed (not just "present"), so
# uninstall.sh can remove exactly what ubuntu-look.sh added — never a package
# that happened to already be on the system for unrelated reasons.
if [ ${#STATUS_INSTALLED[@]} -gt 0 ]; then
  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "${STATUS_INSTALLED[@]}" >> "$INSTALLED_MANIFEST"
fi

# The dependencies apt brought in alongside them.
if [ -s "$PKGS_BEFORE_RUN" ]; then
  mkdir -p "$BACKUP_DIR"
  installed_package_list \
    | comm -13 "$PKGS_BEFORE_RUN" - >> "$INSTALLED_MANIFEST"
fi
rm -f "$PKGS_BEFORE_RUN"
[ -f "$INSTALLED_MANIFEST" ] && sort -u -o "$INSTALLED_MANIFEST" "$INSTALLED_MANIFEST"

message "${GREEN}All steps finished. See SUMMARY below.${ENDCOLOR}"
