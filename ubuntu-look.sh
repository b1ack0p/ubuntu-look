#!/bin/bash
# =============================================================================
# Title       : ubuntu-look.sh
# Description : Makes Debian GNOME look and behave like the newest Ubuntu
#               release that fits the installed GNOME Shell, without
#               breaking Debian: Yaru themes, Ubuntu fonts and wallpapers,
#               Ubuntu Dock, tiling assistant, tray icons, desktop icons,
#               terminal colours, login screen, boot splash and Ubuntu's
#               GNOME defaults.
#
# Original    : DeltaLima
#               https://github.com/DeltaLima/make-debian-look-like-ubuntu
#
# Usage       : bash ubuntu-look.sh                   install or update
#               bash ubuntu-look.sh --download        build or refresh packages/ for an
#                                                     offline install (needs internet)
#               bash ubuntu-look.sh --offline         install from packages/, no network
#               bash ubuntu-look.sh --refresh         list available updates, then ask
#                                                     to apply them
#               bash ubuntu-look.sh --uninstall       undo it, from your desktop session
#               bash ubuntu-look.sh --prepare-upgrade before a Debian release upgrade
#               bash ubuntu-look.sh --help            this text
#               Safe to re-run.
#
# Options     : UBUNTU_CODENAME=<name>        use this Ubuntu release
#               UBUNTU_INCLUDE_DEVEL=1        allow the unreleased series
#               UBUNTU_MIRROR=<url>           Ubuntu mirror (default per architecture)
#               UBUNTU_BOOT_SPLASH=0          no boot splash; removes the look's
#                                             (GRUB only)
#               PLYMOUTH_THEME=<name>         boot splash theme (default bgrt)
#               UBUNTU_LOOK_SYSTEM_UPGRADE=1  also run a system-wide apt upgrade
#               UBUNTU_LOOK_FORCE_BUNDLE=1    accept a bundle built for another
#                                             Debian release or GNOME Shell major
#               UBUNTU_LOOK_LOG=0             no run log
#               UBUNTU_LOOK_ANIMATIONS=0|1    animation effects off or on for
#                                             this user (default: unchanged)
#               An install run saves the first five (--offline only
#               UBUNTU_BOOT_SPLASH and PLYMOUTH_THEME); later runs reuse them
#               unless given again, e.g. UBUNTU_CODENAME=auto.
#
# Offline     : Run --download on an online machine with the same Debian
#               release, architecture and GNOME Shell major; copy this script
#               and packages/ to the target; run --offline there.
#
# Refresh     : --refresh lists what an update would change: a newer Ubuntu
#               release, a Debian or GNOME Shell change, newer builds of the
#               look's packages. It asks before applying anything.
#
# Undo        : bash ubuntu-look.sh --uninstall. Each user undoes their own
#               settings; the last one also undoes the system changes.
#
# Requires    : Debian with GNOME; a normal user (not root) with sudo rights;
#               internet access, except for --offline.
# =============================================================================

# sudo is a shell function that makes apt-get wait for its lock.
# shellcheck disable=SC2033

# Contents
#   1. Helpers      messages, records, options, dconf values
#   2. Packages     apt, the Ubuntu release, sources and pin
#   3. Desktop      Ubuntu's settings, extensions, terminal, login screen
#   4. Boot         GRUB command line and boot splash
#   5. Records      --refresh, summary
#   6. Offline      --download, --offline, --prepare-upgrade
#   7. Setup        help, run log, mode, options, variables
#   8. Uninstall    --uninstall
#   9. Install      the install itself

###############################################################################
# 1. Helpers: messages, records, options, dconf values
###############################################################################

# Create the system record directories.
sys_records_dir() { sudo install -d -m 0755 "$SYS_DIR" "$SYS_RECORDS"; }

# Write stdin to system file $1, or with "-a $1" append to it, readable by
# all: a file sudo creates otherwise takes the user's umask, and the script
# reads its records without sudo.
sudo_tee() { sudo sh -c 'umask 022; exec tee "$@" > /dev/null' sh "$@"; }

# Write text $2 as record $1, atomically: an interrupted write keeps the old
# record whole. Non-zero when the record could not be written.
sys_record_write() {
  local tmp rc=0
  sys_records_dir && tmp="$(mktemp)" || return 1
  { printf '%s\n' "$2" > "$tmp" && sudo_write_atomic "$tmp" "$1"; } || rc=1
  rm -f "$tmp"
  return "$rc"
}

# Append line $2 to record $1; not on a --download machine without the look.
# Non-zero when the record could not be written.
sys_record_append() {
  [ "$NO_SYSTEM_RECORDS" = 1 ] && return 0
  sys_records_dir && printf '%s\n' "$2" | sudo_tee -a "$1"
}

# A system change takes effect at the next boot. The record holds this boot's
# id, so a later run of the same boot still asks for the reboot, and a run
# after the reboot does not.
need_reboot() {
  local id
  REBOOT_NEEDED=1
  [ -d "$SYS_RECORDS" ] || return 0
  id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
  [ -n "$id" ] || return 0
  [ "$(cat "$REBOOT_OWED" 2>/dev/null)" = "$id" ] \
    || printf '%s\n' "$id" | sudo_tee "$REBOOT_OWED"
  return 0
}

# Sort record $1 and drop duplicate lines; replaced atomically, so a failed
# write keeps the record whole. Non-zero on failure.
sys_record_sort() {
  [ -f "$1" ] || return 0
  local tmp rc=0
  tmp="$(mktemp)" || return 1
  # Read with sudo, so a record of any mode sorts.
  # shellcheck disable=SC2024  # the output goes to the user's own temp file
  { sudo sort -u "$1" > "$tmp" && { sudo cmp -s "$tmp" "$1" || sudo_write_atomic "$tmp" "$1"; }; } || rc=1
  rm -f "$tmp"
  return "$rc"
}

# True when $2 is a valid value of option $1. "devel" is no codename: the
# pin matches the release's own codename.
option_value_ok() {
  case "$1" in
    UBUNTU_CODENAME) [[ "$2" =~ ^[a-z]+$ ]] && [ "$2" != devel ] ;;
    UBUNTU_INCLUDE_DEVEL|UBUNTU_BOOT_SPLASH) [[ "$2" =~ ^[01]$ ]] ;;
    PLYMOUTH_THEME) [[ "$2" =~ ^[A-Za-z0-9._+-]+$ ]] ;;
    # One URL for the source's URIs line; empty means the default mirror.
    UBUNTU_MIRROR) [ -z "$2" ] || [[ "$2" =~ ^https?://[][A-Za-z0-9._:/+~%@-]+$ ]] ;;
    *) return 0 ;;
  esac
}

# Set each saved option not given in the environment. The file is parsed,
# never sourced; unsafe or invalid values are ignored, so the default applies.
load_saved_options() {
  local key val
  readable_regular_file "$SAVED_OPTIONS" || return 0
  while IFS='=' read -r key val; do
    in_word_list "$key" "$SAVED_OPTION_NAMES" && [ -z "${!key+x}" ] || continue
    case "$val" in *[[:space:][:cntrl:]\"\'\`\$\\]*) continue ;; esac
    option_value_ok "$key" "$val" || continue
    printf -v "$key" '%s' "$val"
  done < "$SAVED_OPTIONS"
}

# Add mirror $1 to UBUNTU_HOSTS_RE by its full URL, unless it is an ubuntu.com host.
add_mirror_to_hosts_re() {
  [[ "$1/" =~ $UBUNTU_COM_RE ]] && return 0
  # ] first and [ last in the bracket: an IPv6 host has both.
  UBUNTU_HOSTS_RE="${UBUNTU_HOSTS_RE}|^$(printf '%s' "$1" | sed 's/[]$.+?*()|{}[]/[&]/g') "
}

# message [warn|error] <text>
message() {
  local label="${GREEN}INFO${ENDCOLOR}"
  case $1 in
    warn)  label="${YELLOW}WARN${ENDCOLOR}"; shift ;;
    error) label="${RED}ERROR${ENDCOLOR}"; shift ;;
  esac
  echo -e "[${label}] $*"
}

error() { message error "$@"; exit 1; }

# Returns 1 unless the answer is yes.
ask_yes() {
  message warn "Type '${GREEN}y${ENDCOLOR}' or '${GREEN}yes${ENDCOLOR}' and press Enter to continue"
  local reply
  echo "[y/N?] "
  # From the terminal even when the script itself comes through a pipe;
  # without one the answer is no.
  if [ -t 0 ]; then
    read -r reply
  else
    { read -r reply < /dev/tty; } 2>/dev/null || reply=""
  fi
  [ "${reply,,}" = y ] || [ "${reply,,}" = yes ]
}

confirm_continue() { ask_yes || error "Aborted."; }

# True when $1 is installed; "hold ok installed" counts.
is_installed() {
  case "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" in *" ok installed") return 0 ;; esac
  return 1
}

# True when $1 is on the system in any state short of removed: installed, or
# left half-way by an interrupted or failed dpkg run.
is_present() {
  case "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" in
    ''|not-installed|config-files) return 1 ;;
  esac
}

# True when $1 is present or left with its configuration files.
is_present_or_configured() {
  case "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" in
    ''|not-installed) return 1 ;;
  esac
}

# True when the user has put $1 on hold (apt-mark hold); it is never moved.
is_held() {
  case "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" in "hold "*) return 0 ;; esac
  return 1
}

# Installed packages, sorted; removed-but-not-purged ones excluded.
installed_package_list() {
  dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
    | awk '$3 == "ok" && $4 == "installed" { print $1 }' | sort -u
}

# The packages in word list $1 that are not installed.
missing_packages() {
  local missing="" pkg
  for pkg in $1; do
    is_installed "$pkg" || missing="$missing $pkg"
  done
  echo "${missing# }"
}

# True when word $1 is in the space-separated list $2.
in_word_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Word list $1 without word $2.
word_list_without() {
  local e out=""
  for e in $1; do [ "$e" = "$2" ] || out="$out $e"; done
  echo "$out"
}

# Copy $1 over $2 (mode 0644) only when the content differs.
# Returns 0 = written, 1 = already identical, 2 = failed.
install_if_changed() {
  [ -f "$2" ] && cmp -s "$1" "$2" && return 1
  install -Dm 0644 "$1" "$2" || return 2
}

# Replace system file $2 with a copy of $1 (mode $3, default 0644, owner
# root) through a temp file in the same directory and a rename, so a failed
# write leaves $2 unchanged. A symlink at $2 stays; its target is replaced.
# Returns 0 on success, 1 on failure.
sudo_write_atomic() {
  local dest="$2" dir tmp
  if [ -L "$dest" ]; then
    dest="$(readlink -f "$dest")" && [ -n "$dest" ] || return 1
  fi
  dir="$(dirname "$dest")"
  [ -d "$dir" ] || sudo install -d -m 0755 "$dir" || return 1
  # A dot name: apt and dconf skip hidden files in their directories. One a
  # cut earlier write left goes first.
  sudo find "$dir" -maxdepth 1 -name ".${dest##*/}.??????" -type f -delete 2>/dev/null
  tmp="$(sudo mktemp "${dir}/.${dest##*/}.XXXXXX")" || return 1
  if sudo install -m "${3:-0644}" -o root -g root "$1" "$tmp" && sudo mv -f "$tmp" "$dest"; then
    return 0
  fi
  sudo rm -f "$tmp"
  return 1
}

# As install_if_changed, through sudo and atomically.
sudo_install_if_changed() {
  [ -f "$2" ] && cmp -s "$1" "$2" && return 1
  sudo_write_atomic "$1" "$2" || return 2
}

# Render a space-separated list as a GVariant string array.
gvariant_string_array() {
  local out="" e
  for e in $1; do out="${out:+${out}, }'${e}'"; done
  # An empty array must carry its type, or dconf rejects the write.
  if [ -z "$out" ]; then echo "@as []"; else echo "[${out}]"; fi
}

# A dconf value for the log; "unset" when the key is not set.
dconf_show() {
  local v
  v="$(dconf read "$1" 2>/dev/null)"
  printf '%s' "${v:-unset}"
}

# A GVariant string array as a space-separated list.
array_items() { printf '%s' "$1" | sed 's/^@[a-z]* //' | tr -d "[]' " | tr ',' ' '; }

# The dconf string array at key $1 as a space-separated list.
dconf_array_items() { array_items "$(dconf read "$1" 2>/dev/null)"; }

# Value of key $3 in group $2 of the ini-style file $1.
ini_value() {
  [ -f "$1" ] || return 0
  awk -v grp="[$2]" -v key="$3" '
    $0 == grp { ingrp = 1; next }
    /^\[/     { ingrp = 0 }
    ingrp && index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
  ' "$1"
}

# Major version of the installed gnome-shell, e.g. "48"; asked once per run
# (SHELL_MAJOR_CACHE is filled in the setup), since callers run in $(...).
shell_major() {
  [ -n "${SHELL_MAJOR_CACHE:-}" ] \
    || SHELL_MAJOR_CACHE="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  printf '%s\n' "$SHELL_MAJOR_CACHE"
}

# True when $1 is a readable regular file (a FIFO would block).
readable_regular_file() {
  [ -f "$1" ] && [ -r "$1" ]
}

# dconf on the user's own database only, without any system defaults; a
# plain dump or list also shows the system databases' keys.
user_dconf() { DCONF_PROFILE=/dev/fd/3 dconf "$@" 2>/dev/null 3<<< "user-db:user"; }

# The user's own value of dconf key $1.
user_dconf_read() { user_dconf read "$1"; }

# Use the user's own session bus when one is running: over SSH or tmux there
# is none in the environment, after 'su user' another user's.
adopt_session_bus() {
  local uid
  uid="$(id -u)"
  if [ ! -S "/run/user/${uid}/bus" ]; then
    # Another user's bus is no session of this user's.
    case "${DBUS_SESSION_BUS_ADDRESS:-}" in
      *"/run/user/${uid}/"*) ;;
      *"/run/user/"*) unset DBUS_SESSION_BUS_ADDRESS ;;
    esac
    return 0
  fi
  case "${DBUS_SESSION_BUS_ADDRESS:-}" in *"/run/user/${uid}/"*) return 0 ;; esac
  export XDG_RUNTIME_DIR="/run/user/${uid}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus"
}

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${YELLOW}━━━ ${STEP}. $1${ENDCOLOR}"
}

# "NAME=value" for each option named in $@, as saved: the release options as
# asked for, not as resolved.
option_lines() {
  local n v
  for n in "$@"; do
    case "$n" in
      UBUNTU_CODENAME) v="$REQUESTED_CODENAME" ;;
      UBUNTU_MIRROR)   v="$REQUESTED_MIRROR" ;;
      *)               v="${!n}" ;;
    esac
    printf '%s=%s\n' "$n" "$v"
  done
}

# Save the options of this install run for later runs; setup has checked
# their values with option_value_ok.
save_options() {
  local tmp head="# Options of the last install run, reused by later runs."
  tmp="$(mktemp)" || { STATUS_FAILED+=("The options of this run could not be saved — give them again next time"); return 0; }
  if [ "$MODE" = offline ]; then
    # Only the boot options; the release options stay as last saved online.
    {
      if readable_regular_file "$SAVED_OPTIONS"; then
        grep -vE "^($(echo "$BOOT_OPTION_NAMES" | tr ' ' '|'))=" "$SAVED_OPTIONS"
      else
        echo "$head"
      fi
      # shellcheck disable=SC2086
      option_lines $BOOT_OPTION_NAMES
    } > "$tmp"
  else {
    echo "$head"
    # shellcheck disable=SC2086
    option_lines $SAVED_OPTION_NAMES
  } > "$tmp"; fi
  if ! { readable_regular_file "$SAVED_OPTIONS" && cmp -s "$tmp" "$SAVED_OPTIONS"; }; then
    { sys_records_dir && sudo_write_atomic "$tmp" "$SAVED_OPTIONS"; } \
      || STATUS_FAILED+=("The options of this run could not be saved in ${SAVED_OPTIONS} — give them again next time")
  fi
  rm -f "$tmp"
}

# Take the run lock, waiting while another run holds it, then check dpkg.
# Stops when the lock cannot be taken.
take_run_lock() {
  local fail="Could not take the run lock ${UBUNTU_LOOK_LOCK}."
  # Anything but a root-owned regular file is replaced.
  if [ -L "$UBUNTU_LOOK_LOCK" ] || { [ -e "$UBUNTU_LOOK_LOCK" ] && { [ ! -f "$UBUNTU_LOOK_LOCK" ] \
       || [ "$(stat -c %u "$UBUNTU_LOOK_LOCK" 2>/dev/null)" != 0 ]; }; }; then
    sudo rm -f "$UBUNTU_LOOK_LOCK"
  fi
  # Created with noclobber, so two runs never make two lock files.
  [ -f "$UBUNTU_LOOK_LOCK" ] \
    || sudo sh -c 'umask 022; set -C; : > "$1"' _ "$UBUNTU_LOOK_LOCK" 2>/dev/null \
    || [ -f "$UBUNTU_LOOK_LOCK" ] || error "$fail"
  # The braces keep the stderr redirect from outliving this line.
  { exec 9< "$UBUNTU_LOOK_LOCK"; } 2>/dev/null || error "$fail"
  if ! flock -n 9; then
    message "another ubuntu-look run is in progress — waiting for it to finish"
    flock 9 || error "$fail"
  fi
  require_dpkg_ready
}

# Stop when an interrupted dpkg run must be repaired first: apt would refuse
# every change, and its refusals would read as the look's.
require_dpkg_ready() {
  # A package manager at work leaves the same traces: it is waited for first.
  wait_dpkg_lock \
    || error "Another package manager is still running after 5 minutes — let it finish, then run this again."
  # A pending journal or a package left half-way; not dpkg --audit, which
  # also lists harmless issues that 'dpkg --configure -a' does not clear.
  [ -z "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ] \
    && ! dpkg-query -W -f='${db:Status-Status}\n' 2>/dev/null | grep -qvxE 'installed|config-files|not-installed' \
    && return 0
  error "dpkg was interrupted earlier — run 'sudo dpkg --configure -a' and then 'sudo apt-get -f install', then run this again."
}

# Wait up to 300 seconds, as apt-get does, while a package manager holds
# the dpkg frontend lock; boot tools must not run beside a dpkg run. The
# lock is an fcntl lock, listed in /proc/locks by inode. Non-zero on timeout.
wait_dpkg_lock() {
  local ino n=0
  # /proc/locks names a file as <major>:<minor>:<inode>. Only the inode is
  # compared: on btrfs, stat reports the subvolume's device, not the one
  # /proc/locks shows.
  ino="$(stat -c %i /var/lib/dpkg/lock-frontend 2>/dev/null)" || return 0
  while awk -v ino="$ino" '{ for (k = 1; k <= NF; k++) if ($k ~ ":" ino "$") f = 1 } END { exit !f }' \
          /proc/locks 2>/dev/null; do
    [ "$n" = 0 ] && message "waiting for another package manager to finish"
    [ "$n" -ge 300 ] && return 1
    n=$((n + 1))
    command sleep 1
  done
  return 0
}

debian_codename() { (. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}"); }

# Checksum of the Ubuntu pin and apt source, to detect a change.
apt_config_sum() { cat "$UBUNTU_SOURCES" "$UBUNTU_PIN" 2>/dev/null | sha256sum; }

# Percent-encode a path for a file: URI in an apt source.
uri_path_encode() {
  local s="$1"
  s="${s//%/%25}"; s="${s// /%20}"; s="${s//$'\t'/%09}"
  s="${s//#/%23}"; s="${s//\[/%5B}"; s="${s//\]/%5D}"
  printf '%s' "$s"
}

###############################################################################
# 2. Packages: apt, the Ubuntu release, sources and pin
###############################################################################

# True when $1 was installed before the first install: per the system record,
# else the copy an unfinished uninstall keeps in BACKUP_DIR.
predates_install() {
  grep -qxF "$1" "$PACKAGES_BEFORE" 2>/dev/null \
    || { [ ! -f "$PACKAGES_BEFORE" ] && grep -qxF "$1" "${BACKUP_DIR}/packages-before.txt" 2>/dev/null; }
}

# Back to automatically installed, if it was before. One the user added
# later keeps its mark.
restore_auto_mark() {
  if [ -f "$MANUAL_BEFORE" ] && predates_install "$1" && ! grep -qxF "$1" "$MANUAL_BEFORE"; then
    sudo apt-mark auto "$1" >/dev/null 2>&1 || true
  fi
}

# Record the packages apt simulation $1 newly installs, before installing, so
# an interrupted run leaves them on record. Non-zero when a record failed.
record_planned_installs() {
  local p new="" rc=0
  for p in $(printf '%s\n' "$1" | awk '/^Inst / && $3 !~ /^\[/ { print $2 }'); do
    grep -qxF "$p" "$INSTALLED_MANIFEST" 2>/dev/null && continue
    in_word_list "$p" "$new" || predates_install "$p" || new="${new} ${p}"
  done
  # shellcheck disable=SC2086
  [ -z "$new" ] || sys_record_append "$INSTALLED_MANIFEST" "$(printf '%s\n' $new)" || rc=1
  # Packages the combined package replaces, the user's included; the uninstall
  # restores them.
  new=""
  for p in $(printf '%s\n' "$1" | awk '/^Remv /{ print $2 }'); do
    grep -qxF "$p" "$INSTALLED_MANIFEST" "$REPLACED_BY_COMBINED" 2>/dev/null && continue
    in_word_list "$p" "$new" && continue
    new="${new} ${p}"
  done
  # Reported by apt_install_checked once apt has run.
  PLANNED_REPLACED="$new"
  # shellcheck disable=SC2086
  [ -z "$new" ] || sys_record_append "$REPLACED_BY_COMBINED" "$(printf '%s\n' $new)" || rc=1
  return "$rc"
}

# True when build $1 of the combined extensions package is the real one that
# carries the dock, not an older metapackage; apt options follow.
combined_carries_dock() {
  [ -n "$1" ] && LC_ALL=C apt-cache "${@:2}" show "${COMBINED_EXT_PKG}=$1" 2>/dev/null \
    | grep -q '^Provides:.*gnome-shell-extension-ubuntu-dock'
}

# Use the combined extensions package where the pinned release offers it.
use_combined_extensions_if_offered() {
  local stage="2-desktop-gnome" p list=""
  if combined_carries_dock "$(pkg_candidate_version "$COMBINED_EXT_PKG")" "${APT_OPTS[@]}"; then
    for p in ${packages[$stage]}; do
      in_word_list "$p" "$SEPARATE_EXT_PKGS" || list="${list} ${p}"
    done
    packages[$stage]="$(echo "$list $COMBINED_EXT_PKG" | xargs)"
    ALLOWED_REMOVALS="$SEPARATE_EXT_PKGS"
    message "${UBUNTU_CODENAME} ships its shell extensions as ${COMBINED_EXT_PKG} — using it"
  elif is_installed "$COMBINED_EXT_PKG" \
       && grep -qxF "$COMBINED_EXT_PKG" "$INSTALLED_MANIFEST" 2>/dev/null; then
    ALLOWED_REMOVALS="$COMBINED_EXT_PKG"
  fi
}

# True when $1 is not installed.
not_installed() { ! is_installed "$1"; }

# A package prepare-upgrade removed that is still missing; a separate
# extension package counts as back while the combined one is installed.
not_restored() {
  ! is_installed "$1" \
    && ! { in_word_list "$1" "$SEPARATE_EXT_PKGS" && is_installed "$COMBINED_EXT_PKG"; }
}

# Keep the packages in record $1 for which test $2 holds; rewritten only when
# one goes, removed when none is left.
prune_record() {
  [ -f "$1" ] || return 0
  local p keep
  keep="$(while read -r p; do [ -n "$p" ] && "$2" "$p" && echo "$p"; done < "$1")"
  if [ -z "$keep" ]; then
    sudo rm -f "$1"
  elif [ "$keep" != "$(cat "$1")" ]; then
    sys_record_write "$1" "$keep"
  fi
}

# Record the builds apt simulation $1 replaces with Ubuntu's, a dependency's
# included, so the uninstall puts them back. Non-zero when a record failed.
record_planned_upgrades() {
  local p was new origin rc=0
  while read -r p was new origin; do
    # The bundle's index names no origin: there, every pinned package counts.
    # record_upgraded_pkg keeps only builds that predate the look or are Debian's.
    case "$origin" in
      Ubuntu:*) ;;
      *) [ "$MODE" = offline ] && in_word_list "$p" "$UBUNTU_PINNED_PACKAGES" || continue ;;
    esac
    record_upgraded_pkg "$p" "$was" || rc=1
  done < <(printf '%s\n' "$1" \
    | awk '/^Inst / && $3 ~ /^\[/ { gsub(/[][()]/, ""); print $2, $3, $4, $5 }')
  return "$rc"
}

# apt-get install $@ after one simulation, with the new packages recorded
# first. Returns 1, without installing, when apt cannot resolve it or it
# would remove packages other than ALLOWED_REMOVALS (then in REMOVES); 2
# when apt fails; 3, without installing, when the records could not be
# written. Call directly, not in $(...).
apt_install_checked() {
  local sim
  local -a no_remove=()
  REMOVES=""
  sim="$(LC_ALL=C apt-get -s install "${APT_OPTS[@]}" "$@" 2>&1)" || return 1
  REMOVES="$(unexpected_removals "$sim")"
  [ -z "$REMOVES" ] || return 1
  if ! record_planned_installs "$sim" || ! record_planned_upgrades "$sim"; then
    message warn "could not write the install records in ${SYS_RECORDS} — apt not run"
    return 3
  fi
  # With no removal allowed, the real run cannot remove what the simulation kept.
  [ -n "$ALLOWED_REMOVALS" ] || no_remove=(--no-remove)
  sudo apt-get install -y "${no_remove[@]}" "${APT_OPTS[@]}" "$@" || return 2
  local p
  for p in $PLANNED_REPLACED; do
    STATUS_CHANGES+=("${p} replaced by Ubuntu's ${COMBINED_EXT_PKG}, which carries it — the uninstall puts it back")
  done
  PLANNED_REPLACED=""
}

# Keep only packages available in the apt cache.
available_packages() {
  local avail="" pkg
  for pkg in $1; do
    apt-cache "${APT_OPTS[@]}" show "$pkg" >/dev/null 2>&1 && avail="$avail $pkg"
  done
  echo "${avail# }"
}

# Installed version of $1, empty and non-zero when not installed (as in
# is_installed).
pkg_installed_version() {
  dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null \
    | awk '$2 == "ok" && $3 == "installed" { print $4; f = 1; exit } END { exit !f }'
}

# apt's chosen version for $1; empty when the pin leaves no candidate.
pkg_candidate_version() {
  LC_ALL=C apt-cache "${APT_OPTS[@]}" policy "$1" 2>/dev/null \
    | awk '/^  Candidate:/ { if ($2 != "(none)") print $2; exit }'
}

# Every version of $1 the pin allows (priority 0 or more), from apt's
# candidate down, newest first; nothing when there is no candidate.
pkg_allowed_versions_desc() {
  LC_ALL=C apt-cache "${APT_OPTS[@]}" policy "$1" 2>/dev/null | awk '
    /^  Candidate:/ { cand = $2; next }
    $1 == "***" && $3 ~ /^[0-9]+$/ { v = $2 }
    NF == 2 && $1 !~ /:$/ && $2 ~ /^[0-9]+$/ { v = $1 }
    v != "" { if (v == cand) on = 1; if (on) print v; v = "" }'
}

# Removals in apt simulation $1 other than ALLOWED_REMOVALS.
unexpected_removals() {
  printf '%s\n' "$1" | awk '/^Remv /{print $2}' \
    | grep -vxF -f <(printf '%s\n' $ALLOWED_REMOVALS) | xargs
}

# True when apt can install $@ without removals other than ALLOWED_REMOVALS.
installs_cleanly() {
  local sim
  sim="$(LC_ALL=C apt-get install -s "${APT_OPTS[@]}" "$@" 2>&1)" || return 1
  [ -z "$(unexpected_removals "$sim")" ]
}

# The build of $1 an update would install: the newest allowed one that
# installs cleanly and is newer than installed version $2 (if any).
refresh_target() {
  local v
  for v in $(pkg_allowed_versions_desc "$1"); do
    [ -z "$2" ] || dpkg --compare-versions "$v" gt "$2" || return 0
    installs_cleanly "${1}=${v}" && { echo "$v"; return 0; }
  done
}

# One-line reason why $1 cannot be installed at $2 (default: its candidate).
explain_blocked() {
  local pkg="$1" ver="${2:-}" have sim rem dep out=""
  [ -z "$ver" ] && ver="$(pkg_candidate_version "$pkg")"
  if [ -z "$ver" ]; then
    if [ "$MODE" = offline ]; then
      echo "the bundle carries no build of it"
    elif apt-cache show "$pkg" >/dev/null 2>&1; then
      echo "apt has no candidate for it — every build it can see is blocked by ${UBUNTU_PIN}"
    else
      echo "no configured repository offers a package by that name"
    fi
    return
  fi
  have="$(pkg_installed_version "$pkg")"
  [ "$have" = "$ver" ] && { echo "${ver} is already the newest build apt offers"; return; }

  sim="$(LC_ALL=C apt-get install -s "${APT_OPTS[@]}" "${pkg}=${ver}" 2>&1)"
  rem="$(unexpected_removals "$sim")"
  if [ -n "$rem" ]; then
    # shellcheck disable=SC2086
    set -- $rem
    if [ $# -gt 4 ]; then
      echo "${ver} would have removed $# packages, among them: $1 $2 $3 $4"
    else
      echo "${ver} would have removed: ${rem}"
    fi
    return
  fi
  # Unmet dependencies: none on offer, or one apt did not select.
  for dep in $(echo "$sim" \
      | grep -oE '(Pre)?Depends: [^ ]+( \([^)]*\))? but ' \
      | awk '{print $2}' | sort -u); do
    if [ -z "$(pkg_candidate_version "$dep")" ] \
       && apt-cache "${APT_OPTS[@]}" show "$dep" >/dev/null 2>&1; then
      out="${out} ${dep} (Ubuntu-only, blocked by ${UBUNTU_PIN})"
    else
      out="${out} ${dep}"
    fi
  done
  [ -n "$out" ] && { echo "${ver} needs:${out}"; return; }
  out="$(echo "$sim" | grep -m1 '^E: ' | sed 's/^E: //')"
  [ -n "$out" ] && { echo "${ver}: ${out}"; return; }
  echo "${ver} will not install on this system"
}

# Install $1 at the newest version this system can take, never below the
# installed one. Sets ENSURE_VERSION; call directly, not in $(...). Returns:
#   0  installed or upgraded
#   1  nothing on offer can be installed here
#   2  already at the newest version that fits
ensure_package() {
  local pkg="$1" have ver log rc busy
  ENSURE_VERSION=""
  have="$(pkg_installed_version "$pkg")"

  # Newest allowed build first; none when the pin leaves no candidate.
  for ver in $(pkg_allowed_versions_desc "$pkg"); do
    if [ -n "$have" ] && dpkg --compare-versions "$ver" le "$have"; then
      ENSURE_VERSION="$have"
      return 2
    fi
    # Turned down earlier this run (by the alignment, say); not tried twice.
    in_word_list "${pkg}=${ver}" "$REJECTED_BUILDS" && continue
    log="$(mktemp)"
    # Run here, not in a pipeline subshell, so its records reach the summary;
    # C locale so the messages below can be read.
    LC_ALL=C apt_install_checked "${pkg}=${ver}" > >(tee "$log") 2>&1
    rc=$?
    wait $! 2>/dev/null
    # A busy apt, a lost network or an interrupted dpkg says nothing about
    # the build: stop here.
    busy=0
    [ "$rc" -eq 2 ] && grep -qE 'Could not get lock|(Failed|Unable) to fetch (https?|ftp)://|Temporary failure resolving|dpkg was interrupted' "$log" && busy=1
    rm -f "$log"
    if [ "$rc" -eq 0 ]; then
      ENSURE_VERSION="$ver"
      return 0
    fi
    [ "$busy" -eq 0 ] \
      || error "apt is busy or the network failed while installing ${pkg} — nothing more is changed; run this again later."
    [ "$rc" -ne 3 ] \
      || error "could not write the look's records in ${SYS_RECORDS} while installing ${pkg} — nothing more is changed; run this again."
    REJECTED_BUILDS="${REJECTED_BUILDS} ${pkg}=${ver}"
    [ "$rc" -eq 1 ] || message warn "${pkg}=${ver} would not install after all — trying an older build"
  done

  [ -n "$have" ] && { ENSURE_VERSION="$have"; return 2; }
  return 1
}

# One Ubuntu release as "<version> <state> <mirror>", from the run's release
# cache, whichever mirror it came from, else probed and added to it: on
# mirror $2 only, if given. "devel"
# comes from Valid-Until. Returns 1 when no mirror publishes it, 2 when a
# mirror could not be read (no connection, a server error).
ubuntu_release_info() {
  local cn="$1" mirror out code unread=0
  local -a mirrors=("$UBUNTU_MIRROR" "${UBUNTU_OLD_MIRROR:-}")
  [ -z "${2:-}" ] || mirrors=("$2")
  out="$(awk -v c="$cn" '$1 == c { print $2, $3, $4; exit }' "${UBUNTU_RELEASE_CACHE:-/dev/null}" 2>/dev/null)"
  [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  for mirror in "${mirrors[@]}"; do
    [ -n "$mirror" ] || continue
    # A timeout or a server error is retried; a 404 is not. The reply's HTTP
    # code comes last.
    out="$(curl -sSL --connect-timeout 5 -m 15 --retry 2 --retry-delay 2 -r 0-2047 \
             -w '\n%{http_code}' "${mirror}/dists/${cn}/Release" 2>/dev/null)"
    code="${out##*$'\n'}"
    case "$code" in
      2*) ;;
      4*) continue ;;
      *)  unread=1; continue ;;
    esac
    out="$(printf '%s\n' "${out%$'\n'*}" | awk -v m="$mirror" '
          /^Version:/     { v = $2 }
          /^Valid-Until:/ { unreleased = 1 }
          END { if (v != "") print v, (unreleased ? "devel" : "stable"), m }')"
    if [ -n "$out" ]; then
      [ -n "${UBUNTU_RELEASE_CACHE:-}" ] && printf '%s %s\n' "$cn" "$out" >> "$UBUNTU_RELEASE_CACHE"
      printf '%s\n' "$out"
      return 0
    fi
  done
  [ "$unread" -eq 0 ] || return 2
  return 1
}

# True when suite $1 should be written for mirror $2. Only a 4xx reply means absent.
ubuntu_suite_published() {
  local code hit memo="${UBUNTU_RELEASE_CACHE:+${UBUNTU_RELEASE_CACHE}.suites}"
  memo="${memo:-/dev/null}"
  # Answered once per run.
  hit="$(awk -v s="$1" -v m="$2" '$1 == s && $2 == m { print $3; exit }' "$memo" 2>/dev/null)"
  [ -n "$hit" ] && return "$hit"
  code="$(curl -fsSL -o /dev/null --connect-timeout 5 -m 15 -r 0-255 -w '%{http_code}' \
            "${2}/dists/${1}/Release" 2>/dev/null)"
  case "$code" in
    2*|3*) echo "$1 $2 0" >> "$memo"; return 0 ;;
    4*)    echo "$1 $2 1" >> "$memo"; return 1 ;;
    # Unread: kept, and not asked again this run.
    *)     message warn "could not check ${1} on ${2} — keeping it" >&2
           echo "$1 $2 0" >> "$memo"; return 0 ;;
  esac
}

# Mirror serving $1. Returns 1 when none publishes it, 2 when a mirror could
# not be read, as ubuntu_release_info.
ubuntu_mirror_for() {
  local info
  info="$(ubuntu_release_info "$1")" || return
  printf '%s' "${info##* }"
}

# Codenames listed in a mirror's dists/ directory.
list_dists() {
  local page
  # A listing cut off by the timeout would read as a shorter list.
  page="$(curl -fsSL -m 30 "${1}/dists/" 2>/dev/null)" || return 1
  printf '%s\n' "$page" \
    | grep -oE 'href="[^"?]+/"' \
    | sed -E 's|.*href="([^"]+)/"|\1|' \
    | grep -E '^[a-z]+$' | grep -vx devel | sort -u
}

# Every released Ubuntu the archive lists, plus those the apt source names,
# oldest to newest (development series only with UBUNTU_INCLUDE_DEVEL=1).
# Debian's distro-info-data may lack new Ubuntu releases.
discover_ubuntu_codenames() {
  local names header cn info ver state versioned="" rc
  # A mirror without a directory listing falls back to the default mirror.
  names="$(list_dists "$UBUNTU_MIRROR")"
  [ -n "$names" ] || [ "$UBUNTU_MIRROR" = "$UBUNTU_DEFAULT_MIRROR" ] \
    || names="$(list_dists "$UBUNTU_DEFAULT_MIRROR")"
  # No directory listing (a proxy such as apt-cacher-ng refuses one): the
  # names come from Ubuntu's release list, else Debian's distro-info-data;
  # each is still probed on the mirror below.
  if [ -z "$names" ]; then
    names="$( { curl -fsSL -m 15 "$UBUNTU_META_RELEASE"
                [ "$UBUNTU_INCLUDE_DEVEL" = 1 ] && curl -fsSL -m 15 "${UBUNTU_META_RELEASE}-development"
              } 2>/dev/null | sed -n 's/^Dist: //p' | grep -E '^[a-z]+$' | tail -n 12)"
    [ -n "$names" ] || names="$(awk -F, 'NR > 1 && $3 ~ /^[a-z]+$/ { print $3 }' \
      /usr/share/distro-info/ubuntu.csv 2>/dev/null | tail -n 12)"
    [ -n "$names" ] && message warn "no release listing at ${UBUNTU_MIRROR} — the newest releases Ubuntu names are probed instead" >&2
  fi

  # Re-probe the configured releases; a retired one is on old-releases.
  header="$(sed -n 's/^# codenames: //p' "$UBUNTU_SOURCES" 2>/dev/null)"
  [ -z "$names" ] && [ -n "$header" ] \
    && message warn "could not list Ubuntu releases at ${UBUNTU_MIRROR} — newer releases are not checked this run" >&2
  names="$(printf '%s\n%s\n' "$names" "$header" \
    | tr ' ' '\n' | grep -E '^[a-z]+$' | sort -u)"

  for cn in $names; do
    info="$(ubuntu_release_info "$cn")"; rc=$?
    [ "$rc" -eq 2 ] && { release_unread "$cn"; return 2; }
    [ "$rc" -eq 0 ] || continue
    ver="${info%% *}"
    state="${info#* }"; state="${state%% *}"
    if [ "$state" = "devel" ] && [ "$UBUNTU_INCLUDE_DEVEL" != "1" ]; then
      message "  skipping '${cn}' (${ver}) — not released yet; UBUNTU_INCLUDE_DEVEL=1 to use it" >&2
      continue
    fi
    versioned="${versioned}${ver} ${cn}
"
  done

  printf '%s' "$versioned" | oldest_first | xargs
}

# Retired releases not already known, at most MAX_UBUNTU_LOOKBACK. One that
# cannot be read is skipped with a warning; returns 2 only when none could be.
discover_retired_codenames() {
  local cn info versioned="" rc unread="" listed order found=0 ordered="" rest=""
  listed="$(list_dists "$UBUNTU_OLD_MIRROR" | xargs)"
  # An unreadable listing is not "none retired": the caller must not claim
  # that no release fits.
  if [ -z "$listed" ]; then
    message error "Could not list the retired Ubuntu releases on ${UBUNTU_OLD_MIRROR} — check the connection, then run this again." >&2
    return 2
  fi
  # Ubuntu's own release list orders them, newest first, so only the newest
  # are probed; without it, every listed one is.
  order="$(curl -fsSL -m 15 "$UBUNTU_META_RELEASE" 2>/dev/null \
    | awk '/^Dist:/ { d = $2 } /^Version:/ { print $2, d }' | oldest_first | tac | xargs)"
  for cn in $order; do in_word_list "$cn" "$listed" && ordered="${ordered} ${cn}"; done
  for cn in $listed; do in_word_list "$cn" "$order" || rest="${rest} ${cn}"; done
  for cn in $ordered $rest; do
    in_word_list "$cn" "$UBUNTU_ALL_CODENAMES" && continue
    info="$(ubuntu_release_info "$cn" "$UBUNTU_OLD_MIRROR")"; rc=$?
    [ "$rc" -eq 2 ] && { unread="${unread} ${cn}"; continue; }
    [ "$rc" -eq 0 ] || continue
    versioned="${versioned}${info%% *} ${cn}
"
    found=$((found + 1))
    [ -n "$order" ] && [ "$found" -ge "$MAX_UBUNTU_LOOKBACK" ] && break
  done
  if [ -n "$unread" ]; then
    [ -n "$versioned" ] || { release_unread "${unread# }"; return 2; }
    message warn "could not read these retired Ubuntu releases, skipped:${unread}" >&2
  fi
  printf '%s' "$versioned" | oldest_first | tail -n "$MAX_UBUNTU_LOOKBACK" | xargs
}

# Install the missing tools in $1 (curl, ca-certificates). Generic tools, not
# recorded: the uninstall keeps them.
install_prereqs() {
  local prereq
  [ -n "$1" ] || return 0
  if sudo apt-get update -qq; then APT_LISTS_FRESH=1; else message warn "apt update reported an error"; fi
  for prereq in $1; do
    installs_cleanly "$prereq" \
      || error "Installing prerequisite ${prereq} would remove packages or cannot be done — install it by hand"
    sudo apt-get install -y "$prereq" < /dev/null \
      || error "Failed to install prerequisite: $prereq"
    STATUS_CHANGES+=("Installed prerequisite: $prereq (kept on uninstall)")
  done
}

# Report on stderr that release $1 could not be read from the archive.
release_unread() {
  message error "Could not read Ubuntu ${1} from the archive — check the connection, then run this again." >&2
}

# The codenames of "<version> <codename>" lines on stdin, oldest first.
oldest_first() { LC_ALL=C sort -V | awk '{ print $NF }'; }

# Codenames $@ ordered oldest to newest by their release versions.
codenames_by_version() {
  local cn
  for cn in "$@"; do
    printf '%s %s\n' "$(ubuntu_release_info "$cn" | cut -d' ' -f1)" "$cn"
  done | oldest_first | xargs
}

# UBUNTU_CANDIDATE_CODENAMES: the newest releases of UBUNTU_ALL_CODENAMES,
# plus a requested release ($1, unless "auto") outside that window.
set_candidate_codenames() {
  UBUNTU_CANDIDATE_CODENAMES="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' \
    | tail -n "$MAX_UBUNTU_CANDIDATES" | xargs)"
  if [ "$1" != auto ] && ! in_word_list "$1" "$UBUNTU_CANDIDATE_CODENAMES"; then
    ubuntu_release_info "$1" >/dev/null
    case $? in
      0) ;;
      2) release_unread "$1"; exit 1 ;;
      *) error "UBUNTU_CODENAME=${1} is not published on ${UBUNTU_MIRROR} or ${UBUNTU_OLD_MIRROR}" ;;
    esac
    # shellcheck disable=SC2086
    UBUNTU_CANDIDATE_CODENAMES="$(codenames_by_version $UBUNTU_CANDIDATE_CODENAMES "$1")"
  fi
}

# Read the published releases into UBUNTU_ALL_CODENAMES and set the
# candidates for requested release $1. Stops when any release cannot be
# read: a release left out unread could be the one that fits.
discover_releases() {
  message "reading published Ubuntu releases from ${UBUNTU_MIRROR}..."
  UBUNTU_ALL_CODENAMES="$(discover_ubuntu_codenames)" || exit 1
  [ -n "$UBUNTU_ALL_CODENAMES" ] \
    || error "No Ubuntu release reachable at ${UBUNTU_MIRROR} — check your internet connection."
  set_candidate_codenames "$1"
}

# False when the Ubuntu index is empty, as for an architecture Ubuntu does not serve.
ubuntu_index_has_packages() {
  madison_rows gnome-shell-extension-ubuntu-dock yaru-theme-icon \
    | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '$2 ~ re { f = 1 } END { exit !f }'
}

# Ubuntu's archive keys, from Debian's own ubuntu-keyring; the run stops without them.
ensure_ubuntu_keyring() {
  if ! is_installed ubuntu-keyring; then
    # The prerequisites' update, if any, is recent enough.
    [ "${APT_LISTS_FRESH:-0}" = 1 ] || sudo apt-get update -qq || message warn "apt update reported an error"
    wait_dpkg_lock || error "Another package manager is still running after 5 minutes — let it finish, then run this again."
    apt_install_checked ubuntu-keyring \
      || error "Could not install Debian's ubuntu-keyring package (Ubuntu's archive keys)."
    if [ "$MODE" = download ] && [ "$KEYRING_FOR_BUILD" = 1 ]; then
      STATUS_CHANGES+=("Installed ubuntu-keyring for this build only; it is removed again at the end")
    else
      STATUS_CHANGES+=("Installed ubuntu-keyring (Ubuntu's archive keys, from Debian)")
    fi
  fi
  [ -s "$UBUNTU_KEYRING" ] || error "${UBUNTU_KEYRING} is missing — reinstall ubuntu-keyring."
}

# Write the Ubuntu apt source (deb822), one stanza per release. Returns 0 =
# changed, 1 = already correct, 2 = no archive answered, 3 = the file could
# not be written. With no argument, every candidate is written.
write_ubuntu_sources() {
  local tmp _c _m _rc_m _suites _comp _missing="" _list="${*:-$UBUNTU_CANDIDATE_CODENAMES}"
  tmp="$(mktemp)"
  {
    echo "# Written by ubuntu-look.sh — the Ubuntu look packages. Pinned: see ${UBUNTU_PIN}."
    echo "# Later runs read the next line to re-check these releases."
    echo "# codenames: ${UBUNTU_CANDIDATE_CODENAMES}"
    for _c in $_list; do
      # The pinned release, and the one pinned before, get universe too.
      _comp="$UBUNTU_COMPONENTS"
      case "$_c" in
        "${UBUNTU_CODENAME:-}"|"${PINNED_BEFORE:-}") _comp="$UBUNTU_PINNED_COMPONENTS" ;;
      esac
      # The host that answered; a retired release is on old-releases.
      _m="$(ubuntu_mirror_for "$_c")"; _rc_m=$?
      if [ "$_rc_m" -ne 0 ] || [ -z "$_m" ]; then
        if [ "$_rc_m" -eq 2 ]; then
          message warn "could not reach the archive for Ubuntu '${_c}' — leaving it out of the apt source" >&2
        else
          message warn "no archive serves Ubuntu '${_c}' — leaving it out of the apt source" >&2
        fi
        _missing="${_missing} ${_c}"
        continue
      fi
      # A mirror found without universe stays on main; narrow_ubuntu_sources
      # tries universe again on the next run.
      grep -qxF "${_c} ${_m}" "$NO_UNIVERSE_RECORD" 2>/dev/null && _comp="$UBUNTU_COMPONENTS"
      _suites="$_c"
      ubuntu_suite_published "${_c}-updates" "$_m" && _suites="${_c} ${_c}-updates"
      # Architectures keeps foreign architectures off; Targets skips translations.
      printf '\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: %s\nTargets: Packages\n' \
        "$_m" "$_suites" "$_comp" "$UBUNTU_ARCH" "$UBUNTU_KEYRING"
    done
  } > "$tmp"

  # No release reachable, or the pinned one missing: keep the current source.
  if ! grep -q '^Types: ' "$tmp" \
     || { [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != auto ] \
          && in_word_list "$UBUNTU_CODENAME" "$_missing"; }; then
    rm -f "$tmp"
    STATUS_FAILED+=("Ubuntu apt sources left as they were — no archive answered${_missing:+ for:${_missing}}")
    return 2
  fi

  # 0644: apt reads sources as any user.
  local rc
  sudo_install_if_changed "$tmp" "$UBUNTU_SOURCES"; rc=$?
  rm -f "$tmp"
  if [ "$rc" -eq 2 ]; then
    STATUS_FAILED+=("Could not write ${UBUNTU_SOURCES}")
    rc=3
  fi
  return "$rc"
}

# Bring the look packages back to the pinned release. apt never downgrades by
# itself; only these packages move, and nothing is removed but what
# ALLOWED_REMOVALS names: the separate extension packages the combined one
# replaces, or the combined one where the release no longer offers it.
align_look_packages() {
  [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != "auto" ] || return 0

  local pkg want have plan="" any_down=0 codes
  local -A is_down=()
  # shellcheck disable=SC2086
  for pkg in $LOOK_PACKAGES $UBUNTU_SHELL_EXT_PKGS; do
    have="$(pkg_installed_version "$pkg")"
    [ -n "$have" ] || continue
    is_held "$pkg" && continue
    if [ "$MODE" = offline ]; then
      # The bundle's build; a downgrade only over a Debian or other-release build.
      want="$(madison_rows "${APT_OPTS[@]}" "$pkg" | awk -F'|' '{ print $1; exit }')"
      [ -n "$want" ] && [ "$have" != "$want" ] || continue
      if dpkg --compare-versions "$want" lt "$have"; then
        codes="$(pkg_version_ubuntu_codenames "$pkg" "$have")"
        if ! pkg_version_is_debian "$pkg" "$have" \
           && { [ -z "$codes" ] || printf '%s\n' "$codes" | grep -qxF "$UBUNTU_CODENAME"; }; then
          STATUS_NOCHANGE+=("${pkg} stays at ${have} — newer than the bundle's ${want}, and not shown to be from another release")
          ALIGN_KEPT="${ALIGN_KEPT} ${pkg}"
          continue
        fi
      fi
    else
      # The pinned release's newest build, up or down.
      pkg_version_in_codename "$pkg" "$have" "$UBUNTU_CODENAME" && continue
      want="$(release_build "$pkg" "$UBUNTU_CODENAME")"
      [ -n "$want" ] && [ "$want" != "$have" ] || continue
    fi
    if dpkg --compare-versions "$want" lt "$have"; then is_down[$pkg]=1; any_down=1; fi
    plan="${plan} ${pkg}=${want}"
  done

  [ -n "$plan" ] || return 0

  # Record the displaced versions before apt runs; the uninstall restores them.
  for pkg in $plan; do
    if ! record_upgraded_pkg "${pkg%%=*}" "$(pkg_installed_version "${pkg%%=*}")"; then
      STATUS_FAILED+=("Not aligned to ${UBUNTU_CODENAME}:${plan} — the install records could not be written")
      return 0
    fi
  done

  message "aligning the look to ${UBUNTU_CODENAME}:${plan}"
  local done_list="" refused="" failed="" down="" rc
  [ "$any_down" = 1 ] && down=--allow-downgrades
  # shellcheck disable=SC2086
  apt_install_checked $down $plan; rc=$?
  if [ "$rc" -eq 0 ]; then
    done_list="$plan"
  elif [ "$rc" -eq 1 ]; then
    [ -n "$REMOVES" ] && message warn "aligning ${plan# } would remove: ${REMOVES} — skipped"
    # One package that cannot move must not hold back the others.
    for pkg in $plan; do
      down=""
      [ "${is_down[${pkg%%=*}]:-0}" = 1 ] && down=--allow-downgrades
      # shellcheck disable=SC2086
      apt_install_checked $down "$pkg"; rc=$?
      if [ "$rc" -eq 0 ]; then
        done_list="${done_list} ${pkg}"
        continue
      fi
      [ -n "$REMOVES" ] && message warn "aligning ${pkg} would remove: ${REMOVES} — skipped"
      if [ "$rc" -eq 1 ]; then
        refused="${refused} ${pkg%%=*}"
        # The stages do not try the refused build again.
        REJECTED_BUILDS="${REJECTED_BUILDS} ${pkg}"
      else
        failed="${failed} ${pkg%%=*}"
      fi
      # Reported here; the drift check does not repeat it.
      ALIGN_KEPT="${ALIGN_KEPT} ${pkg%%=*}"
    done
  else
    # apt itself failed, or the records could not be written: each package
    # would fail the same way.
    for pkg in $plan; do
      failed="${failed} ${pkg%%=*}"
      ALIGN_KEPT="${ALIGN_KEPT} ${pkg%%=*}"
    done
  fi

  for pkg in $done_list; do
    STATUS_CHANGES+=("${pkg%%=*} taken to ${UBUNTU_CODENAME}'s build (${pkg##*=})")
    RELOGIN_NEEDED=1
  done
  [ -n "$refused" ] && STATUS_FAILED+=("Not aligned to ${UBUNTU_CODENAME}:${refused} — apt refused or it would remove packages")
  [ -n "$failed" ] && STATUS_FAILED+=("Not aligned to ${UBUNTU_CODENAME}:${failed} — apt failed or the install records could not be written; run this again")
  return 0
}

# Other existing users of the look: the registry, plus homes with its files.
other_users() {
  local u h uid_min uid_max
  uid_min="$(awk '$1 == "UID_MIN" { print $2 }' /etc/login.defs 2>/dev/null)"
  uid_max="$(awk '$1 == "UID_MAX" { print $2 }' /etc/login.defs 2>/dev/null)"
  {
    cat "$SYS_USERS" 2>/dev/null
    getent passwd | awk -F: -v lo="${uid_min:-1000}" -v hi="${uid_max:-60000}" \
        '$3 >= lo && $3 <= hi { print $1 ":" $6 }' \
      | while IFS=: read -r u h; do
          [ "$u" = "$RUN_USER" ] && continue
          sudo test -f "${h}/${LOOK_ENV_REL}" 2>/dev/null && echo "$u"
        done
  } | sed '/^$/d' | sort -u | grep -vxF "$RUN_USER" \
    | while read -r u; do getent passwd "$u" > /dev/null && echo "$u"; done | xargs
}

# A per-release wallpaper pack a release change left unused goes, unless it
# predates the install.
remove_unused_wallpaper_packs() {
  local pkg orphan purge=""
  orphan="$(LC_ALL=C apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' \
            | grep -E '^ubuntu-wallpapers-' | xargs)"
  [ -n "$orphan" ] || return 0
  # Only this user's wallpaper can be seen: a look shared by several users
  # keeps the pack.
  if [ -n "$(other_users)" ]; then
    STATUS_NOCHANGE+=("${orphan} is now unused — kept, as another user may show it; 'sudo apt autoremove' reclaims it")
    return 0
  fi
  # The packages owning the wallpapers in use (URIs with plain paths).
  local key path owners=""
  for key in picture-uri picture-uri-dark; do
    path="$(dconf read "/org/gnome/desktop/background/${key}" 2>/dev/null | tr -d "'")"
    path="${path#file://}"
    [ -n "$path" ] && owners="${owners} $(dpkg -S "$path" 2>/dev/null | cut -d: -f1 | tr "," " ")"
  done
  for pkg in $orphan; do
    predates_install "$pkg" && continue
    # A pack holding the wallpaper in use stays.
    if in_word_list "$pkg" "$owners"; then
      STATUS_NOCHANGE+=("${pkg} kept — your wallpaper is one of its pictures")
      continue
    fi
    purge="${purge} ${pkg}"
  done
  # shellcheck disable=SC2086
  if [ -n "$purge" ] && sudo apt-get purge -y $purge; then
    STATUS_CHANGES+=("Removed the wallpaper pack the old release left unused:${purge}")
  elif [ -n "$purge" ]; then
    STATUS_FAILED+=("Could not remove the unused wallpaper pack:${purge}")
  fi
  return 0
}

# Print the Ubuntu apt source $1 with the Components of release $2's stanza
# on mirror $3 set to UBUNTU_COMPONENTS. The stanzas are write_ubuntu_sources'
# own: URIs and Suites come before Components.
source_on_main() {
  CN="$2" MIRROR="$3" COMPS="$UBUNTU_COMPONENTS" awk '
    /^$/           { uri = ""; hit = 0 }
    /^URIs:/       { uri = $2 }
    /^Suites:/     { for (i = 2; i <= NF; i++) { s = $i; sub(/-[a-z]+$/, "", s); if (s == ENVIRON["CN"]) hit = 1 } }
    /^Components:/ && hit && uri == ENVIRON["MIRROR"] { print "Components: " ENVIRON["COMPS"]; next }
    { print }' "$1"
}

# After a failed Ubuntu apt update caused by universe: put the apt source on
# main and record each release and mirror, so later runs stay there. Returns
# 1 when universe was not the cause or nothing changed.
drop_unserved_universe() {
  # "<release> <mirror>" of each universe index apt found missing (404);
  # progress lines and passing network errors name universe too.
  local pairs
  pairs="$(sed -nE 's#^(E|W): Failed to fetch (.*)/dists/([a-z]+)(-[a-z]+)?/universe/.*[[:space:]]404[[:space:]].*#\3 \2#p' \
           <<< "${APT_UPDATE_OUTPUT:-}" | sort -u)"
  [ -n "$pairs" ] || return 1
  local tmp cn m dropped=""
  tmp="$(mktemp)" || return 1
  cp "$UBUNTU_SOURCES" "$tmp"
  # Only those releases' stanzas go to main.
  while read -r cn m; do
    source_on_main "$tmp" "$cn" "$m" > "${tmp}.new" && mv -f "${tmp}.new" "$tmp"
    sys_record_append "$NO_UNIVERSE_RECORD" "${cn} ${m}"
    dropped="${dropped} ${cn}"
  done <<< "$pairs"
  sys_record_sort "$NO_UNIVERSE_RECORD"
  local rc
  sudo_install_if_changed "$tmp" "$UBUNTU_SOURCES"; rc=$?
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
  # One summary line, naming every release dropped so far.
  local i old msg="Ubuntu mirror without universe for:"
  for i in "${!STATUS_FAILED[@]}"; do
    case "${STATUS_FAILED[$i]}" in "$msg"*)
      old="${STATUS_FAILED[$i]#"$msg"}"; old="${old%% — *}"
      # shellcheck disable=SC2086
      dropped="$(printf '%s\n' $old $dropped | sort -u | xargs)"
      unset 'STATUS_FAILED[i]' ;;
    esac
  done
  STATUS_FAILED+=("${msg} $(echo $dropped) — its source stays on main; humanity-icon-theme may be missing")
  return 0
}

# Narrow the apt source to the pinned release before anything installs.
# Only a newly added suite needs an apt update.
narrow_ubuntu_sources() {
  [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != "auto" ] || return 0
  local before rc=0
  before="$(ubuntu_source_entries)"
  # Each run tries universe again; the record stays if no archive answers.
  local no_universe=""
  if [ -f "$NO_UNIVERSE_RECORD" ]; then
    no_universe="$(cat "$NO_UNIVERSE_RECORD")"
    sudo rm -f "$NO_UNIVERSE_RECORD"
  fi
  write_ubuntu_sources "$UBUNTU_CODENAME" || rc=$?
  if [ "$rc" -ge 2 ]; then
    [ -n "$no_universe" ] && sys_record_write "$NO_UNIVERSE_RECORD" "$no_universe"
    return 0
  fi
  if [ "$rc" -eq 0 ] \
     && ubuntu_source_entries | grep -qvxF -f <(printf '%s\n' "$before"); then
    # A mirror without universe goes to main and is fine; any other failure counts.
    if ! apt_update_ubuntu_only \
       && ! { drop_unserved_universe && apt_update_ubuntu_only; }; then
      STATUS_FAILED+=("apt update failed for ${UBUNTU_CODENAME}'s sources")
    fi
  fi
  # The comment lines (the releases re-checked) are no change of the sources.
  if [ "$(grep -v '^#' "$UBUNTU_SOURCES" 2>/dev/null)" != "$(printf '%s\n' "${INITIAL_UBUNTU_SOURCES:-}" | grep -v '^#')" ]; then
    local comps="$UBUNTU_COMPONENTS"
    grep -qxF "Components: ${UBUNTU_PINNED_COMPONENTS}" "$UBUNTU_SOURCES" && comps="$UBUNTU_PINNED_COMPONENTS"
    STATUS_CHANGES+=("Ubuntu apt sources: ${UBUNTU_CODENAME} (${comps})")
  else
    STATUS_NOCHANGE+=("Ubuntu apt sources already current")
  fi
}

# The Ubuntu apt source as one line per suite: "<URI> <suite> <components>".
ubuntu_source_entries() {
  awk '
    function flush(  i) { for (i = 1; i <= n; i++) print uri, suite[i], comps; uri = comps = ""; n = 0 }
    /^$/           { flush(); next }
    /^URIs:/       { uri = $2 }
    /^Suites:/     { n = 0; for (i = 2; i <= NF; i++) suite[++n] = $i }
    /^Components:/ { comps = $0; sub(/^Components:[ \t]*/, "", comps) }
    END            { flush() }' "$UBUNTU_SOURCES" 2>/dev/null
}

# Codenames the Ubuntu apt source names.
configured_codenames() {
  ubuntu_source_entries | awk '{ sub(/-updates$/, "", $2); print $2 }' | sort -u
}

# apt-get update for the Ubuntu sources only, waiting for a lock. The output
# is kept in APT_UPDATE_OUTPUT.
apt_update_ubuntu_only() {
  local log rc
  log="$(mktemp)" || return 1
  apt_update_waiting "$log" quiet -o Dir::Etc::sourcelist="$UBUNTU_SOURCES" \
    -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
  rc=$?
  APT_UPDATE_OUTPUT="$(cat "$log")"
  rm -f "$log"
  return "$rc"
}

# apt-get update with options $3..., output in file $1 (and on screen unless
# $2 is "quiet"); up to five tries a minute apart while apt is locked.
apt_update_waiting() {
  local log="$1" mode="$2" rc try=1
  shift 2
  while :; do
    if [ "$mode" = quiet ]; then
      # shellcheck disable=SC2024  # the log is this user's file
      LC_ALL=C sudo apt-get update "$@" > "$log" 2>&1
      rc=$?
    else
      LC_ALL=C sudo apt-get update "$@" 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
    fi
    [ "$rc" -ne 0 ] && [ "$try" -lt 5 ] \
      && grep -q 'Could not get lock' "$log" || break
    message "apt is busy — trying again in a minute"
    try=$((try + 1)); sleep 60
  done
  return "$rc"
}

# apt-get update that waits for a lock and tolerates other repositories' errors.
# Returns 3 when apt stayed locked.
apt_update() {
  local log rc
  log="$(mktemp)" || return 1
  apt_update_waiting "$log" show
  rc=$?
  [ "$rc" -eq 0 ] && { rm -f "$log"; return 0; }
  # Still locked after five tries.
  grep -q 'Could not get lock' "$log" && { rm -f "$log"; return 3; }
  rm -f "$log"

  # Another repository failed; the Ubuntu part is what matters.
  if [ -f "$UBUNTU_SOURCES" ] && apt_update_ubuntu_only; then
    message warn "apt update reported errors for another repository — continuing"
    STATUS_NOCHANGE+=("apt update: another repository reported an error (see above)")
    return 0
  fi
  # A mirror without universe: its sources go to main and apt tries again.
  if [ -f "$UBUNTU_SOURCES" ] && drop_unserved_universe && apt_update_ubuntu_only; then
    message warn "an Ubuntu mirror does not serve universe — continuing on main"
    return 0
  fi
  return "$rc"
}

# Newest candidate release whose shell theme installs here, and its dock too
# when it has one. Empty when nothing fits.
resolve_ubuntu_codename() {
  local cn pkg ver ok allowed
  for cn in $(echo "$UBUNTU_CANDIDATE_CODENAMES" | tr ' ' '\n' | tac); do
    ok=1
    # The dock comes as its own package, or in the combined one.
    for pkg in yaru-theme-gnome-shell gnome-shell-extension-ubuntu-dock "$COMBINED_EXT_PKG"; do
      ver="$(release_build "$pkg" "$cn")"
      if [ -z "$ver" ]; then
        # The theme is required; the dock is optional.
        [ "$pkg" = yaru-theme-gnome-shell ] && { ok=0; break; }
        continue
      fi
      message "  checking ${cn}: ${pkg}=${ver}" >&2
      allowed=""
      [ "$pkg" = "$COMBINED_EXT_PKG" ] && allowed="$SEPARATE_EXT_PKGS"
      if ! ALLOWED_REMOVALS="$allowed" installs_cleanly "${pkg}=${ver}"; then
        ok=0; break
      fi
      [ "$pkg" = gnome-shell-extension-ubuntu-dock ] && break
    done
    [ "$ok" -eq 1 ] && { echo "$cn"; return 0; }
  done
  return 0
}

# Newest build of $1 that release $2 (or its -updates) serves; empty if none.
release_build() {
  madison_rows "$1" | awk -F'|' -v c="$2" '$2 ~ ("[ /]" c "(-updates)?/") { print $1; exit }'
}

# apt-cache madison $@ (apt options, packages) as trimmed "<version>|<source>" lines.
madison_rows() {
  LC_ALL=C apt-cache madison "$@" 2>/dev/null | awk -F'|' '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); print $2 "|" $3 }'
}

# True when the installed version of $1 is served only by Ubuntu. Needs the
# sources configured.
pkg_origin_is_ubuntu() {
  local ver
  ver="$(pkg_installed_version "$1")"
  [ -n "$ver" ] || return 1
  madison_rows "$1" | awk -F'|' -v v="$ver" -v re="$UBUNTU_HOSTS_RE" '
    $1 == v { if ($2 ~ re) u = 1; else d = 1 }
    END { exit (u && !d) ? 0 : 1 }'
}

# True when version $2 of $1 is served by release $3 (or its -updates).
pkg_version_in_codename() {
  madison_rows "$1" | awk -F'|' -v v="$2" -v cn="$3" '
    $1 == v && $2 ~ ("[ /]" cn "(-updates)?/") { f = 1 } END { exit !f }'
}

# True when version $2 of $1 is Debian's build.
pkg_version_is_debian() {
  madison_rows "$1" | awk -F'|' -v v="$2" -v re="$UBUNTU_HOSTS_RE" '
    $1 == v && $2 !~ re { f = 1 } END { exit !f }'
}

# Upper bound on gnome-shell that the installed $1 declares, e.g. "49".
pkg_shell_upper_bound() {
  dpkg-query -W -f='${Depends}' "$1" 2>/dev/null \
    | grep -oE 'gnome-shell \(<< [0-9]+' | grep -oE '[0-9]+$' | head -1
}

# Warn about extensions the installed gnome-shell has moved past, look packages
# not from the pinned release, and extensions holding back a newer gnome-shell.
check_shell_coupling_drift() {
  local running pkg bound drift=0 themepkg themed want why cand_major
  running="$(shell_major)"
  [ -n "$running" ] || return 0

  for pkg in $SEPARATE_EXT_PKGS $COMBINED_EXT_PKG; do
    is_installed "$pkg" || continue
    bound="$(pkg_shell_upper_bound "$pkg")"
    [ -n "$bound" ] || continue
    if [ "$running" -ge "$bound" ]; then
      message warn "${pkg} is built for GNOME Shell < ${bound}, but ${running} is installed"
      STATUS_FAILED+=("${pkg} does not support GNOME Shell ${running} — it will not load")
      drift=1
    fi
  done

  # Every Ubuntu-built look package should be the pinned release's build
  # (-updates included).
  if [ -n "$UBUNTU_CODENAME" ] && [ "$UBUNTU_CODENAME" != "auto" ]; then
    for themepkg in $LOOK_PACKAGES; do
      # Every installed build that is not Debian's. After narrowing, a build from
      # another Ubuntu release has no source left that marks it as Ubuntu's.
      themed="$(pkg_installed_version "$themepkg")"
      [ -n "$themed" ] || continue
      is_held "$themepkg" && continue
      # Kept on purpose by align_look_packages, which says why.
      in_word_list "$themepkg" "$ALIGN_KEPT" && continue
      pkg_version_is_debian "$themepkg" "$themed" && continue
      pkg_version_in_codename "$themepkg" "$themed" "$UBUNTU_CODENAME" && continue
      [ "$MODE" = offline ] && bundle_has_version "$themepkg" "$PACKAGES_DIR" "$themed" >/dev/null && continue
      want="$(madison_rows "${APT_OPTS[@]}" "$themepkg" | awk -F'|' -v c="$UBUNTU_CODENAME" '
              $2 ~ ("[ /]" c "(-updates)?/") || $2 ~ /^file:/ { print $1; exit }')"
      message warn "${themepkg} ${themed} is not the build for ${UBUNTU_CODENAME}"
      # apt does not downgrade by itself.
      if [ -n "$want" ] && ! in_word_list "${themepkg}=${want}" "$REJECTED_BUILDS" \
         && installs_cleanly --allow-downgrades "${themepkg}=${want}"; then
        message warn "  to align it: sudo apt install --allow-downgrades ${themepkg}=${want}"
        STATUS_FAILED+=("${themepkg} is ${themed}, but ${UBUNTU_CODENAME} ships ${want} — see the command above")
      elif [ -n "$want" ]; then
        why="$(explain_blocked "$themepkg" "$want")"
        message warn "  ${why} — ${themed} stays"
        STATUS_FAILED+=("${themepkg} stays at ${themed} — ${why}")
      else
        message warn "  ${UBUNTU_CODENAME} offers no build of it in the configured sources"
        STATUS_FAILED+=("${themepkg} stays at ${themed} — ${UBUNTU_CODENAME} offers no build of it")
      fi
    done
  fi

  # The Ubuntu extensions hold back a newer gnome-shell major.
  cand_major="$(LC_ALL=C apt-cache policy gnome-shell 2>/dev/null \
    | awk '/^  Candidate:/ { if ($2 != "(none)") print $2; exit }' | grep -oE '^[0-9]+')"
  if [ -n "$cand_major" ] && [ "$cand_major" -gt "$running" ]; then
    for pkg in $UBUNTU_SHELL_EXT_PKGS; do
      bound="$(pkg_shell_upper_bound "$pkg")"
      if [ -n "$bound" ] && [ "$cand_major" -ge "$bound" ]; then
        STATUS_FAILED+=("GNOME Shell ${cand_major} is available but ${pkg} holds it back — run 'bash ubuntu-look.sh --prepare-upgrade', upgrade, then run this script again")
        break
      fi
    done
  fi

  # Only the extensions wait on a GNOME Shell change; each release line above
  # says what to do.
  [ "$drift" -eq 1 ] && message warn "see the summary; re-run this script after a GNOME Shell change"
  return 0
}

# Codenames of the Ubuntu releases serving version $2 of $1; empty when unknown.
pkg_version_ubuntu_codenames() {
  madison_rows "$1" | awk -F'|' -v v="$2" -v re="$UBUNTU_HOSTS_RE" '
    $1 == v && $2 ~ re { split($2, f, " "); sub(/\/.*/, "", f[2]); sub(/-updates$/, "", f[2]); print f[2] }' \
    | sort -u
}

# The release the Ubuntu pin $1 (default: UBUNTU_PIN) names; empty without one.
pinned_codename() { sed -n 's/^Pin: release o=Ubuntu, n=//p' "${1:-$UBUNTU_PIN}" 2>/dev/null | head -1; }

# Without a pin, write one that blocks every Ubuntu package. Returns 0 =
# written, 1 = a pin exists, 2 = the file could not be written.
write_provisional_pin() {
  [ ! -f "$UBUNTU_PIN" ] || return 1
  printf '%s\n' \
    "# provisional — written before the Ubuntu sources, replaced once the codename resolves" \
    "Package: *" \
    "Pin: release o=Ubuntu" \
    "Pin-Priority: -1" | sudo_tee "$UBUNTU_PIN" \
    || { sudo rm -f "$UBUNTU_PIN"; return 2; }
}

# Write the Ubuntu pin for UBUNTU_CODENAME to $1 (default: UBUNTU_PIN).
# Returns 0 when the file changed, 1 when already current, 2 when it could
# not be written.
write_ubuntu_pin() {
  local tmp dest="${1:-$UBUNTU_PIN}"
  tmp="$(mktemp)"
  cat << EOF > "$tmp"
# pin-version: ${PIN_VERSION}
# Written by ubuntu-look.sh. Every Ubuntu package is blocked (-1) except the
# look, which comes from one release. Debian's builds it replaces are put back
# by 'ubuntu-look.sh --uninstall'.
Package: *
Pin: release o=Ubuntu
Pin-Priority: -1

Package: ${UBUNTU_PINNED_PACKAGES} ubuntu-wallpapers-${UBUNTU_CODENAME}
Pin: release o=Ubuntu, n=${UBUNTU_CODENAME}
Pin-Priority: 990
EOF
  local rc
  if [ "$dest" = "$UBUNTU_PIN" ]; then sudo_install_if_changed "$tmp" "$dest"; rc=$?
  else install_if_changed "$tmp" "$dest"; rc=$?; fi
  rm -f "$tmp"
  [ "$rc" -ne 2 ] || STATUS_FAILED+=("Could not write the Ubuntu pin ${dest}")
  return "$rc"
}

# The package list, manual marks and config-files list before this script
# installs anything, taken once. Any failed query or write stops the run
# before PACKAGES_BEFORE, whose presence marks the snapshot complete; the
# build keyring's manifest entry, written first, is added only once.
record_packages_before() {
  [ ! -f "$PACKAGES_BEFORE" ] || return 0
  local tmp ok=0 build_keyring=0
  # A keyring a stopped --download installed for its build is the script's:
  # left out of the snapshot and recorded as installed, the uninstall removes it.
  [ -e "${DOWNLOAD_SAVED}/keyring-for-build" ] && is_installed ubuntu-keyring && build_keyring=1
  tmp="$(mktemp -d)" || error "Could not take the pre-install package snapshot."
  # pipefail: a failed query must not pass as an empty list.
  if ( set -o pipefail
       apt-mark showmanual 2>/dev/null | sort > "${tmp}/manual" \
       && dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
            | awk '$4 == "config-files" { print $1 }' | sort > "${tmp}/config" \
       && installed_package_list > "${tmp}/installed" && [ -s "${tmp}/installed" ] ) \
     && { [ "$build_keyring" = 0 ] \
          || sed -i '/^ubuntu-keyring$/d' "${tmp}/installed" "${tmp}/manual"; } \
     && sys_records_dir \
     && { [ "$build_keyring" = 0 ] || grep -qxF ubuntu-keyring "$INSTALLED_MANIFEST" 2>/dev/null \
          || sys_record_append "$INSTALLED_MANIFEST" ubuntu-keyring; } \
     && sudo_write_atomic "${tmp}/manual" "$MANUAL_BEFORE" \
     && sudo_write_atomic "${tmp}/config" "$CONFIG_FILES_BEFORE" \
     && sudo_write_atomic "${tmp}/installed" "$PACKAGES_BEFORE"; then
    ok=1
  fi
  rm -rf "$tmp"
  [ "$ok" = 1 ] || error "Could not take the pre-install package snapshot in ${SYS_RECORDS}; nothing was installed. Run this again."
  STATUS_CHANGES+=("Pre-install package list saved → ${PACKAGES_BEFORE}")
}

# Configure the releases $1 beside the window, oldest first as the source's
# header lists them, and resolve again.
try_older_releases() {
  local window="$UBUNTU_CANDIDATE_CODENAMES"
  message "trying other releases: $1"
  # shellcheck disable=SC2086
  UBUNTU_CANDIDATE_CODENAMES="$(codenames_by_version $1 $window)"
  if write_ubuntu_sources; then apt_update_ubuntu_only || true; fi
  # The window was tried already; only the older releases are simulated.
  UBUNTU_CODENAME="$(UBUNTU_CANDIDATE_CODENAMES="$1" resolve_ubuntu_codename)"
  if [ -n "$UBUNTU_CODENAME" ]; then
    # Keep only the release found, beside the window.
    # shellcheck disable=SC2086
    UBUNTU_CANDIDATE_CODENAMES="$(codenames_by_version "$UBUNTU_CODENAME" $window)"
    STATUS_CHANGES+=("Reached back to ${UBUNTU_CODENAME} for a GNOME Shell-compatible theme")
  else
    UBUNTU_CANDIDATE_CODENAMES="$window"
  fi
}

# Set UBUNTU_CODENAME to the newest release whose theme and dock install here.
# Else: the newest release when gnome-shell is newer than every release;
# otherwise the release pinned before ($1), older listed ones, retired ones;
# finally the release pinned before, if still published, or the oldest
# candidate.
resolve_release() {
  local hint="$1" older newest debian_shell newest_shell pinned_info
  UBUNTU_CODENAME="$(resolve_ubuntu_codename)"

  if [ -z "$UBUNTU_CODENAME" ]; then
    newest="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $NF}')"
    debian_shell="$(shell_major)"
    newest_shell="$(ubuntu_shell_major "$newest")"
    if [ -n "$debian_shell" ] && [ -n "$newest_shell" ] && [ "$debian_shell" -gt "$newest_shell" ]; then
      UBUNTU_CODENAME="$newest"
      message warn "GNOME Shell ${debian_shell} is newer than any released Ubuntu — using the newest, ${UBUNTU_CODENAME}"
      [ "$UBUNTU_INCLUDE_DEVEL" = 1 ] \
        || message warn "  a development release may support it: UBUNTU_INCLUDE_DEVEL=1 bash ubuntu-look.sh"
      return 0
    fi
    message warn "no Ubuntu release in the current window has a theme this GNOME Shell can load"
    # The release pinned before, unless it is a development release the
    # options no longer allow.
    if [[ "$hint" =~ ^[a-z]+$ ]] && ! in_word_list "$hint" "$UBUNTU_CANDIDATE_CODENAMES" \
       && { [ "$UBUNTU_INCLUDE_DEVEL" = 1 ] || [[ "$(ubuntu_release_info "$hint" 2>/dev/null)" != *" devel "* ]]; }; then
      try_older_releases "$hint"
    fi
    if [ -z "$UBUNTU_CODENAME" ]; then
      older="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' \
        | head -n -"$MAX_UBUNTU_CANDIDATES" | tail -n "$MAX_UBUNTU_LOOKBACK" | xargs)"
      # The hint was tried above.
      older="$(word_list_without "$older" "$hint" | xargs)"
      [ -n "$older" ] && try_older_releases "$older"
    fi
    if [ -z "$UBUNTU_CODENAME" ]; then
      older="$(discover_retired_codenames)" || exit 1
      [ -n "$older" ] && try_older_releases "$older"
    fi
  fi
  if [ -z "$UBUNTU_CODENAME" ]; then
    local info_rc=1
    if [[ "$hint" =~ ^[a-z]+$ ]]; then
      pinned_info="$(ubuntu_release_info "$hint")"; info_rc=$?
      [ "$info_rc" -eq 2 ] && { release_unread "$hint"; exit 1; }
    fi
    if [ "$info_rc" -eq 0 ] \
       && { [ "$UBUNTU_INCLUDE_DEVEL" = 1 ] || [[ "$pinned_info" != *" devel "* ]]; }; then
      UBUNTU_CODENAME="$hint"
      # shellcheck disable=SC2086
      in_word_list "$hint" "$UBUNTU_CANDIDATE_CODENAMES" \
        || UBUNTU_CANDIDATE_CODENAMES="$(codenames_by_version $UBUNTU_CANDIDATE_CODENAMES "$hint")"
    else
      UBUNTU_CODENAME="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $1}')"
    fi
    message warn "no Ubuntu release ships a shell theme for this GNOME Shell — using ${UBUNTU_CODENAME}"
    return 0
  fi
  message "resolved Ubuntu release: ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} ($(gnome-shell --version 2>/dev/null || echo 'GNOME Shell not installed')) — verified via simulated install"
}

# gnome-shell major of Ubuntu release $1.
ubuntu_shell_major() {
  local v
  v="$(release_build gnome-shell "$1")"
  printf '%s' "${v%%.*}"
}

# Put back the Ubuntu apt source saved in PREV_UBUNTU_SOURCES, and drop a
# provisional pin this run wrote.
restore_prev_ubuntu_sources() {
  if [ -s "$PREV_UBUNTU_SOURCES" ]; then
    # A failed restore keeps the saved copy and names it.
    if sudo_write_atomic "$PREV_UBUNTU_SOURCES" "$UBUNTU_SOURCES"; then
      rm -f "$PREV_UBUNTU_SOURCES"
    else
      message warn "could not put back ${UBUNTU_SOURCES} — the previous one is kept at ${PREV_UBUNTU_SOURCES}"
    fi
  else
    sudo rm -f "$UBUNTU_SOURCES"
    rm -f "$PREV_UBUNTU_SOURCES"
  fi
  [ "${PROVISIONAL_PIN_NEW:-0}" = 1 ] && sudo rm -f "$UBUNTU_PIN"
  return 0
}

# Record that $1 replaced version $2, so the uninstall reinstalls it. Only a
# version that predates the install or is Debian's is recorded; the first entry
# per package is kept. Non-zero when the record could not be written.
record_upgraded_pkg() {
  local pkg="$1" was="$2"
  [ -n "$pkg" ] && [ -n "$was" ] || return 0
  awk -v p="$pkg" '$1 == p { f = 1 } END { exit !f }' "$UPGRADED_MANIFEST" 2>/dev/null && return 0
  grep -qxF "$pkg" "$INSTALLED_MANIFEST" 2>/dev/null && return 0
  predates_install "$pkg" || pkg_version_is_debian "$pkg" "$was" || return 0
  sys_record_append "$UPGRADED_MANIFEST" "${pkg} ${was}" && sys_record_sort "$UPGRADED_MANIFEST"
}

###############################################################################
# 3. Desktop: Ubuntu's settings, extensions, terminal, login screen
###############################################################################

# Print the look profile: the system's user profile, then the look database
# last, so the system's own databases come first. user-db:user leads when
# that profile has no user database.
look_profile_content() {
  local base=""
  # dconf's own search order: /etc, then the system data directories.
  for base in "$DCONF_USER_PROFILE" /usr/local/share/dconf/profile/user \
              /usr/share/dconf/profile/user ""; do
    [ -z "$base" ] || [ -f "$base" ] && break
  done
  [ -n "$base" ] && grep -q '^user-db:' "$base" 2>/dev/null || echo 'user-db:user'
  [ -n "$base" ] && grep '' "$base"
  printf 'system-db:%s\n' "$LOOK_DB_NAME"
}

# Write the look profile atomically: a partial profile would leave sessions
# without their user database. Returns 0 = changed, 1 = current, 2 = failed.
write_look_profile() {
  local tmp rc
  # A pending boot-time removal would delete the new profile. The directory it
  # was to remove too was the install's: that stays on record.
  if [ -f "$LOOK_CLEANUP_CONF" ]; then
    grep -qxF 'r /etc/dconf/profile' "$LOOK_CLEANUP_CONF" 2>/dev/null \
      && sys_records_dir && sudo touch "$DCONF_PROFILE_DIR_MADE"
    sudo rm -f "$LOOK_CLEANUP_CONF"
  fi
  tmp="$(mktemp)" || return 2
  look_profile_content > "$tmp" || { rm -f "$tmp"; return 2; }
  if [ ! -d /etc/dconf/profile ]; then
    sys_records_dir; sudo touch "$DCONF_PROFILE_DIR_MADE"
    sudo install -d -m 0755 /etc/dconf/profile || { rm -f "$tmp"; return 2; }
  fi
  sudo_install_if_changed "$tmp" "$LOOK_PROFILE"; rc=$?
  rm -f "$tmp"
  return $rc
}

# True when the look profile is in place with a user database, so a session
# pointed at it keeps the user's own settings.
look_profile_usable() {
  readable_regular_file "$LOOK_PROFILE" && grep -q '^user-db:' "$LOOK_PROFILE"
}

# Mask session-migration. Returns 0 = masked now, 1 = already masked,
# 2 = failed or an admin's own unit file is there.
mask_session_migration() {
  [ "$(readlink "$SESSION_MIGRATION_MASK" 2>/dev/null)" = /dev/null ] && return 1
  [ -e "$SESSION_MIGRATION_MASK" ] || [ -L "$SESSION_MIGRATION_MASK" ] && return 2
  sys_records_dir && sudo touch "$SESSION_MIGRATION_MASKED" || return 2
  sudo mkdir -p "${SESSION_MIGRATION_MASK%/*}" \
    && sudo ln -s /dev/null "$SESSION_MIGRATION_MASK" && return 0
  sudo rm -f "$SESSION_MIGRATION_MASKED"
  return 2
}

# Make this user's sessions read the look profile from the next login.
# Returns 0 = changed, 1 = current, 2 = failed.
enable_look_for_user() {
  local want have
  want="# Written by ubuntu-look.sh; removed by 'ubuntu-look.sh --uninstall'.
DCONF_PROFILE=${LOOK_PROFILE_NAME}"
  have="$(cat "$LOOK_ENV_FILE" 2>/dev/null)"
  [ "$have" = "$want" ] && return 1
  mkdir -p "${LOOK_ENV_FILE%/*}" && printf '%s\n' "$want" > "$LOOK_ENV_FILE" && return 0
  return 2
}

# The valid extension uuids (name@domain) in the dconf string array at key $1.
extension_uuids() {
  local e out=""
  for e in $(dconf_array_items "$1"); do
    case "$e" in ?*@?*) out="$out $e" ;; esac
  done
  echo "$out"
}

# True when Ubuntu Dock is installed and built for the installed gnome-shell.
ubuntu_dock_usable() {
  local bound major pkg=gnome-shell-extension-ubuntu-dock
  is_installed "$COMBINED_EXT_PKG" && pkg="$COMBINED_EXT_PKG"
  is_installed "$pkg" || return 1
  bound="$(pkg_shell_upper_bound "$pkg")"
  [ -n "$bound" ] || return 0
  major="$(shell_major)"
  [ -n "$major" ] && [ "$major" -lt "$bound" ]
}

# Turn back on a Dash-to-Dock this script turned off, as Ubuntu Dock cannot run:
# in a session through ENABLE_ADD, otherwise at the next login.
dash_to_dock_back_on() {
  [ -f "$DASH_TO_DOCK_OFF" ] || return 0
  if ! extension_installed "$DASH_TO_DOCK_UUID"; then
    rm -f "$DASH_TO_DOCK_OFF"
    return 0
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DASH_TO_DOCK_PENDING=1
    STATUS_CHANGES+=("Dash-to-Dock is turned back on at your next login — Ubuntu Dock cannot run on this GNOME Shell")
    return 0
  fi
  ENABLE_ADD="$DASH_TO_DOCK_UUID"
}

# Ubuntu Dock stands aside while Dash-to-Dock is on, so turn that off for this
# user (the uninstall turns it back on): through ENABLE_DROP when the running
# shell knows Ubuntu Dock, otherwise at the next login.
turn_off_dash_to_dock() {
  local en
  if ! ubuntu_dock_usable; then dash_to_dock_back_on; return 0; fi
  # Only with Ubuntu's defaults, on the first install: a Dash-to-Dock the user
  # turns on later is their choice, which re-runs keep.
  [ -f "$DEFAULTS_PENDING" ] || return 0
  en="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  in_word_list "$DASH_TO_DOCK_UUID" "$en" || return 0
  mkdir -p "$BACKUP_DIR" && touch "$DASH_TO_DOCK_OFF"
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
     || ! LC_ALL=C gnome-extensions info ubuntu-dock@ubuntu.com > /dev/null 2>&1; then
    DASH_TO_DOCK_PENDING=1
    STATUS_CHANGES+=("Dash-to-Dock is turned off at your next login — Ubuntu Dock takes its place")
    return 0
  fi
  ENABLE_DROP="$DASH_TO_DOCK_UUID"
}

# Report the Dash-to-Dock switch; $1 is enable_shell_extensions' result.
dash_to_dock_status() {
  if in_word_list "$DASH_TO_DOCK_UUID" "$ENABLE_DROP"; then
    if [ "$1" -eq 0 ]; then
      STATUS_CHANGES+=("Dash-to-Dock turned off for you — Ubuntu Dock takes its place; the uninstall turns it back on")
    else
      STATUS_FAILED+=("Dash-to-Dock could not be turned off — Ubuntu Dock stays hidden while it is on")
    fi
  elif in_word_list "$DASH_TO_DOCK_UUID" "$ENABLE_ADD"; then
    if [ "$1" -eq 0 ]; then
      rm -f "$DASH_TO_DOCK_OFF"
      STATUS_CHANGES+=("Dash-to-Dock turned back on — Ubuntu Dock cannot run on this GNOME Shell")
    else
      STATUS_FAILED+=("Dash-to-Dock could not be turned back on — Ubuntu Dock cannot run on this GNOME Shell")
    fi
  fi
}

# Enable extensions $@ and those in ENABLE_ADD in the user's dconf database,
# keeping the others, and take those in ENABLE_DROP off, in one write.
# Returns 1 when it fails.
enable_shell_extensions() {
  # shellcheck disable=SC2086
  set -- $ENABLE_ADD "$@"
  local own now merged keep="" e dis
  # Start from the user's own list, not the one the defaults supply.
  own="$(user_dconf_read /org/gnome/shell/enabled-extensions)"
  now="$(array_items "$own" | xargs)"
  # An optional extension this release does not ship leaves the list, as it
  # does the defaults; otherwise, with nothing to add or drop, nothing changes.
  [ $# -gt 0 ] || [ -n "$ENABLE_DROP" ] \
    || [ "$(present_extensions "$now")" != "$now" ] || return 0
  command -v dconf >/dev/null 2>&1 || return 1

  [ -n "$own" ] || now="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  merged="$(echo "$(present_extensions "$now") $*" | tr ' ' '\n' \
    | awk -v drop=" $ENABLE_DROP " 'NF && !seen[$0]++ && !index(drop, " " $0 " ")' | tr '\n' ' ')"
  # Skip an unchanged list: no needless write.
  if [ -z "$own" ] || [ "$(echo $now)" != "$(echo $merged)" ]; then
    dconf write /org/gnome/shell/enabled-extensions "$(gvariant_string_array "$merged")" 2>/dev/null || return 1
  fi

  dis="$(extension_uuids /org/gnome/shell/disabled-extensions)"
  for e in $dis; do in_word_list "$e" "$*" || keep="$keep $e"; done
  [ "$(echo $keep)" = "$(echo $dis)" ] && return 0
  # A failed write is reported only when it was to turn Dash-to-Dock back on.
  dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$keep")" 2>/dev/null \
    || [ -z "$ENABLE_ADD" ] || return 1
}

# True when extension $1 is installed system-wide, under /usr/local, or for this user.
extension_installed() {
  [ -d "/usr/share/gnome-shell/extensions/$1" ] \
    || [ -d "${LOCAL_EXT_DIR}/$1" ] \
    || [ -d "${DATA_HOME}/gnome-shell/extensions/$1" ]
}

# True when $1 is an extension only some Ubuntu releases ship and it is not installed.
optional_extension_missing() {
  in_word_list "$1" "$OPTIONAL_SHELL_EXTENSIONS" && ! extension_installed "$1"
}

# The extensions in list $1 without those optional_extension_missing names.
present_extensions() {
  local e out=""
  for e in $1; do optional_extension_missing "$e" || out="$out $e"; done
  echo $out
}

# True when gnome-shell reports extension $1 as running; older GNOME Shell
# versions call that state ENABLED, newer ones ACTIVE.
EXT_RUNNING_RE='State: (ACTIVE|ENABLED)$'
extension_active() { LC_ALL=C gnome-extensions info "$1" 2>/dev/null | grep -qE "$EXT_RUNNING_RE"; }

# The look's installed extensions not yet switched on for this user; with
# "all", also those not installed, except the ones only some releases ship.
extensions_to_switch_on() {
  local e out=""
  for e in $SHELL_EXTENSIONS; do
    if [ "${1:-}" != all ] || in_word_list "$e" "$OPTIONAL_SHELL_EXTENSIONS"; then
      extension_installed "$e" || continue
    fi
    grep -qxF "$e" "$EXTENSIONS_ON_RECORD" 2>/dev/null || out="${out} ${e}"
  done
  echo $out
}

# Record extensions $@ as switched on once for this user.
record_extensions_on() {
  [ $# -gt 0 ] || return 0
  mkdir -p "$BACKUP_DIR" && printf '%s\n' "$@" >> "$EXTENSIONS_ON_RECORD"
}

# Remove the one-shot autostart entry, its script, retry mark and directory.
remove_extension_autostart() {
  rm -f "$EXT_AUTOSTART_FILE" "$EXT_AUTOSTART_SCRIPT" "${EXT_AUTOSTART_SCRIPT}.retry"
  rmdir "${EXT_AUTOSTART_SCRIPT%/*}" 2>/dev/null || true
}

# Install the login helper: at each login of a user of the look, the look's
# installed extensions never switched on for that user are switched on once
# and recorded, so one a later release adds reaches every user, as Ubuntu's
# defaults do. One the user turned off stays off. Returns 0 = written,
# 1 = current, 2 = failed.
install_login_helper() {
  local tmp rc=1 r
  tmp="$(mktemp -d)" || return 2
  cat << HELPER > "${tmp}/helper"
#!/bin/sh
# Written by ubuntu-look.sh; removed by its uninstall.
[ "\${DCONF_PROFILE:-}" = ${LOOK_PROFILE_NAME} ] || exit 0
rec="\${HOME}/${EXTENSIONS_ON_RECORD#"${HOME:-}/"}"
[ -f "\$rec" ] || exit 0
# This user's one-shot entry, where still in place, switches them on itself.
[ -e "\${XDG_CONFIG_HOME:-\$HOME/.config}/autostart/${EXT_AUTOSTART_FILE##*/}" ] && exit 0
# Wait up to 30 seconds for the shell to answer.
for _i in \$(seq 1 30); do
  gnome-extensions list >/dev/null 2>&1 && break
  sleep 1
done
# Ubuntu Dock stays off while this user's Dash-to-Dock is on.
dtd=0
dconf read /org/gnome/shell/enabled-extensions 2>/dev/null \
  | grep -qF "'${DASH_TO_DOCK_UUID}'" && dtd=1
for e in ${SHELL_EXTENSIONS}; do
  grep -qxF "\$e" "\$rec" && continue
  [ "\$e" = ubuntu-dock@ubuntu.com ] && [ "\$dtd" = 1 ] && continue
  [ -d "/usr/share/gnome-shell/extensions/\$e" ] || [ -d "${LOCAL_EXT_DIR}/\$e" ] || continue
  gnome-extensions enable "\$e" 2>/dev/null && printf '%s\n' "\$e" >> "\$rec"
done
exit 0
HELPER
  cat << ENTRY > "${tmp}/entry"
[Desktop Entry]
Type=Application
Name=ubuntu-look: new extensions
Comment=Switches on the Ubuntu look's extensions a newer release adds
Exec=${LOGIN_HELPER}
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
ENTRY
  # The helper runs, so 0755.
  if [ -f "$LOGIN_HELPER" ] && cmp -s "${tmp}/helper" "$LOGIN_HELPER"; then r=1
  elif sudo_write_atomic "${tmp}/helper" "$LOGIN_HELPER" 0755; then r=0
  else r=2; fi
  rc=$r
  if [ "$r" != 2 ]; then
    sudo_install_if_changed "${tmp}/entry" "$LOGIN_HELPER_ENTRY"; r=$?
    [ "$r" = 0 ] && rc=0
    [ "$r" = 2 ] && rc=2
  fi
  rm -rf "$tmp"
  return "$rc"
}

# Enable the extensions at the next login through a one-shot autostart entry;
# a running Wayland shell cannot rescan them.
install_extension_autostart() {
  local script="$EXT_AUTOSTART_SCRIPT" dir="${EXT_AUTOSTART_SCRIPT%/*}"
  local desktop="$EXT_AUTOSTART_FILE" retry="${EXT_AUTOSTART_SCRIPT}.retry"
  local todo tmp e all_on=1 want="$EXT_RUNNING_RE" dtd _wrote=0 _rc
  todo="$(extensions_to_switch_on)"
  if [ -z "$todo" ] && [ "$DASH_TO_DOCK_PENDING" != 1 ]; then
    remove_extension_autostart
    [ "$EXT_RECORDED" = 1 ] || [ ! -s "$EXTENSIONS_ON_RECORD" ] \
      || STATUS_NOCHANGE+=("Extensions were switched on before — any you turn off later stay off")
    return 0
  fi

  # Nothing to schedule when the running session has all of them on and
  # Dash-to-Dock needs no switch at login.
  if [ "$DASH_TO_DOCK_PENDING" != 1 ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
     && command -v gnome-extensions >/dev/null 2>&1; then
    # A locked screen switches extensions off until unlock.
    gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver \
      --method org.gnome.ScreenSaver.GetActive 2>/dev/null | grep -q true \
      && want='Enabled: Yes|State: ENABLED$'
    for e in $todo; do
      LC_ALL=C gnome-extensions info "$e" 2>/dev/null | grep -qE "$want" || { all_on=0; break; }
    done
    if [ $all_on -eq 1 ]; then
      # shellcheck disable=SC2086
      record_extensions_on $todo
      remove_extension_autostart
      STATUS_NOCHANGE+=("Extensions are already on — no autostart entry needed")
      return 0
    fi
  fi

  # Ubuntu Dock stands aside while Dash-to-Dock is on; where Ubuntu Dock
  # cannot run, Dash-to-Dock goes back on instead.
  if ubuntu_dock_usable; then
    dtd="gnome-extensions disable ${DASH_TO_DOCK_UUID} 2>/dev/null || true"
  else
    dtd="gnome-extensions enable ${DASH_TO_DOCK_UUID} 2>/dev/null && rm -f \"${DASH_TO_DOCK_OFF}\""
  fi
  tmp="$(mktemp)"

  cat << EOF > "$tmp"
#!/bin/bash
# One-shot, written by ubuntu-look.sh: switches on the look's extensions at
# login, then removes itself. One that fails is tried once more at the next
# login.
SHELL_EXTENSIONS="${todo}"

# Wait up to 30 seconds for the shell to answer about an extension.
for _i in \$(seq 1 30); do
  for _e in \$SHELL_EXTENSIONS ${DASH_TO_DOCK_UUID}; do
    gnome-extensions info "\$_e" >/dev/null 2>&1 && break 2
  done
  sleep 1
done

# Dash-to-Dock, as the install recorded it; on the first login only.
if [ -f "${DASH_TO_DOCK_OFF}" ] && [ ! -f "${retry}" ]; then
  ${dtd}
fi

# Enable through gnome-shell only; a dconf write as well would enable an
# extension twice. Each one switched on is recorded: switched on once, the
# user's later choices stand.
tried=""
failed=0
for e in \$SHELL_EXTENSIONS; do
  grep -qxF "\$e" "${EXTENSIONS_ON_RECORD}" 2>/dev/null && continue
  tried="\${tried} \$e"
  if gnome-extensions enable "\$e" 2>/dev/null; then
    mkdir -p "${BACKUP_DIR}" && printf '%s\\n' "\$e" >> "${EXTENSIONS_ON_RECORD}"
  else
    failed=1
  fi
done

# Fallback: remove any tried now still listed in disabled-extensions.
keep=""
still=0
for e in \$(dconf read /org/gnome/shell/disabled-extensions 2>/dev/null \\
            | sed 's/^@[a-z]* //' | tr -d "[]' " | tr ',' ' '); do
  case " \$tried " in
    *" \$e "*) still=1 ;;
    *)          keep="\${keep}'\$e'," ;;
  esac
done
if [ "\$still" = 1 ]; then
  # if/else: a failed write must not fall through to the empty list.
  if [ -n "\$keep" ]; then
    dconf write /org/gnome/shell/disabled-extensions "[\${keep%,}]" 2>/dev/null || true
  else
    dconf write /org/gnome/shell/disabled-extensions "@as []" 2>/dev/null || true
  fi
fi

# Kept for one more login when an extension did not switch on.
if [ "\$failed" = 1 ] && [ ! -f "${retry}" ]; then
  : > "${retry}"
  exit 0
fi
rm -f "${desktop}" "${script}" "${retry}"
rmdir "${dir}" 2>/dev/null || true
EOF
  install_if_changed "$tmp" "$script"; _rc=$?
  [ "$_rc" -eq 0 ] && _wrote=1
  if [ "$_rc" -eq 2 ]; then
    rm -f "$tmp"
    STATUS_FAILED+=("Could not write ${script} — extensions will not be switched on automatically")
    return 0
  fi
  # install_if_changed writes 0644.
  chmod 0755 "$script" 2>/dev/null || true

  cat << EOF > "$tmp"
[Desktop Entry]
Type=Application
Name=ubuntu-look: enable extensions
Comment=Finishes the Ubuntu look's extension setup once, then removes itself
Exec="${script}"
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
  install_if_changed "$tmp" "$desktop"; _rc=$?
  [ "$_rc" -eq 0 ] && _wrote=1
  rm -f "$tmp"
  if [ "$_rc" -eq 2 ]; then
    STATUS_FAILED+=("Could not write ${desktop} — extensions will not be switched on automatically")
    return 0
  fi
  # Each run's entry gets its own retry.
  rm -f "$retry"

  if [ "$_wrote" -eq 1 ]; then
    if [ -n "$todo" ]; then
      STATUS_CHANGES+=("Extensions will be switched on at your next login (one-shot, self-removing)")
    else
      STATUS_CHANGES+=("Your next login finishes the extension changes above (one-shot, self-removing)")
    fi
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("The one-shot extension autostart is already in place")
  fi
}

# Reset the user's value of dconf key $1/$2 when it equals the look's default;
# a changed one is kept and named in the summary. Run only when the session
# reads the look profile.
reclaim_dconf_key() {
  local path="$1" key="$2"
  local full="/${path}/${key}" effective default
  command -v dconf >/dev/null 2>&1 || return 0

  # No value of the user's: the profile answers already.
  if [ -z "$(user_dconf_read "$full")" ]; then
    GSETTINGS_UNCHANGED=$((GSETTINGS_UNCHANGED + 1))
    return 0
  fi
  effective="$(dconf read "$full" 2>/dev/null)"
  default="$(dconf read -d "$full" 2>/dev/null)"

  if [ "$effective" = "$default" ]; then
    # A stored copy of the default goes; the effective value stays.
    dconf reset "$full" 2>/dev/null && GSETTINGS_RECLAIMED=$((GSETTINGS_RECLAIMED + 1))
    GSETTINGS_UNCHANGED=$((GSETTINGS_UNCHANGED + 1))
  else
    SETTINGS_KEPT+=("${full} — yours: ${effective:-unset}, Ubuntu's: ${default:-unset}")
  fi
}

# Fit the table's fonts to the release, once per run. An older fonts-ubuntu
# has no "Ubuntu Sans"; its fonts are "Ubuntu" and "Ubuntu Mono 13".
fit_fonts_to_release() {
  [ "$FONTS_FITTED" = 1 ] && return 0
  FONTS_FITTED=1
  local i major
  if command -v fc-list >/dev/null 2>&1 && ! fc-list -q 'Ubuntu Sans' \
     && fc-list -q 'Ubuntu'; then
    for i in "${!GNOME_SETTINGS[@]}"; do
      GNOME_SETTINGS[i]="${GNOME_SETTINGS[i]//Ubuntu Sans Mono/Ubuntu Mono}"
      GNOME_SETTINGS[i]="${GNOME_SETTINGS[i]//Ubuntu Sans/Ubuntu}"
    done
    return 0
  fi
  # Ubuntu's monospace size by release: 11 with GNOME 49 and later, 13 before.
  major="$(shell_major)"
  [ "${major:-0}" -ge 49 ] || return 0
  for i in "${!GNOME_SETTINGS[@]}"; do
    GNOME_SETTINGS[i]="${GNOME_SETTINGS[i]//Ubuntu Sans Mono 13/Ubuntu Sans Mono 11}"
  done
}

# Render GNOME_SETTINGS as dconf keyfile groups.
render_dconf_groups() {
  local line last_path="" path key value
  fit_fonts_to_release
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    # Ubuntu's session enables only the extensions its release ships.
    [ "$key" = enabled-extensions ] \
      && value="$(gvariant_string_array "$(present_extensions "$SHELL_EXTENSIONS")")"
    if [ "$path" != "$last_path" ]; then
      [ -n "$last_path" ] && echo ""
      echo "[${path}]"
      last_path="$path"
    fi
    echo "${key}=${value}"
  done
}

# True when this user's running gnome-shell reads the look profile.
session_on_look_profile() {
  local pid
  pid="$(pgrep -u "$(id -u)" -x gnome-shell 2>/dev/null | head -1)"
  [ -n "$pid" ] && tr '\0' '\n' 2>/dev/null < "/proc/${pid}/environ" \
    | grep -qxF "DCONF_PROFILE=${LOOK_PROFILE_NAME}"
}

# Hand the table's keys and the wallpaper keys back to the look profile,
# keeping the user's own values.
reclaim_live_settings() {
  local line path key value
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    case "$DCONF_ONLY_KEYS" in *" $key "*) continue ;; esac
    # Yaru-dark and the accent variants (Yaru-purple, ...) are the theme
    # extension's values for the colour scheme and the accent colour.
    case "$key" in
      gtk-theme|icon-theme)
        case "$(dconf read "/${path}/${key}" 2>/dev/null)" in "'Yaru-"*) continue ;; esac ;;
    esac
    reclaim_dconf_key "$path" "$key"
  done
  for line in "${WALLPAPER_KEYS[@]}"; do
    IFS='|' read -r path key <<< "$line"
    # Without Ubuntu's wallpaper the look sets none: the user's own stays.
    [ -n "$(dconf read -d "/${path}/${key}" 2>/dev/null)" ] || continue
    reclaim_dconf_key "$path" "$key"
  done
}

# Every key the look sets or clears, as "<path> <key>", the colour scheme
# first, so a running theme extension picks the theme from it before the
# other keys go. The extension list and the dock have their own steps.
look_keys() {
  local line path key
  for line in "$COLOR_SCHEME_KEY" "${GNOME_SETTINGS[@]}" "${WALLPAPER_KEYS[@]}"; do
    IFS='|' read -r path key _ <<< "$line"
    case "$DCONF_ONLY_KEYS" in *" $key "*) continue ;; esac
    [ "$path" = org/gnome/shell/extensions/dash-to-dock ] && continue
    echo "$path $key"
  done
}

# Fresh install: clear the user's own values of the look's keys, the wallpaper
# and the dock, so Ubuntu's defaults apply. Dock favourites stay.
apply_ubuntu_defaults() {
  local path key value cleared="" failed=0
  command -v dconf >/dev/null 2>&1 || return 1
  while read -r path key; do
    value="$(user_dconf_read "/${path}/${key}")"
    [ -n "$value" ] || continue
    # Without Ubuntu's wallpaper the look sets none: the user's own stays.
    case "$key" in
      picture-uri|picture-uri-dark)
        [ -n "$(DCONF_PROFILE="$LOOK_PROFILE_NAME" dconf read -d "/${path}/${key}" 2>/dev/null)" ] || continue ;;
    esac
    dconf reset "/${path}/${key}" 2>/dev/null || { failed=1; continue; }
    # A stored copy of Ubuntu's own value (one an app wrote) is no loss.
    [ "$value" = "$(DCONF_PROFILE="$LOOK_PROFILE_NAME" dconf read -d "/${path}/${key}" 2>/dev/null)" ] \
      && continue
    # The two picture-uri keys, the desktop's and the lock screen's, by group.
    case "$key" in picture-uri*) key="${path##*/} ${key}" ;; esac
    cleared="${cleared}${cleared:+, }${key}"
  done < <(look_keys)
  # The whole dock, including settings the table does not list.
  if [ -n "$(user_dconf dump /org/gnome/shell/extensions/dash-to-dock/)" ]; then
    if dconf reset -f /org/gnome/shell/extensions/dash-to-dock/ 2>/dev/null; then
      cleared="${cleared}${cleared:+, }dock settings"
    else
      failed=1
    fi
  fi
  if [ "$failed" -eq 1 ]; then
    STATUS_FAILED+=("Some of your settings could not be cleared for Ubuntu's defaults — re-run to retry")
    return 1
  fi
  # A forced-dark GTK setting goes with them; one set later is the user's.
  local f
  for f in "${CONFIG_HOME}/gtk-3.0/settings.ini" "${CONFIG_HOME}/gtk-4.0/settings.ini"; do
    grep -qs '^gtk-application-prefer-dark-theme=1$' "$f" || continue
    sed -i --follow-symlinks '/^gtk-application-prefer-dark-theme=1$/d' "$f"
    # A symlink (a dotfiles repository, say) stays even when empty.
    [ -z "$(grep -v '^\[Settings\]$' "$f" | tr -d '[:space:]')" ] && { [ -L "$f" ] || rm -f "$f"; }
    STATUS_CHANGES+=("Removed gtk-application-prefer-dark-theme=1 from $(basename "$(dirname "$f")") — Ubuntu's default is light")
    RELOGIN_NEEDED=1
  done
  rm -f "$DEFAULTS_PENDING"
  if [ -n "$cleared" ]; then
    STATUS_CHANGES+=("Ubuntu's defaults replace your own: ${cleared} — dock favourites kept; the uninstall returns Debian's defaults")
    # A session already on the look profile shows Ubuntu's values at once.
    session_on_look_profile || RELOGIN_NEEDED=1
  fi
}

# A blank line and the background group for wallpapers $1 (light) and $2
# (dark); a missing dark wallpaper falls back to the light one.
background_group() {
  local dark="$2"
  [ -f "$dark" ] || dark="$1"
  printf "\n[org/gnome/desktop/background]\npicture-uri='file://%s'\npicture-uri-dark='file://%s'" "$1" "$dark"
}

# The system side of the look: Ubuntu's defaults database, the look profile
# and the session-migration mask. Returns 0 when the look profile was written
# (or current) and usable, so the user may be switched to it; 1 otherwise.
write_dconf_profile() {
  local wp_light="$1" wp_dark="$2" bg_block="" profile_rc
  # Background keys only when the wallpaper file exists.
  if [ -f "$wp_light" ]; then
    bg_block="$(background_group "$wp_light" "$wp_dark")

[org/gnome/desktop/screensaver]
picture-uri='file://${wp_light}'"
  else
    message warn "wallpaper file not found (${wp_light:-none}) — skipping background/screensaver keys"
    message warn "install ubuntu-wallpapers, then run 'bash ubuntu-look.sh' again"
  fi

  write_look_profile
  profile_rc=$?
  case $profile_rc in
    0) STATUS_CHANGES+=("dconf profile for users of the look → ${LOOK_PROFILE}"); RELOGIN_NEEDED=1 ;;
    2) STATUS_FAILED+=("${LOOK_PROFILE} could not be written — the look cannot apply") ;;
  esac
  if [ "$profile_rc" -ne 2 ] && ! look_profile_usable; then
    STATUS_FAILED+=("${LOOK_PROFILE} has no user database — the look is not enabled")
    profile_rc=2
  fi
  mask_session_migration
  case $? in
    0) STATUS_CHANGES+=("session-migration masked → ${SESSION_MIGRATION_MASK}") ;;
    2) STATUS_FAILED+=("session-migration could not be masked (${SESSION_MIGRATION_MASK}) — it may change color-scheme at login") ;;
  esac

  local tmp
  tmp="$(mktemp)"
  {
    echo "# Written by ubuntu-look.sh — Ubuntu's GNOME defaults, read only by users"
    echo "# who installed the look (see ${LOOK_PROFILE}). Their own values win."
    echo ""
    render_dconf_groups
    echo "$bg_block"
  } > "$tmp"

  local db_rc=2
  { [ -d "${LOOK_DB_FILE%/*}" ] || sudo install -d -m 0755 "${LOOK_DB_FILE%/*}"; } \
    && { sudo_install_if_changed "$tmp" "$LOOK_DB_FILE"; db_rc=$?; }
  case $db_rc in
    0) compile_dconf && { STATUS_CHANGES+=("Ubuntu's defaults written → ${LOOK_DB_FILE}"); RELOGIN_NEEDED=1; } ;;
    2) STATUS_FAILED+=("${LOOK_DB_FILE} could not be written — Ubuntu's defaults are not updated") ;;
    *) if dconf_db_stale "$LOOK_DB_NAME"; then
         # A run stopped before dconf update.
         compile_dconf && { STATUS_CHANGES+=("Ubuntu's defaults compiled → /etc/dconf/db/${LOOK_DB_NAME}"); RELOGIN_NEEDED=1; }
       else
         STATUS_NOCHANGE+=("Ubuntu's defaults already current")
       fi ;;
  esac
  rm -f "$tmp"
  [ "$profile_rc" -ne 2 ]
}

install_greeter_extension() {
  install_local_extension "$GREETER_EXT_UUID" "Login screen extension" \
    "Ubuntu look for the login screen" "Draws the login screen with Yaru, as Ubuntu does." \
    '"gdm"' << 'EOF'
import Gio from 'gi://Gio';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// The two values of Ubuntu's gdm session mode that make up its theme.
const SESSION = {
    themeResourceName: 'theme/Yaru/gnome-shell-theme.gresource',
    stylesheetName: 'gdm.css',
};

export default class UbuntuLookGreeter extends Extension {
    enable() {
        // Without Yaru's shell theme and its login stylesheet, Debian's theme stays.
        try {
            Gio.Resource.load(`${global.datadir}/${SESSION.themeResourceName}`)
                .get_info(`/org/gnome/shell/theme/${SESSION.stylesheetName}`,
                    Gio.ResourceLookupFlags.NONE);
        } catch {
            return;
        }
        this._saved = {};
        for (const [prop, value] of Object.entries(SESSION)) {
            this._saved[prop] = Main.sessionMode[prop];
            // A mode change writes the mode's own values back; they are kept
            // for disable() and Yaru stays.
            Object.defineProperty(Main.sessionMode, prop, {
                configurable: true,
                get: () => value,
                set: v => {
                    this._saved[prop] = v;
                },
            });
        }
        this._reload();
    }

    disable() {
        if (!this._saved)
            return;
        for (const [prop, value] of Object.entries(this._saved)) {
            delete Main.sessionMode[prop];
            Main.sessionMode[prop] = value;
        }
        this._saved = null;
        this._reload();
    }

    // The shell reloads its stylesheet whenever the colour scheme is announced.
    _reload() {
        Main.reloadThemeResource();
        St.Settings.get().notify('color-scheme');
    }
}
EOF
}

# Install shell extension $1 (uuid) under /usr/local. $2 labels it, $3 and $4
# are name and description, $5 its session modes; extension.js on stdin.
# It declares only the installed gnome-shell major.
install_local_extension() {
  local uuid="$1" label="$2" dir="${LOCAL_EXT_DIR}/$1"
  local major tmp f changed=0 failed=0
  major="$(shell_major)"
  if [ -z "$major" ]; then
    cat > /dev/null
    STATUS_FAILED+=("${label} skipped — the GNOME Shell version is unknown")
    return 1
  fi
  # ES modules need GNOME Shell 45.
  if [ "$major" -lt 45 ]; then
    cat > /dev/null
    STATUS_NOCHANGE+=("${label} needs GNOME Shell 45 or later — skipped")
    return 1
  fi
  tmp="$(mktemp -d)"
  cat > "${tmp}/extension.js"
  cat << EOF > "${tmp}/metadata.json"
{
  "uuid": "${uuid}",
  "name": "$3",
  "description": "$4 Installed by ubuntu-look.sh; safe to delete.",
  "shell-version": ["${major}"],
  "session-modes": [$5]
}
EOF
  # Recorded once, so the uninstall removes only directories this script made.
  if [ ! -f "$LOCAL_SHELL_DIRS_FILE" ] \
     && [ ! -d "$THEME_EXT_DIR" ] \
     && [ ! -d "$GREETER_EXT_DIR" ]; then
    local _made=""
    [ -d "$LOCAL_EXT_DIR" ] || _made="$LOCAL_EXT_DIR"
    [ -d "${LOCAL_EXT_DIR%/*}" ] || _made="${_made} ${LOCAL_EXT_DIR%/*}"
    printf '%s\n' $_made > "${tmp}/dirs"
    # Without the record the uninstall could not remove the directories.
    if ! { sys_records_dir && sudo_write_atomic "${tmp}/dirs" "$LOCAL_SHELL_DIRS_FILE"; }; then
      rm -rf "$tmp"
      STATUS_FAILED+=("${label} not installed — ${LOCAL_SHELL_DIRS_FILE} could not be written")
      return 1
    fi
  fi
  # The code first: metadata on disk marks a complete extension.
  if [ -d "$dir" ] || sudo install -d -m 0755 "$dir"; then
    for f in extension.js metadata.json; do
      sudo_install_if_changed "${tmp}/${f}" "${dir}/${f}"
      case $? in 0) changed=1 ;; 2) failed=1; break ;; esac
    done
  else
    failed=1
  fi
  rm -rf "$tmp"
  if [ "$failed" -eq 1 ]; then
    STATUS_FAILED+=("${label} could not be written to ${dir}")
    return 1
  elif [ $changed -eq 1 ]; then
    STATUS_CHANGES+=("${label} → ${dir}")
    # GNOME Shell loads extension code only when it starts.
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("${label} already current")
  fi
}

# Ubuntu's shell theme, Yaru light or dark by the colour scheme, lock screen
# included. As on Ubuntu, a Yaru GTK and icon theme follow the colour scheme
# and accent colour, and the Dark Style toggle also moves the icons to Yaru.
install_theme_extension() {
  install_local_extension "$THEME_EXT_UUID" "Shell theme extension" \
    "Ubuntu look" "Yaru on the desktop and the lock screen, light or dark, as on Ubuntu." \
    '"user", "unlock-dialog"' << 'EOF'
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// The three values of Ubuntu's session mode that make up its theme.
const SESSION = {
    themeResourceName: 'theme/Yaru/gnome-shell-theme.gresource',
    stylesheetName: 'Yaru/gnome-shell.css',
    colorScheme: 'prefer-light',
};
// The icons resource of Ubuntu's session mode: Yaru's shell icons over GNOME's.
const ICONS_RESOURCE = 'theme/Yaru/gnome-shell-icons.gresource';

// Ubuntu's Yaru variant for each accent colour; orange is plain Yaru.
const YARU_VARIANTS = {
    blue: 'blue', teal: 'prussiangreen', green: 'olive',
    yellow: 'yellow', orange: 'default', red: 'red', pink: 'magenta',
    purple: 'purple', slate: 'sage',
};
// Yaru variants Ubuntu's libadwaita accepts in a theme name; the last two
// are older ones it maps to current variants.
const YARU_KNOWN = ['default', 'blue', 'prussiangreen', 'olive', 'yellow', 'red',
    'magenta', 'purple', 'sage', 'bark', 'viridian'];
const YARU_MIGRATED = {bark: 'default', viridian: 'olive'};

export default class UbuntuLookTheme extends Extension {
    enable() {
        // Yaru's icons first, so the theme reload below draws with them.
        this._loadIcons();
        if (this._hasYaruStylesheet()) {
            this._saved = {};
            for (const [prop, value] of Object.entries(SESSION)) {
                this._saved[prop] = Main.sessionMode[prop];
                // Locking and unlocking write the mode's own values back; they
                // are kept for disable() and Yaru stays.
                Object.defineProperty(Main.sessionMode, prop, {
                    configurable: true,
                    get: () => value,
                    set: v => {
                        this._saved[prop] = v;
                    },
                });
            }
            this._reload();
        }
        this._interface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        // GNOME before 47 has no accent colour; the current Yaru variant is kept.
        this._hasAccent = this._interface.settings_schema.has_key('accent-color');
        this._schemeId = this._interface.connect('changed::color-scheme',
            () => this._followAppearance());
        this._accentId = this._hasAccent
            ? this._interface.connect('changed::accent-color', () => this._followAppearance())
            : 0;
        // Only a change moves the themes, as on Ubuntu: a style or accent colour
        // changed while this was off is followed, as Ubuntu's Settings would at
        // the change; a Yaru theme chosen on purpose stays. Before any record,
        // a Yaru theme that does not match is set right.
        const gtk = this._interface.get_string('gtk-theme');
        const dark = this._interface.get_string('color-scheme') === 'prefer-dark';
        const seen = this._readAppearance();
        if (gtk.startsWith('Yaru') && (seen === null
            ? gtk !== this._yaruTheme(this._accentVariant(), dark)
            : seen !== this._currentAppearance()))
            this._followAppearance();
        else
            this._saveAppearance();
        this._hookDarkToggle();
    }

    disable() {
        if (this._hookRetryId) {
            GLib.source_remove(this._hookRetryId);
            this._hookRetryId = 0;
        }
        this._hookTries = 0;
        if (this._darkToggle) {
            // The toggle's own method, from its class, applies again.
            delete this._darkToggle._toggleMode;
            this._darkToggle = null;
        }
        if (this._interface) {
            this._interface.disconnect(this._schemeId);
            if (this._accentId)
                this._interface.disconnect(this._accentId);
            this._interface = null;
        }
        this._icons?._unregister();
        this._icons = null;
        if (!this._saved)
            return;
        for (const [prop, value] of Object.entries(this._saved)) {
            delete Main.sessionMode[prop];
            Main.sessionMode[prop] = value;
        }
        this._saved = null;
        this._reload();
    }

    // Without Yaru's shell theme and its stylesheet, Debian's theme stays.
    _hasYaruStylesheet() {
        try {
            Gio.Resource.load(`${global.datadir}/${SESSION.themeResourceName}`)
                .get_info(`/org/gnome/shell/theme/${SESSION.stylesheetName}`,
                    Gio.ResourceLookupFlags.NONE);
            return true;
        } catch {
            return false;
        }
    }

    // The shell reloads its stylesheet whenever the colour scheme is announced.
    _reload() {
        Main.reloadThemeResource();
        St.Settings.get().notify('color-scheme');
    }

    // Registered after GNOME's icons, Yaru's take precedence. A missing or
    // unreadable resource leaves GNOME's icons.
    _loadIcons() {
        const path = `${global.datadir}/${ICONS_RESOURCE}`;
        if (!Gio.File.new_for_path(path).query_exists(null))
            return;
        try {
            const icons = Gio.Resource.load(path);
            icons._register();
            this._icons = icons;
        } catch (e) {
            console.warn(`${this.uuid}: ${e.message}`);
        }
    }

    // Ubuntu's Dark Style toggle (gnome-shell patch "darkMode: Add support to
    // Yaru theme color variants"): the screen transition starts, then the
    // colour scheme and, with a Yaru GTK theme, the Yaru themes are written.
    _hookDarkToggle() {
        const toggle = Main.panel?.statusArea?.quickSettings?._darkMode
            ?.quickSettingsItems?.[0];
        if (typeof toggle?._toggleMode !== 'function') {
            // Quick Settings adds its indicators asynchronously at startup;
            // a slow login gets 30 seconds.
            this._hookTries = (this._hookTries ?? 0) + 1;
            if (this._hookTries <= 300) {
                this._hookRetryId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 100, () => {
                    this._hookRetryId = 0;
                    this._hookDarkToggle();
                    return GLib.SOURCE_REMOVE;
                });
            }
            return;
        }
        this._hookTries = 0;
        this._darkToggle = toggle;
        toggle._toggleMode = () => {
            Main.layoutManager.screenTransition.run();
            const preferDark = !toggle.checked;
            this._toggling = true;
            this._interface.set_string('color-scheme',
                toggle.checked ? 'default' : 'prefer-dark');
            this._toggling = false;

            if (this._interface.get_string('gtk-theme').split('-')[0] === 'Yaru')
                this._setYaruSettings(preferDark);
        };
    }

    // The style and accent colour the themes last followed, kept across logins.
    _appearanceFile() {
        return GLib.build_filenamev([GLib.get_user_state_dir(), 'ubuntu-look', 'appearance']);
    }

    _currentAppearance() {
        const accent = this._hasAccent ? this._interface.get_string('accent-color') : '';
        return `${this._interface.get_string('color-scheme')} ${accent}`;
    }

    _readAppearance() {
        try {
            const [ok, bytes] = GLib.file_get_contents(this._appearanceFile());
            return ok ? new TextDecoder().decode(bytes).trim() : null;
        } catch {
            return null;
        }
    }

    _saveAppearance() {
        try {
            const file = this._appearanceFile();
            GLib.mkdir_with_parents(GLib.path_get_dirname(file), 0o700);
            GLib.file_set_contents(file, this._currentAppearance());
        } catch (e) {
            console.warn(`${this.uuid}: ${e.message}`);
        }
    }

    _setYaruSettings(preferDark) {
        this._saveAppearance();
        const currentlyDark =
            this._interface.get_string('gtk-theme').endsWith('-dark') &&
            this._interface.get_string('icon-theme').endsWith('-dark');

        if (currentlyDark !== preferDark) {
            const newTheme = this._yaruTheme(this._accentVariant(), preferDark);
            this._setTheme('gtk-theme', newTheme);
            this._setTheme('icon-theme', newTheme);
        }

        const schemaSource = Gio.SettingsSchemaSource.get_default();
        const geditSchema = schemaSource.lookup('org.gnome.gedit.preferences.editor', true);

        if (geditSchema) {
            const geditSettings = Gio.Settings.new_full(geditSchema, null, null);
            const geditScheme = geditSettings.get_user_value('scheme')?.unpack();

            if (geditScheme?.startsWith('Yaru') &&
                geditScheme.endsWith('-dark') !== preferDark)
                geditSettings.set_string('scheme', `Yaru${preferDark ? '-dark' : ''}`);
        }
    }

    // Ubuntu's Appearance panel (gnome-control-center patch "background: Update
    // legacy theme settings matching the accent color"), which Debian's
    // Settings lacks: after the colour scheme or the accent colour changes,
    // a Yaru GTK theme and a Yaru icon theme follow them. Settings has already
    // started the screen transition.
    _followAppearance() {
        if (this._toggling)
            return;
        this._saveAppearance();
        if (this._themeVariant() === null)
            return;
        const dark = this._interface.get_string('color-scheme') === 'prefer-dark';
        const theme = this._yaruTheme(this._accentVariant(), dark);

        this._setTheme('gtk-theme', theme);
        const icons = this._interface.get_string('icon-theme');
        if (!icons || icons.startsWith('Yaru'))
            this._setTheme('icon-theme', theme);
    }

    // The Yaru variant of the GTK theme, as Ubuntu's libadwaita reads it;
    // null when the GTK theme is not Yaru.
    _themeVariant() {
        const theme = this._interface.get_string('gtk-theme');
        if (theme === 'Yaru' || theme === 'Yaru-dark')
            return 'default';
        if (!theme.startsWith('Yaru-'))
            return null;
        const variant = theme.split('-')[1];
        if (!YARU_KNOWN.includes(variant))
            return null;
        return YARU_MIGRATED[variant] ?? variant;
    }

    // The Yaru variant for the accent colour; GNOME before 47 has none.
    _accentVariant() {
        if (!this._hasAccent)
            return this._themeVariant() ?? 'default';
        return YARU_VARIANTS[this._interface.get_string('accent-color')] ?? 'default';
    }

    _yaruTheme(variant, dark) {
        return `Yaru${variant !== 'default' ? `-${variant}` : ''}${dark ? '-dark' : ''}`;
    }

    // Writes the theme key only when it changes. A theme equal to the system
    // default is reset instead of stored, so the default stays in one place.
    _setTheme(key, value) {
        if (this._interface.get_string(key) === value)
            return;
        if (this._interface.get_default_value(key)?.unpack() === value)
            this._interface.reset(key);
        else
            this._interface.set_string(key, value);
    }
}
EOF
}

# True when the compiled dconf database $1 is missing or older than its keyfiles.
dconf_db_stale() {
  local db="/etc/dconf/db/$1"
  [ -d "${db}.d" ] || return 1
  [ -f "$db" ] || return 0
  [ -n "$(find "${db}.d" -newer "$db" -print -quit 2>/dev/null)" ]
}

# Compile the system dconf databases; a failure is reported for a re-run.
compile_dconf() {
  sudo dconf update && return 0
  STATUS_FAILED+=("dconf update failed — the new defaults are not in effect; re-run to retry")
  return 1
}

# The login screen profile $1 as the look writes it: the greeter's database,
# then the file database of Debian's own profile.
greeter_profile_content() {
  printf 'user-db:user\nsystem-db:gdm\n'
  if readable_regular_file "/usr/share/dconf/profile/$1"; then
    sed -n '/^file-db:/p' "/usr/share/dconf/profile/$1" 2>/dev/null
  fi
}

# True when greeter profile file $1 is still the look's: its own two lines
# and Debian's file-db lines, whichever Debian release wrote those.
greeter_profile_is_ours() {
  [ "$(grep -v '^file-db:' "$1" 2>/dev/null)" = "$(printf 'user-db:user\nsystem-db:gdm')" ]
}

# Point greeter profile $1 at the gdm database, keeping Debian's file-db line
# after it. $2 records the creation.
write_greeter_dconf_profile() {
  local name="$1" created="$2" target="/etc/dconf/profile/$1" want
  want="$(greeter_profile_content "$name")"
  # Never write through a symlink; report it instead.
  if [ -L "$target" ]; then
    message warn "${target} is a symlink — leaving it alone"
    STATUS_NOCHANGE+=("${target} is a symlink and was left alone; the login screen may not pick up the theme")
    return 0
  fi

  local verb
  if [ ! -e "$target" ]; then
    # Record first, so an interrupted run still leaves a record.
    sys_records_dir
    [ -d /etc/dconf/profile ] || sudo touch "$DCONF_PROFILE_DIR_MADE"
    sudo install -d -m 0755 /etc/dconf/profile
    sudo touch "$created"
    verb=Created
  elif [ ! -f "$target" ]; then
    message warn "${target} is not a regular file — leaving it alone"
    STATUS_NOCHANGE+=("${target} is not a regular file and was left alone; the login screen may not pick up the theme")
    return 0
  elif [ -f "$created" ] && ! printf '%s\n' "$want" | cmp -s - "$target"; then
    # Only a profile this script created, and only its Debian line; one an
    # administrator changed since is theirs, as the uninstall treats it.
    if ! greeter_profile_is_ours "$target"; then
      STATUS_NOCHANGE+=("${target} was changed after the install — left as it is")
      return 0
    fi
    verb=Repaired
  else
    return 0
  fi
  # Written atomically: a partial greeter profile would break the login screen.
  local tmp ok=1
  tmp="$(mktemp)" && printf '%s\n' "$want" > "$tmp" \
    && sudo_write_atomic "$tmp" "$target" && ok=0
  rm -f "$tmp"
  if [ "$ok" -eq 0 ]; then
    STATUS_CHANGES+=("${verb} ${target} so the login screen reads its database")
  elif [ "$verb" = Created ]; then
    sudo rm -f "$created"
    STATUS_FAILED+=("${target} could not be created — the login screen keeps Debian's look")
  else
    STATUS_FAILED+=("${target} could not be repaired")
  fi
}

write_gdm_profile() {
  local wp_light="${1:-}" wp_dark="${2:-}" bg_block="" ext_block=""
  if ! is_installed gdm3; then
    STATUS_NOCHANGE+=("GDM is not installed — login screen left alone")
    return 0
  fi

  # The login screen reads the profile of Debian's greeter user, Debian-gdm;
  # the gdm profile is written too, so the two agree.
  write_greeter_dconf_profile gdm "${SYS_RECORDS}/gdm-profile-created"
  if getent passwd Debian-gdm > /dev/null; then
    write_greeter_dconf_profile Debian-gdm "${SYS_RECORDS}/gdm-profile-Debian-gdm-created"
  fi

  # Ubuntu sets the wallpaper on the greeter as well.
  [ -f "$wp_light" ] && bg_block="$(background_group "$wp_light" "$wp_dark")"

  install_greeter_extension
  # Listed only when on disk; this replaces the greeter's list.
  if [ -f "${GREETER_EXT_DIR}/metadata.json" ]; then
    ext_block="
[org/gnome/shell]
enabled-extensions=['${GREETER_EXT_UUID}']"
  fi

  # Whether a greeter profile reads the database; -f, as grep blocks on a FIFO.
  local _reader=0 _prof
  for _prof in /etc/dconf/profile/gdm /etc/dconf/profile/Debian-gdm; do
    [ -f "$_prof" ] && grep -q '^system-db:gdm$' "$_prof" 2>/dev/null && _reader=1
  done

  # The theme and font values of Ubuntu's defaults, as Ubuntu's greeter has
  # them; its sound theme override is global, so the greeter's sounds are Yaru's.
  local tmp line path key value iface="" sound=""
  fit_fonts_to_release
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    case "${path}/${key}" in
      org/gnome/desktop/interface/gtk-theme|org/gnome/desktop/interface/accent-color|\
      org/gnome/desktop/interface/icon-theme|org/gnome/desktop/interface/cursor-theme|\
      org/gnome/desktop/interface/font-name|org/gnome/desktop/interface/monospace-font-name|\
      org/gnome/desktop/interface/font-antialiasing)
        iface="${iface}${key}=${value}"$'\n' ;;
      org/gnome/desktop/sound/theme-name)
        sound="
[org/gnome/desktop/sound]
${key}=${value}" ;;
    esac
  done
  tmp="$(mktemp)"
  cat << EOF > "$tmp"
# Written by ubuntu-look.sh — the login screen's Ubuntu theme; removed by 'ubuntu-look.sh --uninstall'.
[org/gnome/desktop/interface]
${iface%$'\n'}
${sound}
${ext_block}
${bg_block}
EOF

  local gdm_rc=2
  if [ ! -d "$GDM_PROFILE_DIR" ]; then
    sys_records_dir; sudo touch "${SYS_RECORDS}/dconf-gdm-dir-created"
    sudo install -d -m 0755 "$GDM_PROFILE_DIR"
  fi
  [ -d "$GDM_PROFILE_DIR" ] && { sudo_install_if_changed "$tmp" "$GDM_PROFILE_FILE"; gdm_rc=$?; }
  case $gdm_rc in
    0) compile_dconf && if [ "$_reader" -eq 1 ]; then
         STATUS_CHANGES+=("Login screen themed → ${GDM_PROFILE_FILE}")
         RELOGIN_NEEDED=1
       else
         STATUS_NOCHANGE+=("${GDM_PROFILE_FILE} written, but no greeter profile reads it — login screen unchanged")
       fi ;;
    1) if dconf_db_stale gdm; then
         compile_dconf && { STATUS_CHANGES+=("Login screen defaults compiled → /etc/dconf/db/gdm"); RELOGIN_NEEDED=1; }
       elif [ "$_reader" -eq 1 ]; then
         STATUS_NOCHANGE+=("Login screen theme already current")
       else
         STATUS_NOCHANGE+=("${GDM_PROFILE_FILE} is current, but no greeter profile reads it — login screen unchanged")
       fi ;;
    2) STATUS_FAILED+=("${GDM_PROFILE_FILE} could not be written — login screen unchanged") ;;
  esac
  rm -f "$tmp"
  return 0
}

# The gnome-terminal profiles marked as the look's, one uuid per line.
marked_terminal_profiles() {
  local one
  for one in $(dconf list "${TERMINAL_PROFILES}/" 2>/dev/null | sed -n 's#^:\(.*\)/$#\1#p'); do
    [ "$(dconf read "${TERMINAL_PROFILES}/:${one}/ubuntu-look-managed" 2>/dev/null)" = true ] && echo "$one"
  done
  return 0
}

# UBUNTU_LOOK_ANIMATIONS: sets the user's own animation switch, the one in
# Settings > Accessibility; neither the look nor the uninstall resets it.
# Prints the result. Returns 0 changed, 1 already so, 2 failed, 3 not asked.
apply_animation_option() {
  [ -n "$UBUNTU_LOOK_ANIMATIONS" ] || return 3
  local want=true state=on
  [ "$UBUNTU_LOOK_ANIMATIONS" = 0 ] && { want=false; state=off; }
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "Animation effects not set — run this again from your desktop session"
    return 2
  fi
  if [ "$(gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null)" = "$want" ]; then
    echo "Animation effects already ${state}"; return 1
  fi
  gsettings set org.gnome.desktop.interface enable-animations "$want" 2>/dev/null \
    && { echo "Animation effects turned ${state}"; return 0; }
  echo "Animation effects could not be turned ${state}"
  return 2
}

install_terminal_profile() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || ! command -v dconf >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("No desktop session — terminal colours are applied by a run from the desktop")
    return 0
  fi
  if ! command -v gnome-terminal >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("gnome-terminal is not installed — terminal colours left alone")
    return 0
  fi

  local uuid created=0 fresh=0 managed="" listed one
  uuid="$(sed -n 's/^uuid=//p' "$TERMINAL_PROFILE_RECORD" 2>/dev/null | head -1 | tr -d '\r')"
  [ -n "$uuid" ] && managed="$(dconf read "${TERMINAL_PROFILES}/:${uuid}/ubuntu-look-managed" 2>/dev/null)"
  listed="$(dconf_array_items "${TERMINAL_PROFILES}/list")"

  # Recorded only once listed, so a recorded profile no longer listed was
  # deleted in gnome-terminal, which resets its own keys but not the look's
  # mark: the user's choice stays.
  if [ -n "$uuid" ] && ! in_word_list "$uuid" "$listed"; then
    STATUS_NOCHANGE+=("Ubuntu terminal profile left out — you deleted it")
    return 0
  fi

  # No record: adopt a listed profile marked as the look's (a user's own
  # profile named Ubuntu is never taken); otherwise make a new one.
  if [ -z "$uuid" ]; then
    fresh=1
    for one in $(marked_terminal_profiles); do
      if in_word_list "$one" "$listed"; then
        [ -n "$uuid" ] || uuid="$one"
      else
        # Unlisted: left by a stopped run, or deleted by the user; it goes.
        dconf reset -f "${TERMINAL_PROFILES}/:${one}/" 2>/dev/null
      fi
    done
    if [ -z "$uuid" ]; then
      uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
      if [ -z "$uuid" ]; then
        STATUS_FAILED+=("Could not generate a terminal profile id")
        return 0
      fi
      created=1
    fi
    [ "$created" -eq 1 ] || message "adopting the existing Ubuntu terminal profile (${uuid})"
  fi

  local base="${TERMINAL_PROFILES}/:${uuid}" changed=0 key val _write_failed=0
  # A recorded profile is the user's to change; only a new or adopted one is written.
  local write_keys=1
  if [ "$fresh" -eq 0 ] && [ "$managed" = true ]; then
    write_keys=0
    STATUS_NOCHANGE+=("Terminal: the Ubuntu profile is left as you set it")
  fi
  [ "$write_keys" -eq 1 ] && for key in "ubuntu-look-managed|true" \
             "visible-name|'Ubuntu'" \
             "use-theme-colors|false" \
             "background-color|'${TERMINAL_BACKGROUND}'" \
             "foreground-color|'${TERMINAL_FOREGROUND}'"; do
    val="${key#*|}"; key="${key%%|*}"
    # Compared without spacing, to avoid a needless rewrite.
    [ "$(dconf read "${base}/${key}" 2>/dev/null | tr -d '[:space:]')" \
      = "$(printf '%s' "$val" | tr -d '[:space:]')" ] && continue
    if dconf write "${base}/${key}" "$val" 2>/dev/null; then changed=1; else _write_failed=1; fi
  done
  # A new profile only partly written (its mark missing, say) could be neither
  # adopted nor removed later: it goes, and the next run makes it again.
  if [ "$created" -eq 1 ] && [ "$_write_failed" -eq 1 ]; then
    dconf reset -f "${base}/" 2>/dev/null
    STATUS_FAILED+=("Terminal profile not written — dconf refused a key; run this again")
    return 0
  fi
  # Add the profile to the list; unset means gnome-terminal's default list.
  local list
  list="$(dconf_array_items "${TERMINAL_PROFILES}/list")"
  [ -n "$list" ] || list="$(array_items "$(GSETTINGS_BACKEND=memory gsettings get org.gnome.Terminal.ProfilesList list 2>/dev/null)" | xargs)"
  case " $list " in
    *" $uuid "*) ;;
    *) # Unlisted, the profile is never shown.
       if dconf write "${TERMINAL_PROFILES}/list" \
            "$(gvariant_string_array "${list:+${list} }${uuid}")" 2>/dev/null; then
         changed=1
       else
         _write_failed=1
       fi ;;
  esac
  # Made the default only when new or when nothing is set.
  local _cur_default _made_default=0
  _cur_default="$(dconf read "${TERMINAL_PROFILES}/default" 2>/dev/null | tr -d \')"
  if [ "$_cur_default" != "$uuid" ] && { [ -z "$_cur_default" ] || [ "$created" -eq 1 ]; }; then
    if dconf write "${TERMINAL_PROFILES}/default" "'${uuid}'" 2>/dev/null; then
      changed=1; _made_default=1
    else
      _write_failed=1
    fi
  elif [ "$_cur_default" != "$uuid" ]; then
    STATUS_NOCHANGE+=("Terminal default left on the profile you chose")
  fi

  # A new or adopted profile is recorded only once fully written, listed and
  # made the default: a recorded profile missing from the list is one the
  # user deleted, and a run cut before this is finished by the next.
  if [ "$fresh" -eq 1 ] && [ "$_write_failed" -eq 0 ]; then
    mkdir -p "$BACKUP_DIR"
    printf 'uuid=%s\n' "$uuid" > "$TERMINAL_PROFILE_RECORD"
  fi

  [ "$_write_failed" -eq 1 ] \
    && STATUS_FAILED+=("Terminal profile not fully written — dconf refused at least one key")

  # No re-login: gnome-terminal applies profile changes at once.
  if [ $changed -eq 1 ]; then
    if [ "$_made_default" -eq 1 ]; then
      STATUS_CHANGES+=("Terminal: Ubuntu profile applied and made the default")
    else
      STATUS_CHANGES+=("Terminal: Ubuntu profile applied")
    fi
  else
    [ "$_write_failed" -eq 0 ] && [ "$write_keys" -eq 1 ] \
      && STATUS_NOCHANGE+=("Terminal: Ubuntu profile already current")
  fi
}

# A key binding in one spelling: lower case, <Control> and <Ctrl> as
# <Primary>, the modifiers in sorted order.
normalise_binding() {
  local b key
  b="$(printf '%s' "$1" | tr -d "'" | tr '[:upper:]' '[:lower:]' | sed 's/<control>/<primary>/g; s/<ctrl>/<primary>/g')"
  key="${b##*>}"
  printf '%s%s' "$(printf '%s' "${b%"$key"}" | grep -o '<[^>]*>' | sort -u | tr -d '\n')" "$key"
}

# Ubuntu binds Ctrl+Alt+T to the terminal; Debian binds nothing there. It is
# added as the user's own custom shortcut, never a look default, as the
# uninstall's reset of the look's keys would drop the user's own shortcuts.
# Added once: a shortcut the user removes stays removed.
install_terminal_shortcut() {
  local list_key="$CUSTOM_KEYBINDINGS_KEY"
  local want list p key val changed=0 failed=0
  want="$(normalise_binding '<Primary><Alt>t')"
  if [ -f "$TERMINAL_SHORTCUT_RECORD" ]; then
    if in_word_list "$TERMINAL_SHORTCUT_PATH" "$(dconf_array_items "$list_key")"; then
      STATUS_NOCHANGE+=("Ctrl+Alt+T terminal shortcut already added")
    else
      STATUS_NOCHANGE+=("Ctrl+Alt+T terminal shortcut left out — you removed it")
    fi
    return 0
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || ! command -v dconf >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("No desktop session — the Ctrl+Alt+T shortcut is applied by a run from the desktop")
    return 0
  fi
  list="$(dconf_array_items "$list_key")"
  # A shortcut of the user's own on Ctrl+Alt+T wins.
  for p in $list; do
    [ "$p" = "$TERMINAL_SHORTCUT_PATH" ] && continue
    if [ "$(normalise_binding "$(dconf read "${p}binding" 2>/dev/null)")" = "$want" ]; then
      STATUS_NOCHANGE+=("Ctrl+Alt+T already runs your own shortcut — left as it is")
      return 0
    fi
  done
  # The binding last and the list after it: a stopped run leaves no half entry
  # in use, and the next run completes it.
  for key in "name|'Terminal'" "command|'x-terminal-emulator'" "binding|'<Primary><Alt>t'"; do
    val="${key#*|}"; key="${key%%|*}"
    [ "$(user_dconf_read "${TERMINAL_SHORTCUT_PATH}${key}")" = "$val" ] && continue
    if dconf write "${TERMINAL_SHORTCUT_PATH}${key}" "$val" 2>/dev/null; then changed=1; else failed=1; fi
  done
  if [ "$failed" -eq 0 ] && ! in_word_list "$TERMINAL_SHORTCUT_PATH" "$list"; then
    if dconf write "$list_key" "$(gvariant_string_array "${list:+${list} }${TERMINAL_SHORTCUT_PATH}")" 2>/dev/null; then
      changed=1
    else
      failed=1
    fi
  fi
  if [ "$failed" -eq 1 ]; then
    STATUS_FAILED+=("Ctrl+Alt+T terminal shortcut not fully written — re-run to retry")
    return 0
  fi
  mkdir -p "$BACKUP_DIR" && : > "$TERMINAL_SHORTCUT_RECORD"
  if [ "$changed" -eq 1 ]; then
    STATUS_CHANGES+=("Ctrl+Alt+T opens the terminal, as on Ubuntu")
  else
    STATUS_NOCHANGE+=("Ctrl+Alt+T terminal shortcut already in place")
  fi
}

# Ubuntu turns on RGB sub-pixel font rendering for every program through
# fontconfig; Debian's fontconfig appends "none", and the look's
# font-antialiasing reaches only GTK and the Shell. This per-user rule turns
# that "none" into "rgb" and leaves a value an app sets itself alone.
subpixel_conf_content() {
  cat << 'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Written by ubuntu-look.sh; its uninstall removes this file. -->
<fontconfig>
  <match target="pattern">
    <test name="rgba" compare="eq"><const>none</const></test>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
EOF
}

# Written per user, once, never over the user's files.
install_subpixel_rendering() {
  # The file an earlier run wrote, wherever the configuration directory was.
  local recorded
  recorded="$(subpixel_conf_path)"
  if [ "$recorded" != "$SUBPIXEL_CONF" ] && { [ -e "$recorded" ] || [ -L "$recorded" ]; }; then
    STATUS_NOCHANGE+=("Sub-pixel font rendering already on (${recorded})")
    return 0
  fi
  if [ -e "$SUBPIXEL_CONF" ] || [ -L "$SUBPIXEL_CONF" ]; then
    if [ -f "$SUBPIXEL_RECORD" ]; then
      STATUS_NOCHANGE+=("Sub-pixel font rendering already on")
    else
      STATUS_NOCHANGE+=("Sub-pixel font rendering: your own ${SUBPIXEL_CONF} is kept")
    fi
    return 0
  fi
  if [ -f "$SUBPIXEL_RECORD" ]; then
    STATUS_NOCHANGE+=("Sub-pixel font rendering left off — you removed ${recorded}")
    return 0
  fi
  local f
  for f in "${SUBPIXEL_CONF%/*}"/10-sub-pixel-*.conf; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      STATUS_NOCHANGE+=("Sub-pixel font rendering: your own ${f} is kept")
      return 0
    fi
  done
  # Recorded first, with its path, so the uninstall finds a file a stopped
  # run made even when the configuration directory has moved since.
  if mkdir -p "$BACKUP_DIR" "${SUBPIXEL_CONF%/*}" \
     && printf '%s\n' "$SUBPIXEL_CONF" > "$SUBPIXEL_RECORD" \
     && subpixel_conf_content > "$SUBPIXEL_CONF"; then
    STATUS_CHANGES+=("Sub-pixel font rendering on, as on Ubuntu → ${SUBPIXEL_CONF} (programs started from now on)")
  else
    rm -f "$SUBPIXEL_RECORD" "$SUBPIXEL_CONF"
    STATUS_FAILED+=("Sub-pixel font rendering could not be turned on (${SUBPIXEL_CONF})")
  fi
}

# The sub-pixel rule's path as the install recorded it; the current one for
# a record without a path.
subpixel_conf_path() {
  local p=""
  [ -f "$SUBPIXEL_RECORD" ] && p="$(head -n 1 "$SUBPIXEL_RECORD" 2>/dev/null)"
  printf '%s\n' "${p:-$SUBPIXEL_CONF}"
}

# Remove user icon $1 and any directories left empty; refresh its cache.
remove_user_icon() {
  local f="$1" d theme
  [ -f "$f" ] || return 1
  d="${f%/*}"; theme="${d%/*/*}"
  rm -f "$f"
  if [ -f "${theme}/icon-theme.cache" ]; then
    if find "$theme" -mindepth 2 -type f 2>/dev/null | grep -q .; then
      gtk-update-icon-cache -f -t "$theme" >/dev/null 2>&1 || true
    else
      rm -f "${theme}/icon-theme.cache"
    fi
  fi
  rmdir "$d" "${d%/*}" "$theme" "${theme%/*}" 2>/dev/null || true
  return 0
}

# Write $1 to $2 with its viewBox widened until the artwork covers
# APP_GRID_INK_FRACTION of it. Non-zero when the image cannot be read.
normalise_app_grid_icon() {
  python3 - "$1" "$2" "$APP_GRID_INK_FRACTION" << 'PYEOF' 2>/dev/null
import re
import sys

src, dest, frac = sys.argv[1], sys.argv[2], float(sys.argv[3])
data = open(src, encoding="utf-8", errors="replace").read()

# The root element's viewBox only (not one on a <symbol>, a nested <svg> or
# inside a comment).
comments = [(c.start(), c.end()) for c in re.finditer(r'<!--.*?-->', data, re.S)]
root = None
for cand in re.finditer(r'<svg(?::\w+)?\b[^>]*>', data, re.S):
    if any(a <= cand.start() < b for a, b in comments):
        continue
    root = cand
    break
vb = re.search(r'viewBox="([^"]*)"', root.group(0)) if root else None
if not vb:
    raise SystemExit(1)
# Offsets are relative to the root element, so lift them back to the file.
vb_start = root.start() + vb.start(1)
vb_end = root.start() + vb.end(1)
box = [float(v) for v in vb.group(1).replace(",", " ").split()]
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
open(dest, "w", encoding="utf-8").write(data[:vb_start] + new + data[vb_end:])
PYEOF
}

install_app_grid_icon() {
  local src="" c tmp _icon_rc=0 _changed_note="" _current_note=""
  for c in /usr/share/desktop-base/debian-logos/logo.svg \
           /usr/share/desktop-base/debian-logos/openlogo-nd.svg \
           /usr/share/desktop-base/debian-logos/openlogo.svg \
           /usr/share/desktop-base/debian-logos/logo-debian.svg \
           /usr/share/icons/hicolor/scalable/apps/debian-logo.svg \
           /usr/share/icons/hicolor/scalable/places/debian-swirl.svg; do
    [ -f "$c" ] && { src="$c"; break; }
  done

  # Fall back to another Debian logo without lettering: desktop-base's, or a
  # system icon named for Debian, never another program's.
  if [ -z "$src" ]; then
    src="$( { find /usr/share/desktop-base -maxdepth 4 -iname '*logo*.svg'
              find /usr/share/icons/hicolor/scalable -maxdepth 2 -iname 'debian*.svg'; } 2>/dev/null \
           | grep -viE 'text|version|nologo|background' | LC_ALL=C sort | head -1)"
  fi

  if [ -z "$src" ]; then
    STATUS_NOCHANGE+=("No Debian logo on this system — Show Applications keeps the generic grid")
    return 0
  fi
  if ! command -v python3 > /dev/null 2>&1; then
    STATUS_NOCHANGE+=("Show Applications button left alone — python3 is not installed")
    return 0
  fi

  tmp="$(mktemp)"
  # Copy unchanged only when the file is valid XML.
  if ! normalise_app_grid_icon "$src" "$tmp"; then
    if ! python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$src" 2>/dev/null; then
      rm -f "$tmp"
      STATUS_NOCHANGE+=("Show Applications button left alone — ${src} is not readable as SVG")
      return 0
    fi
    cp "$src" "$tmp"
    local why="the image could not be measured"
    if ! python3 -c 'import gi' 2>/dev/null; then
      why="python3-gi is not installed"
    elif ! python3 -c 'import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf' 2>/dev/null; then
      why="gir1.2-gdkpixbuf-2.0 is not installed"
    fi
    _changed_note=" — copied unscaled, ${why}"
    _current_note=" — an unscaled copy; ${why}"
  fi

  install_if_changed "$tmp" "$APP_GRID_ICON"; _icon_rc=$?
  if [ "$_icon_rc" -eq 2 ]; then
    rm -f "$tmp"
    STATUS_FAILED+=("Show Applications icon could not be written to ${APP_GRID_ICON}")
    return 0
  fi
  # No icon cache is needed: GTK finds uncached user icons. An unscaled copy
  # is reported on every run.
  if [ "$_icon_rc" -eq 0 ]; then
    STATUS_CHANGES+=("Show Applications button now uses ${src##*/}${_changed_note}")
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("Show Applications button icon already current${_current_note}")
  fi
  rm -f "$tmp"
}

###############################################################################
# 4. Boot: GRUB command line and boot splash
###############################################################################

# The splash needs GRUB and update-initramfs.
has_boot_splash_tools() {
  [ -f /etc/default/grub ] && command -v update-grub >/dev/null 2>&1 \
    && command -v update-initramfs >/dev/null 2>&1 || return 1
  # GRUB's own boot loader package, not only its tools left after a move to
  # systemd-boot, whose command line is /etc/kernel/cmdline.
  dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'grub-pc' 'grub-efi-*' 'grub-ieee1275' \
    'grub-coreboot' 'grub-xen' 'grub-uboot' 2>/dev/null \
    | grep -qE '^installed grub-(pc|efi-(amd64|arm64|ia32|ia64|arm|riscv64|loong64)|ieee1275|coreboot|xen|uboot)$'
}

# Run boot tool $@ through sudo once no dpkg run holds its lock: a dpkg
# trigger may run the same tool. Returns 1, not running it, on a timeout.
boot_tool() {
  if ! wait_dpkg_lock; then
    message warn "the dpkg lock is still held — ${1} not run"
    return 1
  fi
  sudo "$@"
}

# The current Plymouth theme. Debian has no plymouth-get-default-theme; its
# plymouth-set-default-theme prints the theme when given no arguments.
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

# Save plymouthd.conf once, before the look first changes the theme; an
# absent file is saved as an empty record with ".absent".
save_plymouth_conf() {
  [ -f "$PLYMOUTH_CONF_BEFORE" ] || [ -f "${PLYMOUTH_CONF_BEFORE}.absent" ] && return 0
  sys_records_dir || return 1
  if [ -f "$PLYMOUTH_CONF" ]; then
    # Atomic: a partial copy would later replace the real file.
    sudo_write_atomic "$PLYMOUTH_CONF" "$PLYMOUTH_CONF_BEFORE"
  else
    sudo touch "${PLYMOUTH_CONF_BEFORE}.absent"
  fi
}

# True when Plymouth theme $1 is installed.
plymouth_theme_installed() { plymouth-set-default-theme -l 2>/dev/null | grep -qxF -- "$1"; }

# Forget the boot splash theme records: the theme before, the one set, and
# the saved plymouthd.conf.
drop_plymouth_records() {
  sudo rm -f "$PLYMOUTH_BEFORE_FILE" "$PLYMOUTH_SET_FILE" \
    "$PLYMOUTH_CONF_BEFORE" "${PLYMOUTH_CONF_BEFORE}.absent"
}

# plymouthd.conf $1 without its theme setting and blank lines.
plymouth_conf_rest() { grep -vE '^[[:space:]]*(Theme=|\[Daemon\]|$)' "$1" 2>/dev/null; }

# Set boot splash theme $1 back: the saved plymouthd.conf, so the file is as
# before the install, where nothing but the theme changed since; else by name.
put_back_plymouth_theme() {
  # A theme no longer installed cannot come back; nothing is touched, and the
  # records stay for a later try.
  plymouth_theme_installed "$1" || return 1
  if [ -f "$PLYMOUTH_CONF_BEFORE" ] \
     && [ "$(plymouth_conf_rest "$PLYMOUTH_CONF")" = "$(plymouth_conf_rest "$PLYMOUTH_CONF_BEFORE")" ]; then
    sudo install -m 0644 "$PLYMOUTH_CONF_BEFORE" "$PLYMOUTH_CONF" || return 1
  elif [ -f "${PLYMOUTH_CONF_BEFORE}.absent" ] && [ -z "$(plymouth_conf_rest "$PLYMOUTH_CONF")" ]; then
    sudo rm -f "$PLYMOUTH_CONF" || return 1
  fi
  [ "$(plymouth_current_theme)" = "$1" ] || boot_tool plymouth-set-default-theme "$1" || return 1
  # Kept until the theme is back, so a failed attempt can be retried from it.
  sudo rm -f "$PLYMOUTH_CONF_BEFORE" "${PLYMOUTH_CONF_BEFORE}.absent"
}

# Read GRUB_CMDLINE_LINUX_DEFAULT from /etc/default/grub. Prints
# "<state> <value>"; state is active (value follows), commented, absent, or
# unparsable (not safe to rewrite). Strict, because a grub file that no
# longer parses as shell breaks every later update-grub.
read_grub_cmdline() {
  local file=/etc/default/grub line val q body rest
  # Unreadable is not absent: callers drop their record on absent.
  if [ -e "$file" ] && [ ! -r "$file" ]; then
    printf 'unparsable \n'; return 0
  fi
  [ -r "$file" ] || { printf 'absent \n'; return 0; }

  line="$(grep -E "$GRUB_KEY_RE" "$file" 2>/dev/null)"
  if [ -z "$line" ]; then
    if grep -qE "^[[:space:]]*#${GRUB_KEY_RE#^}" "$file" 2>/dev/null; then
      printf 'commented \n'
    else
      printf 'absent \n'
    fi
    return 0
  fi
  # Two active assignments are not safe to rewrite.
  case "$line" in *$'\n'*) printf 'unparsable \n'; return 0 ;; esac
  val="${line#*=}"

  # An unquoted value is one word with nothing after it; a comment, shell
  # syntax, quotes or a leading ~ (rewritten quoted, they would mean
  # something else) are refused.
  case "$val" in
    \"*) q='"' ;;
    \'*) q="'" ;;
    *)   rest="${val#"${val%%[[:space:]]*}"}"
         case "$val" in *"#"*|*[\;\&\|\<\>\(\)\`\$\\\'\"]*|"~"*) printf 'unparsable \n'; return 0 ;; esac
         case "$rest" in *[![:space:]]*) printf 'unparsable \n'; return 0 ;; esac
         printf 'active %s\n' "${val%%[[:space:]]*}"; return 0 ;;
  esac

  # The value runs to the closing quote. Refused: an unterminated quote, an
  # escaped closing quote, and anything after it other than blanks or a comment.
  body="${val#?}"
  case "$body" in
    *"$q"*) rest="${body#*"$q"}"; body="${body%%"$q"*}" ;;
    *)      printf 'unparsable \n'; return 0 ;;
  esac
  case "$body" in
    *\\) printf 'unparsable \n'; return 0 ;;
  esac
  # A comment starts only after a blank; a # right after the quote belongs
  # to the value.
  case "$rest" in
    ""|[[:space:]]*) ;;
    *) printf 'unparsable \n'; return 0 ;;
  esac
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$rest" in
    ""|"#"*) ;;
    *) printf 'unparsable \n'; return 0 ;;
  esac
  printf 'active %s\n' "$body"
}

# Print kernel command line $1 without the words in $2. Returns 0 when a word
# was dropped, 1 when none matched. read -a avoids globbing * and ? in $1.
grub_without_words() {
  local val="$1" drop="$2" kept="" hit=0 w d found
  local words=()
  IFS=$' \t' read -r -a words <<< "$val"
  for w in "${words[@]}"; do
    found=0
    for d in $drop; do [ "$w" = "$d" ] && { found=1; break; }; done
    if [ "$found" -eq 1 ]; then hit=1; else kept="${kept:+${kept} }${w}"; fi
  done
  printf '%s' "$kept"
  [ "$hit" -eq 1 ]
}

# Set GRUB_CMDLINE_LINUX_DEFAULT to $1: replaced in place (indentation,
# "export", quote style and trailing comment kept), or appended.
write_grub_cmdline() {
  local val="$1" tmp
  GRUB_BACKUP_KEPT=""
  tmp="$(mktemp)" || return 1

  # Passed through the environment: awk -v would eat backslashes.
  val="$val" awk -v re="$GRUB_KEY_RE" '
    BEGIN { swapped = 0; val = ENVIRON["val"] }
    !swapped && $0 ~ re {
      match($0, /^[[:space:]]*(export[[:space:]]+)?/)
      pre = substr($0, 1, RLENGTH)
      match($0, /GRUB_CMDLINE_LINUX_DEFAULT=/)
      rest = substr($0, RSTART + RLENGTH)
      # Single quotes stay, unless the value holds one.
      tail = ""; q = "\""
      if (substr(rest, 1, 1) == "\"") { i = index(substr(rest, 2), "\""); if (i > 0) tail = substr(rest, i + 2) }
      else if (substr(rest, 1, 1) == "\047") {
        i = index(substr(rest, 2), "\047"); if (i > 0) tail = substr(rest, i + 2)
        if (index(val, "\047") == 0) q = "\047"
      }
      printf "%sGRUB_CMDLINE_LINUX_DEFAULT=%s%s%s%s\n", pre, q, val, q, tail
      swapped = 1; next
    }
    { print }
    END { if (!swapped) printf "GRUB_CMDLINE_LINUX_DEFAULT=\"%s\"\n", val }
  ' /etc/default/grub > "$tmp"

  # A failed awk (a full /tmp) leaves a partial copy that may still parse.
  if [ $? -ne 0 ] || [ ! -s "$tmp" ] || ! grep -qE "$GRUB_KEY_RE" "$tmp"; then
    rm -f "$tmp"
    message warn "the /etc/default/grub rewrite did not come out right — leaving it alone"
    return 1
  fi
  install_grub_file "$tmp"
}

# Delete the GRUB_CMDLINE_LINUX_DEFAULT line this script appended.
remove_grub_cmdline_line() {
  local tmp
  GRUB_BACKUP_KEPT=""
  tmp="$(mktemp)" || return 1
  awk -v re="$GRUB_KEY_RE" '!done && $0 ~ re { done = 1; next } { print }' \
    /etc/default/grub > "$tmp" || { rm -f "$tmp"; return 1; }
  install_grub_file "$tmp"
}

# Install temporary file $1 as /etc/default/grub (atomically, its mode kept)
# and run update-grub; put the original back if either fails. The backup is
# removed only once the file is known to match it or the new content took.
install_grub_file() {
  local tmp="$1" backup="" mode grub=/etc/default/grub
  # grub-mkconfig sources the file, so it must parse as shell.
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    message warn "the rewritten /etc/default/grub would not parse as shell — leaving it alone"
    return 1
  fi
  # A package run holding the lock may run update-grub on the new file itself.
  if ! wait_dpkg_lock; then
    rm -f "$tmp"
    message warn "the dpkg lock is still held — /etc/default/grub left alone"
    return 1
  fi
  mode="$(stat -L -c %a "$grub" 2>/dev/null)" || mode=644

  # Kept in SYS_RECORDS, which survives a reboot.
  sys_records_dir 2>/dev/null \
    && backup="$(sudo mktemp "${SYS_RECORDS}/grub.before-failed-update-grub.XXXXXX")"
  [ -n "$backup" ] || backup="$(mktemp)" || { rm -f "$tmp"; return 1; }
  sudo cp "$grub" "$backup" 2>/dev/null || { rm -f "$tmp"; sudo rm -f "$backup"; return 1; }

  if sudo_write_atomic "$tmp" "$grub" "$mode"; then
    rm -f "$tmp"
    if boot_tool update-grub; then
      sudo rm -f "$backup"
      return 0
    fi
    message warn "update-grub failed — putting /etc/default/grub back as it was"
  else
    rm -f "$tmp"
    message warn "could not write /etc/default/grub"
  fi

  if sudo cmp -s "$backup" "$grub" || sudo_write_atomic "$backup" "$grub" "$mode"; then
    sudo rm -f "$backup"
  else
    message warn "could not restore /etc/default/grub — the original is kept at ${backup}"
    GRUB_BACKUP_KEPT="$backup"
  fi
  return 1
}

# Forget the words this script added to the kernel command line, and the
# other records $@.
forget_grub_words() { sudo rm -f "$GRUB_ADDED_FILE" "$GRUB_LINE_ADDED" "$@"; }

# Remove line $1 from the grub record; with $2 = "line", also the note that
# this script added the whole line.
drop_grub_record() {
  local rec
  rec="$(mktemp)" || return 1
  # grep exits 1 when no line is left, 2 on an error: the record is then kept.
  grep -vxF -- "$1" "$GRUB_ADDED_FILE" > "$rec" 2>/dev/null
  case $? in
    0) sudo_write_atomic "$rec" "$GRUB_ADDED_FILE" ;;
    1) sudo rm -f "$GRUB_ADDED_FILE" ;;
  esac
  rm -f "$rec"
  [ "${2:-}" != line ] || sudo rm -f "$GRUB_LINE_ADDED"
}

# Record an initramfs rebuild as owed; the next run makes it if this one stops.
owe_initramfs() { sys_records_dir && sudo touch "$INITRAMFS_PENDING"; }

# Rebuild the initramfs, owed on record until it succeeds, so a failure or a
# cut (power loss, a killed run) is retried by the next run.
rebuild_initramfs_recorded() {
  # Tried in this run, whatever the outcome: the next run retries a failure.
  INITRAMFS_REBUILT=1
  owe_initramfs
  # A timeout leaves the rebuild owed, as a failure does.
  wait_dpkg_lock || { message warn "the dpkg lock is still held — update-initramfs not run"; return 1; }
  if ! sudo update-initramfs -u -k all; then
    # The newest kernel at least. The others failed for a reason of their own
    # (a leftover kernel, say), which a retry would only repeat: reported once.
    sudo update-initramfs -u || return 1
    message warn "update-initramfs failed for some kernels — the newest one is rebuilt"
    INITRAMFS_PARTIAL=1
  fi
  sudo rm -f "$INITRAMFS_PENDING"
}

# Put back the boot splash theme from before the install, unless the user
# chose another since; an initramfs rebuild still owed is finished too.
# Sets PLY_WAS and PLY_CURRENT. Returns 0 restored, 1 nothing to do, 2 the
# user's own theme kept, 3 theme unreadable, 4 put-back failed, 5 initramfs
# rebuild failed after the put-back, 6 owed rebuild finished, 7 owed rebuild
# failed, 8 records not writable. On 3-5, 7 and 8 the records stay.
plymouth_put_back() {
  local ours rc
  # The theme the install set: its record, else the saved option.
  ours="$(head -1 "$PLYMOUTH_SET_FILE" 2>/dev/null)"
  ours="${ours:-$PLYMOUTH_THEME}"
  PLY_CURRENT="$(plymouth_current_theme)"
  PLY_WAS="$(cat "$PLYMOUTH_BEFORE_FILE" 2>/dev/null)"
  [ -n "$PLY_CURRENT" ] || return 3
  if [ -z "$PLY_WAS" ] || [ "$PLY_WAS" = "$PLY_CURRENT" ]; then
    # Nothing to set back; finish a rebuild an earlier run still owes.
    rc=1
    if [ -f "$INITRAMFS_PENDING" ]; then
      rebuild_initramfs_recorded || return 7
      rc=6
    fi
  elif [ "$PLY_CURRENT" != "$ours" ]; then
    rc=2
    # The user's theme stays; a rebuild still owed is made for it.
    if [ -f "$INITRAMFS_PENDING" ]; then
      rebuild_initramfs_recorded || return 7
    fi
  else
    # The rebuild is owed from before any change, so a cut run still makes it;
    # a put-back that changes nothing owes none.
    local owed_before=0
    [ -f "$INITRAMFS_PENDING" ] && owed_before=1
    owe_initramfs || return 8
    if ! put_back_plymouth_theme "$PLY_WAS"; then
      [ "$owed_before" -eq 1 ] || sudo rm -f "$INITRAMFS_PENDING"
      return 4
    fi
    rebuild_initramfs_recorded || return 5
    rc=0
  fi
  drop_plymouth_records
  return $rc
}

# Retry an initramfs rebuild an earlier run still owes, and report it.
retry_owed_initramfs() {
  [ -f "$INITRAMFS_PENDING" ] || return 0
  if rebuild_initramfs_recorded; then
    STATUS_CHANGES+=("Boot splash theme rebuilt into the initramfs")
    need_reboot
  else
    STATUS_FAILED+=("The initramfs rebuild failed again — run: sudo update-initramfs -u")
  fi
}

# $1 = set or unset: that boot splash change, then any rebuild an earlier run
# owes, unless this run rebuilt the initramfs already.
boot_splash() {
  INITRAMFS_REBUILT=0
  "${1}_boot_splash"
  [ "$INITRAMFS_REBUILT" -eq 1 ] || retry_owed_initramfs
}

# Add "quiet splash" to the kernel command line and set the Plymouth theme.
set_boot_splash() {
  local where val new opt added="" before="" kept_out=""
  where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"
  # A commented line counts as none; a new line is appended to the file.
  case "$where" in
    absent|commented) val="" ;;
    unparsable)
      message warn "/etc/default/grub is not in a shape this script will edit — leaving it alone"
      STATUS_NOCHANGE+=("/etc/default/grub left alone — the boot splash is not applied")
      return 0 ;;
  esac
  # Tabs separate parameters as spaces do.
  local val_words="${val//$'\t'/ }"

  # A drop-in in /etc/default/grub.d is read after this file and wins, unless
  # it only adds to the value: then this file is left alone.
  local overridden=0
  if grep -hsE "$GRUB_KEY_RE" /etc/default/grub.d/*.cfg \
     | grep -qvE '\$\{?GRUB_CMDLINE_LINUX_DEFAULT'; then
    overridden=1
    message warn "/etc/default/grub.d sets GRUB_CMDLINE_LINUX_DEFAULT — it overrides /etc/default/grub"
  fi

  # An earlier run stopped between recording its words and update-grub:
  # finish it if the file was written, else drop the record.
  local pending="$GRUB_ADD_PENDING" pend p_line
  if [ -f "$pending" ]; then
    pend="$(sed -n 1p "$pending")"; p_line="$(sed -n 2p "$pending")"
    if ! in_word_list "${pend%% *}" "$val_words"; then
      drop_grub_record "$pend" "$p_line"
      sudo rm -f "$pending"
    elif boot_tool update-grub; then
      sudo rm -f "$pending"; need_reboot
      STATUS_CHANGES+=("update-grub finished for '${pend}', which an interrupted run added")
    else
      STATUS_FAILED+=("update-grub failed — run: sudo update-grub")
    fi
  fi

  # Add the missing words, except recorded ones the user has since removed.
  # After a removal that stopped before update-grub: if it had written the
  # file (the recorded words are gone), the record is dropped and the words
  # are added again; otherwise the record stays.
  if [ -f "$GRUB_STRIP_PENDING" ]; then
    local rec
    rec="$(head -1 "$GRUB_ADDED_FILE" 2>/dev/null)"
    { [ -n "$rec" ] && in_word_list "${rec%% *}" "$val_words"; } || forget_grub_words
    sudo rm -f "$GRUB_STRIP_PENDING"
  fi
  before="$(tr '\n' ' ' 2>/dev/null < "$GRUB_ADDED_FILE")"
  # The first run records which words were already there, so one the user
  # takes off later is not put back either.
  if [ ! -f "$GRUB_SEEN_FILE" ]; then
    local had=""
    for opt in quiet splash; do
      in_word_list "$opt" "$val_words" && had="${had:+${had} }${opt}"
    done
    sys_record_write "$GRUB_SEEN_FILE" "$had"
  fi
  before="${before} $(cat "$GRUB_SEEN_FILE" 2>/dev/null)"
  new="$val"
  for opt in quiet splash; do
    in_word_list "$opt" "$val_words" && continue
    if in_word_list "$opt" "$before"; then
      kept_out="${kept_out:+${kept_out} }${opt}"; continue
    fi
    new="${new:+${new} }${opt}"; added="${added:+${added} }${opt}"
  done

  [ -n "$kept_out" ] && STATUS_NOCHANGE+=("'${kept_out}' left off the kernel command line — you took it off after the install")

  if [ "$overridden" = 1 ] \
     && grep -hsE "$GRUB_KEY_RE" /etc/default/grub.d/*.cfg | grep -qw quiet \
     && grep -hsE "$GRUB_KEY_RE" /etc/default/grub.d/*.cfg | grep -qw splash; then
    STATUS_NOCHANGE+=("/etc/default/grub left alone — /etc/default/grub.d sets the kernel command line, with 'quiet splash' already")
  elif [ "$overridden" = 1 ]; then
    STATUS_NOCHANGE+=("/etc/default/grub left alone — /etc/default/grub.d sets the kernel command line; add 'quiet splash' there for the boot splash")
  elif [ -z "$added" ]; then
    [ -z "$kept_out" ] && STATUS_NOCHANGE+=("/etc/default/grub already boots with 'quiet splash'")
  else
    message "adding '${added}' to GRUB_CMDLINE_LINUX_DEFAULT"
    # Record first; the pending note tells an interrupted run's successor
    # whether the file was written. With no active line before, the uninstall
    # removes the whole line.
    local line_marker=""
    sys_records_dir
    [ "$where" != active ] && [ ! -f "$GRUB_LINE_ADDED" ] && line_marker=line
    # Without the records the uninstall could not take the words off again.
    if ! { printf '%s\n%s\n' "$added" "$line_marker" | sudo_tee "$pending" \
           && sys_record_append "$GRUB_ADDED_FILE" "$added" \
           && { [ -z "$line_marker" ] || sudo touch "$GRUB_LINE_ADDED"; }; }; then
      sudo rm -f "$pending"
      drop_grub_record "$added" "$line_marker"
      STATUS_FAILED+=("/etc/default/grub left alone — the boot splash records could not be written")
      return 0
    fi
    if write_grub_cmdline "$new"; then
      sudo rm -f "$pending"
      STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"")
      need_reboot
    else
      # With the original not put back, the note and record stay: a later
      # run finishes update-grub.
      [ -n "$GRUB_BACKUP_KEPT" ] || { sudo rm -f "$pending"; drop_grub_record "$added" "$line_marker"; }
      STATUS_FAILED+=("/etc/default/grub could not be updated")
      [ -n "$GRUB_BACKUP_KEPT" ] \
        && STATUS_FAILED+=("the file as it was before that attempt is at ${GRUB_BACKUP_KEPT}")
      return 0
    fi
  fi

  # Plymouth theme; the previous one is recorded once for the uninstall.
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("No Plymouth on this system — boot splash theme left alone")
    return 0
  fi

  local current new_record=0 owed_before=0
  current="$(plymouth_current_theme)"

  if [ -z "$current" ]; then
    STATUS_NOCHANGE+=("Could not read the current boot splash theme — left as it is")
  elif [ "$current" = "$PLYMOUTH_THEME" ]; then
    # Record it, so a later user choice is left alone.
    [ -f "$PLYMOUTH_BEFORE_FILE" ] || sys_record_write "$PLYMOUTH_BEFORE_FILE" "$current"
    [ -f "$PLYMOUTH_SET_FILE" ] \
      || sys_record_write "$PLYMOUTH_SET_FILE" "$current"
    STATUS_NOCHANGE+=("Boot splash theme already '${PLYMOUTH_THEME}'")
  elif [ -f "$PLYMOUTH_SET_FILE" ] && [ -z "$PLYMOUTH_THEME_GIVEN" ]; then
    # Set by the look and changed by the user since (the record of the
    # earlier theme alone may be from a run cut off before setting it); a
    # PLYMOUTH_THEME given to this run overrides.
    STATUS_NOCHANGE+=("Boot splash theme left as you set it ('${current}')")
  elif ! plymouth_theme_installed "$PLYMOUTH_THEME"; then
    # A theme the user asked for is a failure; the default one missing is not.
    if [ -n "$PLYMOUTH_THEME_GIVEN" ]; then
      STATUS_FAILED+=("Boot splash theme '${PLYMOUTH_THEME}' is not installed — the theme stays '${current}'")
    else
      STATUS_NOCHANGE+=("Boot splash theme '${PLYMOUTH_THEME}' is not installed — left as it is")
    fi
  else
    message "setting the boot splash theme to '${PLYMOUTH_THEME}'"
    # Without both records the uninstall could not put the theme back.
    if [ ! -f "$PLYMOUTH_BEFORE_FILE" ]; then
      sys_record_write "$PLYMOUTH_BEFORE_FILE" "$current" && new_record=1
    fi
    if [ ! -f "$PLYMOUTH_BEFORE_FILE" ] || ! save_plymouth_conf; then
      [ "$new_record" -eq 1 ] && drop_plymouth_records
      message warn "could not write the boot splash records — the theme stays '${current}'"
      STATUS_FAILED+=("Boot splash theme left as '${current}' — its records could not be written in ${SYS_RECORDS}")
    elif { [ -f "$INITRAMFS_PENDING" ] && owed_before=1; owe_initramfs; } \
         && sys_record_write "$PLYMOUTH_SET_FILE" "$PLYMOUTH_THEME" \
         && boot_tool plymouth-set-default-theme "$PLYMOUTH_THEME"; then
      if rebuild_initramfs_recorded; then
        STATUS_CHANGES+=("Boot splash theme set to '${PLYMOUTH_THEME}' (was '${current}')")
      else
        STATUS_FAILED+=("Boot splash theme changed, but the initramfs rebuild failed — run: sudo update-initramfs -u")
      fi
      need_reboot
    else
      # Drop only records made by this attempt; an older one is the original.
      [ "$new_record" -eq 1 ] \
        && drop_plymouth_records
      [ "$owed_before" -eq 1 ] || sudo rm -f "$INITRAMFS_PENDING"
      message warn "could not set the boot splash theme to '${PLYMOUTH_THEME}'"
      STATUS_FAILED+=("Boot splash theme could not be set to '${PLYMOUTH_THEME}'")
    fi
  fi
}

# Remove the recorded words from GRUB_CMDLINE_LINUX_DEFAULT; a line this
# script appended goes whole once nothing else is on it. Sets GRUB_ADDED_WORDS
# (the recorded words) and GRUB_CMDLINE_NEW. Returns 0 = done, 1 = words
# already gone, 2 = file unparsable, 3 = write failed.
strip_grub_words() {
  local where val pending="$GRUB_STRIP_PENDING"
  GRUB_ADDED_WORDS="$(tr '\n' ' ' < "$GRUB_ADDED_FILE")"
  GRUB_ADDED_WORDS="${GRUB_ADDED_WORDS% }"
  where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"
  [ "$where" = unparsable ] && return 2
  if ! GRUB_CMDLINE_NEW="$(grub_without_words "$val" "$GRUB_ADDED_WORDS")" || [ "$where" != active ]; then
    # An earlier run wrote the file but stopped before update-grub finished.
    if [ -f "$pending" ]; then
      message "finishing the update-grub an earlier run left undone"
      boot_tool update-grub || return 3
      GRUB_CMDLINE_NEW="$val"
      forget_grub_words "$pending"
      return 0
    fi
    forget_grub_words
    return 1
  fi
  message "removing '${GRUB_ADDED_WORDS}' from GRUB_CMDLINE_LINUX_DEFAULT"
  sudo touch "$pending"
  if [ -z "$GRUB_CMDLINE_NEW" ] && [ -f "$GRUB_LINE_ADDED" ]; then
    # Kept when the original could not be put back: a later run then finishes it.
    remove_grub_cmdline_line || { [ -n "$GRUB_BACKUP_KEPT" ] || sudo rm -f "$pending"; return 3; }
  else
    write_grub_cmdline "$GRUB_CMDLINE_NEW" || { [ -n "$GRUB_BACKUP_KEPT" ] || sudo rm -f "$pending"; return 3; }
  fi
  forget_grub_words "$pending"
  return 0
}

# UBUNTU_BOOT_SPLASH=0: remove the recorded words from the kernel command line
# and restore the previous Plymouth theme.
unset_boot_splash() {
  if [ -f "$GRUB_ADDED_FILE" ] \
     && { [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; }; then
    STATUS_NOCHANGE+=("GRUB is gone — the words this script added cannot be removed")
    forget_grub_words
  elif [ -f "$GRUB_ADDED_FILE" ]; then
    local _line_was_added=0
    [ -f "$GRUB_LINE_ADDED" ] && _line_was_added=1
    strip_grub_words
    case $? in
      0) if [ -z "$GRUB_CMDLINE_NEW" ] && [ "$_line_was_added" = 1 ]; then
           STATUS_CHANGES+=("/etc/default/grub: the GRUB_CMDLINE_LINUX_DEFAULT line this script added is removed")
         else
           STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"")
         fi
         need_reboot ;;
      1) STATUS_NOCHANGE+=("/etc/default/grub no longer carries what this script added") ;;
      2) message warn "/etc/default/grub is not in a shape this script will edit — leaving it alone"
         STATUS_NOCHANGE+=("/etc/default/grub left alone — remove '${GRUB_ADDED_WORDS}' by hand if you want it gone") ;;
      *) STATUS_FAILED+=("/etc/default/grub could not be updated — '${GRUB_ADDED_WORDS}' is still on the kernel command line")
         [ -n "$GRUB_BACKUP_KEPT" ] \
           && STATUS_FAILED+=("the file as it was before that attempt is at ${GRUB_BACKUP_KEPT}") ;;
    esac
  else
    STATUS_NOCHANGE+=("Nothing of this script's is on the kernel command line")
  fi

  # Restore the previous theme, unless the user has chosen another since.
  if [ -f "$PLYMOUTH_BEFORE_FILE" ] && ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("Plymouth is gone — no boot splash theme to put back")
    drop_plymouth_records
  elif [ -f "$PLYMOUTH_BEFORE_FILE" ]; then
    plymouth_put_back
    case $? in
      0) STATUS_CHANGES+=("Boot splash theme restored to '${PLY_WAS}'"); need_reboot ;;
      1) if [ -z "$PLY_WAS" ]; then
           STATUS_NOCHANGE+=("No earlier boot splash theme was recorded — left on '${PLY_CURRENT}'")
         else
           STATUS_NOCHANGE+=("Boot splash theme is already '${PLY_CURRENT}'")
         fi ;;
      2) STATUS_NOCHANGE+=("Boot splash theme left on '${PLY_CURRENT}', which you chose after the install") ;;
      3) STATUS_FAILED+=("Could not read the boot splash theme — not restored; run this again later") ;;
      4) message warn "could not set the Plymouth theme back to '${PLY_WAS}' — it may no longer be installed"
         STATUS_FAILED+=("Boot splash theme still not '${PLY_WAS}' — the record is kept at ${PLYMOUTH_BEFORE_FILE}") ;;
      5) STATUS_FAILED+=("Boot splash theme set to '${PLY_WAS}', but the initramfs rebuild failed — run: sudo update-initramfs -u") ;;
      6) STATUS_CHANGES+=("Boot splash theme rebuilt into the initramfs"); need_reboot ;;
      7) STATUS_FAILED+=("The initramfs rebuild still owed failed — run: sudo update-initramfs -u") ;;
      8) STATUS_FAILED+=("Boot splash theme not put back — ${SYS_RECORDS} could not be written; run this again") ;;
    esac
  fi

  return 0
}

###############################################################################
# 5. Records: --refresh, summary
###############################################################################

# What a run is resolved against: Debian, gnome-shell, architecture, the
# release options of this run (as save_options writes them) and the Ubuntu
# releases. Compared by later runs and by --refresh.
release_fingerprint() {
  local pinned pinned_ver configured
  echo "debian $(debian_codename)"
  echo "shell $(shell_major)"
  # Debian's gnome-shell build: an update of it may make another release fit.
  echo "shell-build $(dpkg-query -W -f='${Version}' gnome-shell 2>/dev/null)"
  echo "arch ${UBUNTU_ARCH}"
  # A new pin format counts as a change.
  echo "format ${PIN_VERSION}"
  # shellcheck disable=SC2086
  option_lines $RELEASE_OPTION_NAMES | sed 's/^/option /'
  pinned="$(pinned_codename)"
  pinned_ver="$(awk -v c="$pinned" '$1 == c { print $2; exit }' "$UBUNTU_RELEASE_CACHE" 2>/dev/null)"
  configured=" $(configured_codenames | xargs) "
  # "newer" only for listed releases; retired ones are not probed. The C
  # locale reads "25.04" as a number everywhere.
  LC_ALL=C awk -v conf="$configured" -v known=" ${UBUNTU_ALL_CODENAMES:-} " -v pv="${pinned_ver:-0}" '
    index(conf, " " $1 " ")                            { print "configured", $1, $4 }
    index(known, " " $1 " ") && ($2 + 0) > (pv + 0)    { print "newer", $1, $3 }
  ' "$UBUNTU_RELEASE_CACHE" 2>/dev/null
}

# True when the apt pin is in this script's current format.
pin_is_current() { grep -q "# pin-version: ${PIN_VERSION}" "$UBUNTU_PIN" 2>/dev/null; }

# True when nothing changed since the last install run; sets KEPT_CODENAME.
unchanged_since_last_run() {
  local pinned tmp rc=1
  [ -f "$UBUNTU_SOURCES" ] && readable_regular_file "$RELEASE_STATE" || return 1
  # Only when the last install run also chose automatically.
  grep -qx 'UBUNTU_CODENAME=auto' "$SAVED_OPTIONS" 2>/dev/null || return 1
  pin_is_current || return 1
  pinned="$(pinned_codename)"
  [ -n "$pinned" ] && configured_codenames | grep -qxF "$pinned" || return 1
  tmp="$(fingerprint_file)"
  cmp -s "$tmp" "$RELEASE_STATE" && { KEPT_CODENAME="$pinned"; rc=0; }
  rm -f "$tmp"
  return $rc
}

# The current fingerprint in a new temporary file; prints its path.
fingerprint_file() {
  local tmp
  tmp="$(mktemp)" && release_fingerprint | sort -u > "$tmp" && echo "$tmp"
}

# --refresh: list what an update would change, then ask. Exits when there is
# nothing to do or the user declines; returns to apply the update. Before
# the answer it changes nothing but apt's package lists.
refresh_check() {
  local tmp line key p have cand running bound log rc findings=0 combined=0
  echo ""
  message "refreshing apt's package lists (nothing is installed yet)"
  # Plain apt update: its fallbacks (a mirror without universe) would edit
  # the apt source before the user agrees.
  log="$(mktemp)" || error "Could not create a temporary file."
  apt_update_waiting "$log" quiet
  rc=$?
  if [ "$rc" -ne 0 ]; then
    grep -q 'Could not get lock' "$log" && { rm -f "$log"; error "apt is in use by another program — try again later."; }
    message warn "apt reported errors while refreshing its lists; the list below may be incomplete"
  else
    # Only a clean refresh spares the update its second apt update.
    APT_LISTS_FRESH=1
  fi
  rm -f "$log"

  echo ""
  echo "Updates for the Ubuntu look:"
  # The Ubuntu release and what it depends on.
  if [ "$UBUNTU_CODENAME" != auto ]; then
    echo "  = Ubuntu release fixed by UBUNTU_CODENAME=${UBUNTU_CODENAME}"
    if ! pin_is_current; then
      echo "  + This script writes a newer apt pin"
      findings=$((findings + 1))
    fi
  elif unchanged_since_last_run; then
    REFRESH_UNCHANGED=1
    echo "  = Ubuntu ${KEPT_CODENAME}: nothing changed since it was chosen"
  elif ! readable_regular_file "$RELEASE_STATE"; then
    echo "  + No record of the releases checked last time: the Ubuntu release is checked again"
    findings=$((findings + 1))
  else
    tmp="$(fingerprint_file)"
    while read -r line; do
      key="${line#?}"
      case "$line" in
        ">debian "*)     echo "  + Debian release is now ${key#debian }" ;;
        ">shell "*)      echo "  + GNOME Shell is now ${key#shell }" ;;
        ">shell-build "*) echo "  + Debian's GNOME Shell build is now ${key#shell-build }: the Ubuntu release is checked again" ;;
        ">arch "*)       echo "  + Architecture is now ${key#arch }" ;;
        ">format "*)     echo "  + This script writes a newer apt pin" ;;
        ">option "*)     echo "  + Option changed: ${key#option }" ;;
        ">newer "*)      set -- $key
                         echo "  + Newer Ubuntu release published: $2 ($(ubuntu_release_info "$2" | cut -d' ' -f1)); whether it fits GNOME Shell $(shell_major) is checked when applying" ;;
        ">configured "*) set -- $key; echo "  + Ubuntu $2 is now served from $3" ;;
        *)               continue ;;
      esac
      findings=$((findings + 1))
    done < <(diff "$RELEASE_STATE" "$tmp" | sed -n 's/^\([<>]\) /\1/p')
    # Only lines that went away (a retired release, a dropped option), or a
    # missing apt source or pin.
    if [ "$findings" -eq 0 ]; then
      echo "  + The Ubuntu releases on offer or the look's apt source changed: the Ubuntu release is checked again"
      findings=1
    fi
    rm -f "$tmp"
  fi
  # Options outside the fingerprint: one given now that differs from the
  # saved one. The boot options always; the release options when the release
  # is fixed (the fingerprint is not compared then).
  local -a opts
  local names="$BOOT_OPTION_NAMES"
  [ "$UBUNTU_CODENAME" = auto ] || names="$SAVED_OPTION_NAMES"
  # shellcheck disable=SC2086
  mapfile -t opts < <(option_lines $names)
  for line in "${opts[@]}"; do
    grep -q "^${line%%=*}=" "$SAVED_OPTIONS" 2>/dev/null || continue
    grep -qxF "$line" "$SAVED_OPTIONS" && continue
    echo "  + Option changed: ${line}"
    findings=$((findings + 1))
  done

  # Newer builds of the look's packages, and packages it lacks, as the update
  # would handle them.
  is_installed "$COMBINED_EXT_PKG" && combined=1
  for p in $ALL_STAGE_PACKAGES; do
    # Replaced by the combined package, which carries them.
    [ "$combined" -eq 1 ] && in_word_list "$p" "$SEPARATE_EXT_PKGS" && continue
    have="$(pkg_installed_version "$p")"
    if [ -n "$have" ]; then
      is_held "$p" && continue
      # A package the user had before the look is left to their own apt upgrade.
      predates_install "$p" && ! in_word_list "$p" "$LOOK_PACKAGES" && continue
    fi
    cand="$(refresh_target "$p" "$have")"
    [ -n "$cand" ] || continue
    if [ -z "$have" ]; then
      echo "  + ${p}: not installed; the look installs ${cand}"
    else
      echo "  + ${p}: ${have} → ${cand}"
    fi
    findings=$((findings + 1))
  done
  if [ "$combined" -eq 1 ]; then
    have="$(pkg_installed_version "$COMBINED_EXT_PKG")"
    cand=""
    is_held "$COMBINED_EXT_PKG" || cand="$(refresh_target "$COMBINED_EXT_PKG" "$have")"
    if [ -n "$cand" ]; then
      echo "  + ${COMBINED_EXT_PKG}: ${have} → ${cand}"
      findings=$((findings + 1))
    fi
  fi

  # Extensions the installed GNOME Shell has moved past. Not an update by
  # itself: a release that supports it shows above as a newer release or a
  # GNOME Shell change; until Ubuntu has one, applying cannot help.
  running="$(shell_major)"
  for p in $UBUNTU_SHELL_EXT_PKGS; do
    is_installed "$p" || continue
    bound="$(pkg_shell_upper_bound "$p")"
    [ -n "$running" ] && [ -n "$bound" ] && [ "$running" -ge "$bound" ] || continue
    echo "  ! ${p} does not support GNOME Shell ${running}; a release that does is listed above when Ubuntu has one"
  done

  echo ""
  if [ "$findings" -eq 0 ]; then
    message "The Ubuntu look is up to date — nothing to apply."
    exit 0
  fi
  message "${findings} update(s) found. Apply them now?"
  ask_yes || { message "Nothing changed."; exit 0; }
}

# Save the fingerprint that later runs and --refresh compare against.
save_release_state() {
  local tmp
  tmp="$(fingerprint_file)"
  sudo_install_if_changed "$tmp" "$RELEASE_STATE"
  rm -f "$tmp"
}

# Log the installed packages, the pin, the extension states, the Plymouth
# theme, kernel command line, GTK and icon themes, wallpaper, favourites,
# terminal profile and shortcut, and the subpixel rule.
log_final_state() {
  local p e state v enabled

  echo ""
  echo "--- state after this run ---"
  for p in $ALL_STAGE_PACKAGES; do
    printf '  %-46s %s\n' "$p" "$(pkg_installed_version "$p" || echo 'not installed')"
  done
  v="$(pkg_installed_version "$COMBINED_EXT_PKG")" \
    && printf '  %-46s %s\n' "$COMBINED_EXT_PKG" "$v"

  echo "  pin            : $(grep -m1 '^Pin: release o=Ubuntu, n=' "$UBUNTU_PIN" 2>/dev/null || echo 'none')"
  echo "  enabled-ext    : $(dconf_show /org/gnome/shell/enabled-extensions)"
  echo "  disabled-ext   : $(dconf_show /org/gnome/shell/disabled-extensions)"
  enabled="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  for e in $SHELL_EXTENSIONS; do
    optional_extension_missing "$e" && continue
    # The running shell knows only the extensions present at login.
    state="$(LC_ALL=C gnome-extensions info "$e" 2>/dev/null | awk -F': ' '/State/{print $2}')"
    if [ -z "$state" ]; then
      if ! extension_installed "$e"; then state="not installed"
      elif ! in_word_list "$e" "$enabled" \
           && [ ! -f "$EXT_AUTOSTART_FILE" ]; then state="off"
      elif [ "$REBOOT_NEEDED" -eq 1 ]; then state="active after the reboot"
      else state="active after you log in again"; fi
    fi
    printf '  %-46s %s\n' "$e" "$state"
  done

  echo "  plymouth theme : $(plymouth_current_theme)"
  echo "  kernel cmdline : $(read_grub_cmdline)"
  echo "  gtk-theme      : $(dconf_show /org/gnome/desktop/interface/gtk-theme)"
  echo "  term profile   : $(dconf_show /org/gnome/terminal/legacy/profiles:/default)"
  echo "  term shortcut  : $(dconf_show "${TERMINAL_SHORTCUT_PATH}binding")"
  echo "  subpixel conf  : $([ -f "$SUBPIXEL_CONF" ] && echo "$SUBPIXEL_CONF" || echo none)"
  echo "  icon-theme     : $(dconf_show /org/gnome/desktop/interface/icon-theme)"
  echo "  wallpaper      : $(dconf_show /org/gnome/desktop/background/picture-uri)"
  echo "  favorite-apps  : $(dconf_show /org/gnome/shell/favorite-apps)"
  echo "--- end of state ---"
}

# One summary section: colour, heading, mark, hint (may be empty), then the
# items. Nothing is printed without items.
summary_block() {
  local colour="$1" heading="$2" mark="$3" hint="$4"
  shift 4
  [ $# -gt 0 ] || return 0
  echo -e "${colour}${heading}${ENDCOLOR}"
  printf "   ${mark} %s\n" "$@"
  [ -z "$hint" ] || echo -e "   ${YELLOW}${hint}${ENDCOLOR}"
}

# The EXIT trap's summary of the install run.
print_summary() {
  local rc=$?
  # Nothing ran yet: a wrong argument, a declined prompt. (--download has its
  # own EXIT trap and summary.)
  [ "${RUN_STARTED:-0}" = 1 ] || return 0
  # A finished run added it before its exit status; a stopped one adds it here.
  [ "$INITRAMFS_PARTIAL" = 1 ] && [ "$RUN_FINISHED" != 1 ] && STATUS_FAILED+=("$INITRAMFS_PARTIAL_NOTE")
  [ "$GSETTINGS_RECLAIMED" -gt 0 ] \
    && STATUS_CHANGES+=("${GSETTINGS_RECLAIMED} stored copy/copies of Ubuntu's values handed back to its defaults (nothing looks different)")
  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  echo -e "${GREEN}                        SUMMARY${ENDCOLOR}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"

  summary_block "$GREEN"  "Installed this run (${#STATUS_INSTALLED[@]}):" + "" "${STATUS_INSTALLED[@]}"
  summary_block "$GREEN"  "Upgraded this run (${#STATUS_UPGRADED[@]}):" "^" "" "${STATUS_UPGRADED[@]}"
  summary_block "$YELLOW" "Already installed and current (${#STATUS_ALREADY[@]}):" = "" "${STATUS_ALREADY[@]}"
  summary_block "$YELLOW" "Kept at the last compatible build (${#STATUS_HELD[@]}):" = \
    "A newer build exists but will not install here — the installed one is the newest that fits." \
    "${STATUS_HELD[@]}"
  summary_block "$RED" "Not in the bundle — skipped (${#STATUS_UNAVAIL[@]}):" "!" \
    "Refresh it on an online machine: bash ubuntu-look.sh --download" "${STATUS_UNAVAIL[@]}"
  summary_block "$RED" "Not done (${#STATUS_FAILED[@]}):" "!" \
    "Everything else was applied. Each line gives the reason." "${STATUS_FAILED[@]}"
  summary_block "$RED" "Extensions not switched on yet (${#STATUS_EXT_FAILED[@]}):" "!" \
    "Those that are installed are switched on at your next login by the one-shot autostart entry." \
    "${STATUS_EXT_FAILED[@]}"
  summary_block "$GREEN"  "Configuration changes:" + "" "${STATUS_CHANGES[@]}"
  summary_block "$YELLOW" "Already in place (no change):" = "" "${STATUS_NOCHANGE[@]}"

  echo ""
  if [ $((GSETTINGS_UNCHANGED + ${#SETTINGS_KEPT[@]})) -gt 0 ]; then
    echo -e "GNOME settings: ${GREEN}${GSETTINGS_UNCHANGED} follow Ubuntu's defaults${ENDCOLOR}, ${YELLOW}${#SETTINGS_KEPT[@]} keep your own value${ENDCOLOR}"
    echo ""
  fi
  [ ${#SETTINGS_KEPT[@]} -gt 0 ] && {
    echo -e "${YELLOW}Your own settings, kept as they are (${#SETTINGS_KEPT[@]}):${ENDCOLOR}"
    printf '   = %s\n' "${SETTINGS_KEPT[@]}"
    echo -e "   ${YELLOW}Ubuntu's value is the system default; yours overrides it. 'dconf reset <key>' takes Ubuntu's.${ENDCOLOR}"
    echo ""
  }

  log_final_state

  # A run that finished exits 1 when a step was not done; that is no stop.
  if [ $rc -ne 0 ] && [ "$RUN_FINISHED" != 1 ]; then
    echo -e "${RED}✗  Script stopped (rc=$rc). See the ERROR or WARN lines above.${ENDCOLOR}"
  elif [ "$PREPARE_UPGRADE" = 1 ] && [ ${#STATUS_FAILED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓  Ready.${ENDCOLOR} Upgrade Debian and reboot, then run this script again as step 4 above shows."
  elif [ "$PREPARE_UPGRADE" = 1 ]; then
    echo -e "${RED}✗  Not ready for the Debian upgrade.${ENDCOLOR} Resolve the items listed above as not done, then run --prepare-upgrade again."
  elif [ $REBOOT_NEEDED -eq 1 ]; then
    echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for the boot splash and kernel command line."
    echo -e "   The reboot also applies the theme and extensions; no separate log out is needed."
    echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
  elif [ $RELOGIN_NEEDED -eq 1 ]; then
    echo -e "${YELLOW}⚠  Log out and back in${ENDCOLOR} so the new theme and extensions apply."
    echo -e "   The system defaults are already compiled; one new login applies them."
  elif [ $(( ${#STATUS_FAILED[@]} + ${#STATUS_EXT_FAILED[@]} + ${#STATUS_UNAVAIL[@]} )) -gt 0 ]; then
    echo -e "${YELLOW}⚠  Done, except the items listed above as not done — each gives its reason.${ENDCOLOR}"
  elif [ ${#STATUS_CHANGES[@]} -gt 0 ]; then
    echo -e "${GREEN}✓  Done — no re-login needed.${ENDCOLOR}"
  else
    echo -e "${GREEN}✓  Nothing changed — the Ubuntu look was already in place.${ENDCOLOR}"
  fi
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
}

# Remove the run's release cache and its suite memo.
rm_release_cache() { rm -f "${UBUNTU_RELEASE_CACHE:-}" "${UBUNTU_RELEASE_CACHE:+${UBUNTU_RELEASE_CACHE}.suites}"; }

# The EXIT trap's cleanup; returns the exit status for print_summary.
_on_exit() {
  local rc=$?
  # A second Ctrl-C must not cut the clean-up and the summary short.
  trap '' INT HUP TERM
  rm_release_cache
  rm -f "${LOCAL_SOURCES:-}"
  # Stopped while the widened apt source was being tried: put it back.
  [ -f "${PREV_UBUNTU_SOURCES:-}" ] && restore_prev_ubuntu_sources
  # A --download that stopped before its own EXIT trap: its sudo keepalive.
  stop_sudo_keepalive
  return $rc
}

# Stop the background loop that keeps sudo's timestamp alive.
stop_sudo_keepalive() {
  [ -n "${SUDO_KEEPALIVE_PID:-}" ] || return 0
  pkill -P "$SUDO_KEEPALIVE_PID" 2>/dev/null
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  SUDO_KEEPALIVE_PID=""
}

# Make the next run, and --refresh, re-evaluate the state this script left.
invalidate_release_state() {
  [ ! -e "$RELEASE_STATE" ] || sudo rm -f "$RELEASE_STATE"
}

###############################################################################
# 6. Offline: --download, --offline, --prepare-upgrade
###############################################################################

# Before a Debian release upgrade: remove the shell-coupled Ubuntu packages, the
# Ubuntu source and the pin. A later run restores the look.
prepare_debian_upgrade() {
  local pkg ver drop="" held="" f files=""
  PREPARE_UPGRADE=1

  message "Preparing this system for a Debian release upgrade."
  sudo -v || error "sudo is required."
  take_run_lock

  [ -f "$UBUNTU_SOURCES" ] \
    || message warn "the Ubuntu apt source is already gone — going by version strings instead"

  # The packages tied to the installed GNOME Shell, which the upgrade would break.
  # A build no index lists any more is Ubuntu's by its version string.
  for pkg in $UBUNTU_SHELL_EXT_PKGS yaru-theme-gnome-shell; do
    ver="$(pkg_installed_version "$pkg")" || continue
    pkg_origin_is_ubuntu "$pkg" \
      || { [[ "$ver" == *ubuntu* ]] && ! pkg_version_is_debian "$pkg" "$ver"; } \
      || continue
    # apt does not remove a held package; the user decides.
    if is_held "$pkg"; then held="${held} ${pkg}"; else drop="${drop} ${pkg}"; fi
  done
  drop="$(echo "$drop" | xargs)"
  held="$(echo "$held" | xargs)"
  # Anything more apt would remove with them, simulated first.
  local _rm_sim _rm_extra=""
  if [ -n "$drop" ]; then
    # shellcheck disable=SC2086
    _rm_sim="$(LC_ALL=C apt-get -s remove $drop 2>&1)" \
      || error "apt cannot remove ${drop} — resolve that before upgrading Debian."
    _rm_extra="$(ALLOWED_REMOVALS="$drop" unexpected_removals "$_rm_sim")"
  fi
  for f in "$UBUNTU_SOURCES" "$UBUNTU_PIN"; do
    [ -f "$f" ] && files="${files} ${f}"
  done

  # A fixed release saved for later runs would pin the old one again.
  local rerun="bash ubuntu-look.sh"
  awk -F= '$1 == "UBUNTU_CODENAME" && $2 != "auto" { f = 1 } END { exit !f }' "$SAVED_OPTIONS" 2>/dev/null \
    && rerun="UBUNTU_CODENAME=auto ${rerun}"

  # What will change, before anything does.
  echo ""
  echo "Before the Debian upgrade, this removes:"
  if [ -n "$drop" ]; then
    echo "  Packages tied to the current GNOME Shell (the look installs the new release's afterwards):"
    printf '    - %s\n' $drop
  fi
  if [ -n "$_rm_extra" ]; then
    echo "  Packages apt removes with them (not put back automatically; reinstall them"
    echo "  yourself after the upgrade if you want them):"
    printf '    ! %s\n' $_rm_extra
  fi
  if [ -n "$files" ]; then
    echo "  apt files the look added (its Ubuntu source and pin):"
    printf '    - %s\n' $files
  fi
  if [ -n "$held" ]; then
    echo "  Kept, as they are on hold (they block the upgrade; 'sudo apt-mark unhold' them first):"
    printf '    ! %s\n' $held
  fi
  if [ -z "${drop}${files}${held}" ]; then
    echo "  nothing: no Ubuntu source, pin or GNOME Shell-tied package is left"
  fi
  echo "It keeps Yaru's app, icon and sound themes, the fonts, the wallpapers and"
  echo "ubuntu-keyring, so the desktop keeps most of its look during the upgrade."
  echo "'${rerun}' afterwards installs the look for the new GNOME Shell."
  echo ""
  if [ -n "${drop}${files}" ]; then
    # Declined: nothing was changed, so no summary.
    ask_yes || error "Aborted — nothing was changed."
  fi
  RUN_STARTED=1

  if [ -n "$drop" ]; then
    message "removing GNOME Shell-coupled Ubuntu packages: ${drop}"
    # Recorded first, so the uninstall reinstalls Debian's builds even after
    # an interrupted removal; it checks what is installed.
    # shellcheck disable=SC2086
    { sys_record_append "$REMOVED_FOR_UPGRADE" "$(printf '%s\n' $drop)" \
      && sys_record_sort "$REMOVED_FOR_UPGRADE"; } \
      || error "Could not record ${drop} in ${REMOVED_FOR_UPGRADE} — nothing was removed."
    # shellcheck disable=SC2086
    sudo apt-get remove -y $drop \
      || error "Could not remove ${drop} — resolve that before upgrading Debian."
    STATUS_CHANGES+=("Removed GNOME Shell-coupled Ubuntu packages: ${drop}")
    # Removing Ubuntu Dock takes Dash-to-Dock's settings file with it.
    if is_installed gnome-shell-extension-dashtodock \
       && [ ! -f /usr/share/glib-2.0/schemas/org.gnome.shell.extensions.dash-to-dock.gschema.xml ]; then
      if sudo apt-get install -y --reinstall gnome-shell-extension-dashtodock; then
        STATUS_CHANGES+=("Reinstalled Dash-to-Dock, whose settings file Ubuntu Dock had taken over")
      else
        STATUS_FAILED+=("Dash-to-Dock lost its settings file — run: sudo apt install --reinstall gnome-shell-extension-dashtodock")
      fi
    fi
  fi

  # The keyring stays: no source names it now, and a re-run needs it.
  for f in $files; do
    if sudo rm -f "$f"; then STATUS_CHANGES+=("Removed ${f}"); else STATUS_FAILED+=("Could not remove ${f}"); fi
  done
  # Saved copies from an interrupted --download would bring them back.
  [ -e "$DOWNLOAD_SAVED" ] && sudo rm -rf "$DOWNLOAD_SAVED"

  [ -n "$files" ] && { sudo apt-get update || message warn "apt update reported an error"; }

  # Not ready while a file stays or a held package blocks the upgrade.
  [ -n "$held" ] \
    && STATUS_FAILED+=("On hold, blocking the Debian upgrade: ${held} — 'sudo apt-mark unhold' them, then run --prepare-upgrade again")
  if [ ${#STATUS_FAILED[@]} -gt 0 ]; then
    message warn "not ready for the Debian upgrade — see the items listed as not done"
    RUN_FINISHED=1
    exit 1
  fi

  message ""
  local codename
  codename="$(debian_codename)"
  local gone=""
  [ -n "$files" ] && gone="the Ubuntu source and pin"
  [ -n "$drop" ] && gone="${gone:+${gone} and }the GNOME Shell-tied packages"
  if [ -n "$gone" ]; then
    message "${GREEN}Done.${ENDCOLOR} Removed ${gone}; the rest of the look stays. Now:"
  else
    message "${GREEN}Done.${ENDCOLOR} Nothing needed removing; the rest of the look stays. Now:"
  fi
  message "  1. point your Debian entries at the new release: replace '${codename:-<current codename>}' with the"
  message "     next codename in /etc/apt/sources.list and /etc/apt/sources.list.d/*"
  message "  2. sudo apt update && sudo apt full-upgrade     # the Debian release upgrade"
  message "  3. reboot"
  message "  4. $(printf '%-45s' "$rerun")# restores the Ubuntu look"
  message ""
  message "Step 4 re-resolves everything against the new GNOME Shell."
}

# .deb files for package $1 on this architecture, in the bundle or in $2.
bundle_debs() {
  local f dir="${2:-$PACKAGES_DIR}"
  for f in "${dir}/${1}"_*_"${UBUNTU_ARCH}".deb "${dir}/${1}"_*_all.deb; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# Newest version of $1 in the bundle, empty if absent.
bundled_version() {
  local f v best=""
  while read -r f; do
    [ -n "$f" ] || continue
    v="$(dpkg-deb -f "$f" Version 2>/dev/null)" || continue
    if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best="$v"; fi
  done < <(bundle_debs "$1")
  printf '%s' "$best"
}

# Take $1 out of the bundle for this run; bundle_discard_restore puts it back.
bundle_discard() {
  local rel="${1#"$PACKAGES_DIR"/}"
  mkdir -p "${DISCARD_DIR}/$(dirname "$rel")" && mv -f "$1" "${DISCARD_DIR}/${rel}"
}

# Put back what bundle_discard took out. With "indexed", a top-level .deb that
# packages/Packages does not list is deleted instead.
bundle_discard_restore() {
  local f rel
  [ -d "$DISCARD_DIR" ] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"$DISCARD_DIR"/}"
    if [ "${1:-}" = indexed ] && [ "$rel" = "${rel##*/}" ] \
       && ! grep -qxF "Filename: ./${rel}" "${PACKAGES_DIR}/Packages" 2>/dev/null; then
      continue
    fi
    mkdir -p "${PACKAGES_DIR}/$(dirname "$rel")" && mv -f "$f" "${PACKAGES_DIR}/${rel}" && BUNDLE_DIRTY=1
  done < <(find "$DISCARD_DIR" -type f -name '*.deb' -print0)
  rm -rf "$DISCARD_DIR"
}

# Print the .deb of package $1 at version $3 in directory $2; non-zero if none.
bundle_has_version() {
  local f
  while read -r f; do
    [ -n "$f" ] && [ "$(dpkg-deb -f "$f" Version 2>/dev/null)" = "$3" ] && { echo "$f"; return 0; }
  done < <(bundle_debs "$1" "$2")
  return 1
}

# Move builds of $1 other than version $2 out of the bundle.
drop_superseded() {
  local f keep rc=1
  keep="$(bundle_has_version "$1" "$PACKAGES_DIR" "$2")" || return 1
  while read -r f; do
    [ -n "$f" ] && [ "$f" != "$keep" ] || continue
    bundle_discard "$f" && rc=0
  done < <(bundle_debs "$1")
  return $rc
}

# Names in the Depends/Pre-Depends closure of $@, at their candidate versions.
dep_closure() {
  [ $# -gt 0 ] || return 0
  LC_ALL=C apt-cache "${BUILD_APT_OPTS[@]}" depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances "$@" 2>/dev/null | grep -E '^[a-z0-9]' | LC_ALL=C sort -u
}

# "<package> <candidate>" for each of $@ that has a candidate.
candidates_of() {
  [ $# -gt 0 ] || return 0
  LC_ALL=C apt-cache "${CLEAN_APT_OPTS[@]}" policy "$@" 2>/dev/null | awk '
    /^[^ ].*:$/                         { p = $0; sub(/:$/, "", p); next }
    /^  Candidate:/ && $2 != "(none)"   { print p, $2 }'
}

# Which of $@ are Essential or Priority required: every Debian system has them.
base_system_packages() {
  [ $# -gt 0 ] || return 0
  LC_ALL=C apt-cache "${BUILD_APT_OPTS[@]}" show --no-all-versions "$@" 2>/dev/null | awk '
    /^Package:/                                   { p = $2 }
    /^Essential: yes$/ || /^Priority: required$/  { print p }' | sort -u
}

# Packages that $@ depend on with a version constraint.
versioned_depends() {
  [ $# -gt 0 ] || return 0
  LC_ALL=C apt-cache "${BUILD_APT_OPTS[@]}" show --no-all-versions "$@" 2>/dev/null | awk '
    /^(Pre-)?Depends:/ {
      sub(/^[^:]*: /, "")
      n = split($0, alt, /[,|]/)
      for (i = 1; i <= n; i++) if (alt[i] ~ /\(/) {
        s = alt[i]; sub(/^ +/, "", s); sub(/[ (:].*/, "", s); print s
      }
    }' | LC_ALL=C sort -u
}

# True when $1 is a complete .deb: its data archive reads to the end.
deb_intact() {
  dpkg-deb --fsys-tarfile "$1" > /dev/null 2>&1
}

# Place .deb $1 in apt's cache, for the uninstall, and record it. Returns 1
# when one is there already, or it is damaged or cannot be copied.
cache_deb() {
  local dest="/var/cache/apt/archives/${1##*/}"
  [ ! -f "$dest" ] && deb_intact "$1" && sudo install -m 0644 "$1" /var/cache/apt/archives/ || return 1
  # Unrecorded, the uninstall could not clear it from apt's cache again.
  sys_record_append "$CACHED_DEBS" "$dest" || { sudo rm -f "$dest"; return 1; }
}

# Set DEBIAN_ONLY_APT_OPTS once: apt with every source but the look's Ubuntu
# one, and a cache of its own. Non-zero when it cannot be set up.
debian_only_apt_opts() {
  [ -z "$DEBIAN_SOURCES_DIR" ] || return 0
  local f
  DEBIAN_SOURCES_DIR="$(mktemp -d)" || return 1
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] && [ "$f" != "$UBUNTU_SOURCES" ] && cp "$f" "${DEBIAN_SOURCES_DIR}/"
  done
  DEBIAN_ONLY_APT_OPTS=(-o "Dir::Etc::sourceparts=${DEBIAN_SOURCES_DIR}"
                        -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
}

# Download $1 at version $2 into $3, checked against the archive's SHA256;
# one retry. With $4 = debian, only Debian's archives are seen, so an Ubuntu
# build of the same version cannot stand in for Debian's. Sets FETCHED_DEB.
fetch_deb() {
  local pkg="$1" ver="$2" dest="$3" f sums try
  local -a opts=()
  if [ "${4:-}" = debian ]; then
    debian_only_apt_opts || return 1
    opts=("${DEBIAN_ONLY_APT_OPTS[@]}")
  fi
  FETCHED_DEB=""
  sums="$(LC_ALL=C apt-cache "${opts[@]}" show "${pkg}=${ver}" 2>/dev/null | awk '/^SHA256:/ { print $2 }')"
  for try in 1 2; do
    rm -rf "$PARTIAL_DIR"
    mkdir -p "$PARTIAL_DIR" "$dest" || return 1
    ( cd "$PARTIAL_DIR" && apt-get "${opts[@]}" download "${pkg}=${ver}" > /dev/null 2>&1 ) || continue
    for f in "$PARTIAL_DIR"/*.deb; do
      [ -f "$f" ] && deb_intact "$f" || continue
      if [ -n "$sums" ] && ! printf '%s\n' "$sums" | grep -qxF "$(sha256sum < "$f" | cut -d' ' -f1)"; then
        continue
      fi
      mv -f "$f" "${dest}/" && FETCHED_DEB="${dest}/${f##*/}"
    done
    [ -n "$FETCHED_DEB" ] && break
    [ "$try" = 1 ] && message warn "${pkg}: the downloaded file did not verify — fetching it again"
  done
  rm -rf "$PARTIAL_DIR"
  [ -n "$FETCHED_DEB" ]
}

# Rewrite packages/Packages from the top-level .debs and, unless $1 is
# "index-only", BUNDLE_INFO.
write_bundle_index() {
  local tmp raw f fields bundle_mirror
  tmp="$(mktemp "${PACKAGES_DIR}/.Packages.XXXXXX")" || return 1
  if command -v apt-ftparchive > /dev/null 2>&1; then
    raw="$(cd "$PACKAGES_DIR" && apt-ftparchive packages . 2>/dev/null)" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$raw" | awk -v RS= -v ORS='\n\n' '
      { fn = $0; sub(/^(.*\n)?Filename: /, "", fn); sub(/\n.*/, "", fn); sub(/^\.\//, "", fn)
        if (fn !~ /\//) print }' > "$tmp"
  else
    for f in "$PACKAGES_DIR"/*.deb; do
      [ -f "$f" ] || continue
      fields="$(dpkg-deb -f "$f" 2>/dev/null)" || continue
      printf '%s\nFilename: ./%s\nSize: %s\nSHA256: %s\n\n' "$fields" "${f##*/}" \
        "$(stat -c %s "$f")" "$(sha256sum < "$f" | cut -d' ' -f1)"
    done > "$tmp"
  fi
  chmod 0644 "$tmp" && mv -f "$tmp" "${PACKAGES_DIR}/Packages" || { rm -f "$tmp"; return 1; }
  BUNDLE_DIRTY=0
  [ "${1:-}" != index-only ] && [ -n "${UBUNTU_CODENAME:-}" ] || return 0

  bundle_mirror="$(ubuntu_mirror_for "$UBUNTU_CODENAME")" || bundle_mirror="$UBUNTU_MIRROR"
  {
    echo "# Written by ubuntu-look.sh --download. KEY=value; read, never sourced."
    echo "UBUNTU_CODENAME=${UBUNTU_CODENAME}"
    echo "UBUNTU_MIRROR=${bundle_mirror}"
    echo "DEBIAN_CODENAME=$(debian_codename)"
    echo "ARCH=${UBUNTU_ARCH}"
    echo "SHELL_MAJOR=$(shell_major)"
    echo "DATE=$(date -Iseconds)"
  } > "${BUNDLE_INFO}.new" && mv -f "${BUNDLE_INFO}.new" "$BUNDLE_INFO"
}

# Save apt file $1 for restore_apt_file: prints a copy's path, or "absent".
save_apt_file() {
  local dest="${DOWNLOAD_SAVED}/${1##*/}"
  sudo install -d -m 0755 "$DOWNLOAD_SAVED" || return 1
  if [ -e "$1" ]; then
    sudo cp -p "$1" "$dest" || return 1
    echo "$dest"
  else
    sudo touch "${dest}.absent" || return 1
    echo absent
  fi
}

# Drop the saved apt files and, when empty, the system directory.
discard_saved_apt_files() {
  sudo rm -rf "$DOWNLOAD_SAVED"
  sudo rmdir "$SYS_DIR" 2>/dev/null || true
}

# Put back the apt files a killed --download left changed.
restore_stale_apt_files() {
  [ -d "$DOWNLOAD_SAVED" ] || return 0
  local f saved put=0
  # A killed build's keyring mark, for download_mode.
  [ -e "${DOWNLOAD_SAVED}/keyring-for-build" ] && STALE_BUILD_KEYRING=1
  for f in "$UBUNTU_SOURCES" "$UBUNTU_PIN"; do
    saved="${DOWNLOAD_SAVED}/${f##*/}"
    # Counted only when the file differed and was put back.
    if [ -f "$saved" ]; then
      cmp -s "$saved" "$f" 2>/dev/null || { restore_apt_file "$saved" "$f" || return 1; put=1; }
    elif [ -e "${saved}.absent" ] && [ -e "$f" ]; then
      restore_apt_file absent "$f" || return 1; put=1
    fi
  done
  [ "$put" -eq 1 ] && message warn "an earlier bundle build was stopped — the apt files it changed are put back"
  discard_saved_apt_files
}

# Put apt file $2 back as save_apt_file found it ($1). Returns 1 on failure.
restore_apt_file() {
  case "$1" in
    "") return 0 ;;
    absent) [ -e "$2" ] || return 0; sudo rm -f "$2" ;;
    *) [ -f "$1" ] || return 0
       cmp -s "$1" "$2" 2>/dev/null || sudo_write_atomic "$1" "$2" ;;
  esac
}

# --download's exit: put the Ubuntu source and pin back, and keep the index in
# step with the .debs. An unfinished run undoes its bundle changes.
_download_exit() {
  local rc=$? f n pkg a added restored=1
  # A second Ctrl-C must not cut the clean-up short.
  trap '' INT HUP TERM
  # Copies not put back stay in DOWNLOAD_SAVED for the next run. The source
  # goes back first, so a failed pin restore leaves no build source in use.
  restore_apt_file "$PREV_SOURCES_FILE" "$UBUNTU_SOURCES" \
    || { restored=0; message warn "could not put back ${UBUNTU_SOURCES} — the next --download retries"; }
  restore_apt_file "$PREV_PIN_FILE" "$UBUNTU_PIN" \
    || { restored=0; message warn "could not put back ${UBUNTU_PIN} — the next --download retries"; }
  [ "$restored" = 1 ] && [ "$DOWNLOAD_DONE" = 1 ] \
    && message "this machine's Ubuntu apt source and pin are put back as they were"
  # The saved copies and the keyring mark go together, so a stale mark never
  # removes a keyring installed later. Copies not yet put back stay.
  [ "$restored" = 1 ] && [ "$SAVED_RESTORED" = 1 ] && [ -d "$DOWNLOAD_SAVED" ] \
    && discard_saved_apt_files
  # The keyring stays while a changed Ubuntu source still names it, and when
  # apt would remove more than the keyring.
  if [ "$KEYRING_FOR_BUILD" = 1 ] && [ "$restored" = 1 ] && is_installed ubuntu-keyring; then
    if [ "$(LC_ALL=C apt-get -s purge ubuntu-keyring 2>/dev/null | grep -c '^Purg ')" = 1 ] \
       && sudo apt-get purge -y ubuntu-keyring > /dev/null 2>&1; then
      message "ubuntu-keyring, installed for this build only, is removed again"
    else
      message warn "could not remove ubuntu-keyring, installed for this build only — run: sudo apt-get purge ubuntu-keyring"
      # Marked again, so the next --download or install still counts it as the build's.
      sudo install -d "$DOWNLOAD_SAVED" && sudo touch "${DOWNLOAD_SAVED}/keyring-for-build"
      [ "$rc" -eq 0 ] && rc=1
    fi
  fi
  stop_sudo_keepalive
  rm -rf "$PARTIAL_DIR" "${BUILD_PREFS_DIR:-}" "${DEBIAN_SOURCES_DIR:-}"
  rm -f "${PACKAGES_DIR}"/.Packages.* 2>/dev/null
  if [ "$DOWNLOAD_DONE" = 1 ]; then
    rm -rf "$DISCARD_DIR"
  else
    bundle_discard_restore
    # A fetched .deb goes when it was new to the bundle or sits beside another build.
    for f in "${FETCHED_NEW[@]}"; do
      [ -f "$f" ] || continue
      pkg="$(dpkg-deb -f "$f" Package 2>/dev/null)" || continue
      n="$(bundle_debs "$pkg" "$(dirname "$f")" | wc -l)"
      added=0
      for a in "${FETCHED_ADDED[@]}"; do [ "$a" = "$f" ] && added=1; done
      if [ "$n" -gt 1 ] || [ "$added" = 1 ]; then
        rm -f "$f" && BUNDLE_DIRTY=1
      fi
    done
  fi
  if [ "$BUNDLE_DIRTY" = 1 ]; then
    # A finished run wrote its index; an unfinished one indexes the restored .debs.
    write_bundle_index index-only || message warn "could not rewrite ${PACKAGES_DIR}/Packages"
  fi
  rm_release_cache
  # A return in an EXIT trap leaves the exit status alone; exit sets it.
  [ "$restored" = 1 ] || [ "$rc" -ne 0 ] || rc=1
  exit "$rc"
}

# --download: build or refresh the offline bundle, then restore the machine's apt files.
download_mode() {
  message "Building or refreshing the offline bundle at ${GREEN}${PACKAGES_DIR}${ENDCOLOR}"
  message warn "This needs internet access. Ubuntu's archive is added to apt for the build"
  message warn "and this machine's Ubuntu source and pin are put back as they were afterwards."
  confirm_continue
  sudo -v || error "User ${RUN_USER} cannot use sudo."
  # Keep sudo alive for the long download.
  ( while sleep 60 && kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || exit 0; done ) \
    > /dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
  take_run_lock

  trap '_download_exit' EXIT
  restore_stale_apt_files || error "Could not put back what an earlier --download changed (${DOWNLOAD_SAVED})"
  SAVED_RESTORED=1
  mkdir -p "$PACKAGES_DIR" || error "Cannot create ${PACKAGES_DIR}"
  # .debs a killed run fetched but never indexed would enter the index of a
  # later run that stops; they go now, as --offline removes them.
  local _f
  if [ -f "${PACKAGES_DIR}/Packages" ]; then
    for _f in "$PACKAGES_DIR"/*.deb; do
      [ -f "$_f" ] || continue
      grep -qxF "Filename: ./${_f##*/}" "${PACKAGES_DIR}/Packages" || rm -f "$_f"
    done
  fi

  # A machine without the look keeps no records of the build, and
  # ubuntu-keyring only for the build.
  if [ -s "$SYS_USERS" ]; then
    record_packages_before
  else
    NO_SYSTEM_RECORDS=1
    if [ "$STALE_BUILD_KEYRING" = 1 ] || ! is_installed ubuntu-keyring; then
      KEYRING_FOR_BUILD=1
      # Marked, so the next build removes the keyring a killed build left.
      sudo install -d "$DOWNLOAD_SAVED" && sudo touch "${DOWNLOAD_SAVED}/keyring-for-build"
    fi
  fi

  install_prereqs "$(missing_packages "curl ca-certificates")"

  bundle_discard_restore
  # A damaged .deb is dropped here and fetched again below.
  local deb
  for deb in "${PACKAGES_DIR}"/*.deb "${DEBIAN_DEBS_DIR}"/*.deb; do
    [ -f "$deb" ] || continue
    deb_intact "$deb" && continue
    message warn "  ${deb##*/} is damaged — removed; it is fetched again"
    rm -f "$deb"
    BUNDLE_DIRTY=1
  done

  step "Discover current Ubuntu releases"
  discover_releases "$REQUESTED_CODENAME"
  message "candidate Ubuntu releases (oldest to newest): ${UBUNTU_CANDIDATE_CODENAMES}"

  step "Configure Ubuntu archive apt sources"
  ensure_ubuntu_keyring

  # Kept so the apt source and pin can be restored.
  PREV_SOURCES_FILE="$(save_apt_file "$UBUNTU_SOURCES")" || error "Could not save ${UBUNTU_SOURCES}"
  PREV_PIN_FILE="$(save_apt_file "$UBUNTU_PIN")" || error "Could not save ${UBUNTU_PIN}"

  # Block every Ubuntu package until the full pin exists (this run only).
  write_provisional_pin
  [ $? -eq 2 ] && error "Could not write ${UBUNTU_PIN}; the apt source was not changed."
  PINNED_BEFORE="$(pinned_codename)"
  # A fixed release is configured alone; auto chooses among the candidates.
  local _codenames="$UBUNTU_CANDIDATE_CODENAMES"
  [ "$REQUESTED_CODENAME" = auto ] || _codenames="$REQUESTED_CODENAME"
  # shellcheck disable=SC2086
  write_ubuntu_sources $_codenames
  case $? in
    2) error "No Ubuntu archive answered — check the connection; the sources are put back as they were." ;;
    3) error "Could not write ${UBUNTU_SOURCES} — the sources are put back as they were." ;;
  esac

  step "Refresh package lists"
  apt_update
  case $? in
    0) ;;
    3) error "apt is in use by another program — the sources are put back as they were; try again later." ;;
    *) error "apt update failed for the Ubuntu sources — they are put back as they were." ;;
  esac
  ubuntu_index_has_packages \
    || error "${UBUNTU_MIRROR} serves no Ubuntu packages for ${UBUNTU_ARCH} — the sources are put back as they were."

  step "Resolve the GNOME Shell-compatible Ubuntu release"
  if [ "$REQUESTED_CODENAME" != auto ]; then
    message "using the requested Ubuntu release ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} (UBUNTU_CODENAME)"
  else
    resolve_release "${PINNED_BEFORE:-$(sed -n 's/^UBUNTU_CODENAME=//p' "$BUNDLE_INFO" 2>/dev/null | head -1)}"
  fi

  step "Apply the Ubuntu pin to this build"
  # The machine's pin stays; this run's apt reads the full pin from a copy.
  local f
  BUILD_PREFS_DIR="$(mktemp -d)" || error "Could not create a temporary directory"
  for f in /etc/apt/preferences.d/*; do
    [ -f "$f" ] && [ "$f" != "$UBUNTU_PIN" ] && cp "$f" "${BUILD_PREFS_DIR}/" 2>/dev/null
  done
  write_ubuntu_pin "${BUILD_PREFS_DIR}/${UBUNTU_PIN##*/}"
  [ $? -eq 2 ] && error "Could not write the build's apt pin in ${BUILD_PREFS_DIR}."
  BUILD_APT_OPTS=(-o "Dir::Etc::preferencesparts=${BUILD_PREFS_DIR}")
  # Versions as a clean machine would get them.
  CLEAN_APT_OPTS=("${BUILD_APT_OPTS[@]}" -o Dir::State::status=/dev/null)

  # The chosen release gets universe, as on Ubuntu. A release reached by
  # looking back has joined the candidates.
  local _rc=0
  _codenames="$UBUNTU_CANDIDATE_CODENAMES"
  [ "$REQUESTED_CODENAME" = auto ] || _codenames="$REQUESTED_CODENAME"
  # shellcheck disable=SC2086
  write_ubuntu_sources $_codenames || _rc=$?
  [ "$_rc" -eq 2 ] && error "Ubuntu ${UBUNTU_CODENAME} did not answer — run --download again"
  [ "$_rc" -eq 3 ] && error "Could not write ${UBUNTU_SOURCES} — run --download again"
  if [ "$_rc" -eq 0 ]; then
    apt_update_ubuntu_only \
      || { drop_unserved_universe && apt_update_ubuntu_only; } \
      || error "apt update failed for Ubuntu ${UBUNTU_CODENAME} — run --download again"
  fi

  step "Resolve the full package set"
  local all_pkgs resolvable="" pkg combined="" ccand
  # The combined extension package where offered, beside the separate ones.
  ccand="$(candidates_of "$COMBINED_EXT_PKG")"; ccand="${ccand#* }"
  combined_carries_dock "$ccand" "${CLEAN_APT_OPTS[@]}" && combined="$COMBINED_EXT_PKG"
  # The target decides on the boot splash and the LibreOffice style;
  # ubuntu-keyring signs its source.
  # shellcheck disable=SC2086
  all_pkgs="$(printf '%s\n' ubuntu-keyring plymouth plymouth-themes libreoffice-style-yaru \
    ${packages[0-base]} ${packages[1-desktop-base]} ${packages[2-desktop-gnome]} \
    $combined | sort -u | xargs)"
  # Drop anything apt cannot see.
  resolvable="$(available_packages "$all_pkgs")"
  for pkg in $all_pkgs; do
    in_word_list "$pkg" "$resolvable" && continue
    # The combined package stands in for the separate ones, as in the checks below.
    [ -n "$combined" ] && in_word_list "$pkg" "$SEPARATE_EXT_PKGS" && continue
    STATUS_UNAVAIL+=("$pkg (not in any configured Ubuntu/Debian repository)")
  done

  # CLEAN_CAND: candidates as a clean machine would get them.
  local -A CANDIDATE_VER=() CLEAN_CAND=()
  local needed="" sim_pkgs="" cand bver dep_pkg dep_ver

  step "Check for package updates (bundle vs. Ubuntu/Debian archive)"
  # shellcheck disable=SC2086
  while read -r pkg cand; do CLEAN_CAND[$pkg]="$cand"; done < <(candidates_of $resolvable)
  # Fetch what the bundle lacks, or holds at a version other than the candidate.
  for pkg in $resolvable; do
    cand="${CLEAN_CAND[$pkg]:-}"
    [ -n "$cand" ] || continue
    CANDIDATE_VER[$pkg]="$cand"
    sim_pkgs="$sim_pkgs $pkg"
    bver="$(bundled_version "$pkg")"
    if [ -z "$bver" ]; then
      needed="$needed $pkg"
      message "  ${pkg}: not in bundle yet → ${cand}"
    elif [ "$bver" != "$cand" ]; then
      needed="$needed $pkg"
      if bundle_has_version "$pkg" "$PACKAGES_DIR" "$cand" >/dev/null; then
        message "  ${pkg}: back to ${cand}, already in the bundle"
      else
        message "  ${pkg}: update available ${bver} → ${cand}"
      fi
    fi
  done

  step "Check for dependencies a fresh target lacks"
  # The stages' Depends closure, less gnome-shell's and base packages. Pinned
  # Ubuntu names and version-constrained dependencies are kept.
  local stage_closure closure base_set required versioned
  # shellcheck disable=SC2086
  stage_closure="$(dep_closure $sim_pkgs | grep -v ':')"
  closure="$( { LC_ALL=C comm -23 <(printf '%s\n' "$stage_closure") <(dep_closure gnome-shell)
                printf '%s\n' "$stage_closure" | grep -xF \
                  -f <(printf '%s\n' $UBUNTU_PINNED_PACKAGES "ubuntu-wallpapers-${UBUNTU_CODENAME}")
              } | sed '/^$/d' | sort -u)"
  # shellcheck disable=SC2086
  versioned=" $(LC_ALL=C comm -12 <(versioned_depends $sim_pkgs $closure) <(printf '%s\n' "$stage_closure") | xargs) "
  # shellcheck disable=SC2086
  closure="$(printf '%s\n' $closure $versioned | sed '/^$/d' | sort -u)"
  # shellcheck disable=SC2086
  base_set="$(candidates_of $closure)"
  # shellcheck disable=SC2046
  required=" $(base_system_packages $(printf '%s\n' "$base_set" | awk '{print $1}') | xargs) "
  while read -r dep_pkg dep_ver; do
    [ -n "$dep_pkg" ] && [ -n "$dep_ver" ] || continue
    [ -n "${CANDIDATE_VER[$dep_pkg]:-}" ] && continue
    in_word_list "$dep_pkg" "$required" && ! in_word_list "$dep_pkg" "$versioned" && continue
    CANDIDATE_VER[$dep_pkg]="$dep_ver"
    if [ "$(bundled_version "$dep_pkg")" != "$dep_ver" ]; then
      needed="$needed $dep_pkg"
      message "  ${dep_pkg}: dependency, not in bundle → ${dep_ver}"
    fi
  done <<< "$base_set"

  step "Check for other dependencies this Debian does not already provide"
  # What apt would install here; an unresolvable batch goes package by package.
  local sim_out one
  # shellcheck disable=SC2086
  if ! sim_out="$(LC_ALL=C apt-get "${BUILD_APT_OPTS[@]}" install -s -y $sim_pkgs 2>&1)"; then
    sim_out=""
    for pkg in $sim_pkgs; do
      if one="$(LC_ALL=C apt-get "${BUILD_APT_OPTS[@]}" install -s -y "$pkg" 2>&1)"; then
        sim_out="${sim_out}${one}"$'\n'
      else
        message warn "apt cannot resolve ${pkg} on this machine — dependencies only it needs may be missing from the bundle"
      fi
    done
  fi
  # A pkg:arch name belongs to another architecture.
  local inst
  inst="$(echo "$sim_out" | awk '/^Inst /{print $2}' | grep -v ':' | sort -u)"
  # shellcheck disable=SC2086
  while read -r dep_pkg dep_ver; do CLEAN_CAND[$dep_pkg]="$dep_ver"; done < <(candidates_of $inst)
  for dep_pkg in $inst; do
    [ -n "${CANDIDATE_VER[$dep_pkg]:-}" ] && continue
    dep_ver="${CLEAN_CAND[$dep_pkg]:-}"
    [ -n "$dep_ver" ] || continue
    CANDIDATE_VER[$dep_pkg]="$dep_ver"
    if [ "$(bundled_version "$dep_pkg")" != "$dep_ver" ]; then
      needed="$needed $dep_pkg"
      message "  ${dep_pkg}: new dependency, not in bundle → ${dep_ver}"
    fi
  done
  # A bundle holding the candidate beside a newer build needs no fetch; the
  # newer build is dropped below.
  local fetch=""
  for pkg in $needed; do
    bundle_has_version "$pkg" "$PACKAGES_DIR" "${CANDIDATE_VER[$pkg]}" >/dev/null \
      || fetch="${fetch} ${pkg}"
  done
  needed="$(echo "$fetch" | xargs)"

  if [ -z "$needed" ]; then
    message "bundle is already current — nothing new to download"
  else
    message "packages to fetch (${GREEN}$(echo "$needed" | wc -w)${ENDCOLOR}): ${needed}"

    step "Download packages into the bundle"
    local fetched=0 failed_dl="" was_absent
    for pkg in $needed; do
      was_absent=0
      [ -z "$(bundle_debs "$pkg")" ] && was_absent=1
      if fetch_deb "$pkg" "${CANDIDATE_VER[$pkg]}" "$PACKAGES_DIR"; then
        FETCHED_NEW+=("$FETCHED_DEB")
        [ "$was_absent" = 1 ] && FETCHED_ADDED+=("$FETCHED_DEB")
        BUNDLE_DIRTY=1
        fetched=$((fetched + 1))
      else
        message warn "could not download ${pkg}=${CANDIDATE_VER[$pkg]}"
        failed_dl="${failed_dl} ${pkg}"
      fi
    done
    message "fetched ${GREEN}${fetched}${ENDCOLOR} .deb(s) into ${PACKAGES_DIR}"
    # A partial download would mix releases; the bundle stays as it was.
    [ -z "$failed_dl" ] \
      || error "Could not download:${failed_dl} — the bundle is left as it was; run --download again"
  fi

  step "Bundle Debian's own builds of the look packages"
  # Every build Debian lists, so an offline uninstall can put them back.
  local dvers dver
  # Dash-to-Dock too: Ubuntu Dock takes over its settings file, and an offline
  # uninstall reinstalls it from the bundle.
  for pkg in $UBUNTU_PINNED_PACKAGES gnome-shell-extension-dashtodock; do
    dvers="$(madison_rows "$pkg" | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '$2 !~ re { print $1 }' | sort -u)"
    [ -n "$dvers" ] || continue
    for dver in $dvers; do
      bundle_has_version "$pkg" "$DEBIAN_DEBS_DIR" "$dver" > /dev/null && continue
      if fetch_deb "$pkg" "$dver" "$DEBIAN_DEBS_DIR" debian; then
        # An unfinished run takes it out again.
        FETCHED_NEW+=("$FETCHED_DEB"); FETCHED_ADDED+=("$FETCHED_DEB")
        message "  ${pkg}: Debian's ${dver}"
      else
        message warn "could not download Debian's ${pkg}=${dver}"
        STATUS_FAILED+=("Debian's ${pkg} ${dver} not bundled — an offline uninstall cannot put it back")
      fi
    done
    # Builds Debian no longer lists.
    while read -r f; do
      [ -n "$f" ] || continue
      printf '%s\n' "$dvers" | grep -qxF "$(dpkg-deb -f "$f" Version 2>/dev/null)" || bundle_discard "$f"
    done < <(bundle_debs "$pkg" "$DEBIAN_DEBS_DIR")
  done

  step "Remove bundled packages that are no longer in the set"
  # Superseded builds go first.
  local pruned=0 deb_pkg deb_arch unresolved="" graph
  for pkg in "${!CANDIDATE_VER[@]}"; do
    if drop_superseded "$pkg" "${CANDIDATE_VER[$pkg]}"; then
      BUNDLE_DIRTY=1
      message "  removed older builds of ${pkg}"
      pruned=$((pruned + 1))
    fi
  done
  # The rest only when every stage package resolved.
  for pkg in $all_pkgs; do
    [ -n "${CANDIDATE_VER[$pkg]:-}" ] && continue
    # Carried by the combined package, which the install then uses.
    [ -n "$combined" ] && in_word_list "$pkg" "$SEPARATE_EXT_PKGS" && continue
    unresolved="$unresolved $pkg"
  done
  if [ -n "$unresolved" ]; then
    message warn "not resolved this run (${unresolved# }) — leaving the bundle as it is"
  else
    # Keep what the dependency graph needs (Recommends included).
    # shellcheck disable=SC2086
    graph="$(apt-cache "${BUILD_APT_OPTS[@]}" depends --recurse --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances $all_pkgs 2>/dev/null \
        | grep -E '^[a-z0-9]' | sort -u)"
    for deb in "${PACKAGES_DIR}"/*.deb; do
      [ -f "$deb" ] || continue
      deb_pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null)"
      deb_arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null)"
      [ -n "$deb_pkg" ] || continue
      case "$deb_arch" in
        "$UBUNTU_ARCH"|all)
          [ -n "${CANDIDATE_VER[$deb_pkg]:-}" ] && continue
          echo "$graph" | grep -qxF "$deb_pkg" && continue ;;
      esac
      bundle_discard "$deb"
      BUNDLE_DIRTY=1
      message "  removed ${deb_pkg} (${deb_arch}) — no longer part of the bundle"
      pruned=$((pruned + 1))
    done
  fi
  [ $pruned -eq 0 ] && message "no package to remove from the bundle"

  step "Verify the bundle is complete"
  # A gap is reported as not done; the bundle stays usable. Where apt chose a
  # build, that build must be there, not an older one.
  local missing="" stale="" present=0 cand
  for pkg in $all_pkgs; do
    [ -n "$combined" ] && in_word_list "$pkg" "$SEPARATE_EXT_PKGS" && continue
    cand="${CANDIDATE_VER[$pkg]:-}"
    if [ -n "$cand" ] && bundle_has_version "$pkg" "$PACKAGES_DIR" "$cand" > /dev/null; then
      present=$((present + 1))
    elif [ -z "$cand" ] && [ -n "$(bundled_version "$pkg")" ]; then
      present=$((present + 1))
    elif [ -n "$(bundled_version "$pkg")" ]; then
      stale="$stale $pkg"
    else
      missing="$missing $pkg"
    fi
  done
  missing="$(echo "$missing" | xargs)"; stale="$(echo "$stale" | xargs)"
  if [ -n "$missing" ]; then
    message warn "these packages are NOT in the bundle: ${missing}"
    message warn "an install from it will skip them and say so in its summary"
    STATUS_FAILED+=("Not in the bundle: ${missing}")
  fi
  if [ -n "$stale" ]; then
    message warn "the bundle holds an older build than apt's choice for: ${stale}"
    STATUS_FAILED+=("Older build than apt's choice in the bundle: ${stale}")
  fi
  [ -z "${missing}${stale}" ] && message "all ${present} stage packages are present in the bundle"

  step "Write the package index"
  write_bundle_index || error "could not write the bundle's index (${PACKAGES_DIR}/Packages or ${BUNDLE_INFO})"
  DOWNLOAD_DONE=1

  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  echo -e "${GREEN}Bundle ready: ${PACKAGES_DIR}${ENDCOLOR}"
  echo -e "${GREEN}  $(grep -c '^Package:' "${PACKAGES_DIR}/Packages") package(s), Ubuntu ${UBUNTU_CODENAME}, ${UBUNTU_ARCH}, Debian $(debian_codename), GNOME Shell $(shell_major)${ENDCOLOR}"
  summary_block "$YELLOW" "Not resolvable from any configured repository (${#STATUS_UNAVAIL[@]}):" "!" "" "${STATUS_UNAVAIL[@]}"
  summary_block "$RED" "Not done (${#STATUS_FAILED[@]}):" "!" "" "${STATUS_FAILED[@]}"
  summary_block "$GREEN" "Changes (this machine and the bundle):" "+" "" "${STATUS_CHANGES[@]}"
  echo -e "${GREEN}Copy ubuntu-look.sh and packages/ to an offline machine with the same Debian release, architecture and GNOME Shell, then run: bash ubuntu-look.sh --offline${ENDCOLOR}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  # A usable bundle with gaps exits 1, as an install with items not done does.
  [ $(( ${#STATUS_FAILED[@]} + ${#STATUS_UNAVAIL[@]} )) -eq 0 ] || exit 1
  exit 0
}

# Read BUNDLE_INFO (parsed, never sourced) and check the bundle fits this system
# and apt can read it. Sets UBUNTU_CODENAME, UBUNTU_MIRROR and LOCAL_SOURCES.
load_bundle() {
  [ -d "$PACKAGES_DIR" ] || error "Local bundle not found: ${PACKAGES_DIR}
  Build it with 'bash ubuntu-look.sh --download' on an online machine with
  the same Debian release, architecture and GNOME Shell, then copy this script
  and packages/ here."
  [ -f "${PACKAGES_DIR}/Packages" ] || error "Packages index missing: ${PACKAGES_DIR}/Packages
  The bundle looks incomplete — rebuild it with --download."
  [ -f "$BUNDLE_INFO" ] || error "${BUNDLE_INFO} is missing — rebuild the bundle with --download."

  local key val b_codename="" b_mirror="" b_debian="" b_arch="" b_shell=""
  while IFS='=' read -r key val || [ -n "$key" ]; do
    # The mirror as the option takes it; every other value plain characters.
    if [ "$key" = UBUNTU_MIRROR ]; then
      if ! option_value_ok UBUNTU_MIRROR "$val"; then
        message warn "${BUNDLE_INFO} names a mirror that is not one http:// or https:// URL — ignored; ${UBUNTU_MIRROR} is used"
        continue
      fi
    elif ! [[ "$val" =~ ^[A-Za-z0-9._:/+-]*$ ]]; then
      continue
    fi
    case "$key" in
      UBUNTU_CODENAME) b_codename="$val" ;;
      UBUNTU_MIRROR)   b_mirror="$val" ;;
      DEBIAN_CODENAME) b_debian="$val" ;;
      ARCH)            b_arch="$val" ;;
      SHELL_MAJOR)     b_shell="$val" ;;
      DATE)            BUNDLE_DATE="$val" ;;
    esac
  done < "$BUNDLE_INFO"

  [[ "$b_codename" =~ ^[a-z]+$ ]] \
    || error "${BUNDLE_INFO} names no Ubuntu release — rebuild the bundle with --download."
  [ -n "$b_arch" ] \
    || error "${BUNDLE_INFO} names no architecture — rebuild the bundle with --download."
  [ "$b_arch" = "$UBUNTU_ARCH" ] \
    || error "The bundle is for ${b_arch}; this system is ${UBUNTU_ARCH}. Rebuild it with --download on ${UBUNTU_ARCH}."

  local t_debian t_shell mismatch=""
  t_debian="$(debian_codename)"
  t_shell="$(shell_major)"
  [ "$b_debian" = "$t_debian" ] \
    || mismatch="Debian ${b_debian:-unknown} (this system: ${t_debian:-unknown})"
  [ "$b_shell" = "$t_shell" ] \
    || mismatch="${mismatch:+${mismatch}, }GNOME Shell ${b_shell:-unknown} (this system: ${t_shell:-none})"
  if [ -n "$mismatch" ]; then
    if [ "${UBUNTU_LOOK_FORCE_BUNDLE:-0}" = "1" ]; then
      message warn "the bundle was built for ${mismatch} — continuing (UBUNTU_LOOK_FORCE_BUNDLE=1)"
      STATUS_NOCHANGE+=("Bundle built for ${mismatch}; used anyway (UBUNTU_LOOK_FORCE_BUNDLE=1)")
    else
      error "The bundle was built for ${mismatch}.
  Rebuild it with --download on a matching machine, or set UBUNTU_LOOK_FORCE_BUNDLE=1."
    fi
  fi

  # A killed --download leaves a .discard that only a writable bundle can clear.
  [ ! -d "$DISCARD_DIR" ] || [ -w "$PACKAGES_DIR" ] \
    || error "${PACKAGES_DIR} holds an unfinished --download and cannot be written here.
  Run this from a writable copy, or rebuild the bundle with --download."

  # apt must read the index; tried with scratch lists, so nothing changes yet.
  local lists rc
  LOCAL_SOURCES="$(mktemp --suffix=.sources)" && lists="$(mktemp -d)" \
    || error "Could not create a temporary apt source"
  printf 'Types: deb\nURIs: file://%s\nSuites: ./\nTrusted: yes\n' "$(uri_path_encode "$PACKAGES_DIR")" > "$LOCAL_SOURCES"
  LC_ALL=C apt-get update -qq -o "Dir::Etc::sourcelist=${LOCAL_SOURCES}" -o Dir::Etc::sourceparts=- \
    -o "Dir::State::Lists=${lists}" -o "Dir::Cache=${lists}" -o Debug::NoLocking=1 \
    -o "APT::Sandbox::User=$(id -un)" -o Acquire::Languages=none >/dev/null 2>&1
  rc=$?
  rm -rf "$lists"
  [ "$rc" -eq 0 ] || error "Failed to load the package index of ${PACKAGES_DIR} — rebuild the bundle with --download."

  UBUNTU_CODENAME="$b_codename"
  if [ -n "$b_mirror" ]; then
    UBUNTU_MIRROR="${b_mirror%/}"
    add_mirror_to_hosts_re "$UBUNTU_MIRROR"
  fi
}

# --offline: use the bundle as the only apt source and write the Ubuntu pin.
prepare_offline() {
  step "Register the local bundle as apt source"
  local f n=0 apt_before
  # Clean up after a killed --download; load_bundle checked the bundle is writable.
  if [ -d "$DISCARD_DIR" ]; then
    for f in "$PACKAGES_DIR"/*.deb; do
      [ -f "$f" ] || continue
      grep -qxF "Filename: ./${f##*/}" "${PACKAGES_DIR}/Packages" 2>/dev/null \
        || { rm -f "$f" && BUNDLE_DIRTY=1; }
    done
    bundle_discard_restore indexed
    [ "$BUNDLE_DIRTY" = 1 ] && { write_bundle_index index-only || error "Could not rewrite ${PACKAGES_DIR}/Packages"; }
  fi
  restore_stale_apt_files || error "Could not put back what an earlier --download changed (${DOWNLOAD_SAVED})"

  # LOCAL_SOURCES is written by load_bundle.
  APT_OPTS=(-o "Dir::Etc::sourcelist=${LOCAL_SOURCES}" -o "Dir::Etc::sourceparts=-")
  sudo apt-get update "${APT_OPTS[@]}" -o APT::Get::List-Cleanup=0 2>/dev/null \
    || error "Failed to load the package index of ${PACKAGES_DIR}"
  # Recorded for the uninstall: no apt update removes them on this machine.
  apt-get indextargets "${APT_OPTS[@]}" --format '$(FILENAME)' 2>/dev/null \
    | while read -r f; do
        [ -f "$f" ] && ! grep -qxF "$f" "$OFFLINE_LISTS_RECORD" 2>/dev/null \
          && sys_record_append "$OFFLINE_LISTS_RECORD" "$f"
      done
  message "bundle: $(grep -c '^Package:' "${PACKAGES_DIR}/Packages") packages, Ubuntu ${UBUNTU_CODENAME}${BUNDLE_DATE:+, built ${BUNDLE_DATE}}"

  # Debian's builds of the look packages go into apt's cache, for the uninstall.
  for f in "$DEBIAN_DEBS_DIR"/*_"$UBUNTU_ARCH".deb "$DEBIAN_DEBS_DIR"/*_all.deb; do
    [ -f "$f" ] && cache_deb "$f" && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && STATUS_CHANGES+=("${n} Debian build(s) of the look's packages placed in apt's cache, for the uninstall")

  step "Write the Ubuntu pin"
  apt_before="$(apt_config_sum)"
  if ! is_installed ubuntu-keyring; then
    if apt_install_checked ubuntu-keyring; then
      STATUS_CHANGES+=("Installed ubuntu-keyring (Ubuntu's archive keys, from Debian)")
    else
      message warn "ubuntu-keyring could not be installed from the bundle"
    fi
  fi
  write_ubuntu_pin
  case $? in
    0) STATUS_CHANGES+=("Ubuntu pin applied (${UBUNTU_CODENAME})") ;;
    1) STATUS_NOCHANGE+=("Ubuntu pin already current") ;;
    2) error "Could not write ${UBUNTU_PIN}; it is left as it was and no Ubuntu package was installed. Run this again." ;;
  esac
  # An existing Ubuntu apt source is kept, and narrowed after aligning.
  if [ -f "$UBUNTU_SOURCES" ] && configured_codenames | grep -qxF "$UBUNTU_CODENAME"; then
    NARROW_WITHOUT_ARCHIVE=1
  elif [ -f "$UBUNTU_SOURCES" ]; then
    STATUS_NOCHANGE+=("Ubuntu apt source left as it is (it does not name ${UBUNTU_CODENAME}) — an online run updates it")
  else
    STATUS_NOCHANGE+=("No Ubuntu apt source written offline — an online run adds it")
  fi
  [ "$(apt_config_sum)" != "$apt_before" ] && invalidate_release_state
  return 0
}

# --offline: keep only the bundle's release in the apt source.
narrow_without_archive() {
  [ "$NARROW_WITHOUT_ARCHIVE" = 1 ] && [ -f "$UBUNTU_SOURCES" ] || return 0
  local tmp
  tmp="$(mktemp)"
  # Paragraph by paragraph: the header, and the stanza of that release.
  CN="$UBUNTU_CODENAME" awk -v RS= '
    { keep = 1; sub(/\n+$/, "")
      if (match($0, /(^|\n)Suites:[^\n]*/)) {
        split(substr($0, RSTART, RLENGTH), f, " ")
        sub(/-updates$/, "", f[2]); keep = (f[2] == ENVIRON["CN"])
      }
      if (keep) printf "%s%s\n", (n++ ? "\n" : ""), $0 }' "$UBUNTU_SOURCES" > "$tmp"
  local rc
  sudo_install_if_changed "$tmp" "$UBUNTU_SOURCES"; rc=$?
  rm -f "$tmp"
  case $rc in
    0) STATUS_CHANGES+=("Ubuntu apt source narrowed to ${UBUNTU_CODENAME}")
       invalidate_release_state ;;
    2) STATUS_FAILED+=("Could not narrow ${UBUNTU_SOURCES} to ${UBUNTU_CODENAME}") ;;
  esac
}

# --offline: place the bundle's builds of the packages the combined package
# replaced in apt's cache, for the uninstall.
cache_replaced_debs() {
  [ -f "$REPLACED_BY_COMBINED" ] || return 0
  local p f
  while read -r p; do
    [ -n "$p" ] || continue
    while read -r f; do
      [ -n "$f" ] && cache_deb "$f"
    done < <(bundle_debs "$p")
  done < "$REPLACED_BY_COMBINED"
}

###############################################################################
# 7. Setup: help, run log, mode, options, variables
###############################################################################

# This script's file; empty when it is read from a pipe (curl ... | bash).
SCRIPT_FILE="${BASH_SOURCE[0]:-}"

# --help prints the header from Usage to Requires.
for _arg in "$@"; do
  case "$_arg" in
    -h|--help)
      if [ -f "$SCRIPT_FILE" ]; then
        sed -n '/^# Usage/,/^# ====/{/^# ====/d;s/^# \{0,1\}//;p}' "$SCRIPT_FILE"
      else
        echo "Usage: bash ubuntu-look.sh [--download | --offline | --refresh | --uninstall | --prepare-upgrade | --help]"
        echo "Save the script to a file and run --help there for the options."
      fi
      exit 0 ;;
  esac
done

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

# Before the run log, so root leaves no log file behind.
[ "$(id -u)" -eq 0 ] \
  && error "Do not run as root. Run as a normal user with sudo rights."

# The logged run re-reads the script, so it must come from a file; the log
# must be writable, or the run would die with the pipe.
_log_name=ubuntu-look
case " $* " in *" --uninstall "*) _log_name=uninstall ;; esac
_log_file="${HOME:-/nonexistent}/${_log_name}-$(date +%Y%m%d-%H%M%S).log"
if [ "${UBUNTU_LOOK_LOG:-1}" != "0" ] && [ -z "${UBUNTU_LOOK_LOGGING:-}" ] \
   && { [ -f "$SCRIPT_FILE" ] && : > "$_log_file"; } 2>/dev/null; then

  # The newest ten logs of this kind stay; older ones go.
  # shellcheck disable=SC2012
  ls -1t "${HOME}/${_log_name}"-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f --

  # Pass on the shell options -u, -e and -x.
  _opts=()
  for _o in u e x; do
    case "$-" in *"$_o"*) _opts+=("-$_o") ;; esac
  done

  export UBUNTU_LOOK_LOGGING=1
  echo "Recording this run to ${_log_file}"
  # tee and sed ignore Ctrl-C and a closed terminal, so the summary still
  # reaches the log; a failed log write does not stop the run. The log's
  # writer is waited for, so the file is complete before the message below.
  bash "${_opts[@]}" "$SCRIPT_FILE" "$@" 2>&1 \
    | (trap '' INT HUP; tee --output-error=warn-nopipe \
         >(trap '' INT HUP; sed -r 's/\x1b\[[0-9;]*[mK]//g' > "$_log_file"); wait $! 2>/dev/null)
  _rc=${PIPESTATUS[0]}
  echo "Log written to ${_log_file}"
  exit "$_rc"
elif [ "${UBUNTU_LOOK_LOG:-1}" != "0" ] && [ -z "${UBUNTU_LOOK_LOGGING:-}" ]; then
  echo "No run log: the script is not read from a file, or ${_log_file} is not writable."
fi

# Debian leaves sbin (update-grub, plymouth tools) off a user's PATH.
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" ;;
esac

# Wait for an apt lock instead of failing.
sudo() {
  if [ "${1:-}" = apt-get ]; then
    shift
    # From a pipe (curl ... | bash) stdin is the script itself: a dpkg prompt
    # would read its lines. Without a terminal, apt reads nothing.
    if [ -t 0 ]; then
      command sudo apt-get -o DPkg::Lock::Timeout=300 "$@"
    else
      command sudo apt-get -o DPkg::Lock::Timeout=300 "$@" < /dev/null
    fi
  else
    command sudo "$@"
  fi
}

# The look's apt source and pin.
UBUNTU_SOURCES=/etc/apt/sources.list.d/ubuntu-themes.sources
UBUNTU_PIN=/etc/apt/preferences.d/ubuntu-themes
# apt's list files of the offline bundle, which the uninstall removes.
OFFLINE_LISTS_RECORD=/var/lib/ubuntu-look/records/offline-lists

# The user's own session bus, before the log reports it.
adopt_session_bus

# Facts for the log.
{
  echo "### $(basename "${SCRIPT_FILE:-ubuntu-look.sh}")  $(sha256sum "${SCRIPT_FILE:-/dev/null}" 2>/dev/null | cut -c1-16)"
  echo "### date    : $(date -Iseconds)"
  echo "### args    : ${*:-<none>}"
  echo "### system  : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "### gnome   : $(gnome-shell --version 2>/dev/null || echo 'GNOME Shell not installed')"
  echo "### session : ${XDG_SESSION_TYPE:-?} / ${XDG_CURRENT_DESKTOP:-?}"
  echo "### dbus    : $([ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && echo present || echo absent)"
  echo "### kernel  : $(uname -r) / $(dpkg --print-architecture 2>/dev/null || uname -m)"
  # Debian ships no mutter binary; its library package names the version.
  _wm="$(mutter --version 2>/dev/null | head -1)"
  [ -n "$_wm" ] ||
    _wm="$(dpkg-query -W -f='${db:Status-Abbrev}${Package} ${Version}\n' 'libmutter-*' 2>/dev/null \
      | sed -n 's/^ii *//p' | head -1)"
  echo "### wm      : ${_wm:-unknown}"
  # The pinned release, and the release yaru-theme-gtk came from.
  _rel_version() {
    [ -n "$1" ] || return 0
    sed -n 's/^Version: //p' /var/lib/apt/lists/*_dists_"$1"_InRelease 2>/dev/null | head -1
  }
  _pinned="$(pinned_codename "$UBUNTU_PIN")"
  # The line after "***" is the installed version's source.
  _float="$(apt-cache policy yaru-theme-gtk 2>/dev/null |
    awk '/^ \*\*\*/{getline; if ($0 ~ /:\/\//) print $3; exit}')"
  _float="${_float%%/*}"
  _pv="$(_rel_version "$_pinned")"
  _fv="$(_rel_version "$_float")"
  _u1="${_pv:+${_pv} (${_pinned})}"; _u1="${_u1:-${_pinned}}"
  _u2="${_fv:+${_fv} (${_float})}"; _u2="${_u2:-${_float}}"
  echo "### pinned  : ${_u1:+ubuntu }${_u1:-none pinned yet}"
  # Installed but with no source left (after --prepare-upgrade, say).
  if [ -z "$_u2" ] && _yv="$(dpkg-query -W -f='${Version}' yaru-theme-gtk 2>/dev/null)" \
     && [ -n "$_yv" ] && [ "$(dpkg-query -W -f='${db:Status-Status}' yaru-theme-gtk 2>/dev/null)" = installed ]; then
    _u2="installed ${_yv}, no source"
    echo "### themes  : ${_u2}"
  else
    echo "### themes  : ${_u2:+from }${_u2:-not installed yet}"
  fi
  echo ""
}

set -u

# Mode flags may appear anywhere; the other words are checked below.
MODE=online
arguments=""
for _arg in "$@"; do
  case "$_arg" in
    --download)   _mode=download ;;
    --offline)    _mode=offline ;;
    --uninstall)  _mode=uninstall ;;
    *)            arguments="${arguments:+${arguments} }${_arg}"; continue ;;
  esac
  [ "$MODE" = online ] || [ "$MODE" = "$_mode" ] \
    || error "Give only one of --download, --offline and --uninstall."
  MODE="$_mode"
done

# id -un always answers; $USER is unset under su.
RUN_USER="$(id -un)"

# Records. System records are shared by all users and root-owned in SYS_DIR;
# per-user records stay in the user's home.
SYS_DIR=/var/lib/ubuntu-look
SYS_RECORDS="${SYS_DIR}/records"
SYS_USERS="${SYS_DIR}/users"                  # users of the look, one per line
SAVED_OPTIONS="${SYS_DIR}/options"
PACKAGES_BEFORE="${SYS_RECORDS}/packages-before.txt"
# Packages left with only their configuration files before the first install.
CONFIG_FILES_BEFORE="${SYS_RECORDS}/config-files-before.txt"
# System packages that Ubuntu's combined extensions package replaced.
REPLACED_BY_COMBINED="${SYS_RECORDS}/replaced-by-combined.txt"
MANUAL_BEFORE="${SYS_RECORDS}/manual-before.txt"
INSTALLED_MANIFEST="${SYS_RECORDS}/installed-by-script.txt"
# "<package> <version it replaced>", one per line.
UPGRADED_MANIFEST="${SYS_RECORDS}/upgraded-by-script.txt"
REMOVED_FOR_UPGRADE="${SYS_RECORDS}/removed-for-upgrade.txt"
# Dependencies the uninstall purged, for its apt cache clean-up.
PURGED_DEPENDENCIES="${SYS_RECORDS}/purged-dependencies.txt"
# "<release> <mirror>" that answered without universe; kept on main until a
# later run finds universe there.
NO_UNIVERSE_RECORD="${SYS_RECORDS}/no-universe.txt"
GRUB_ADDED_FILE="${SYS_RECORDS}/grub-cmdline-added.txt"
# Present when the look appended the whole GRUB_CMDLINE_LINUX_DEFAULT line.
GRUB_LINE_ADDED="${SYS_RECORDS}/grub-line-added"
# Present while an add or a removal of the words awaits update-grub.
GRUB_ADD_PENDING="${SYS_RECORDS}/grub-add-pending"
GRUB_STRIP_PENDING="${SYS_RECORDS}/grub-strip-pending"
# The boot splash theme the look set.
PLYMOUTH_SET_FILE="${SYS_RECORDS}/plymouth-theme-set.txt"
# The id of the boot that owes a reboot for a system change (see need_reboot).
REBOOT_OWED="${SYS_RECORDS}/reboot-owed"
# Which of 'quiet splash' the kernel command line had at the first run.
GRUB_SEEN_FILE="${SYS_RECORDS}/grub-cmdline-seen.txt"
PLYMOUTH_BEFORE_FILE="${SYS_RECORDS}/plymouth-theme-before.txt"
PLYMOUTH_CONF=/etc/plymouth/plymouthd.conf
# plymouthd.conf as it was before the install, kept for the uninstall.
PLYMOUTH_CONF_BEFORE="${SYS_RECORDS}/plymouthd.conf.before"
# The uninstall's package snapshot, kept until it finishes; an install drops it.
UNINSTALL_SNAPSHOT="${SYS_RECORDS}/before-uninstall.txt"
# Present from the start of an initramfs rebuild until it succeeds.
INITRAMFS_PENDING="${SYS_RECORDS}/initramfs-pending"
# Set when update-initramfs rebuilt only the newest kernel; the summaries say so.
INITRAMFS_PARTIAL=0
INITRAMFS_PARTIAL_NOTE="update-initramfs failed for some kernels; only the newest was rebuilt — fix the others, then run: sudo update-initramfs -u -k all"
# Debian .debs an offline install placed in apt's cache, one path per line.
CACHED_DEBS="${SYS_RECORDS}/debs-in-apt-cache.txt"
BACKUP_DIR="${HOME:-}/.ubuntu-look-backup"
# Copies of system records an unfinished uninstall keeps for a later run.
DCONF_PROFILE_COPY="${BACKUP_DIR}/dconf-system-profile.ini"
MANIFEST_COPY="${BACKUP_DIR}/look-packages.txt"
# This user's pre-install settings snapshot.
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
DASH_TO_DOCK_UUID=dash-to-dock@micxgx.gmail.com
# Present when the install turned Dash-to-Dock off for this user.
DASH_TO_DOCK_OFF="${BACKUP_DIR}/dash-to-dock-turned-off"
# Present from a fresh install until Ubuntu's defaults replace the user's own.
DEFAULTS_PENDING="${BACKUP_ORIGINAL}/ubuntu-defaults-pending"
# The user's configuration directory as the desktop session reads it: the
# systemd user manager's XDG_CONFIG_HOME, which the session inherits, not
# this shell's.
_session_env="$(systemctl --user show-environment 2>/dev/null)"
_session_config="$(sed -n 's/^XDG_CONFIG_HOME=//p' <<< "$_session_env")"
CONFIG_HOME="${_session_config:-${HOME:-}/.config}"
# Its data directory likewise: user extensions, icons, the helper script.
_session_data="$(sed -n 's/^XDG_DATA_HOME=//p' <<< "$_session_env")"
DATA_HOME="${_session_data:-${HOME:-}/.local/share}"
# And its state directory: the theme extension's record of the style.
_session_state="$(sed -n 's/^XDG_STATE_HOME=//p' <<< "$_session_env")"
STATE_HOME="${_session_state:-${HOME:-}/.local/state}"
# GNOME's list of custom shortcuts, and the look's terminal shortcut in it.
CUSTOM_KEYBINDINGS_KEY="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
TERMINAL_SHORTCUT_PATH="${CUSTOM_KEYBINDINGS_KEY}/ubuntu-look-terminal/"
TERMINAL_SHORTCUT_RECORD="${BACKUP_DIR}/terminal-shortcut-added"
# Ubuntu's sub-pixel (RGB) font rendering rule, and the note that the look added it.
SUBPIXEL_CONF="${CONFIG_HOME}/fontconfig/conf.d/10-ubuntu-look-sub-pixel.conf"
SUBPIXEL_RECORD="${BACKUP_DIR}/subpixel-conf-added"
# The options an install run saves: those that pick the Ubuntu release, then
# the boot options.
RELEASE_OPTION_NAMES="UBUNTU_CODENAME UBUNTU_INCLUDE_DEVEL UBUNTU_MIRROR"
BOOT_OPTION_NAMES="UBUNTU_BOOT_SPLASH PLYMOUTH_THEME"
SAVED_OPTION_NAMES="${RELEASE_OPTION_NAMES} ${BOOT_OPTION_NAMES}"

# --refresh: list what an update would change, then ask before applying it.
REFRESH=0
if in_word_list --refresh "$arguments"; then
  case "$arguments" in
    --refresh) ;;
    *) error "--refresh takes no other arguments (got '${arguments}')." ;;
  esac
  [ "$MODE" = online ] || error "--refresh takes no mode flag."
  REFRESH=1
  arguments=""
fi
# Set when this run was given PLYMOUTH_THEME, before the saved options load.
PLYMOUTH_THEME_GIVEN="${PLYMOUTH_THEME:+1}"
load_saved_options

# The bundle: --download builds it, --offline installs from it.
# Beside the script; in the current directory for a piped run.
PACKAGES_DIR="$(cd -P -- "$(dirname -- "${SCRIPT_FILE:-./x}")" > /dev/null && pwd)/packages"
BUNDLE_INFO="${PACKAGES_DIR}/BUNDLE_INFO"
# Downloads land here and move into the bundle only once verified.
PARTIAL_DIR="${PACKAGES_DIR}/.partial"
# Files a --download run takes out; deleted once the new index is written.
DISCARD_DIR="${PACKAGES_DIR}/.discard"
# Debian's own builds of the look packages, for an uninstall without network.
DEBIAN_DEBS_DIR="${PACKAGES_DIR}/debian"
BUNDLE_DATE=""
# --offline: the bundle as the only apt source, through a temporary file.
LOCAL_SOURCES=""
# Options for every apt call of the stages (the bundle's source, --offline).
APT_OPTS=()
# --download state, for _download_exit. DOWNLOAD_SAVED keeps the machine's
# Ubuntu source and pin while it runs.
DOWNLOAD_SAVED="${SYS_DIR}/download-saved"
# The .deb fetch_deb placed last.
FETCHED_DEB=""
BUNDLE_DIRTY=0
FETCHED_NEW=()       # .debs this run added; removed if it does not finish
FETCHED_ADDED=()     # of those, the .debs of packages new to the bundle
SUDO_KEEPALIVE_PID=""
DOWNLOAD_DONE=0
# Set once an earlier --download's saved apt files are put back.
SAVED_RESTORED=0
# --download on a machine without the look: no system records, and an
# ubuntu-keyring it installs goes again.
NO_SYSTEM_RECORDS=0
KEYRING_FOR_BUILD=0
STALE_BUILD_KEYRING=0
PREV_SOURCES_FILE=""  # the machine's Ubuntu apt source and pin, to restore
PREV_PIN_FILE=""
BUILD_APT_OPTS=()    # the full pin, for the build's own apt calls only
DEBIAN_ONLY_APT_OPTS=()   # every source but the look's Ubuntu one; see debian_only_apt_opts
# Set by record_planned_installs: packages the combined package replaces.
PLANNED_REPLACED=""
DEBIAN_SOURCES_DIR=""
CLEAN_APT_OPTS=()
BUILD_PREFS_DIR=""

# Yaru's themes, in the stages and among the look's packages.
YARU_PKGS="yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound"
# The look itself, kept at the pinned release's builds. Only these may
# replace an installed Debian build; the uninstall restores the recorded version.
LOOK_PACKAGES="${YARU_PKGS} fonts-ubuntu ubuntu-wallpapers libreoffice-style-yaru"

# One Ubuntu package that replaces the four below, used where offered.
COMBINED_EXT_PKG="gnome-shell-ubuntu-extensions"
SEPARATE_EXT_PKGS="gnome-shell-extension-desktop-icons-ng gnome-shell-extension-ubuntu-dock"
SEPARATE_EXT_PKGS+=" gnome-shell-extension-ubuntu-tiling-assistant gnome-shell-extension-appindicator"
# The Ubuntu packages that carry the dock and the tiling assistant.
UBUNTU_SHELL_EXT_PKGS="gnome-shell-extension-ubuntu-dock gnome-shell-extension-ubuntu-tiling-assistant"
UBUNTU_SHELL_EXT_PKGS+=" ${COMBINED_EXT_PKG}"
# Packages apt may remove this run: those the combined package replaces, or
# the combined one where the release no longer offers it.
ALLOWED_REMOVALS=""

# Every package the pin admits from the pinned release, besides its wallpaper pack.
UBUNTU_PINNED_PACKAGES="${LOOK_PACKAGES} ${UBUNTU_SHELL_EXT_PKGS} session-migration humanity-icon-theme"

declare -A packages

# dconf-cli compiles the look's database; Plymouth is added below.
packages[0-base]="dconf-cli"
packages[1-desktop-base]="fonts-ubuntu ubuntu-wallpapers"
# gir1.2-dbusmenu-gtk3-0.4 gives tray icons their menus; Yaru inherits from
# humanity-icon-theme; gnome-session-canberra plays Yaru's login sound, as
# ubuntu-desktop-minimal pulls it in.
packages[2-desktop-gnome]="gnome-session-canberra ${SEPARATE_EXT_PKGS}
gir1.2-dbusmenu-gtk3-0.4 humanity-icon-theme ${YARU_PKGS}"

# Ubuntu release supplying the look; see resolve_release().
UBUNTU_CODENAME="${UBUNTU_CODENAME:-auto}"
REQUESTED_CODENAME="$UBUNTU_CODENAME"
# Checked before any network work; --offline takes the bundle's release.
case "$MODE" in online|download)
  [ "$UBUNTU_CODENAME" != devel ] \
    || error "UBUNTU_CODENAME=devel names no release: give the series' codename, or UBUNTU_INCLUDE_DEVEL=1."
  option_value_ok UBUNTU_CODENAME "$UBUNTU_CODENAME" \
    || error "UBUNTU_CODENAME must be a codename in lower case letters, or auto." ;;
esac

# amd64 and i386 use archive.ubuntu.com, others ports.ubuntu.com.
UBUNTU_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
case "$UBUNTU_ARCH" in
  amd64|i386) UBUNTU_DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
  *)          UBUNTU_DEFAULT_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
esac
REQUESTED_MIRROR="${UBUNTU_MIRROR:-}"
option_value_ok UBUNTU_MIRROR "$REQUESTED_MIRROR" \
  || error "UBUNTU_MIRROR takes one http:// or https:// URL without spaces (got '${REQUESTED_MIRROR}')."
UBUNTU_MIRROR="${UBUNTU_MIRROR:-$UBUNTU_DEFAULT_MIRROR}"
UBUNTU_MIRROR="${UBUNTU_MIRROR%/}"
UBUNTU_OLD_MIRROR="http://old-releases.ubuntu.com/ubuntu"

# Regex for Ubuntu archive URLs in apt-cache madison: any ubuntu.com host,
# plus the mirrors added below.
UBUNTU_COM_RE="://([a-z0-9.-]+[.])?ubuntu[.]com/"
UBUNTU_HOSTS_RE="$UBUNTU_COM_RE"
add_mirror_to_hosts_re "$UBUNTU_MIRROR"

# curl ignores apt's proxy; use it when no proxy is set. "DIRECT" and
# "false" mean no proxy to apt, but would be taken as a host name by curl.
if [ -z "${http_proxy:-}${https_proxy:-}" ]; then
  _apt_proxy="$(apt-config dump 2>/dev/null | sed -n 's/^Acquire::http::Proxy "\(.*\)";$/\1/p' | head -1)"
  case "$_apt_proxy" in
    ''|DIRECT|false) ;;
    *) export http_proxy="$_apt_proxy" https_proxy="$_apt_proxy" ;;
  esac
fi

# Candidates come from main; the pinned release also gets universe.
UBUNTU_COMPONENTS="main"
UBUNTU_PINNED_COMPONENTS="main universe"
APT_UPDATE_OUTPUT=""

# "quiet splash" and Plymouth; UBUNTU_BOOT_SPLASH=0 reverts them.
UBUNTU_BOOT_SPLASH="${UBUNTU_BOOT_SPLASH:-1}"
# Ubuntu's splash (firmware logo and spinner), also shipped by Debian.
PLYMOUTH_THEME="${PLYMOUTH_THEME:-bgrt}"
option_value_ok UBUNTU_BOOT_SPLASH "$UBUNTU_BOOT_SPLASH" \
  || error "UBUNTU_BOOT_SPLASH takes 0 or 1 (got '${UBUNTU_BOOT_SPLASH}')."
option_value_ok PLYMOUTH_THEME "$PLYMOUTH_THEME" \
  || error "PLYMOUTH_THEME takes a theme name of letters, digits and . _ + - (got '${PLYMOUTH_THEME}')."

[ "$UBUNTU_BOOT_SPLASH" != "0" ] && has_boot_splash_tools \
  && packages[0-base]="plymouth plymouth-themes ${packages[0-base]}"

# Ubuntu's Yaru style for LibreOffice, where LibreOffice is installed.
is_installed libreoffice-core \
  && packages[2-desktop-gnome]="${packages[2-desktop-gnome]} libreoffice-style-yaru"

# Animation effects for this user: 0 off, 1 on, unset leaves them as they are.
UBUNTU_LOOK_ANIMATIONS="${UBUNTU_LOOK_ANIMATIONS:-}"
case "$UBUNTU_LOOK_ANIMATIONS" in
  ''|0|1) ;;
  *) error "UBUNTU_LOOK_ANIMATIONS takes 0 or 1 (got '${UBUNTU_LOOK_ANIMATIONS}')." ;;
esac

# 1 = also consider the Ubuntu series in development.
UBUNTU_INCLUDE_DEVEL="${UBUNTU_INCLUDE_DEVEL:-0}"
option_value_ok UBUNTU_INCLUDE_DEVEL "$UBUNTU_INCLUDE_DEVEL" \
  || error "UBUNTU_INCLUDE_DEVEL takes 0 or 1 (got '${UBUNTU_INCLUDE_DEVEL}')."
# Recent releases configured as sources; few, to keep apt update fast.
MAX_UBUNTU_CANDIDATES=4
# Older releases to try when none of those fits this gnome-shell.
MAX_UBUNTU_LOOKBACK=6
# Ubuntu's list of every release with its version, to order retired ones.
UBUNTU_META_RELEASE="https://changelogs.ubuntu.com/meta-release"
# Bump when the pin or source content changes, so re-runs rewrite them.
PIN_VERSION="v23-2026-09-28"

# Where the look's own extensions live, outside any package's files.
LOCAL_EXT_DIR="/usr/local/share/gnome-shell/extensions"
# The login helper that switches on, for every user of the look, extensions a
# later release adds.
LOGIN_HELPER="/usr/local/lib/ubuntu-look/extensions-at-login.sh"
LOGIN_HELPER_ENTRY="/etc/xdg/autostart/ubuntu-look-extensions.desktop"
# The look's extensions, for the profile, enabling and verification.
THEME_EXT_UUID="ubuntu-look-theme@ubuntu-look"
# Extensions only some Ubuntu releases ship; switched on only where installed.
OPTIONAL_SHELL_EXTENSIONS="web-search-provider@ubuntu.com"
# The theme extension leads: GNOME Shell turns off and on again every
# extension enabled after one it turns off, and each pass reloads the theme.
SHELL_EXTENSIONS="${THEME_EXT_UUID} ubuntu-appindicators@ubuntu.com ubuntu-dock@ubuntu.com ding@rastersoft.com tiling-assistant@ubuntu.com ${OPTIONAL_SHELL_EXTENSIONS}"

# Ubuntu's defaults live in their own dconf database, read only by users of
# the look: their session's DCONF_PROFILE adds it after the system's databases.
# The database name has no hyphen: dconf's change signal uses it in a D-Bus path.
LOOK_PROFILE_NAME=ubuntu-look
LOOK_DB_NAME=ubuntu_look
LOOK_DB_FILE="/etc/dconf/db/${LOOK_DB_NAME}.d/10-ubuntu-look"
LOOK_PROFILE="/etc/dconf/profile/${LOOK_PROFILE_NAME}"
# Under ~/.config itself: the systemd user manager reads it, usually without
# XDG_CONFIG_HOME, and other users' homes are searched for it.
LOOK_ENV_REL=.config/environment.d/90-ubuntu-look.conf
LOOK_ENV_FILE="${HOME:-}/${LOOK_ENV_REL}"
# The one-shot entry that switches the extensions on at the next login.
EXT_AUTOSTART_FILE="${CONFIG_HOME}/autostart/ubuntu-look-enable-extensions.desktop"
EXT_AUTOSTART_SCRIPT="${DATA_HOME}/ubuntu-look/enable-extensions.sh"
# Boot-time removal of the profile, left by an uninstall while it was in use.
LOOK_CLEANUP_CONF=/etc/tmpfiles.d/ubuntu-look-cleanup.conf
# Present when the install created /etc/dconf/profile.
DCONF_PROFILE_DIR_MADE="${SYS_RECORDS}/dconf-profile-dir-created"
# session-migration (a Yaru dependency) would write color-scheme at login
# because of the look database, so it is masked.
SESSION_MIGRATION_MASK=/etc/systemd/user/session-migration.service
# Present when the install made the mask; the uninstall removes only that.
SESSION_MIGRATION_MASKED="${SYS_RECORDS}/session-migration-masked"
DCONF_USER_PROFILE=/etc/dconf/profile/user

# Ubuntu's archive keys, from Debian's ubuntu-keyring package.
UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg

# Per-run cache of "<codename> <version> <state> <mirror>".
UBUNTU_RELEASE_CACHE="$(mktemp)"

declare -a STATUS_INSTALLED=()
declare -a STATUS_UPGRADED=()
declare -a STATUS_ALREADY=()
# Packages with a newer Ubuntu build this Debian cannot take (not a failure).
declare -a STATUS_HELD=()
# Every package the stages name, for log_final_state() and --refresh.
ALL_STAGE_PACKAGES="$(printf '%s ' "${packages[@]}" | xargs -n1 | sort -u | xargs)"

declare -a STATUS_CHANGES=()
declare -a STATUS_NOCHANGE=()
declare -a STATUS_FAILED=()
declare -a STATUS_EXT_FAILED=()
# Builds ensure_package tried and turned down this run, as "pkg=version".
REJECTED_BUILDS=""
# Set by apt_install_checked: the removals that made it refuse.
REMOVES=""
# Packages align_look_packages kept at their build on purpose.
ALIGN_KEPT=""
# Set later in the run; empty until then, so _on_exit never acts on an
# inherited value.
PREV_UBUNTU_SOURCES=""
RUN_STARTED=0
PREPARE_UPGRADE=0
NARROW_WITHOUT_ARCHIVE=0
# Set by plymouth_put_back.
PLY_WAS=""; PLY_CURRENT=""
# Extensions enable_shell_extensions takes off, and turns on, in the same write.
ENABLE_DROP=""
ENABLE_ADD=""
# Set once fit_fonts_to_release has run.
FONTS_FITTED=0
# Set by refresh_check: 1 when the Ubuntu release needs no new check.
REFRESH_UNCHANGED=0
APT_LISTS_FRESH=0
# Set by ensure_package: the version it settled on.
ENSURE_VERSION=""
# Requested but absent from the bundle (--offline).
declare -a STATUS_UNAVAIL=()
GSETTINGS_UNCHANGED=0
# Stored copies of Ubuntu's values handed back to its defaults this run.
GSETTINGS_RECLAIMED=0
declare -a SETTINGS_KEPT=()
# A reboot an interrupted run of this boot owes is still asked for.
REBOOT_NEEDED=0
[ -s "$REBOOT_OWED" ] \
  && [ "$(cat "$REBOOT_OWED" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] \
  && REBOOT_NEEDED=1
RELOGIN_NEEDED=0
# Set by the extension steps: Dash-to-Dock is switched at the next login;
# an extension was recorded as switched on.
DASH_TO_DOCK_PENDING=0
EXT_RECORDED=0
STEP=0
# Set when the install has run to its end; see print_summary.
RUN_FINISHED=0
# Filled here, outside any $(...), so every later call reuses it.
SHELL_MAJOR_CACHE=""
shell_major > /dev/null

# The copy of /etc/default/grub a failed update left behind; the caller
# reports it.
GRUB_BACKUP_KEPT=""
# GRUB_CMDLINE_LINUX_DEFAULT's line in /etc/default/grub.
GRUB_KEY_RE='^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT='
# Set by strip_grub_words: the words this script added.
GRUB_ADDED_WORDS=""

# The extensions already switched on once for this user.
EXTENSIONS_ON_RECORD="${BACKUP_DIR}/extensions-switched-on.txt"

# System profile only; enable_shell_extensions() merges into the user's list.
DCONF_ONLY_KEYS=" enabled-extensions "

# Keys every supported Debian already sets to Ubuntu's values are not listed;
# tap-to-click stays for older GNOME, whose default is off.
GNOME_SETTINGS=(
  "org/gnome/shell|enabled-extensions|$(gvariant_string_array "$SHELL_EXTENSIONS")"
  "org/gnome/shell|always-show-log-out|true"

  "org/gnome/desktop/interface|gtk-theme|'Yaru'"
  "org/gnome/desktop/interface|accent-color|'orange'"
  "org/gnome/desktop/interface|icon-theme|'Yaru'"
  "org/gnome/desktop/interface|cursor-theme|'Yaru'"
  "org/gnome/desktop/interface|font-name|'Ubuntu Sans 11'"
  "org/gnome/desktop/interface|monospace-font-name|'Ubuntu Sans Mono 13'"
  "org/gnome/desktop/interface|document-font-name|'Sans 11'"
  "org/gnome/desktop/interface|font-antialiasing|'rgba'"
  "org/gnome/desktop/interface|enable-hot-corners|false"

  "org/gnome/desktop/wm/preferences|button-layout|':minimize,maximize,close'"
  "org/gnome/desktop/wm/preferences|titlebar-uses-system-font|false"
  "org/gnome/desktop/wm/preferences|action-middle-click-titlebar|'lower'"
  "org/gnome/desktop/wm/preferences|titlebar-font|'Ubuntu Sans Bold 11'"

  # Ubuntu's keybindings: Alt+Tab for windows, Super+Tab for applications.
  "org/gnome/desktop/wm/keybindings|switch-applications|['<Super>Tab']"
  "org/gnome/desktop/wm/keybindings|switch-applications-backward|['<Shift><Super>Tab']"
  "org/gnome/desktop/wm/keybindings|switch-windows|['<Alt>Tab']"
  "org/gnome/desktop/wm/keybindings|switch-windows-backward|['<Shift><Alt>Tab']"
  "org/gnome/desktop/wm/keybindings|show-desktop|['<Primary><Super>d', '<Primary><Alt>d', '<Super>d']"

  "org/gnome/desktop/sound|theme-name|'Yaru'"
  "org/gnome/desktop/sound|input-feedback-sounds|true"

  "org/gnome/desktop/peripherals/touchpad|tap-to-click|true"
  "org/gnome/desktop/peripherals/touchpad|click-method|'default'"

  # Ubuntu's power defaults: the power button asks, no idle sleep on mains.
  "org/gnome/settings-daemon/plugins/power|power-button-action|'interactive'"
  "org/gnome/settings-daemon/plugins/power|sleep-inactive-ac-timeout|0"
  # Ubuntu turns GNOME's donation reminder off; older GNOME lacks the key.
  "org/gnome/settings-daemon/plugins/housekeeping|donation-reminder-enabled|false"

  # gnome-terminal follows Yaru dark; the colours come from the profile.
  "org/gnome/terminal/legacy|theme-variant|'dark'"

  # Ubuntu Dock's settings. Its override applies only to an "ubuntu" session, so
  # they are restated here; keep them in step with 10_ubuntu-dock.gschema.override.
  "org/gnome/shell/extensions/dash-to-dock|dock-position|'LEFT'"
  "org/gnome/shell/extensions/dash-to-dock|dock-fixed|true"
  "org/gnome/shell/extensions/dash-to-dock|intellihide-mode|'ALL_WINDOWS'"
  # Only used when dock-fixed is off.
  "org/gnome/shell/extensions/dash-to-dock|intellihide|true"
  "org/gnome/shell/extensions/dash-to-dock|icon-size-fixed|true"
  "org/gnome/shell/extensions/dash-to-dock|custom-theme-shrink|true"
  "org/gnome/shell/extensions/dash-to-dock|running-indicator-style|'DOTS'"
  "org/gnome/shell/extensions/dash-to-dock|extend-height|true"
  "org/gnome/shell/extensions/dash-to-dock|scroll-action|'switch-workspace'"
  "org/gnome/shell/extensions/dash-to-dock|click-action|'focus-or-appspread'"
  "org/gnome/shell/extensions/dash-to-dock|shift-click-action|'launch'"
  "org/gnome/shell/extensions/dash-to-dock|middle-click-action|'launch'"
  "org/gnome/shell/extensions/dash-to-dock|shift-middle-click-action|'minimize'"
  "org/gnome/shell/extensions/dash-to-dock|disable-overview-on-startup|true"
  "org/gnome/shell/extensions/dash-to-dock|show-mounts-only-mounted|false"
  "org/gnome/shell/extensions/dash-to-dock|show-mounts-network|true"

  # Desktop icons from the bottom right, no trash or volumes.
  "org/gnome/shell/extensions/ding|start-corner|'bottom-right'"
  "org/gnome/shell/extensions/ding|show-trash|false"
  "org/gnome/shell/extensions/ding|show-volumes|false"
  "org/gnome/shell/extensions/ding|arrangeorder|'DESCENDINGNAME'"

  "org/gnome/nautilus/icon-view|default-zoom-level|'small'"
  "org/gnome/nautilus/preferences|open-folder-on-dnd-hover|false"

  "org/gtk/settings/file-chooser|sort-directories-first|true"
  "org/gtk/settings/file-chooser|startup-mode|'cwd'"

  # Ubuntu's defaults for apps Debian also ships; unused until an app is installed.
  "org/gnome/eog/ui|sidebar|false"
  "org/gnome/rhythmbox/rhythmdb|monitor-library|true"
  "org/gnome/rhythmbox/plugins|active-plugins|['alternative-toolbar', 'artsearch', 'audiocd', 'audioscrobbler', 'cd-recorder', 'daap', 'dbus-media-server', 'generic-player', 'ipod', 'iradio', 'mmkeys', 'mpris', 'mtpdevice', 'notification', 'power-manager']"
  "org/gnome/rhythmbox/plugins/alternative_toolbar|display-type|1"
  "org/onboard|layout|'Compact'"
  "org/onboard|theme|'Nightshade'"
  "org/onboard|key-label-font|'Ubuntu Sans'"
  "org/onboard|key-label-overrides|['RWIN::super-group', 'LWIN::super-group']"
  "org/onboard|xembed-onboard|true"
  "org/onboard/window|docking-enabled|true"
  "org/onboard/window|force-to-top|true"
  "org/gnome/software|first-run|false"
)

# The wallpaper keys; their values come with the wallpaper package.
WALLPAPER_KEYS=(
  "org/gnome/desktop/background|picture-uri"
  "org/gnome/desktop/background|picture-uri-dark"
  "org/gnome/desktop/screensaver|picture-uri"
)

# Ubuntu leaves the colour scheme at GNOME's default: the light style.
COLOR_SCHEME_KEY="org/gnome/desktop/interface|color-scheme"

# What the last install run was resolved against, for later runs and --refresh.
RELEASE_STATE="${SYS_DIR}/refresh-state"

# The pinned release, set by unchanged_since_last_run() when nothing changed.
KEPT_CODENAME=""

# Yaru on the login screen. Debian's Shell ignores Ubuntu's gdm gresource, but
# loads extensions whose metadata lists the "gdm" mode; this one loads Yaru's
# stylesheet. Only the greeter's database enables it.
GREETER_EXT_UUID="ubuntu-look-greeter@ubuntu-look"
GREETER_EXT_DIR="${LOCAL_EXT_DIR}/${GREETER_EXT_UUID}"
THEME_EXT_DIR="${LOCAL_EXT_DIR}/${THEME_EXT_UUID}"
# The directories above the extensions that this script created.
LOCAL_SHELL_DIRS_FILE="${SYS_RECORDS}/local-shell-dirs.txt"

# Theme the login screen through a gdm database: theme, fonts, wallpaper and
# the greeter extension.
GDM_PROFILE_DIR="/etc/dconf/db/gdm.d"
GDM_PROFILE_FILE="${GDM_PROFILE_DIR}/10-ubuntu-look"

# Ubuntu's terminal colours (white on Yaru's #300A24, GNOME's palette) go
# into a gnome-terminal profile named Ubuntu, made the default when it is
# new or no default is set. Other profiles are left as they are.
TERMINAL_PROFILES="/org/gnome/terminal/legacy/profiles:"
TERMINAL_PROFILE_RECORD="${BACKUP_DIR}/terminal-profile.txt"
TERMINAL_BACKGROUND="#300A24"
TERMINAL_FOREGROUND="#FFFFFF"

# The Debian logo on the Show Applications button, under Yaru only. The dock
# asks for view-app-grid-<mode>-symbolic, and Yaru has none for "user".
APP_GRID_ICON="${DATA_HOME}/icons/Yaru/scalable/actions/view-app-grid-user-symbolic.svg"

# How much of the canvas the artwork covers; fuller than Ubuntu's 0.742 so
# the button matches the icons beside it.
APP_GRID_INK_FRACTION=0.98

trap '_on_exit; print_summary' EXIT
# Ctrl-C and a closed terminal still print the summary and run the cleanup.
trap 'echo ""; message warn "interrupted — stopping here"; exit 130' INT
trap 'exit 129' HUP; trap 'exit 143' TERM

# One run at a time. The lock lives in /run, which only root can write, so
# no other user can replace it.
UBUNTU_LOOK_LOCK=/run/ubuntu-look.lock

###############################################################################
# 8. Uninstall (--uninstall)
###############################################################################
# The look's settings go back to Debian's defaults; installed packages go,
# replaced ones get Debian's build back. System changes go with the last user.

if [ "$MODE" = uninstall ]; then
trap - INT TERM
trap rm_release_cache EXIT
[ -z "$arguments" ] || error "--uninstall takes no other arguments (got '${arguments}')"
# A closed terminal must not stop the run between a purge and its cleanup.
trap '' HUP

# The records are read from $HOME, so it must be this user's home.
_home="$(getent passwd "$RUN_USER" | cut -d: -f6)"
_h="${HOME:-}"
[ -n "$_home" ] && [ "${_h%/}" = "${_home%/}" ] \
  || error "HOME is '${HOME:-}', but ${RUN_USER}'s home is '${_home}'. Run it from ${RUN_USER}'s own login."

declare -a DONE=()
declare -a SKIPPED=()
declare -a GUESSED=()

# Unfinished work keeps its records, so a later run can finish it.
USER_PENDING=0
SYSTEM_PENDING=0
PURGE_FAILED=0
PURGE_KEPT_CONFIG=""
# Taken before the uninstall changes any package; "none" = not taken.
UNUSED_BEFORE_PURGE=none
INSTALLED_BEFORE_PURGE=""
RESTORED_BEFORE_PURGE=""
# Packages left on Ubuntu's build because Debian's would not install.
RESTORE_FAILED=""
# Set by install_debian_build.
DEBIAN_BUILD=""

# Each mirror in the Ubuntu apt source counts as an Ubuntu archive.
for _u in $(ubuntu_source_entries | awk '{ print $1 }' | sort -u); do
  add_mirror_to_hosts_re "${_u%/}"
done

###############################################################################
# Helpers
###############################################################################

# sudo; a failure marks the system work unfinished.
must_sudo() {
  sudo "$@" && return 0
  SYSTEM_PENDING=1
  message warn "failed: sudo $*"
  return 1
}

# sudo_write_atomic; a failure marks the system work unfinished.
must_write() {
  sudo_write_atomic "$@" && return 0
  SYSTEM_PENDING=1
  message warn "failed to write $2"
  return 1
}

have_session() { [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dconf >/dev/null 2>&1; }

# False without a desktop session or dconf; the step $1 names is left for a
# later run.
need_session() {
  have_session && return 0
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    SKIPPED+=("dconf-cli is missing — $1; sudo apt install dconf-cli, then run this again")
  else
    SKIPPED+=("No desktop session — $1; run this again from your desktop")
  fi
  USER_PENDING=1
  return 1
}

# Removed, but its configuration files are still there (whatever its selection).
is_config_only() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" = config-files ]
}


# The packages a purge of $@ would remove, from an apt simulation; false
# when apt refuses the purge (a held package needs one of them, say).
purge_sim() {
  local o
  o="$(LC_ALL=C apt-get -s purge "$@" 2>/dev/null)" || return 1
  printf '%s\n' "$o" | awk '/^(Remv|Purg) /{print $2}'
}

# Show what a purge of $1 takes, apt's extra removals included, then purge;
# $2, when given, is purge_sim's output for $1. Returns 1 for an empty list.
# Declined or failed: recorded as unfinished.
purge_list() {
  [ -n "${1// /}" ] || return 1
  local p planned extra="" purge="" keepconf=""
  echo ""
  message "these packages will be removed:"
  # shellcheck disable=SC2086
  printf '   - %s\n' $1
  if [ $# -ge 2 ]; then
    planned="$2"
  else
    # shellcheck disable=SC2086
    planned="$(purge_sim $1)"
  fi
  for p in $planned; do
    in_word_list "$p" "$1" || extra="$extra $p"
  done
  if [ -n "$extra" ]; then
    echo ""
    message warn "apt would also remove these, because they depend on the above:"
    # shellcheck disable=SC2086
    printf '   ! %s\n' $extra
    message warn "stop here if you want to keep any of them"
  fi
  echo ""
  if ! ask_yes; then
    PURGE_FAILED=1
    SYSTEM_PENDING=1
    return 0
  fi
  # Configuration files present before the install are the admin's: remove only.
  for p in $1; do
    if grep -qxF "$p" "$CONFIG_FILES_BEFORE" 2>/dev/null; then
      keepconf="${keepconf} ${p}"
    else
      purge="${purge} ${p}"
    fi
  done
  PURGE_KEPT_CONFIG="$keepconf"
  # shellcheck disable=SC2086
  apt_or_pending remove $keepconf
  # shellcheck disable=SC2086
  apt_or_pending purge $purge
  return 0
}

# apt-get $1 on the packages that follow, if any.
apt_or_pending() {
  [ $# -gt 1 ] || return 0
  sudo apt-get "$1" -y "${@:2}" && return 0
  PURGE_FAILED=1
  SYSTEM_PENDING=1
  message warn "apt could not $1 every package — see its output above"
}

###############################################################################
# Settings helpers
###############################################################################

# Pre-install value of key $2 in path $1; empty when it was at the default.
snapshot_dconf_value() { ini_value "${BACKUP_ORIGINAL}/dconf-dump.ini" "$1" "$2"; }

# The value the look set for the key, from its defaults database.
our_dconf_value() {
  local f
  for f in "$LOOK_DB_FILE" "$DCONF_PROFILE_COPY"; do
    [ -f "$f" ] && { ini_value "$f" "$1" "$2"; return; }
  done
}

# The separate package of extension $1, where there is one.
ext_own_package() {
  case "$1" in
    ubuntu-dock@*)          echo gnome-shell-extension-ubuntu-dock ;;
    tiling-assistant@*)     echo gnome-shell-extension-ubuntu-tiling-assistant ;;
    ubuntu-appindicators@*) echo gnome-shell-extension-appindicator ;;
    ding@*)                 echo gnome-shell-extension-desktop-icons-ng ;;
  esac
}

# The package that provides extension $1: the combined one where the look
# installed it, else the separate one.
ext_package() {
  case "$1" in
    ubuntu-dock@*|tiling-assistant@*|ubuntu-appindicators@*|ding@*|web-search-provider@*)
      if grep -qxF "$COMBINED_EXT_PKG" "$INSTALLED_MANIFEST" "$MANIFEST_COPY" 2>/dev/null; then
        echo "$COMBINED_EXT_PKG"; return
      fi ;;
  esac
  ext_own_package "$1"
}

# True when the look installed the package of extension $1. Not so where the
# separate package was there before: the extension is the user's own.
look_installed_ext() {
  local own pkg
  own="$(ext_own_package "$1")"
  [ -n "$own" ] && predates_install "$own" && return 1
  pkg="$(ext_package "$1")"
  [ -n "$pkg" ] && grep -qxF "$pkg" "$INSTALLED_MANIFEST" "$MANIFEST_COPY" 2>/dev/null
}

###############################################################################
# Per-user steps
###############################################################################

# The extension list this user gets from the system without the look: the
# default profile's value (an administrator's site default), else none.
debian_default_extensions() {
  local v
  v="$(DCONF_PROFILE=user dconf read -d /org/gnome/shell/enabled-extensions 2>/dev/null)"
  printf '%s\n' "${v:-@as []}"
}

step_extensions() {
  step "Switching off the extensions ubuntu-look.sh enabled..."
  need_session "extensions not switched off" || return
  # A reinstall after an interrupted uninstall switches them on again.
  rm -f "$EXTENSIONS_ON_RECORD"
  local have_snap=0 now snap_en e new="" dis dtd_on=0 dtd_back=0
  [ -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ] && have_snap=1
  now="$(array_items "$(user_dconf_read /org/gnome/shell/enabled-extensions)")"
  snap_en="$(array_items "$(snapshot_dconf_value org/gnome/shell enabled-extensions)")"

  # Drop the look's extensions, except those enabled before the install.
  for e in $now; do
    case "$e" in *@ubuntu-look) continue ;; esac
    if in_word_list "$e" "$SHELL_EXTENSIONS"; then
      if [ "$have_snap" -eq 1 ]; then
        in_word_list "$e" "$snap_en" || continue
      else
        look_installed_ext "$e" && continue
      fi
    fi
    new="${new} ${e}"
  done
  # Dash-to-Dock goes back on where still installed.
  if [ -f "$DASH_TO_DOCK_OFF" ] && ! in_word_list "$DASH_TO_DOCK_UUID" "$new" \
     && extension_installed "$DASH_TO_DOCK_UUID"; then
    new="${new} ${DASH_TO_DOCK_UUID}"
    dtd_on=1
  fi

  if [ "$(echo "$new" | xargs)" != "$(echo "$now" | xargs)" ]; then
    # Nothing left and nothing set before: Debian's default. While other
    # users keep the look's database and this session still reads it, a reset
    # would bring back its list: an empty one is written, Debian's value too.
    if [ -z "${new// /}" ] && [ -z "$snap_en" ] \
       && ! { [ "$LAST_USER" -eq 0 ] && session_on_look_profile; }; then
      dconf reset /org/gnome/shell/enabled-extensions
    elif [ -z "${new// /}" ] && [ -z "$snap_en" ]; then
      dconf write /org/gnome/shell/enabled-extensions "$(debian_default_extensions)"
    else
      dconf write /org/gnome/shell/enabled-extensions "$(gvariant_string_array "$new")"
    fi || { USER_PENDING=1; GUESSED+=("Could not write enabled-extensions"); return; }
    DONE+=("Switched off the look's extensions; your own stay on")
    [ "$dtd_on" -eq 1 ] && DONE+=("Dash-to-Dock turned back on")
  fi
  # With no list of the user's own, the running shell took the look's default
  # list. The last user's is withdrawn: a write and a reset make the shell
  # read Debian's (none). Otherwise it stays for the other users, and an
  # empty list is written.
  if [ -z "$(user_dconf_read /org/gnome/shell/enabled-extensions)" ] && session_on_look_profile; then
    if [ "$LAST_USER" -eq 1 ]; then
      dconf write /org/gnome/shell/enabled-extensions "@as []" 2>/dev/null \
        && dconf reset /org/gnome/shell/enabled-extensions 2>/dev/null
    else
      dconf write /org/gnome/shell/enabled-extensions "$(debian_default_extensions)" 2>/dev/null
    fi
  fi
  # The install's entry leaves the disabled list, also where Dash-to-Dock is
  # gone; its marker goes once that list is written.
  [ -f "$DASH_TO_DOCK_OFF" ] && dtd_back=1

  # The disabled list: the look's extensions and a re-enabled Dash-to-Dock
  # leave it, as on Debian; the user's other entries stay. Empty goes back to
  # Debian's default (unset).
  local stored_dis was_dis e2 dis_ok=1
  stored_dis="$(user_dconf_read /org/gnome/shell/disabled-extensions)"
  was_dis="$(array_items "$stored_dis")"
  dis=""
  for e2 in $was_dis; do
    [ "$dtd_back" -eq 1 ] && [ "$e2" = "$DASH_TO_DOCK_UUID" ] && continue
    in_word_list "$e2" "$SHELL_EXTENSIONS" && continue
    dis="${dis} ${e2}"
  done
  dis="$(echo "$dis" | xargs)"
  # A changed list, or an explicit empty one ("@as []"), which Debian leaves unset.
  if [ "$dis" != "$(echo "$was_dis" | xargs)" ] \
     || { [ -z "$dis" ] && [ -n "$stored_dis" ]; }; then
    if [ -z "$dis" ]; then
      dconf reset /org/gnome/shell/disabled-extensions
    else
      dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$dis")"
    fi || { dis_ok=0; USER_PENDING=1; GUESSED+=("Could not write disabled-extensions"); }
  fi
  [ "$dis_ok" -eq 1 ] && rm -f "$DASH_TO_DOCK_OFF"
  return 0
}

# What the look's own extensions stored beyond its table: Tiling Assistant's
# and Desktop Icons' settings and Tiling Assistant's session file. Only when
# the look installed the extension; Debian's default is none of it.
step_clear_extension_state() {
  step "Clearing what the look's extensions stored..."
  local e dir cleared=0 left=0
  for e in tiling-assistant@ubuntu.com ding@rastersoft.com; do
    look_installed_ext "$e" || continue
    dir="/org/gnome/shell/extensions/${e%%@*}/"
    if [ -n "$(user_dconf list "$dir")" ]; then
      need_session "the settings of ${e%%@*} not cleared" || { left=1; continue; }
      if dconf reset -f "$dir" 2>/dev/null; then cleared=1; else USER_PENDING=1; left=1; GUESSED+=("Could not clear ${dir}"); fi
    fi
    if [ "$e" = tiling-assistant@ubuntu.com ] && [ -d "${CONFIG_HOME}/tiling-assistant" ]; then
      [ -e "${CONFIG_HOME}/tiling-assistant/tiledSessionRestore2.json" ] \
        && rm -f "${CONFIG_HOME}/tiling-assistant/tiledSessionRestore2.json" && cleared=1
      rmdir "${CONFIG_HOME}/tiling-assistant" 2>/dev/null
    fi
  done
  # The theme extension's record of the style it last followed.
  if [ -f "${STATE_HOME}/ubuntu-look/appearance" ]; then
    rm -f "${STATE_HOME}/ubuntu-look/appearance" && cleared=1
    rmdir "${STATE_HOME}/ubuntu-look" 2>/dev/null
  fi
  if [ "$cleared" -eq 1 ]; then
    DONE+=("Cleared the settings and files the look's extensions stored")
  elif [ "$left" -eq 0 ]; then
    SKIPPED+=("Nothing stored by the look's extensions")
  fi
}

# Give back the keybindings the tiling assistant left empty.
step_restore_tiling_keybindings() {
  step "Restoring the keybindings the tiling assistant takes over..."
  # Only when the look installed it; otherwise it never touched them.
  if ! look_installed_ext tiling-assistant@ubuntu.com; then
    SKIPPED+=("Tiling keybindings left alone — the look did not install the tiling assistant")
    return
  fi
  need_session "tiling keybindings not checked" || return
  local entry path key now before restored=0 active=0 failed=0
  if in_word_list tiling-assistant@ubuntu.com \
       "$(array_items "$(user_dconf_read /org/gnome/shell/enabled-extensions)")"; then
    SKIPPED+=("Tiling assistant stays on — its keybindings stay with it")
    return
  fi
  # Give its disable() time to restore them.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    active=0
    extension_active tiling-assistant@ubuntu.com || break
    active=1
    sleep 1
  done
  # Still running until logout: reset the keys anyway.
  [ "$active" -eq 1 ] \
    && SKIPPED+=("Tiling assistant runs until you log out — until then both it and GNOME answer Super+Arrow")
  for entry in \
    "org/gnome/desktop/wm/keybindings:maximize unmaximize" \
    "org/gnome/mutter/keybindings:toggle-tiled-left toggle-tiled-right" \
    "org/gnome/mutter:edge-tiling"
  do
    path="${entry%%:*}"
    for key in ${entry#*:}; do
      now="$(dconf read "/${path}/${key}" 2>/dev/null)"
      case "$now" in "@as []"|"[]"|"false") ;; *) continue ;; esac
      # The user's own value from before the install stays.
      before="$(snapshot_dconf_value "$path" "$key")"
      [ -n "$before" ] && [ "${before// /}" = "${now// /}" ] && continue
      # Debian's default, as for every other key the look touched.
      if dconf reset "/${path}/${key}" 2>/dev/null; then
        restored=$((restored + 1))
      else
        USER_PENDING=1; failed=1; GUESSED+=("Could not reset ${key}")
      fi
    done
  done
  if [ "$restored" -gt 0 ]; then
    DONE+=("Gave back ${restored} tiling keybinding(s) (Super+Arrow, edge tiling)")
  elif [ "$failed" -eq 0 ]; then
    SKIPPED+=("Tiling keybindings already at Debian's default")
  fi
}

# dconf $@ for step_restore_gnome_settings, counted in its reset or failed.
count_dconf() {
  if dconf "$@" 2>/dev/null; then reset=$((reset + 1)); else USER_PENDING=1; failed=1; fi
}

step_restore_gnome_settings() {
  step "Resetting GNOME settings and wallpaper to Debian's defaults..."
  need_session "GNOME settings not reset" || return
  # Every key the look writes goes back to Debian's default, whatever its
  # value, so no Yaru theme or Ubuntu font outlives its package. Settings the
  # look never writes, dock favourites among them, are left alone.
  local path key ours nudge=0 reset=0 failed=0 rb=0 _i
  # The theme extension, switched off above, would write a Yaru theme back
  # when the colour keys reset: its end is awaited, up to 5 seconds.
  for _i in 1 2 3 4 5; do
    extension_active "$THEME_EXT_UUID" || break
    sleep 1
  done
  # Only a session whose Ubuntu defaults are gone needs telling.
  [ "$LAST_USER" -eq 1 ] && session_on_look_profile && nudge=1
  local value
  while read -r path key; do
    value="$(user_dconf_read "/${path}/${key}")"
    if [ -n "$value" ]; then
      count_dconf reset "/${path}/${key}"
    elif [ "$nudge" -eq 1 ]; then
      # The look's extensions are already off.
      case "$path" in org/gnome/shell/extensions/*) continue ;; esac
      # The running session was not told that Ubuntu's defaults went; a
      # write and a reset make it read Debian's value now.
      ours="$(our_dconf_value "$path" "$key")"
      [ -n "$ours" ] || continue
      dconf write "/${path}/${key}" "$ours" 2>/dev/null
      count_dconf reset "/${path}/${key}"
    else
      continue
    fi
    [ "${path}/${key}" = org/gnome/rhythmbox/plugins/active-plugins ] && rb=1
  done < <(look_keys)
  # Rhythmbox enables its default plugins only where seen-plugins lacks them;
  # resetting it too gives Rhythmbox's own first-run plugin set.
  if [ "$rb" -eq 1 ] && [ -n "$(user_dconf_read /org/gnome/rhythmbox/plugins/seen-plugins)" ]; then
    count_dconf reset /org/gnome/rhythmbox/plugins/seen-plugins
  fi
  # gedit's scheme, which the theme extension switches between the Yaru
  # schemes; they go with the look.
  case "$(user_dconf_read /org/gnome/gedit/preferences/editor/scheme)" in
    "'Yaru'"|"'Yaru-dark'") count_dconf reset /org/gnome/gedit/preferences/editor/scheme ;;
  esac
  if [ "$failed" -eq 1 ]; then
    GUESSED+=("Some GNOME settings could not be reset")
  elif [ "$reset" -gt 0 ]; then
    DONE+=("GNOME settings and wallpaper back to Debian's defaults (${reset} setting(s) changed back)")
  else
    SKIPPED+=("GNOME settings and wallpaper already at Debian's defaults")
  fi
}

# The dock's settings are cleared: Debian's dash returns, and Dash-to-Dock,
# where it comes back on, starts from its defaults. Favourites are kept.
step_restore_dock_settings() {
  step "Clearing the dock settings..."
  need_session "dock settings not cleared" || return
  local dir=/org/gnome/shell/extensions/dash-to-dock/
  if [ -z "$(user_dconf dump "$dir")" ]; then
    SKIPPED+=("Dock settings already at Debian's default")
  elif dconf reset -f "$dir" 2>/dev/null; then
    DONE+=("Dock settings cleared; your dock favourites are kept")
  else
    USER_PENDING=1
    GUESSED+=("Could not clear the dock settings")
  fi
}

step_disable_look_profile() {
  step "Switching your sessions back to the default dconf profile..."
  # Services started from now on no longer get it; running ones keep it.
  # Also after an earlier run removed the file but could not reach systemd.
  if systemctl --user show-environment 2>/dev/null | grep -qx "DCONF_PROFILE=${LOOK_PROFILE_NAME}"; then
    systemctl --user unset-environment DCONF_PROFILE 2>/dev/null \
      || { USER_PENDING=1; GUESSED+=("Could not clear DCONF_PROFILE from your user session — run --uninstall again from your desktop"); }
  fi
  [ -f "$LOOK_ENV_FILE" ] || return
  rm -f "$LOOK_ENV_FILE"
  rmdir "${LOOK_ENV_FILE%/*}" 2>/dev/null || true
  DONE+=("Removed ${LOOK_ENV_FILE} — Ubuntu's defaults no longer apply to you from the next login")
}

# The autostart directory goes too, where now empty.
step_remove_extension_autostart() {
  step "Removing the one-shot extension autostart..."
  if [ -f "$EXT_AUTOSTART_FILE" ] || [ -f "$EXT_AUTOSTART_SCRIPT" ]; then
    DONE+=("Removed the one-shot extension autostart")
  fi
  remove_extension_autostart
  rmdir "${EXT_AUTOSTART_FILE%/*}" 2>/dev/null || true
}

# The user icons directory goes too, where now empty.
step_remove_app_grid_icon() {
  step "Removing the Show Applications button icon..."
  if remove_user_icon "$APP_GRID_ICON"; then
    DONE+=("Removed the Show Applications button icon")
  else
    SKIPPED+=("No Show Applications button icon to remove")
  fi
  rmdir "${DATA_HOME}/icons" 2>/dev/null || true
}

step_terminal_profile() {
  step "Removing the Ubuntu terminal profile..."
  local record="$TERMINAL_PROFILE_RECORD" base="$TERMINAL_PROFILES"
  local uuids keep="" one uuid stock="" rest="" before failed=0
  if ! have_session; then
    # Also a marked profile whose record a stopped install did not write.
    { [ -f "$record" ] || [ -n "$(marked_terminal_profiles)" ]; } \
      && need_session "terminal profile not removed"
    return
  fi
  # The recorded profile and any other marked as the look's.
  uuids="$(sed -n 's/^uuid=//p' "$record" 2>/dev/null | tr -d '\r') $(marked_terminal_profiles)"
  uuids="$(echo "$uuids" | xargs -n1 2>/dev/null | sort -u | xargs)"
  if [ -z "$uuids" ]; then
    SKIPPED+=("No terminal profile was added by this script")
    return
  fi
  # Unset before: only gnome-terminal's own profiles left means its default.
  [ -n "$(snapshot_dconf_value "org/gnome/terminal/legacy/profiles:" list)" ] \
    || stock="$(array_items "$(GSETTINGS_BACKEND=memory gsettings get org.gnome.Terminal.ProfilesList list 2>/dev/null)")"
  for one in $(array_items "$(dconf read "${base}/list" 2>/dev/null)"); do
    in_word_list "$one" "$uuids" && continue
    in_word_list "$one" "$stock" || rest="${rest} ${one}"
    keep="${keep}${keep:+, }'${one}'"
  done
  [ -n "$stock" ] && [ -z "$rest" ] && keep=""
  if [ -n "$keep" ]; then
    dconf write "${base}/list" "[${keep}]" 2>/dev/null || failed=1
  else
    dconf reset "${base}/list" 2>/dev/null || failed=1
  fi
  for uuid in $uuids; do
    dconf reset -f "${base}/:${uuid}/" 2>/dev/null || failed=1
  done
  # The default goes back to the earlier one, if it still exists.
  if in_word_list "$(dconf read "${base}/default" 2>/dev/null | tr -d "'")" "$uuids"; then
    before="$(snapshot_dconf_value "org/gnome/terminal/legacy/profiles:" default | tr -d "'")"
    if [ -n "$before" ] && in_word_list "$before" "$(array_items "$(dconf read "${base}/list" 2>/dev/null)")"; then
      dconf write "${base}/default" "'${before}'" 2>/dev/null || failed=1
    else
      dconf reset "${base}/default" 2>/dev/null || failed=1
    fi
  fi
  if [ "$failed" -eq 0 ]; then
    rm -f "$record"
    DONE+=("Removed the Ubuntu terminal profile; your own profiles and default are kept")
  else
    USER_PENDING=1
    GUESSED+=("Could not fully remove the Ubuntu terminal profile")
  fi
}

# The terminal shortcut the look added; the user's own shortcuts stay.
step_terminal_shortcut() {
  step "Removing the terminal keyboard shortcut..."
  local key="$CUSTOM_KEYBINDINGS_KEY"
  local list one keep="" failed=0
  list="$(array_items "$(user_dconf_read "$key")")"
  # Without the record too, when an interrupted install left the shortcut:
  # its path is the look's alone.
  if [ ! -f "$TERMINAL_SHORTCUT_RECORD" ] \
     && ! in_word_list "$TERMINAL_SHORTCUT_PATH" "$list" \
     && [ -z "$(dconf list "$TERMINAL_SHORTCUT_PATH" 2>/dev/null)" ]; then
    SKIPPED+=("No terminal shortcut was added by this script")
    return
  fi
  need_session "terminal shortcut not removed" || return
  if in_word_list "$TERMINAL_SHORTCUT_PATH" "$list"; then
    for one in $list; do
      [ "$one" = "$TERMINAL_SHORTCUT_PATH" ] || keep="${keep}${keep:+, }'${one}'"
    done
    if [ -n "$keep" ]; then
      dconf write "$key" "[${keep}]" 2>/dev/null || failed=1
    else
      dconf reset "$key" 2>/dev/null || failed=1
    fi
  fi
  dconf reset -f "$TERMINAL_SHORTCUT_PATH" 2>/dev/null || failed=1
  if [ "$failed" -eq 0 ]; then
    rm -f "$TERMINAL_SHORTCUT_RECORD"
    DONE+=("Removed the terminal keyboard shortcut; your own shortcuts are kept")
  else
    USER_PENDING=1
    GUESSED+=("Could not fully remove the terminal keyboard shortcut")
  fi
}

# The subpixel rendering file, only while it is still the one the look made;
# its directories go too, where now empty.
step_subpixel_rendering() {
  step "Removing the subpixel font rendering setting..."
  if [ ! -f "$SUBPIXEL_RECORD" ]; then
    SKIPPED+=("Subpixel font rendering: nothing of this script's is left")
    return
  fi
  local conf
  conf="$(subpixel_conf_path)"
  if [ -f "$conf" ] && [ ! -L "$conf" ] \
     && cmp -s "$conf" <(subpixel_conf_content); then
    if ! rm -f "$conf"; then
      USER_PENDING=1
      GUESSED+=("Could not remove ${conf}")
      return
    fi
    DONE+=("Removed the subpixel font rendering setting (${conf})")
  elif [ -e "$conf" ] || [ -L "$conf" ]; then
    SKIPPED+=("${conf} was changed since the install — left as it is")
  fi
  rm -f "$SUBPIXEL_RECORD"
  rmdir "${conf%/*}" "${conf%/*/*}" 2>/dev/null || true
}

###############################################################################
# System steps (last user only)
###############################################################################

# Compile Ubuntu's defaults empty, so the running session drops them now. A
# copy of the keyfile stays as the reference for the settings steps.
step_empty_look_defaults() {
  [ -f "$LOOK_DB_FILE" ] || return 0
  step "Withdrawing Ubuntu's GNOME defaults from your session..."
  mkdir -p "$BACKUP_DIR" && cp "$LOOK_DB_FILE" "$DCONF_PROFILE_COPY" || return 0
  must_sudo rm -f "$LOOK_DB_FILE" && must_sudo dconf update
}

step_remove_dconf_profile() {
  step "Removing Ubuntu's GNOME defaults..."
  local d="/etc/dconf/db/${LOOK_DB_NAME}"
  # Running sessions keep a deleted database open, so compile it empty first,
  # unless it is compiled empty already.
  if [ -d "${d}.d" ] || [ -f "$d" ]; then
    local ready=0
    if [ -d "${d}.d" ] && [ -z "$(ls -A "${d}.d" 2>/dev/null)" ] && ! dconf_db_stale "$LOOK_DB_NAME"; then
      ready=1
    elif must_sudo rm -rf "${d}.d" && must_sudo mkdir "${d}.d" && must_sudo dconf update; then
      ready=1
    fi
    if [ "$ready" -eq 1 ]; then
      must_sudo rm -rf "${d}.d" \
        && must_sudo rm -f "$d" \
        && DONE+=("Removed Ubuntu's defaults (${d}.d)")
    fi
  fi
  if [ -f "$LOOK_PROFILE" ]; then
    if sudo grep -qas "DCONF_PROFILE=${LOOK_PROFILE_NAME}" /proc/[0-9]*/environ; then
      # Still read by a running session: made plain now, removed at next boot.
      local plain clean
      plain="$(mktemp)"; clean="$(mktemp)"
      look_profile_content | grep -vx "system-db:${LOOK_DB_NAME}" > "$plain"
      printf 'r %s\nr %s\n' "$LOOK_PROFILE" "$LOOK_CLEANUP_CONF" > "$clean"
      # A repeat run keeps the directory line an earlier run added.
      grep -qxF 'r /etc/dconf/profile' "$LOOK_CLEANUP_CONF" 2>/dev/null \
        && echo 'r /etc/dconf/profile' >> "$clean"
      must_write "$plain" "$LOOK_PROFILE" \
        && { [ -d "${LOOK_CLEANUP_CONF%/*}" ] || must_sudo mkdir -p "${LOOK_CLEANUP_CONF%/*}"; } \
        && must_write "$clean" "$LOOK_CLEANUP_CONF" \
        && DONE+=("${LOOK_PROFILE} now has no Ubuntu defaults; it is removed at the next boot")
      rm -f "$plain" "$clean"
    else
      must_sudo rm -f "$LOOK_PROFILE" && DONE+=("Removed ${LOOK_PROFILE}")
    fi
  fi
  return 0
}

step_remove_gdm_profile() {
  step "Removing the login screen theme and the shell theme extension..."
  local changed=0 acted=0 d dirs pair prof rec
  if [ -f "$GDM_PROFILE_FILE" ]; then
    if must_sudo rm -f "$GDM_PROFILE_FILE"; then changed=1; DONE+=("Removed ${GDM_PROFILE_FILE}"); else acted=1; fi
  fi
  if [ -d "$THEME_EXT_DIR" ]; then
    must_sudo rm -rf "$THEME_EXT_DIR" && DONE+=("Removed ${THEME_EXT_DIR}")
    # Removed or reported as failed: either way not "nothing to remove".
    acted=1
  fi
  if [ -d "$GREETER_EXT_DIR" ]; then
    if must_sudo rm -rf "$GREETER_EXT_DIR"; then changed=1; DONE+=("Removed ${GREETER_EXT_DIR}"); else acted=1; fi
  fi
  if [ -e "$LOGIN_HELPER_ENTRY" ] || [ -e "$LOGIN_HELPER" ]; then
    if must_sudo rm -f "$LOGIN_HELPER_ENTRY" "$LOGIN_HELPER"; then
      DONE+=("Removed the login helper for the look's extensions")
    fi
    acted=1
  fi
  # Also where a failed write left it empty.
  [ -d "${LOGIN_HELPER%/*}" ] && sudo rmdir "${LOGIN_HELPER%/*}" 2>/dev/null
  # Only the directories the install made, when empty.
  dirs="$(cat "$LOCAL_SHELL_DIRS_FILE" 2>/dev/null)"
  for d in $dirs; do
    case "$d" in "${LOCAL_EXT_DIR%/*}"|"$LOCAL_EXT_DIR") ;; *) continue ;; esac
    sudo rmdir "$d" 2>/dev/null || true
  done
  # The profiles the install created; each record goes with its file.
  for pair in gdm:gdm-profile-created Debian-gdm:gdm-profile-Debian-gdm-created; do
    prof="/etc/dconf/profile/${pair%%:*}"; rec="${SYS_RECORDS}/${pair#*:}"
    [ -f "$rec" ] || continue
    if [ -e "$prof" ] && ! greeter_profile_is_ours "$prof"; then
      # Changed since the install: the administrator's now.
      SKIPPED+=("${prof} was changed after the install — left in place")
      sudo rm -f "$rec"
      continue
    fi
    if [ -e "$prof" ]; then
      if must_sudo rm -f "$prof"; then changed=1; DONE+=("Removed ${prof}, which this script created"); else acted=1; fi
    fi
    [ -e "$prof" ] || sudo rm -f "$rec"
  done
  # Only where the install created it, and now empty.
  if [ -d "$GDM_PROFILE_DIR" ] && [ -z "$(ls -A "$GDM_PROFILE_DIR" 2>/dev/null)" ] \
     && [ -f "${SYS_RECORDS}/dconf-gdm-dir-created" ]; then
    must_sudo rmdir "$GDM_PROFILE_DIR" && must_sudo rm -f /etc/dconf/db/gdm && changed=1
  fi
  [ -d "$GDM_PROFILE_DIR" ] || sudo rm -f "${SYS_RECORDS}/dconf-gdm-dir-created"
  # The profile directory, where the install created it: now if empty;
  # holding only the look profile still in use, with it at the next boot
  # (systemd-tmpfiles reports a non-empty one as an error).
  [ -f "$DCONF_PROFILE_DIR_MADE" ] && case "$(ls -A /etc/dconf/profile 2>/dev/null)" in
    "") [ -d /etc/dconf/profile ] && must_sudo rmdir /etc/dconf/profile ;;
    "$LOOK_PROFILE_NAME")
        [ -f "$LOOK_CLEANUP_CONF" ] \
          && ! grep -qxF 'r /etc/dconf/profile' "$LOOK_CLEANUP_CONF" \
          && echo 'r /etc/dconf/profile' | must_sudo tee -a "$LOOK_CLEANUP_CONF" > /dev/null ;;
  esac
  # Also recompiles after an earlier failed dconf update.
  if [ $changed -eq 1 ]; then
    must_sudo dconf update
    need_reboot
  elif dconf_db_stale gdm; then
    must_sudo dconf update && DONE+=("Login screen database compiled without the Ubuntu look")
  else
    [ "$acted" -eq 1 ] || SKIPPED+=("No login screen theme to remove")
  fi
  return 0
}

step_restore_grub() {
  step "Restoring the kernel command line..."
  if [ ! -f "$GRUB_ADDED_FILE" ]; then
    SKIPPED+=("Kernel command line: nothing of this script's is left on it")
    return
  fi
  if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; then
    SKIPPED+=("GRUB is gone — the words this script added cannot be removed")
    forget_grub_words
    return
  fi
  strip_grub_words
  case $? in
    0) DONE+=("Removed '${GRUB_ADDED_WORDS}' from the kernel command line; the rest of /etc/default/grub is unchanged")
       need_reboot ;;
    1) SKIPPED+=("/etc/default/grub no longer carries what ubuntu-look.sh added") ;;
    2) SKIPPED+=("/etc/default/grub is not in a shape this script will edit — remove '${GRUB_ADDED_WORDS}' by hand")
       SYSTEM_PENDING=1 ;;
    *) GUESSED+=("/etc/default/grub could not be updated — '${GRUB_ADDED_WORDS}' is still on the kernel command line")
       [ -n "$GRUB_BACKUP_KEPT" ] && GUESSED+=("the file as it was before that attempt is at ${GRUB_BACKUP_KEPT}")
       SYSTEM_PENDING=1 ;;
  esac
}

step_restore_plymouth() {
  step "Restoring the boot splash theme..."
  # A rebuild still owed (INITRAMFS_PENDING) is finished below even without
  # the record.
  if [ ! -f "$PLYMOUTH_BEFORE_FILE" ] && [ ! -f "$INITRAMFS_PENDING" ]; then
    SKIPPED+=("Boot splash theme: nothing of this script's is left to put back")
    return
  fi
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    SKIPPED+=("Plymouth is gone — no theme to put back")
    drop_plymouth_records
    return
  fi
  plymouth_put_back
  case $? in
    0) DONE+=("Boot splash theme restored to '${PLY_WAS}'"); need_reboot ;;
    1) if [ -z "$PLY_WAS" ]; then
         SKIPPED+=("No earlier boot splash theme was recorded — left on '${PLY_CURRENT}'")
       else
         SKIPPED+=("Boot splash theme is already '${PLY_CURRENT}'")
       fi ;;
    2) SKIPPED+=("Boot splash theme left on '${PLY_CURRENT}', which you chose after the install") ;;
    3) GUESSED+=("Could not read the boot splash theme — not restored"); SYSTEM_PENDING=1 ;;
    4) GUESSED+=("Boot splash theme is still '${PLY_CURRENT}' — '${PLY_WAS}' may no longer be installed")
       SYSTEM_PENDING=1 ;;
    5) GUESSED+=("Boot splash theme set to '${PLY_WAS}', but the initramfs rebuild failed — run: sudo update-initramfs -u")
       SYSTEM_PENDING=1 ;;
    6) DONE+=("Boot splash theme '${PLY_CURRENT}' rebuilt into the initramfs"); need_reboot ;;
    7) GUESSED+=("The initramfs rebuild still owed failed — run: sudo update-initramfs -u")
       SYSTEM_PENDING=1 ;;
    8) GUESSED+=("Boot splash theme not put back — ${SYS_RECORDS} could not be written")
       SYSTEM_PENDING=1 ;;
  esac
}

# The newest version of $1 not served by Ubuntu, i.e. Debian's (madison
# lists versions newest first, in apt's order).
debian_version_of() {
  madison_rows "$1" | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '$2 !~ re { print $1; exit }'
}

# True when apt offers version $2 of $1 from any source.
version_available() {
  madison_rows "$1" | awk -F'|' -v v="$2" '$1 == v { f = 1 } END { exit !f }'
}

# A Debian build an offline install cached: version $2, else the newest.
cached_debian_deb() {
  local f v best="" bestv=""
  [ -s "$CACHED_DEBS" ] || return 1
  while read -r f; do
    [ -f "$f" ] && [ "$(dpkg-deb -f "$f" Package 2>/dev/null)" = "$1" ] || continue
    v="$(dpkg-deb -f "$f" Version 2>/dev/null)"
    [ "$v" = "$2" ] && { echo "$f"; return 0; }
    if [ -z "$bestv" ] || dpkg --compare-versions "$v" gt "$bestv"; then best="$f"; bestv="$v"; fi
  done < "$CACHED_DEBS"
  [ -n "$best" ] && echo "$best"
}

# Install $2 at Debian's version $3 from apt, else from the cached .deb $4;
# $1 holds extra apt options, or is empty. Sets DEBIAN_BUILD to the version
# tried last.
install_debian_build() {
  local opt="$1" pkg="$2" deb="$4"
  DEBIAN_BUILD="$3"
  # shellcheck disable=SC2086
  if [ -n "$DEBIAN_BUILD" ] && installs_cleanly $opt "${pkg}=${DEBIAN_BUILD}" \
     && sudo apt-get install -y $opt "${pkg}=${DEBIAN_BUILD}" < /dev/null; then
    return 0
  fi
  [ -n "$deb" ] && DEBIAN_BUILD="$(dpkg-deb -f "$deb" Version)" || return 1
  # shellcheck disable=SC2086
  installs_cleanly $opt "$deb" && sudo apt-get install -y $opt "$deb" < /dev/null
}

# The packages Ubuntu's combined extensions package replaced, from Debian or
# apt's cache.
step_restore_replaced_by_combined() {
  step "Putting back what Ubuntu's combined extensions package replaced..."
  if [ ! -s "$REPLACED_BY_COMBINED" ]; then
    SKIPPED+=("No package was replaced by Ubuntu's combined extensions package")
    return
  fi
  if is_installed "$COMBINED_EXT_PKG"; then
    SKIPPED+=("The packages ${COMBINED_EXT_PKG} replaced stay replaced while it is installed")
    # Unfinished only when its purge failed or was declined, which marked the
    # run so; kept on purpose (held, or it would take other packages) it is final.
    return
  fi
  local pkg want deb
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    is_installed "$pkg" && continue
    want="$(debian_version_of "$pkg")"
    deb="$(cached_debian_deb "$pkg" "${want:-none}")" || deb=""
    if install_debian_build "" "$pkg" "$want" "$deb"; then
      restore_auto_mark "$pkg"
      DONE+=("Reinstalled ${pkg}, which Ubuntu's combined extensions package had replaced")
    else
      GUESSED+=("Could not reinstall ${pkg} (it may need the network) — run this again")
      SYSTEM_PENDING=1
    fi
  done < "$REPLACED_BY_COMBINED"
}

# Replaced packages go back to Debian's build.
step_restore_upgraded_packages() {
  step "Putting back the package versions that were here before..."
  if [ ! -s "$UPGRADED_MANIFEST" ]; then
    SKIPPED+=("No package was replaced by an Ubuntu build")
    return
  fi
  local pkg ver now want deb restored=0 failed=0 kept=0 was_auto rc
  while read -r pkg ver; do
    [ -n "$pkg" ] && [ -n "$ver" ] || continue
    now="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
    if ! is_installed "$pkg"; then
      # Removed by the user: stays removed. Removed by prepare-upgrade: restored.
      grep -qxF "$pkg" "$REMOVED_FOR_UPGRADE" 2>/dev/null || continue
      now=""
    fi
    [ "$now" = "$ver" ] && continue
    # A package the user holds is not moved.
    if is_held "$pkg"; then SKIPPED+=("${pkg} kept at ${now} — held by you"); kept=1; continue; fi
    # Keep a newer Debian build (a security update, say).
    if [ -n "$now" ] && [ ! -e "$UBUNTU_SOURCES" ] \
       && dpkg --compare-versions "$now" gt "$ver" && pkg_version_is_debian "$pkg" "$now"; then
      SKIPPED+=("${pkg} stays at ${now}, a newer Debian build than ${ver}")
      kept=1
      continue
    fi
    # Debian's build, or the recorded version when Debian's is older.
    want="$(debian_version_of "$pkg")"
    if [ -z "$want" ] || dpkg --compare-versions "$want" lt "$ver"; then
      version_available "$pkg" "$ver" && want="$ver"
    fi
    deb="$(cached_debian_deb "$pkg" "$ver")" || deb=""
    if [ -z "$want" ] && [ -z "$deb" ]; then
      SKIPPED+=("${pkg}: neither ${ver} nor a Debian build is available — left ${now:+at }${now:-uninstalled}")
      [ -n "$now" ] && RESTORE_FAILED="${RESTORE_FAILED} ${pkg}"
      failed=1
      continue
    fi
    # apt install marks the package manual; an automatic one stays automatic.
    was_auto=0
    apt-mark showauto "$pkg" 2>/dev/null | grep -qxF "$pkg" && was_auto=1
    install_debian_build --allow-downgrades "$pkg" "$want" "$deb"; rc=$?
    want="$DEBIAN_BUILD"
    if [ "$rc" -eq 0 ]; then
      restore_auto_mark "$pkg"
      [ "$was_auto" -eq 1 ] && sudo apt-mark auto "$pkg" >/dev/null 2>&1
      DONE+=("${pkg} back to ${want}${now:+ (was ${now})}")
      restored=$((restored + 1))
    else
      GUESSED+=("${pkg} is still ${now:-not installed} — ${want} will not install (it may need the network)")
      [ -n "$now" ] && RESTORE_FAILED="${RESTORE_FAILED} ${pkg}"
      SYSTEM_PENDING=1; failed=1
    fi
  done < "$UPGRADED_MANIFEST"
  [ "$restored" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$kept" -eq 0 ] \
    && SKIPPED+=("Replaced packages are already back on their earlier builds")
  return 0
}

step_remove_ubuntu_repo() {
  step "Removing the Ubuntu apt source and pin..."
  local src=0 pin=0
  # The pin goes only with the source: a source left unpinned would offer
  # every Ubuntu package. An offline install has a pin only.
  if [ -f "$UBUNTU_SOURCES" ]; then
    must_sudo rm -f "$UBUNTU_SOURCES" || return 0
    src=1
  fi
  [ -f "$UBUNTU_PIN" ] && must_sudo rm -f "$UBUNTU_PIN" && pin=1
  # The offline bundle's package list, which no apt update removes.
  local f lists=0
  while read -r f; do
    case "$f" in /var/lib/apt/lists/*) [ -f "$f" ] && sudo rm -f "$f" && lists=1 ;; esac
  done < <(cat "$OFFLINE_LISTS_RECORD" 2>/dev/null)
  sudo rm -f "$OFFLINE_LISTS_RECORD"
  [ "$lists" -eq 1 ] && DONE+=("Removed the offline bundle's package list from apt")
  # The apt files a killed --download saved; the next run would put them back.
  sudo rm -rf "$DOWNLOAD_SAVED"
  if [ "$src" -eq 1 ] && [ "$pin" -eq 1 ]; then
    DONE+=("Removed the Ubuntu apt source and pin")
  elif [ "$src" -eq 1 ]; then
    DONE+=("Removed the Ubuntu apt source; the pin could not be removed yet")
  elif [ "$pin" -eq 1 ]; then
    DONE+=("Removed the Ubuntu pin")
  else
    return 0
  fi
  # apt reads only the lists of configured sources, so Ubuntu's are unused
  # from here; a successful update also deletes them. A failing source of the
  # user's own changes neither.
  sudo apt-get update -qq < /dev/null 2>/dev/null || true
  return 0
}

# Purging Ubuntu Dock can delete Dash-to-Dock's schema; reinstall it.
repair_dashtodock() {
  is_installed gnome-shell-extension-dashtodock || return 0
  [ -f /usr/share/glib-2.0/schemas/org.gnome.shell.extensions.dash-to-dock.gschema.xml ] && return 0
  if sudo apt-get install -y --reinstall gnome-shell-extension-dashtodock < /dev/null; then
    DONE+=("Reinstalled Dash-to-Dock, whose settings file Ubuntu Dock had taken over")
  else
    GUESSED+=("Dash-to-Dock lost its settings file with Ubuntu Dock — run: sudo apt install --reinstall gnome-shell-extension-dashtodock")
    SYSTEM_PENDING=1
  fi
}

# Remove the install's mask, also where session-migration stays: it only
# kept Ubuntu's migrations away from the look's database, which is gone now.
step_unmask_session_migration() {
  [ -f "$SESSION_MIGRATION_MASKED" ] || return 0
  # The look's own session-migration still installed (its purge declined or
  # failed): the mask stays for the run that removes it. One the user had
  # before, or keeps, is unmasked now.
  grep -qxF session-migration "$INSTALLED_MANIFEST" 2>/dev/null \
    && is_present session-migration && [ "$SYSTEM_PENDING" -eq 1 ] && return 0
  if [ "$(readlink "$SESSION_MIGRATION_MASK" 2>/dev/null)" = /dev/null ]; then
    must_sudo rm -f "$SESSION_MIGRATION_MASK" || return 0
    DONE+=("Unmasked session-migration")
  fi
  sudo rm -f "$SESSION_MIGRATION_MASKED"
}

# Remove the Debian builds an offline install cached, and apt's downloads
# of the look's packages that are no longer installed.
step_remove_cached_debs() {
  [ "$SYSTEM_PENDING" -eq 0 ] || return 0
  local f pkg have n=0 m=0
  if [ -s "$CACHED_DEBS" ]; then
    while read -r f; do
      case "$f" in /var/cache/apt/archives/*.deb) ;; *) continue ;; esac
      [ -f "$f" ] && sudo rm -f "$f" && n=$((n + 1))
    done < "$CACHED_DEBS"
  fi
  # Every downloaded build of a removed package; for a package put back on
  # Debian's build, every build but the installed one.
  for pkg in $({ cat "$INSTALLED_MANIFEST" "$PURGED_DEPENDENCIES"
                 awk '{ print $1 }' "$UPGRADED_MANIFEST"; } 2>/dev/null | sort -u); do
    have="$(pkg_installed_version "$pkg")"
    for f in /var/cache/apt/archives/"${pkg}"_*.deb; do
      [ -f "$f" ] || continue
      [ -n "$have" ] && [ "$(dpkg-deb -f "$f" Version 2>/dev/null)" = "$have" ] && continue
      sudo rm -f "$f" && m=$((m + 1))
    done
  done
  # Ubuntu's builds of the look's packages an earlier install left there:
  # Ubuntu-only packages, or versions Ubuntu marks as its own.
  for pkg in $UBUNTU_PINNED_PACKAGES; do
    for f in /var/cache/apt/archives/"${pkg}"_*.deb; do
      [ -f "$f" ] || continue
      case "$pkg" in
        "$COMBINED_EXT_PKG"|gnome-shell-extension-ubuntu-*|ubuntu-wallpapers*) ;;
        *) case "${f##*/}" in *ubuntu*) ;; *) continue ;; esac
           case "${f##*/}" in "${pkg}"_*ubuntu*) ;; *) continue ;; esac ;;
      esac
      [ "$(dpkg-deb -f "$f" Version 2>/dev/null)" = "$(pkg_installed_version "$pkg")" ] && continue
      sudo rm -f "$f" && m=$((m + 1))
    done
  done
  [ "$n" -gt 0 ] && DONE+=("Removed ${n} Debian package file(s) the offline install placed in apt's cache")
  [ "$m" -gt 0 ] && DONE+=("Removed ${m} downloaded package file(s) of the look from apt's cache")
  return 0
}

step_remove_packages() {
  step "Removing packages..."
  local list="" pkg keep="" dep extra cand takes planned="" kept changed=1
  local -A alone
  if [ ! -s "$INSTALLED_MANIFEST" ]; then
    SKIPPED+=("No record of installed packages — no package removed")
    return
  fi
  # With broken dependencies every simulation fails, and apt would fail too.
  if ! LC_ALL=C apt-get -s check > /dev/null 2>&1; then
    GUESSED+=("apt reports broken dependencies — no package removed; fix apt, then run this again")
    SYSTEM_PENDING=1
    return
  fi

  # Keep replaced packages and, where their restore failed, their dependencies.
  [ -s "$UPGRADED_MANIFEST" ] && keep="$(awk '{print $1}' "$UPGRADED_MANIFEST" | xargs)"
  if [ -n "${RESTORE_FAILED// /}" ]; then
    # shellcheck disable=SC2086
    for dep in $(apt-cache depends --recurse --no-suggests --no-conflicts \
                   --no-breaks --no-replaces --no-enhances $RESTORE_FAILED 2>/dev/null \
                 | grep -E '^[a-z0-9]' | sort -u); do
      is_installed "$dep" && ! predates_install "$dep" && keep="${keep} ${dep}"
    done
  fi
  # A later run from the desktop needs dconf.
  if [ "$USER_PENDING" -eq 1 ] && grep -qxF dconf-cli "$INSTALLED_MANIFEST" 2>/dev/null; then
    keep="${keep} dconf-cli"
    SYSTEM_PENDING=1
  fi

  for pkg in $(sort -u "$INSTALLED_MANIFEST"); do
    predates_install "$pkg" && continue
    in_word_list "$pkg" "$keep" && continue
    # apt refuses to purge a held package; the user's hold stands.
    if is_held "$pkg"; then SKIPPED+=("${pkg} kept — held by you (apt-mark unhold ${pkg} to let it go)"); continue; fi
    # Ubuntu's keys stay while an apt source the user added needs any of them.
    if [ "$pkg" = ubuntu-keyring ] \
       && dpkg -L ubuntu-keyring 2>/dev/null | grep '\.gpg$' \
          | grep -rqsF -f - /etc/apt/sources.list /etc/apt/sources.list.d/; then
      SKIPPED+=("ubuntu-keyring kept — another apt source uses its keys")
      continue
    fi
    if is_config_only "$pkg"; then
      grep -qxF "$pkg" "$CONFIG_FILES_BEFORE" 2>/dev/null && continue
      list="${list} ${pkg}"
    elif is_present "$pkg"; then
      list="${list} ${pkg}"
    fi
  done

  # Drop any candidate apt will not purge, or whose purge would take a
  # non-candidate.
  while [ -n "${list// /}" ] && [ "$changed" -eq 1 ]; do
    changed=0
    # shellcheck disable=SC2086
    if ! planned="$(purge_sim $list)"; then
      # Kept one by one, so the rest still go.
      kept=""
      for cand in $list; do
        # shellcheck disable=SC2086
        if purge_sim $kept "$cand" > /dev/null; then
          kept="${kept} ${cand}"
        else
          SKIPPED+=("${cand} kept — apt refuses to remove it (a held or essential package needs it, or apt reported an error)")
        fi
      done
      list="$kept"
      changed=1
      continue
    fi
    extra="$(for pkg in $planned; do in_word_list "$pkg" "$list" || echo "$pkg"; done | xargs)"
    [ -n "$extra" ] || break
    for cand in $list; do
      # Each candidate's own simulation does not change between rounds.
      [ -n "${alone[$cand]+set}" ] || alone[$cand]="$(purge_sim "$cand")"
      # shellcheck disable=SC2086
      takes="$(printf '%s\n' "${alone[$cand]}" | grep -xF -f <(printf '%s\n' $extra) | xargs)"
      if [ -n "$takes" ]; then
        # The leading space stays, as the summary lines below expect.
        list=" $(printf '%s\n' $list | grep -vxF "$cand" | xargs)"
        SKIPPED+=("${cand} kept — removing it would also remove: ${takes}")
        changed=1
      fi
    done
  done

  if ! purge_list "$list" "$planned"; then
    SKIPPED+=("No package to remove")
  elif [ $PURGE_FAILED -eq 1 ]; then
    GUESSED+=("Not purged (declined, or apt failed) — some of these are still installed:${list}")
  else
    DONE+=("Removed the packages ubuntu-look.sh installed:${list}")
    [ -n "${PURGE_KEPT_CONFIG// /}" ] \
      && DONE+=("Configuration files kept, as before the install:${PURGE_KEPT_CONFIG}")
  fi
  remove_stale_icon_caches
}

# Automatically installed packages nothing needs, as apt's autoremove sees
# them; "none" when apt cannot tell.
unused_packages() {
  local sim
  sim="$(LC_ALL=C apt-get -s autoremove 2>/dev/null)" || { echo none; return; }
  printf '%s\n' "$sim" | awk '/^Remv /{print $2}' | xargs
}

# Purge the dependencies the removal left unused, so no autoremove is needed.
# Runs after the restores, which may need some of them again. Packages unused
# before the uninstall, and packages it put back, stay.
step_remove_unused_dependencies() {
  step "Removing dependencies the look's packages left unused..."
  local pkg orphans="" now
  now="$(unused_packages)"
  if [ "$now" = none ]; then
    GUESSED+=("apt could not list unused packages — no dependency removed; run --uninstall again once apt works")
    SYSTEM_PENDING=1
    return
  fi
  for pkg in $now; do
    in_word_list "$pkg" "$UNUSED_BEFORE_PURGE" && continue
    in_word_list "$pkg" "$INSTALLED_BEFORE_PURGE" || continue
    in_word_list "$pkg" "$RESTORED_BEFORE_PURGE" && continue
    predates_install "$pkg" && continue
    orphans="${orphans} ${pkg}"
  done
  # The main purge's outcome; the snapshot stays until both are done.
  local main_failed="$PURGE_FAILED"
  PURGE_FAILED=0
  if ! purge_list "$orphans"; then
    SKIPPED+=("No dependency left unused")
  elif [ $PURGE_FAILED -eq 1 ]; then
    GUESSED+=("Not purged (declined, or apt failed) — dependencies left unused:${orphans}")
  else
    DONE+=("Removed the dependencies the look's packages left unused:${orphans}")
    # shellcheck disable=SC2086
    sys_record_append "$PURGED_DEPENDENCIES" "$(printf '%s\n' $orphans)"
  fi
  # Done with it: a later run for another pending step must not reuse it.
  [ "$PURGE_FAILED" -eq 0 ] && [ "$main_failed" -eq 0 ] && sudo rm -f "$UNINSTALL_SNAPSHOT"
  return 0
}

# The purge leaves each icon theme's generated icon-theme.cache behind; a
# directory holding only that, and owned by no package, goes.
remove_stale_icon_caches() {
  local d removed=0
  for d in /usr/share/icons/Yaru* /usr/share/icons/Humanity*; do
    [ -d "$d" ] && [ "$(ls -A "$d" 2>/dev/null)" = icon-theme.cache ] || continue
    dpkg -S "$d" > /dev/null 2>&1 && continue
    must_sudo rm -rf "$d" && removed=1
  done
  [ "$removed" -eq 1 ] && DONE+=("Removed the icon caches the Yaru and Humanity themes left behind")
  return 0
}

###############################################################################
# Run
###############################################################################

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
echo -e "${YELLOW}       ubuntu-look UNINSTALL${ENDCOLOR}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
echo ""
echo "This undoes only what ubuntu-look.sh did:"
echo "  - for you: extensions, GNOME settings, wallpaper, terminal profile, helper files"
echo "  - for the system, when you are the last user of the look: packages it"
echo "    installed, apt source and pin, login screen, boot splash and kernel"
echo "    command line"
echo "Every setting it made goes back to Debian's default. Your dock favourites, and"
echo "the packages and apps you had before or installed later, are kept."
[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
  && message warn "No desktop session: your settings are reset on a later run from the desktop."
echo ""
confirm_continue

sudo -v || error "sudo is required."

# Wait for any run in progress; from here no other run can start.
take_run_lock

OTHERS="$(other_users)"
LAST_USER=1
[ -n "$OTHERS" ] && LAST_USER=0

# A user who never installed the look keeps their settings as they are.
if grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null || [ -d "$BACKUP_DIR" ] || [ -f "$LOOK_ENV_FILE" ]; then
  step_disable_look_profile
  [ "$LAST_USER" -eq 1 ] && step_empty_look_defaults
  step_extensions
  step_restore_tiling_keybindings
  step_restore_gnome_settings
  step_clear_extension_state
  step_restore_dock_settings
  step_remove_extension_autostart
  step_remove_app_grid_icon
  step_terminal_profile
  step_terminal_shortcut
  step_subpixel_rendering

  # session-migration's records (one per session type), where the look
  # brought session-migration in.
  grep -qxF session-migration "$INSTALLED_MANIFEST" "$MANIFEST_COPY" 2>/dev/null \
    && rm -f "${DATA_HOME}"/session_migration-*
  # The install may have created these; rmdir leaves any that hold files.
  rmdir "$DATA_HOME" 2>/dev/null || true
  rmdir "$HOME/.local" 2>/dev/null || true
else
  SKIPPED+=("No settings of the look recorded for ${RUN_USER} — settings left unchanged")
fi
_anim_failed=0
_anim="$(apply_animation_option)"
case $? in
  0) DONE+=("$_anim") ;;
  1) SKIPPED+=("$_anim") ;;
  2) GUESSED+=("$_anim"); _anim_failed=1 ;;
esac

# This user no longer uses the look once their settings are reset; until then
# only dconf-cli stays, for the later run from the desktop. Their records go
# now, so a run cut off in the system part does not repeat these steps.
if [ "$USER_PENDING" -eq 0 ]; then
  if grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null; then
    _users_tmp="$(mktemp)"
    grep -vxF "$RUN_USER" "$SYS_USERS" > "$_users_tmp"
    must_write "$_users_tmp" "$SYS_USERS"
    rm -f "$_users_tmp"
  fi
  if [ -d "$BACKUP_DIR" ] && ! grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null; then
    rm -rf "$BACKUP_DIR"
    message "Removed ${BACKUP_DIR}"
  fi
fi

if [ "$LAST_USER" -eq 1 ]; then
  step_remove_dconf_profile
  step_remove_gdm_profile
  step_restore_grub
  # Before the purge: once the look's theme package is gone, Plymouth reports
  # its fallback theme, not the one the install set.
  step_restore_plymouth
  # Without the Ubuntu source and pin, restores take Debian's builds.
  step_remove_ubuntu_repo
  # What is unused, installed and replaced before any package changes; kept
  # on record, so a run that is declined or cut off is finished by the next.
  _snapshot_failed=0
  if [ ! -f "$UNINSTALL_SNAPSHOT" ]; then
    _unused="$(unused_packages)"
    if [ "$_unused" != none ]; then
      sys_record_write "$UNINSTALL_SNAPSHOT" "unused: ${_unused}
installed: $(installed_package_list | xargs)
restored: $(awk '{print $1}' "$UPGRADED_MANIFEST" 2>/dev/null | xargs)" \
        || { _snapshot_failed=1; sudo rm -f "$UNINSTALL_SNAPSHOT"; }
    fi
  fi
  if [ "$_snapshot_failed" -eq 1 ]; then
    GUESSED+=("Could not write ${UNINSTALL_SNAPSHOT} — no package was changed; run --uninstall again")
    SYSTEM_PENDING=1
  elif [ -f "$UNINSTALL_SNAPSHOT" ]; then
    UNUSED_BEFORE_PURGE="$(sed -n 's/^unused: //p' "$UNINSTALL_SNAPSHOT")"
    INSTALLED_BEFORE_PURGE="$(sed -n 's/^installed: //p' "$UNINSTALL_SNAPSHOT")"
    RESTORED_BEFORE_PURGE="$(sed -n 's/^restored: //p' "$UNINSTALL_SNAPSHOT")"
    _had_plymouth=0
    is_installed plymouth && _had_plymouth=1
    # Before any purge: Ubuntu's yaru-theme-gtk depends on session-migration.
    step_restore_upgraded_packages
    step_remove_packages
    step_restore_replaced_by_combined
    # Also retries a repair that failed earlier.
    repair_dashtodock
    step_remove_unused_dependencies
    step_unmask_session_migration
    step_remove_cached_debs
    # Purging Plymouth rebuilt the initramfs.
    [ "$_had_plymouth" -eq 1 ] && ! is_installed plymouth && need_reboot
  else
    # Without the snapshot the purge would leave its dependencies behind.
    GUESSED+=("apt cannot tell which packages are unused (see 'sudo apt-get check') — no package was changed; run --uninstall again once apt works")
    SYSTEM_PENDING=1
  fi
else
  SKIPPED+=("System changes kept — the look is still used by: ${OTHERS}")
fi

[ "$INITRAMFS_PARTIAL" = 1 ] && GUESSED+=("$INITRAMFS_PARTIAL_NOTE")
echo ""
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
echo -e "${GREEN}                    UNINSTALL SUMMARY${ENDCOLOR}"
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
summary_block "$GREEN" "Restored/removed:" + "" "${DONE[@]}"
summary_block "$YELLOW" "Could not finish:" "?" "" "${GUESSED[@]}"
summary_block "$YELLOW" "Skipped:" - "" "${SKIPPED[@]}"
echo ""

# System records go once all system work is done.
if [ "$LAST_USER" -eq 1 ]; then
  if [ "$SYSTEM_PENDING" -eq 0 ]; then
    # Settings still to restore need to know which extensions came with the look.
    if [ "$USER_PENDING" -eq 1 ] && [ -f "$INSTALLED_MANIFEST" ]; then
      mkdir -p "$BACKUP_DIR" && cp "$INSTALLED_MANIFEST" "$MANIFEST_COPY"
      cp "$PACKAGES_BEFORE" "${BACKUP_DIR}/packages-before.txt" 2>/dev/null
    fi
    sudo rm -rf "$SYS_DIR"
  else
    message warn "Keeping ${SYS_DIR}: system work is unfinished. Run this again to finish it."
  fi
fi

[ "$USER_PENDING" -eq 1 ] && [ -d "$BACKUP_DIR" ] \
  && message warn "Keeping ${BACKUP_DIR}: run 'bash ubuntu-look.sh --uninstall' again from your desktop to reset your settings."

if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for the system changes above."
  [ "$USER_PENDING" -eq 0 ] \
    && echo -e "   The reboot also applies your restored settings; no separate log out is needed."
  echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
elif [ "${#DONE[@]}" -gt 0 ] && [ "$USER_PENDING" -eq 0 ]; then
  echo -e "${YELLOW}Log out and back in for all changes to take effect.${ENDCOLOR}"
elif [ "${#DONE[@]}" -gt 0 ]; then
  echo -e "${YELLOW}Log out and back in for the changes so far to take effect.${ENDCOLOR}"
fi
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
exit $((USER_PENDING || SYSTEM_PENDING || _anim_failed || INITRAMFS_PARTIAL))
fi

###############################################################################
# 9. Install
###############################################################################

if in_word_list --prepare-upgrade "$arguments"; then
  [ "$MODE" = online ] || error "--prepare-upgrade takes no mode flag."
  case "$arguments" in
    --prepare-upgrade) ;;
    *) error "--prepare-upgrade takes no other arguments (got '${arguments}')." ;;
  esac
  prepare_debian_upgrade
  exit 0
fi

[ -z "$arguments" ] || error "Unknown argument '${arguments}'. See: bash ubuntu-look.sh --help"

[ "$MODE" = download ] && download_mode
# Check the bundle before changing anything.
[ "$MODE" = offline ] && load_bundle

if [ "$REFRESH" = 1 ]; then
  # Only a look this user installed has updates.
  if [ ! -f "$PACKAGES_BEFORE" ] || [ ! -d "$BACKUP_ORIGINAL" ] \
     || ! grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null; then
    error "The Ubuntu look is not installed for ${RUN_USER}. Install it with: bash ubuntu-look.sh"
  fi
  if ! grep -q '^# pin-version: ' "$UBUNTU_PIN" 2>/dev/null; then
    error "The look is prepared for a Debian upgrade (or its pin is missing). Set it up again with: bash ubuntu-look.sh"
  fi
  [ -z "$(missing_packages "curl ca-certificates")" ] \
    || error "curl or ca-certificates is missing; run 'bash ubuntu-look.sh' to install them with the look."
  message "Checking the Ubuntu look for updates. Nothing is changed without your yes."
  sudo -v || error "User ${RUN_USER} cannot use sudo."
  take_run_lock
  discover_releases "$UBUNTU_CODENAME"
  # Lists the updates and asks; returns only to apply them.
  refresh_check
else
  message "${GREEN}ubuntu-look${ENDCOLOR}: makes Debian GNOME look and behave like Ubuntu."
  message ""
  message "Applies the Ubuntu look for user ${YELLOW}${RUN_USER}${ENDCOLOR}."
  [ "$MODE" = offline ] && message "Offline: packages come from ${YELLOW}${PACKAGES_DIR}${ENDCOLOR} (Ubuntu ${UBUNTU_CODENAME})."
  if [ -d "$BACKUP_ORIGINAL" ] && [ ! -f "$DEFAULTS_PENDING" ]; then
    message "Re-run: your own theme, wallpaper, dock and other settings are kept."
  else
    message "First install: Ubuntu's defaults replace your theme, wallpaper, dock and other"
    message "settings, as on a fresh Ubuntu. Your dock favourites are kept."
  fi
  message "Safe to re-run. Undo with: bash ubuntu-look.sh --uninstall"
  message ""
  confirm_continue
  sudo -v || error "User ${RUN_USER} cannot use sudo."
  take_run_lock
fi
# From here on the run changes the system; the summary reports it.
RUN_STARTED=1

# Per-user snapshot, taken once.
if [ ! -d "$BACKUP_ORIGINAL" ]; then
  message "first run for ${RUN_USER} — saving your settings to ${BACKUP_ORIGINAL} (for the uninstall)"
  # Made in a side directory and moved into place whole, so a cut run leaves
  # either no snapshot or a complete one.
  _snap="${BACKUP_ORIGINAL}.new"
  rm -rf "$_snap"
  mkdir -p "$_snap" || error "Could not create ${_snap}"
  # Ubuntu's defaults need a desktop session, now or on a later run.
  : > "${_snap}/${DEFAULTS_PENDING##*/}"
  # dconf reads the database file itself; no session is needed. A failed
  # dump leaves none, which a later run takes again.
  if command -v dconf >/dev/null 2>&1; then
    user_dconf dump / > "${_snap}/dconf-dump.ini" || rm -f "${_snap}/dconf-dump.ini"
  fi
  echo "ubuntu-look.sh pre-install snapshot — $(date -Iseconds)" > "${_snap}/INFO"
  mv "$_snap" "$BACKUP_ORIGINAL" || error "Could not create ${BACKUP_ORIGINAL}"
  STATUS_CHANGES+=("Your pre-install settings saved → ${BACKUP_ORIGINAL}")
else
  STATUS_NOCHANGE+=("Your pre-install settings snapshot already exists")
fi

# System snapshot, taken once.
record_packages_before

# Users with the look; system changes are undone when the last one uninstalls.
grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null || sys_record_append "$SYS_USERS" "$RUN_USER" \
  || error "Could not record ${RUN_USER} in ${SYS_USERS}; nothing was installed. Run this again."
# An unfinished uninstall's snapshot and hand-over copies no longer apply.
[ -e "$UNINSTALL_SNAPSHOT" ] && sudo rm -f "$UNINSTALL_SNAPSHOT"
rm -f "${BACKUP_DIR}/packages-before.txt" "$MANIFEST_COPY" "$DCONF_PROFILE_COPY"

if [ "$MODE" = offline ]; then
  prepare_offline
else

step "Configure the Ubuntu apt source"

# curl reads the archive; generic tools, so not recorded.
install_prereqs "$(missing_packages "curl ca-certificates")"

# Read every run so a new release is found at once; --refresh already has.
[ "$REFRESH" = 1 ] || discover_releases "$UBUNTU_CODENAME"
message "Ubuntu releases in play (oldest to newest): ${GREEN}${UBUNTU_CANDIDATE_CODENAMES}${ENDCOLOR}"

# Nothing changed since the last install run: the sources are not widened.
# --refresh has checked this already; its answer is reused.
KEEP_SOURCES=0
if [ "$UBUNTU_CODENAME" = auto ] \
   && if [ "$REFRESH" = 1 ]; then [ "$REFRESH_UNCHANGED" = 1 ]; else unchanged_since_last_run; fi; then
  KEEP_SOURCES=1
  UBUNTU_CODENAME="$KEPT_CODENAME"
  # A looked-back release stays in the list's header.
  in_word_list "$UBUNTU_CODENAME" "$UBUNTU_CANDIDATE_CODENAMES" \
    || UBUNTU_CANDIDATE_CODENAMES="$UBUNTU_CODENAME $UBUNTU_CANDIDATE_CODENAMES"
  message "no new Ubuntu release, no Debian or GNOME Shell change — keeping ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} without fetching the other releases"
fi
# A fixed release is configured alone; auto chooses among the candidates.
UBUNTU_SOURCE_LIST="$UBUNTU_CANDIDATE_CODENAMES"
[ "$UBUNTU_CODENAME" = auto ] || UBUNTU_SOURCE_LIST="$UBUNTU_CODENAME"

ensure_ubuntu_keyring

# Block every Ubuntu package until the full pin is written.
PROVISIONAL_PIN_NEW=0
write_provisional_pin
case $? in
  0) PROVISIONAL_PIN_NEW=1
     message "Ubuntu packages blocked by default until the Ubuntu pin is written" ;;
  2) error "Could not write ${UBUNTU_PIN}; the apt source was not changed." ;;
esac

# Saved so a failing apt source can be put back.
# An empty copy means there was none; a source that cannot be copied stops the run.
PREV_UBUNTU_SOURCES="$(mktemp)"
if [ -e "$UBUNTU_SOURCES" ]; then
  if ! cp "$UBUNTU_SOURCES" "$PREV_UBUNTU_SOURCES"; then
    # Nothing changed yet: the exit trap must not restore from the empty copy.
    rm -f "$PREV_UBUNTU_SOURCES"; PREV_UBUNTU_SOURCES=""
    [ "$PROVISIONAL_PIN_NEW" = 1 ] && sudo rm -f "$UBUNTU_PIN"
    error "Could not save a copy of ${UBUNTU_SOURCES}; the apt source was not changed."
  fi
fi
# Only a net change of the list is reported.
INITIAL_UBUNTU_SOURCES="$(cat "$UBUNTU_SOURCES" 2>/dev/null)"
PINNED_BEFORE="$(pinned_codename)"

# 1 = the apt source is as it was.
_src_rc=1
if [ "$KEEP_SOURCES" = 1 ]; then
  message "Ubuntu sources not widened: $(configured_codenames | xargs)"
else
  # shellcheck disable=SC2086
  write_ubuntu_sources $UBUNTU_SOURCE_LIST
  _src_rc=$?
  case $_src_rc in
    0) message "configuring Ubuntu archive sources: ${UBUNTU_SOURCE_LIST}" ;;
    1) message "Ubuntu candidate sources already current" ;;
    2) message warn "no Ubuntu archive answered — the apt source is left as it was" ;;
    *) message warn "could not write ${UBUNTU_SOURCES} — the apt source is left as it was" ;;
  esac
fi

step "Refresh package lists"
# A failing Ubuntu source would break every apt update. --refresh has just
# refreshed them; with the sources unchanged that stands.
if [ "$REFRESH" = 1 ] && [ "$_src_rc" -eq 1 ] && [ "$APT_LISTS_FRESH" = 1 ]; then
  message "package lists refreshed a moment ago"
  _upd=0
else
  apt_update
  _upd=$?
fi
case $_upd in
  0) ;;
  3) restore_prev_ubuntu_sources
     error "apt is in use by another program — the sources were put back as they were; try again later." ;;
  *) restore_prev_ubuntu_sources
     error "apt update failed for the Ubuntu sources — they were put back as they were." ;;
esac
if ! ubuntu_index_has_packages; then
  restore_prev_ubuntu_sources
  error "${UBUNTU_MIRROR} serves no Ubuntu packages for ${UBUNTU_ARCH} — the sources were put back as they were."
fi

step "Resolve the Ubuntu release"

[ "$UBUNTU_CODENAME" = "auto" ] && resolve_release "$PINNED_BEFORE"

# Rewrite a missing, provisional, outdated or other-release pin.
NEED_PIN_REWRITE=1
if [ ! -f "$UBUNTU_PIN" ] || grep -q '^# provisional' "$UBUNTU_PIN"; then
  :
elif ! pin_is_current; then
  message warn "Ubuntu pin is out of date — rewriting"
elif ! grep -q "n=${UBUNTU_CODENAME}\$" "$UBUNTU_PIN"; then
  message warn "Ubuntu release changed to ${UBUNTU_CODENAME} — rewriting the Ubuntu pin"
else
  NEED_PIN_REWRITE=0
fi
if [ "$NEED_PIN_REWRITE" = 1 ]; then
  # On failure the exit puts the apt source back, and the pin is left whole.
  write_ubuntu_pin
  [ $? -eq 2 ] && error "Could not write ${UBUNTU_PIN}; the apt source and pin are left as they were. Run this again."
  STATUS_CHANGES+=("Ubuntu pin applied (${UBUNTU_CODENAME})")
else
  message "Ubuntu pin already current (${UBUNTU_CODENAME})"
  STATUS_NOCHANGE+=("Ubuntu pin already current")
fi
# The source and pin now agree; the saved source is no longer needed.
rm -f "$PREV_UBUNTU_SOURCES"

# Only the pinned release stays configured.
narrow_ubuntu_sources
# The apt files a killed --download saved; the sources and pin above replace them.
[ ! -e "$DOWNLOAD_SAVED" ] || sudo rm -rf "$DOWNLOAD_SAVED"

fi

step "System upgrade (only with UBUNTU_LOOK_SYSTEM_UPGRADE=1)"
if [ "${UBUNTU_LOOK_SYSTEM_UPGRADE:-0}" = "1" ]; then
  _sim="$(LC_ALL=C apt-get -s upgrade --with-new-pkgs "${APT_OPTS[@]}" 2>/dev/null)"
  upgradable_before="$(printf '%s\n' "$_sim" | grep -c '^Inst ')"
  if [ "$upgradable_before" -gt 0 ]; then
    message warn "UBUNTU_LOOK_SYSTEM_UPGRADE=1 — upgrading ${upgradable_before} package(s) system-wide"
    # The pinned packages it moves to Ubuntu's builds are recorded first, as in
    # the stages, so the uninstall puts back what they replace.
    _sim="$(printf '%s\n' "$_sim" \
      | awk -v l=" ${UBUNTU_PINNED_PACKAGES} ubuntu-wallpapers-${UBUNTU_CODENAME} " '/^Inst / && index(l, " " $2 " ")')"
    _rec_ok=1
    record_planned_installs "$_sim" || _rec_ok=0
    while read -r _p _was; do
      record_upgraded_pkg "$_p" "$_was" || _rec_ok=0
    done < <(printf '%s\n' "$_sim" | awk '$3 ~ /^\[/ { gsub(/[][]/, "", $3); print $2, $3 }')
    # Not fatal: a held package or third-party repository must not stop the look.
    if [ "$_rec_ok" = 0 ]; then
      message warn "could not write the install records — system upgrade skipped"
      STATUS_FAILED+=("system upgrade (the install records could not be written)")
    elif sudo apt-get upgrade -y --with-new-pkgs "${APT_OPTS[@]}"; then
      STATUS_CHANGES+=("Upgraded ${upgradable_before} package(s) system-wide")
      RELOGIN_NEEDED=1
    else
      message warn "apt upgrade failed — continuing; the theming steps do not depend on it"
      STATUS_FAILED+=("system upgrade (apt-get upgrade returned an error)")
    fi
  else
    message "nothing to upgrade"
    STATUS_NOCHANGE+=("apt upgrade: nothing to upgrade")
  fi
else
  message "leaving the rest of the system to your own 'apt upgrade'"
  message "  this script upgrades only the look's packages"
  STATUS_NOCHANGE+=("System-wide apt upgrade skipped (UBUNTU_LOOK_SYSTEM_UPGRADE=1 to enable)")
fi
# The upgrade may have moved gnome-shell to a new major version; the release
# was resolved for the old one, so its state is not saved and the next run
# resolves it again.
_shell_before="$SHELL_MAJOR_CACHE"
SHELL_MAJOR_CACHE=""
shell_major > /dev/null
_shell_moved=0
if [ "$_shell_before" != "$SHELL_MAJOR_CACHE" ]; then
  _shell_moved=1
  STATUS_FAILED+=("GNOME Shell moved from ${_shell_before:-?} to ${SHELL_MAJOR_CACHE:-?} during the system upgrade — reboot, then run this script again")
fi

use_combined_extensions_if_offered

# Installed look packages onto the pinned release first, so the stages
# configure the builds that stay (fonts-ubuntu decides the font names).
align_look_packages

for category in $(printf '%s\n' "${!packages[@]}" | sort); do
  step "Install + configure: ${category}"

  available="$(available_packages "${packages[$category]}")"
  for p in ${packages[$category]}; do
    in_word_list "$p" "$available" && continue
    if [ "$MODE" = offline ]; then
      STATUS_UNAVAIL+=("$p")
      message warn "${p} is not in the bundle — skipped"
    else
      STATUS_FAILED+=("$p (not offered by any configured repository)")
      message warn "${p} is not available from any configured repository — skipped"
    fi
  done

  # Split into installs and upgrades.
  declare -A PKG_BEFORE=()
  to_install=""
  to_upgrade=""
  for p in $available; do
    _have="$(pkg_installed_version "$p")"
    _cand="$(pkg_candidate_version "$p")"
    PKG_BEFORE[$p]="$_have"
    if [ -z "$_have" ]; then
      to_install="$to_install $p"
    elif is_held "$p"; then
      STATUS_ALREADY+=("$p (${_have}, held by you)")
    elif [ -n "$_cand" ] && dpkg --compare-versions "$_cand" gt "$_have" \
         && { ! predates_install "$p" || in_word_list "$p" "$LOOK_PACKAGES"; }; then
      to_upgrade="$to_upgrade $p"
    else
      STATUS_ALREADY+=("$p (${_have})")
    fi
  done
  to_install="$(echo "$to_install" | xargs)"
  to_upgrade="$(echo "$to_upgrade" | xargs)"
  to_change="$(echo "$to_install $to_upgrade" | xargs)"

  if [ -z "$to_change" ]; then
    message "everything in ${category} is installed and current"
  else
    [ -n "$to_install" ] && message "installing: ${GREEN}${to_install}${ENDCOLOR}"
    [ -n "$to_upgrade" ] && message "newer build available for: ${GREEN}${to_upgrade}${ENDCOLOR}"

    # Record replaced builds before apt runs; without the records nothing runs.
    _rec_ok=1
    for p in $to_upgrade; do record_upgraded_pkg "$p" "${PKG_BEFORE[$p]:-}" || _rec_ok=0; done
    [ "$_rec_ok" = 1 ] \
      || error "could not write the look's records in ${SYS_RECORDS} — nothing more is changed; run this again."

    # Simulated first; a batch that would remove something is never run.
    # shellcheck disable=SC2086
    apt_install_checked $to_change
    case $? in
      1) if [ -n "$REMOVES" ]; then
           message warn "installing this stage as one batch would REMOVE: ${REMOVES}"
           message warn "not doing that — falling back to one package at a time"
         else
           message warn "apt cannot resolve this stage as one batch — going package by package"
         fi ;;
      2) message warn "batch install failed — retrying one package at a time" ;;
      3) error "could not write the look's records in ${SYS_RECORDS} — nothing more is changed; run this again." ;;
    esac

    # Whatever the batch did not change gets the newest version that installs
    # without removals.
    _installed_any=0
    for p in $to_change; do
      _before="${PKG_BEFORE[$p]:-}"
      _now="$(pkg_installed_version "$p")"
      if [ -z "$_now" ] || [ "$_now" = "$_before" ]; then
        ensure_package "$p"; _rc=$?
        _now="$ENSURE_VERSION"
        if [ "$_rc" -eq 2 ]; then
          STATUS_HELD+=("$p at ${_now} — $(explain_blocked "$p")")
          message warn "${p} stays at ${_now}: no newer build fits this system"
          continue
        elif [ "$_rc" -ne 0 ]; then
          STATUS_FAILED+=("$p — $(explain_blocked "$p")")
          message warn "${p} cannot be installed on this system — skipped, nothing was touched"
          continue
        fi
      fi
      if [ -z "$_before" ]; then
        STATUS_INSTALLED+=("$p (${_now})")
      else
        STATUS_UPGRADED+=("$p (${_before} → ${_now})")
      fi
      _installed_any=1
    done
    [ $_installed_any -eq 1 ] && RELOGIN_NEEDED=1
  fi

  case $category in
    0-base)
      # Taking the splash off works from the records, with or without GRUB.
      if [ "$UBUNTU_BOOT_SPLASH" = "0" ]; then
        boot_splash unset
      elif ! has_boot_splash_tools; then
        STATUS_NOCHANGE+=("No GRUB or update-initramfs on this system — boot splash left alone")
      else
        boot_splash set
      fi
      ;;

    2-desktop-gnome)
      # Ubuntu's default wallpaper; the file names are the same in every release.
      WP_LIGHT=/usr/share/backgrounds/warty-final-ubuntu.png
      WP_DARK=/usr/share/backgrounds/ubuntu-wallpaper-d.png

      # The user's own animation switch, whatever else this stage does.
      _anim="$(apply_animation_option)"
      case $? in
        0) STATUS_CHANGES+=("$_anim") ;;
        1) STATUS_NOCHANGE+=("$_anim") ;;
        2) STATUS_FAILED+=("$_anim") ;;
      esac

      # Settings naming Yaru without its themes would leave apps without icons.
      _missing=""
      for p in $YARU_PKGS; do is_installed "$p" || _missing="${_missing} ${p}"; done
      if [ -n "$_missing" ]; then
        message warn "Yaru is not installed (${_missing# }) — Ubuntu's settings are not written"
        STATUS_FAILED+=("Ubuntu's settings, extensions and login screen not applied — missing:${_missing}")
        _env_rc=2
        continue
      fi

      # System defaults, read at the next login.
      message "writing Ubuntu's GNOME defaults"
      write_dconf_profile "$WP_LIGHT" "$WP_DARK"
      _profile_ok=$?
      install_theme_extension
      install_login_helper
      case $? in
        0) STATUS_CHANGES+=("Login helper for the look's extensions → ${LOGIN_HELPER_ENTRY}") ;;
        2) STATUS_FAILED+=("Could not write the login helper (${LOGIN_HELPER}) — extensions a later release adds reach other users only when they run this script") ;;
      esac

      # From the next login on; only with a usable profile, else dconf has no database.
      _env_rc=2
      if [ "$_profile_ok" -eq 0 ]; then
        enable_look_for_user
        _env_rc=$?
        case $_env_rc in
          0) STATUS_CHANGES+=("The look is enabled for ${RUN_USER} → ${LOOK_ENV_FILE} (from the next login)")
             RELOGIN_NEEDED=1 ;;
          2) STATUS_FAILED+=("${LOOK_ENV_FILE} could not be written — your sessions keep Debian's defaults") ;;
        esac
        export DCONF_PROFILE="$LOOK_PROFILE_NAME"
        # environment.d is read only when the user manager starts; a quick
        # log out and in keeps the manager, so it is told as well.
        [ "$_env_rc" -ne 2 ] \
          && { systemctl --user set-environment DCONF_PROFILE="$LOOK_PROFILE_NAME" 2>/dev/null || true; }
      fi

      _fresh_defaults=0
      # A first run without dconf-cli takes the snapshot now that the stages
      # brought it, before the look changes any setting; dconf dump needs no
      # session.
      if [ -f "$DEFAULTS_PENDING" ] && [ ! -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ] \
         && command -v dconf >/dev/null 2>&1; then
        user_dconf dump / > "${BACKUP_ORIGINAL}/.dconf-dump.ini" \
          && mv "${BACKUP_ORIGINAL}/.dconf-dump.ini" "${BACKUP_ORIGINAL}/dconf-dump.ini"
        rm -f "${BACKUP_ORIGINAL}/.dconf-dump.ini"
      fi
      # Without the profile in the user's sessions, clearing their values
      # would leave Debian's defaults, not Ubuntu's: nothing more changes.
      if [ "$_env_rc" -eq 2 ]; then
        message warn "the look is not enabled for your sessions — your settings, extensions, terminal and icons are left as they are"
        STATUS_FAILED+=("Ubuntu's defaults and the look's extensions not applied — run this script again")
      elif [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        turn_off_dash_to_dock
        message "your session bus is available — settings written now; new extensions and the shell theme load at the next login"

        # Fresh install: Ubuntu's defaults. Later runs keep the user's own values
        # and hand the rest back to the profile once the session reads it.
        if [ -f "$DEFAULTS_PENDING" ]; then
          apply_ubuntu_defaults && _fresh_defaults=1
        elif [ -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ]; then
          if session_on_look_profile; then
            reclaim_live_settings
          else
            STATUS_NOCHANGE+=("Your own copies of Ubuntu's settings are handed back on the next run after you log in again")
          fi
        fi

        # Restart the tiling assistant when mutter's own tiling came back on
        # beside it. Its lists are kept on file first, so a restart cut short
        # is finished by the next run.
        _tiling_note="${BACKUP_DIR}/tiling-restart"
        if [ -f "$_tiling_note" ] \
           || { extension_active tiling-assistant@ubuntu.com \
                && [ "$(gsettings get org.gnome.mutter edge-tiling 2>/dev/null)" = true ]; }; then
          if [ ! -f "$_tiling_note" ]; then
            mkdir -p "$BACKUP_DIR" && {
              printf 'enabled-extensions:%s\n' "$(user_dconf_read /org/gnome/shell/enabled-extensions)"
              printf 'disabled-extensions:%s\n' "$(user_dconf_read /org/gnome/shell/disabled-extensions)"
            } > "$_tiling_note"
          fi
          gnome-extensions disable tiling-assistant@ubuntu.com 2>/dev/null
          gnome-extensions enable tiling-assistant@ubuntu.com 2>/dev/null \
            && STATUS_CHANGES+=("Tiling assistant restarted — mutter's own tiling had come back on beside it")
          # The restart rewrote both lists; they are put back as they were.
          while IFS= read -r _k; do
            if [ -n "${_k#*:}" ]; then dconf write "/org/gnome/shell/${_k%%:*}" "${_k#*:}" 2>/dev/null
            else dconf reset "/org/gnome/shell/${_k%%:*}" 2>/dev/null; fi
          done < "$_tiling_note"
          rm -f "$_tiling_note"
        fi

        # Only extensions not switched on for this user before, in one write to
        # the user database, which the running shell follows.
        EXT_TODO="$(extensions_to_switch_on all)"
        EXT_ON_BEFORE="$(user_dconf_read /org/gnome/shell/enabled-extensions)"
        # shellcheck disable=SC2086
        enable_shell_extensions $EXT_TODO
        dash_to_dock_status $?

        # Verify in the user database; the shell lists new packages only after re-login.
        ENABLED_NOW="$(user_dconf_read /org/gnome/shell/enabled-extensions)"
        # Still on the disabled list, an extension stays off however it is listed.
        DISABLED_NOW="$(user_dconf_read /org/gnome/shell/disabled-extensions)"
        EXT_FAILED_NOW=0; EXT_SWITCHED_ON=""; EXT_TOOK=""
        for ext in $EXT_TODO; do
          case "$DISABLED_NOW" in *"'${ext}'"*) ENABLED_NOW_EXT="" ;; *) ENABLED_NOW_EXT="$ENABLED_NOW" ;; esac
          case "$ENABLED_NOW_EXT" in
            *"'${ext}'"*) EXT_TOOK+=" ${ext}"
                          case "$EXT_ON_BEFORE" in
                            *"'${ext}'"*) ;;
                            *) extension_installed "$ext" \
                                 && EXT_SWITCHED_ON+=" ${ext}" ;;
                          esac ;;
            *) EXT_FAILED_NOW=1
               message warn "the enabled-extensions setting did not take for ${ext}"
               STATUS_EXT_FAILED+=("${ext}")
               RELOGIN_NEEDED=1 ;;
          esac
        done
        # Switched off, extensions do not run however they are listed. Ubuntu's
        # own run regardless; here they are user extensions, so it is reported.
        if [ "$(dconf read /org/gnome/shell/disable-user-extensions 2>/dev/null)" = true ]; then
          message warn "extensions are switched off for you — the dock, tiling assistant and shell theme do not run"
          STATUS_NOCHANGE+=("Extensions are switched off for you (the Extensions app's main switch; GNOME also turns it off after a crash) — to turn them on: gsettings set org.gnome.shell disable-user-extensions false")
        fi
        # One append for all that took; install_extension_autostart reads EXT_RECORDED.
        # shellcheck disable=SC2086
        [ -n "$EXT_TOOK" ] && { record_extensions_on $EXT_TOOK; EXT_RECORDED=1; }
        if [ -n "$EXT_SWITCHED_ON" ]; then
          STATUS_CHANGES+=("Extensions switched on:${EXT_SWITCHED_ON}")
        elif [ "$EXT_RECORDED" = 1 ] && [ "$EXT_FAILED_NOW" = 0 ]; then
          STATUS_NOCHANGE+=("The look's extensions are on — any you turn off later stay off")
        fi
      else
        turn_off_dash_to_dock
        message warn "No D-Bus session detected — the look applies from your next login; run this again from the desktop for Ubuntu's defaults and the terminal profile."
        [ -f "$DEFAULTS_PENDING" ] \
          && STATUS_FAILED+=("Ubuntu's defaults are not applied yet — run this script again from your desktop session")
      fi

      # The rest of the user's look, only where the look is enabled for them.
      if [ "$_env_rc" -ne 2 ]; then
        message "applying Ubuntu's terminal colours"
        install_terminal_profile
        # Per-user settings, written like the terminal profile only in a session.
        if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
          install_terminal_shortcut
          install_subpixel_rendering
        fi

        message "setting the Show Applications button icon"
        install_app_grid_icon
      fi

      message "theming the login screen"
      write_gdm_profile "$WP_LIGHT" "$WP_DARK"
      ;;
  esac
done

# Not when the look could not be enabled for the user's sessions, or Yaru is missing.
[ "${_env_rc:-0}" -eq 2 ] || install_extension_autostart

remove_unused_wallpaper_packs
# Failed installs leave the manifest; replaced packages installed again leave
# their record.
# A package apt removed but did not purge (its configuration files left)
# stays on record, so the uninstall purges it.
prune_record "$INSTALLED_MANIFEST" is_present_or_configured
prune_record "$REPLACED_BY_COMBINED" not_installed
if [ "$MODE" = offline ]; then
  cache_replaced_debs
  narrow_without_archive
fi

# Report anything that no longer matches the installed gnome-shell.
check_shell_coupling_drift

# The run records its options and what it was resolved against.
# Packages prepare-upgrade removed and this run could not restore stay recorded.
prune_record "$REMOVED_FOR_UPGRADE" not_restored
save_options
[ "$MODE" = online ] && [ "$_shell_moved" = 0 ] && save_release_state

[ "$INITRAMFS_PARTIAL" = 1 ] && STATUS_FAILED+=("$INITRAMFS_PARTIAL_NOTE")
message "${GREEN}All steps finished. See SUMMARY below.${ENDCOLOR}"
RUN_FINISHED=1
# A step not done makes the exit status 1, as in the uninstall.
[ $(( ${#STATUS_FAILED[@]} + ${#STATUS_EXT_FAILED[@]} + ${#STATUS_UNAVAIL[@]} )) -eq 0 ] || exit 1
