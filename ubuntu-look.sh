#!/bin/bash
# =============================================================================
# Title       : ubuntu-look.sh
# Description : Applies the Ubuntu desktop look to Debian GNOME: Yaru themes,
#               Ubuntu fonts and wallpapers, Ubuntu Dock, tiling assistant,
#               app indicators, desktop icons, terminal colours, login screen,
#               boot splash and Ubuntu's GNOME defaults. The packages come from
#               the newest Ubuntu release that fits the installed gnome-shell.
#
# Original    : DeltaLima
#               https://github.com/DeltaLima/make-debian-look-like-ubuntu
#
# Usage       : bash ubuntu-look.sh                   full run
#               bash ubuntu-look.sh <stage>...        only these stages:
#                                                     0-base 1-desktop-base 2-desktop-gnome
#               bash ubuntu-look.sh --download        build or refresh packages/ for an
#                                                     offline install (needs internet)
#               bash ubuntu-look.sh --offline         install from packages/, no network
#               bash ubuntu-look.sh --uninstall       undo it, from your desktop session
#               bash ubuntu-look.sh --prepare-upgrade before a Debian release upgrade
#               bash ubuntu-look.sh --help            this text
#               Safe to re-run.
#
# Options     : UBUNTU_CODENAME=<name>      use this Ubuntu release
#               UBUNTU_INCLUDE_DEVEL=1      allow the unreleased series
#               UBUNTU_MIRROR=<url>         Ubuntu mirror (default per architecture)
#               UBUNTU_BOOT_SPLASH=0        no boot splash (removes one applied)
#               PLYMOUTH_THEME=<name>       boot splash theme (default bgrt)
#               UBUNTU_LOOK_AUTO_REFRESH=1  daily refresh timer (off by default)
#               UBUNTU_LOOK_SYSTEM_UPGRADE=1  also run a system-wide apt upgrade
#               UBUNTU_LOOK_FORCE_BUNDLE=1  accept a bundle built for another Debian
#                                           release or gnome-shell major
#               UBUNTU_LOOK_LOG=0           no run log
#               A full online run saves the first six (--offline only the
#               boot ones); later runs and the timer reuse them unless given
#               again (e.g. UBUNTU_CODENAME=auto).
#
# Offline     : Run --download on an online machine with the same Debian
#               release, architecture and gnome-shell major; copy this script
#               and packages/ to the target; run --offline there.
#
# Refresh     : With UBUNTU_LOOK_AUTO_REFRESH=1, a full online run installs
#               ubuntu-look-refresh.timer. Daily, it re-runs the system part
#               (--refresh, as root) after a new or retired Ubuntu release, or a
#               change of Debian release, gnome-shell major, architecture,
#               mirror or saved options.
#
# Undo        : bash ubuntu-look.sh --uninstall. Each user undoes their own
#               settings; the last one also undoes the system changes.
#
# Requires    : Debian with GNOME, sudo rights; internet access except --offline.
# =============================================================================

# In --refresh mode sudo and apt-get are shell functions; this is intended.
# shellcheck disable=SC2033

# Contents
#   1. Helpers      messages, records, options, dconf values
#   2. Packages     apt, the Ubuntu release, sources and pin
#   3. Desktop      Ubuntu's settings, extensions, terminal, login screen
#   4. Boot         GRUB command line and boot splash
#   5. Records      migration, daily refresh, summary
#   6. Offline      --download, --offline, --prepare-upgrade
#   7. Setup        help, run log, mode, options, variables
#   8. Uninstall    --uninstall
#   9. Install      the install itself

###############################################################################
# 1. Helpers: messages, records, options, dconf values
###############################################################################

sys_records_dir() { sudo install -d -m 0755 "$SYS_DIR" "$SYS_RECORDS"; }

# Write text $2 as record $1.
sys_record_write() {
  sys_records_dir
  printf '%s\n' "$2" | sudo tee "$1" > /dev/null
}

# Append line $2 to record $1.
sys_record_append() {
  sys_records_dir
  printf '%s\n' "$2" | sudo tee -a "$1" > /dev/null
}

# Sort record $1 and drop duplicate lines.
sys_record_sort() {
  [ ! -f "$1" ] || sudo sort -u -o "$1" "$1"
}

# Install $1 as system record $2, then delete the home record $3.
move_to_sys_record() {
  sys_records_dir; sudo install -m 0644 "$1" "$2" && rm -f "$3"
}

# Set each saved option not given in the environment. The file is parsed,
# never sourced; unsafe values are ignored.
load_saved_options() {
  local key val optin=0
  readable_regular_file "$SAVED_OPTIONS" || return 0
  # The timer was on by default before; such a saved value is not a choice.
  grep -qxF "$REFRESH_OPT_IN_MARK" "$SAVED_OPTIONS" && optin=1
  while IFS='=' read -r key val; do
    [ "$key" = UBUNTU_LOOK_AUTO_REFRESH ] && [ "$optin" -eq 0 ] && continue
    in_word_list "$key" "$SAVED_OPTION_NAMES" && [ -z "${!key+x}" ] || continue
    case "$val" in *[[:space:][:cntrl:]\"\'\`\$\\]*) continue ;; esac
    printf -v "$key" '%s' "$val"
  done < "$SAVED_OPTIONS"
}

# Add mirror $1 to UBUNTU_HOSTS_RE by its full URL, unless it is an ubuntu.com host.
add_mirror_to_hosts_re() {
  [[ "$1/" =~ $UBUNTU_COM_RE ]] && return 0
  UBUNTU_HOSTS_RE="${UBUNTU_HOSTS_RE}|^$(printf '%s' "$1" | sed 's/[.+?*()|{}$]/[&]/g') "
}

# message [warn|error|info] <text>
message() {
  local label="${GREEN}INFO${ENDCOLOR}"
  case $1 in
    warn)  label="${YELLOW}WARN${ENDCOLOR}"; shift ;;
    error) label="${RED}ERROR${ENDCOLOR}"; shift ;;
    info)  shift ;;
  esac
  echo -e "[${label}] $*"
}

error() { message error "$@"; exit 1; }

# Returns 1 unless the answer is yes.
ask_yes() {
  message warn "Type '${GREEN}y${ENDCOLOR}' or '${GREEN}yes${ENDCOLOR}' and hit [ENTER] to continue"
  local reply
  echo "[y/N?] "
  read -r reply
  [ "${reply,,}" = y ] || [ "${reply,,}" = yes ]
}

confirm_continue() { ask_yes || error "Aborted."; }

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Installed packages, sorted; removed-but-not-purged ones excluded.
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

# Major version of the running gnome-shell, e.g. "48".
shell_major() { gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1; }

# True when $1 is a readable regular file (a FIFO would block).
readable_regular_file() {
  [ -f "$1" ] && [ -r "$1" ]
}

# dconf on the user's own database only, without any system defaults; a
# plain dump or list also shows the system databases' keys.
user_dconf() {
  local prof rc
  prof="$(mktemp)" || return 1
  echo "user-db:user" > "$prof"
  DCONF_PROFILE="$prof" dconf "$@" 2>/dev/null
  rc=$?
  rm -f "$prof"
  return $rc
}

# The user's own value of dconf key $1.
user_dconf_read() { user_dconf read "$1"; }

# Over SSH or tmux, use the user's session bus when one is running.
adopt_session_bus() {
  local uid
  uid="$(id -u)"
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/${uid}/bus" ] || return 0
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${uid}}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus"
}

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${YELLOW}━━━ ${STEP}. $1${ENDCOLOR}"
}

# Save the options of this full run for the refresh timer.
save_options() {
  local tmp head="# Options of the last full run, reused by later runs and the refresh timer."
  tmp="$(mktemp)"
  if [ "$MODE" = offline ]; then
    # Only the boot options; the release options stay as last saved online.
    if readable_regular_file "$SAVED_OPTIONS"; then cat "$SAVED_OPTIONS" > "$tmp"
    else echo "$head" > "$tmp"; fi
    UBUNTU_BOOT_SPLASH="$UBUNTU_BOOT_SPLASH" PLYMOUTH_THEME="$PLYMOUTH_THEME" awk '
      function opt(k,  v) { v = ENVIRON[k]; return (v ~ /^[A-Za-z0-9._+-]*$/) ? k "=" v : "" }
      BEGIN { b = opt("UBUNTU_BOOT_SPLASH"); p = opt("PLYMOUTH_THEME") }
      /^UBUNTU_BOOT_SPLASH=/ { if (b != "" && !sb++) print b; else if (b == "") print; next }
      /^PLYMOUTH_THEME=/     { if (p != "" && !sp++) print p; else if (p == "") print; next }
      { print }
      END { if (b != "" && !sb) print b; if (p != "" && !sp) print p }
    ' "$tmp" > "${tmp}.new" && mv -f "${tmp}.new" "$tmp"
  else {
    echo "$head"
    echo "${REFRESH_OPT_IN_MARK}"
    echo "UBUNTU_CODENAME=${REQUESTED_CODENAME}"
    echo "UBUNTU_INCLUDE_DEVEL=${UBUNTU_INCLUDE_DEVEL}"
    echo "UBUNTU_MIRROR=${REQUESTED_MIRROR}"
    echo "UBUNTU_BOOT_SPLASH=${UBUNTU_BOOT_SPLASH}"
    echo "PLYMOUTH_THEME=${PLYMOUTH_THEME}"
    echo "UBUNTU_LOOK_AUTO_REFRESH=${UBUNTU_LOOK_AUTO_REFRESH:-0}"
  } > "$tmp"; fi
  if ! { readable_regular_file "$SAVED_OPTIONS" && cmp -s "$tmp" "$SAVED_OPTIONS"; }; then
    sys_records_dir
    sudo install -m 0644 "$tmp" "$SAVED_OPTIONS"
  fi
  rm -f "$tmp"
}

# $1 = wait: block until free. Returns 1 when another run holds the lock,
# 2 when the lock cannot be made.
take_run_lock() {
  # Anything but a root-owned regular file is replaced.
  if [ -L "$UBUNTU_LOOK_LOCK" ] || { [ -e "$UBUNTU_LOOK_LOCK" ] && { [ ! -f "$UBUNTU_LOOK_LOCK" ] \
       || [ "$(stat -c %u "$UBUNTU_LOOK_LOCK" 2>/dev/null)" != 0 ]; }; }; then
    sudo rm -f "$UBUNTU_LOOK_LOCK"
  fi
  # Created with noclobber, so two runs never make two lock files.
  [ -f "$UBUNTU_LOOK_LOCK" ] \
    || sudo sh -c 'umask 022; set -C; : > "$1"' _ "$UBUNTU_LOOK_LOCK" 2>/dev/null \
    || [ -f "$UBUNTU_LOOK_LOCK" ] || return 2
  # The braces keep the stderr redirect from outliving this line.
  { exec 9< "$UBUNTU_LOOK_LOCK"; } 2>/dev/null || return 2
  flock -n 9 && return 0
  [ "${1:-}" = wait ] || return 1
  message "another ubuntu-look run is in progress — waiting for it to finish"
  flock 9
}

debian_codename() { (. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}"); }

# Checksum of the Ubuntu pin and source list, to detect a change.
apt_config_sum() { cat "$UBUNTU_LIST" "$UBUNTU_PIN" 2>/dev/null | sha256sum; }

# Percent-encode a path for a file: URI in a sources.list line.
uri_path_encode() {
  local s="$1"
  s="${s//%/%25}"; s="${s// /%20}"; s="${s//$'\t'/%09}"
  s="${s//#/%23}"; s="${s//\[/%5B}"; s="${s//\]/%5D}"
  printf '%s' "$s"
}

###############################################################################
# 2. Packages: apt, the Ubuntu release, sources and pin
###############################################################################

# True when $1 was installed before this script first ran on this system.
predates_install() {
  grep -qxF "$1" "$PACKAGES_BEFORE" 2>/dev/null
}

# Record the packages apt simulation $1 newly installs, before installing, so
# an interrupted run leaves them on record.
record_planned_installs() {
  local p
  for p in $(printf '%s\n' "$1" | awk '/^Inst / && $3 !~ /^\[/ { print $2 }'); do
    grep -qxF "$p" "$INSTALLED_MANIFEST" 2>/dev/null && continue
    predates_install "$p" && continue
    sys_record_append "$INSTALLED_MANIFEST" "$p"
  done
  # Packages the combined package replaces, the user's included; the uninstall
  # restores them.
  for p in $(printf '%s\n' "$1" | awk '/^Remv /{ print $2 }'); do
    grep -qxF "$p" "$INSTALLED_MANIFEST" 2>/dev/null && continue
    grep -qxF "$p" "$REPLACED_BY_COMBINED" 2>/dev/null && continue
    sys_record_append "$REPLACED_BY_COMBINED" "$p"
    STATUS_CHANGES+=("${p} replaced by Ubuntu's ${COMBINED_EXT_PKG}, which carries it — the uninstall puts it back")
  done
}

# Use the combined extensions package where the pinned release offers it.
use_combined_extensions_if_offered() {
  local stage="2-desktop-gnome" p list="" cand
  cand="$(pkg_candidate_version "$COMBINED_EXT_PKG")"
  # Only the real package that carries the dock, not an older metapackage.
  if [ -n "$cand" ] && LC_ALL=C apt-cache "${APT_OPTS[@]}" show "${COMBINED_EXT_PKG}=${cand}" 2>/dev/null \
       | grep -q '^Provides:.*gnome-shell-extension-ubuntu-dock'; then
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

# Drop replaced packages that are installed again from the record.
prune_replaced_by_combined() {
  [ -f "$REPLACED_BY_COMBINED" ] || return 0
  local p keep=""
  while read -r p; do
    [ -n "$p" ] && ! is_installed "$p" && keep="${keep} ${p}"
  done < "$REPLACED_BY_COMBINED"
  if [ -z "$keep" ]; then
    sudo rm -f "$REPLACED_BY_COMBINED"
  else
    # shellcheck disable=SC2086
    sys_record_write "$REPLACED_BY_COMBINED" "$(printf '%s\n' $keep)"
  fi
}

# Drop manifest entries that are not installed (an install that failed).
prune_installed_manifest() {
  [ -f "$INSTALLED_MANIFEST" ] || return 0
  local p keep
  keep="$(while read -r p; do [ -n "$p" ] && is_installed "$p" && echo "$p"; done < "$INSTALLED_MANIFEST")"
  if [ "$keep" != "$(cat "$INSTALLED_MANIFEST")" ]; then
    sys_record_write "$INSTALLED_MANIFEST" "$(printf '%s\n' "$keep" | sed '/^$/d')"
  fi
}

# apt-get install with the new packages recorded first. $@ = install arguments.
apt_install_recorded() {
  local sim
  sim="$(LC_ALL=C apt-get -s install "${APT_OPTS[@]}" "$@" 2>&1)" && record_planned_installs "$sim"
  sudo apt-get install -y "${APT_OPTS[@]}" "$@"
}

# Keep only packages available in the apt cache.
available_packages() {
  local avail="" pkg
  for pkg in $1; do
    apt-cache "${APT_OPTS[@]}" show "$pkg" >/dev/null 2>&1 && avail="$avail $pkg"
  done
  echo "$avail" | xargs
}

# Installed version of $1, empty when not installed (as in is_installed).
pkg_installed_version() {
  is_installed "$1" && dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# apt's chosen version for $1; empty when the pin leaves no candidate.
pkg_candidate_version() {
  LC_ALL=C apt-cache "${APT_OPTS[@]}" policy "$1" 2>/dev/null \
    | awk '/^  Candidate:/ { if ($2 != "(none)") print $2; exit }'
}

# Every version of $1 the pin allows (priority 0 or more), newest first.
pkg_allowed_versions_desc() {
  LC_ALL=C apt-cache "${APT_OPTS[@]}" policy "$1" 2>/dev/null | awk '
    $1 == "***" && $3 ~ /^[0-9]+$/ { print $2; next }
    NF == 2 && $1 !~ /:$/ && $2 ~ /^[0-9]+$/ { print $1 }'
}

# Removals in apt simulation $1 other than ALLOWED_REMOVALS.
unexpected_removals() {
  printf '%s\n' "$1" | awk '/^Remv /{print $2}' \
    | grep -vxF -f <(printf '%s\n' $ALLOWED_REMOVALS) | xargs
}

installs_cleanly() {
  local sim
  sim="$(LC_ALL=C apt-get install -s "${APT_OPTS[@]}" "$@" 2>&1)" || return 1
  [ -z "$(unexpected_removals "$sim")" ]
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
      | grep -oE '(Pre)?Depends: [^ ]+ but it is not (installable|going to be installed)' \
      | awk '{print $2}' | sort -u); do
    if [ -z "$(pkg_candidate_version "$dep")" ] && apt-cache show "$dep" >/dev/null 2>&1; then
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
  local pkg="$1" have cand ver
  ENSURE_VERSION=""
  have="$(pkg_installed_version "$pkg")"
  cand="$(pkg_candidate_version "$pkg")"

  # Without a candidate the pin blocks every build; nothing to try.
  [ -n "$cand" ] && for ver in $(pkg_allowed_versions_desc "$pkg"); do
    dpkg --compare-versions "$ver" gt "$cand" && continue
    if [ -n "$have" ] && dpkg --compare-versions "$ver" le "$have"; then
      ENSURE_VERSION="$have"
      return 2
    fi
    if ! installs_cleanly "${pkg}=${ver}"; then
      REJECTED_BUILDS="${REJECTED_BUILDS} ${pkg}=${ver}"
      continue
    fi
    if apt_install_recorded "${pkg}=${ver}"; then
      ENSURE_VERSION="$ver"
      return 0
    fi
    APT_ERRORS=$((APT_ERRORS + 1))
    REJECTED_BUILDS="${REJECTED_BUILDS} ${pkg}=${ver}"
    message warn "${pkg}=${ver} would not install after all — trying an older build"
  done

  [ -n "$have" ] && { ENSURE_VERSION="$have"; return 2; }
  return 1
}

# One Ubuntu release as "<version> <state> <mirror>", also added to the
# release cache; non-zero when neither mirror publishes it. "devel" comes from
# Valid-Until.
ubuntu_release_info() {
  local cn="$1" mirror out
  for mirror in "$UBUNTU_MIRROR" "${UBUNTU_OLD_MIRROR:-}"; do
    [ -n "$mirror" ] || continue
    # A timeout is retried; a 404 is not.
    out="$(curl -fsSL --connect-timeout 5 -m 15 --retry 2 --retry-delay 2 -r 0-2047 \
             "${mirror}/dists/${cn}/Release" 2>/dev/null \
      | awk -v m="$mirror" '
          /^Version:/     { v = $2 }
          /^Valid-Until:/ { unreleased = 1 }
          END { if (v != "") print v, (unreleased ? "devel" : "stable"), m }')"
    if [ -n "$out" ]; then
      [ -n "${UBUNTU_RELEASE_CACHE:-}" ] && printf '%s %s\n' "$cn" "$out" >> "$UBUNTU_RELEASE_CACHE"
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

# True when suite $1 should be written for mirror $2. Only a 4xx reply means absent.
ubuntu_suite_published() {
  local code
  code="$(curl -fsSL -o /dev/null --connect-timeout 5 -m 15 -r 0-255 -w '%{http_code}' \
            "${2}/dists/${1}/Release" 2>/dev/null)"
  case "$code" in
    2*|3*) return 0 ;;
    4*)    return 1 ;;
    *)     message warn "could not check ${1} on ${2} — keeping it" >&2; return 0 ;;
  esac
}

# Mirror serving $1: from the run's cache, else probed live and cached.
ubuntu_mirror_for() {
  local cn="$1" hit info
  hit="$(awk -v c="$cn" '$1 == c { print $4; exit }' "$UBUNTU_RELEASE_CACHE" 2>/dev/null)"
  [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  info="$(ubuntu_release_info "$cn")" || return 1
  printf '%s' "${info##* }"
}

# Codenames listed in a mirror's dists/ directory.
list_dists() {
  curl -fsSL -m 30 "${1}/dists/" 2>/dev/null \
    | grep -oiE 'href="[^"?]+/"' \
    | sed -E 's|.*href="([^"]+)/"|\1|' \
    | grep -E '^[a-z]+$' | grep -vx devel | sort -u
}

# Every released Ubuntu the archive serves, oldest to newest (development
# series only with UBUNTU_INCLUDE_DEVEL=1). distro-info-data is frozen on Debian.
discover_ubuntu_codenames() {
  local names cn info ver state versioned=""
  # A mirror without a directory listing falls back to the default mirror.
  names="$(list_dists "$UBUNTU_MIRROR")"
  [ -n "$names" ] || names="$(list_dists "$UBUNTU_DEFAULT_MIRROR")"

  # Re-probe the configured releases; a retired one is on old-releases.
  names="$(printf '%s\n%s\n' "$names" \
    "$(sed -n 's/^# codenames: //p' "$UBUNTU_LIST" 2>/dev/null)" \
    | tr ' ' '\n' | grep -E '^[a-z]+$' | sort -u)"

  for cn in $names; do
    info="$(ubuntu_release_info "$cn")" || continue
    ver="${info%% *}"
    state="${info#* }"; state="${state%% *}"
    # Cached for ubuntu_mirror_for().
    if [ "$state" = "devel" ] && [ "$UBUNTU_INCLUDE_DEVEL" != "1" ]; then
      message "  skipping '${cn}' (${ver}) - not released yet; UBUNTU_INCLUDE_DEVEL=1 to use it" >&2
      continue
    fi
    versioned="${versioned}${ver} ${cn}
"
  done

  printf '%s' "$versioned" | sort -V | awk '{print $2}' | tr '\n' ' ' | xargs
}

# Retired releases not already known, at most MAX_UBUNTU_LOOKBACK.
discover_retired_codenames() {
  local cn info versioned=""
  for cn in $(list_dists "$UBUNTU_OLD_MIRROR"); do
    in_word_list "$cn" "$UBUNTU_ALL_CODENAMES" && continue
    info="$(ubuntu_release_info "$cn")" || continue
    versioned="${versioned}${info%% *} ${cn}
"
  done
  printf '%s' "$versioned" | sort -V | awk '{print $2}' \
    | tail -n "$MAX_UBUNTU_LOOKBACK" | xargs
}

# Write the Ubuntu source list. Returns 0 = changed, 1 = already correct,
# 2 = no archive answered. With no argument, every candidate is written.
write_ubuntu_sources() {
  local tmp _c _m _deb _comp _missing="" _list="${*:-$UBUNTU_CANDIDATE_CODENAMES}"
  tmp="$(mktemp)"
  {
    echo "# Written by ubuntu-look.sh — the Ubuntu look packages. Pinned: see ${UBUNTU_PIN}."
    echo "# The lines below are read by later runs to re-check these releases."
    echo "# codenames: ${UBUNTU_CANDIDATE_CODENAMES}"
    echo "# configured: ${_list}"
    echo ""
    for _c in $_list; do
      # The pinned release gets universe too.
      _comp="$UBUNTU_COMPONENTS"
      case "$_c" in
        "${UBUNTU_CODENAME:-}"|"${PINNED_BEFORE:-}") _comp="$UBUNTU_PINNED_COMPONENTS" ;;
      esac
      # The host that answered; a retired release is on old-releases.
      if ! _m="$(ubuntu_mirror_for "$_c")" || [ -z "$_m" ]; then
        message warn "no archive serves Ubuntu '${_c}' — leaving it out of the source list" >&2
        _missing="${_missing} ${_c}"
        continue
      fi
      # arch= keeps foreign architectures off; target=Packages skips translations.
      _deb="deb [arch=${UBUNTU_ARCH} signed-by=${UBUNTU_KEYRING} target=Packages] ${_m}"
      echo "${_deb} ${_c} ${_comp}"
      ubuntu_suite_published "${_c}-updates" "$_m" && echo "${_deb} ${_c}-updates ${_comp}"
    done
  } > "$tmp"

  # No release reachable, or the pinned one missing: keep the current list.
  if ! grep -q '^deb ' "$tmp" \
     || { [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != auto ] \
          && [[ " $_missing " == *" $UBUNTU_CODENAME "* ]]; }; then
    rm -f "$tmp"
    STATUS_FAILED+=("Ubuntu apt sources left as they were — no archive answered for:${_missing}")
    return 2
  fi

  if [ -f "$UBUNTU_LIST" ] && cmp -s "$tmp" "$UBUNTU_LIST"; then
    rm -f "$tmp"
    return 1
  fi
  # 0644: apt reads sources as any user.
  sudo install -m 0644 "$tmp" "$UBUNTU_LIST"
  rm -f "$tmp"
  return 0
}

# Bring the look packages back to the pinned release. apt never downgrades by
# itself; only these packages move, and only when nothing is removed.
align_look_packages() {
  [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != "auto" ] || return 0

  local pkg want have plan="" any_down=0 codes
  local -A is_down=()
  # shellcheck disable=SC2086
  for pkg in $LOOK_PACKAGES $UBUNTU_SHELL_EXT_PKGS; do
    have="$(pkg_installed_version "$pkg")"
    [ -n "$have" ] || continue
    if [ "$MODE" = offline ]; then
      # The bundle's build; a downgrade only over a Debian or other-release build.
      want="$(LC_ALL=C apt-cache "${APT_OPTS[@]}" madison "$pkg" 2>/dev/null \
              | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -V | tail -1)"
      [ -n "$want" ] && [ "$have" != "$want" ] || continue
      if dpkg --compare-versions "$want" lt "$have"; then
        codes="$(pkg_version_ubuntu_codenames "$pkg" "$have")"
        if ! pkg_version_is_debian "$pkg" "$have" \
           && { [ -z "$codes" ] || printf '%s\n' "$codes" | grep -qxF "$UBUNTU_CODENAME"; }; then
          STATUS_NOCHANGE+=("${pkg} stays at ${have} — newer than the bundle's ${want}, and not shown to be from another release")
          continue
        fi
      fi
    else
      # The pinned release's newest build, up or down.
      pkg_version_in_codename "$pkg" "$have" "$UBUNTU_CODENAME" && continue
      want="$(LC_ALL=C apt-cache madison "$pkg" 2>/dev/null \
              | grep -E "[ /]${UBUNTU_CODENAME}(-updates)?/" \
              | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -V | tail -1)"
      [ -n "$want" ] && [ "$want" != "$have" ] || continue
    fi
    # Already tried and turned down while installing.
    if in_word_list "${pkg}=${want}" "$REJECTED_BUILDS"; then
      STATUS_NOCHANGE+=("${pkg} stays at ${have} — ${want} was already tried and would not install")
      continue
    fi
    if dpkg --compare-versions "$want" lt "$have"; then is_down[$pkg]=1; any_down=1; fi
    plan="${plan} ${pkg}=${want}"
  done

  [ -n "$plan" ] || return 0

  # Record the displaced versions before apt runs; the uninstall restores them.
  for pkg in $plan; do
    record_upgraded_pkg "${pkg%%=*}" "$(pkg_installed_version "${pkg%%=*}")"
  done

  message "aligning the look to ${UBUNTU_CODENAME}:${plan}"
  local done_list="" failed=""
  # shellcheck disable=SC2086
  if align_install "$any_down" $plan; then
    done_list="$plan"
  else
    # One package that cannot move must not hold back the others.
    for pkg in $plan; do
      if align_install "${is_down[${pkg%%=*}]:-0}" "$pkg"; then
        done_list="${done_list} ${pkg}"
      else
        failed="${failed} ${pkg%%=*}"
      fi
    done
  fi

  for pkg in $done_list; do
    STATUS_CHANGES+=("${pkg%%=*} taken to ${UBUNTU_CODENAME}'s build (${pkg##*=})")
    RELOGIN_NEEDED=1
  done
  [ -n "$failed" ] && STATUS_FAILED+=("Not aligned to ${UBUNTU_CODENAME}:${failed} — apt refused or it would remove packages")

  # A per-release wallpaper pack left unused is not removed; the user is told.
  local orphan
  orphan="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' \
            | grep -E '^ubuntu-wallpapers-' | xargs)"
  [ -n "$orphan" ] && STATUS_NOCHANGE+=("${orphan} is now unused — 'sudo apt autoremove' reclaims it")
  return 0
}

# Install "pkg=version ..." with downgrades allowed, only when a simulation
# shows nothing removed. Returns 0 installed, 1 refused, 2 apt failed.
align_install() {
  local opts=("${APT_OPTS[@]}") sim removes
  [ "$1" = 1 ] && opts+=(--allow-downgrades)
  shift
  sim="$(LC_ALL=C apt-get -s install "${opts[@]}" "$@" 2>&1)" || return 1
  removes="$(unexpected_removals "$sim")"
  if [ -n "$removes" ]; then
    message warn "aligning $* would remove: ${removes} — skipped"
    return 1
  fi
  record_planned_installs "$sim"
  sudo apt-get install -y "${opts[@]}" "$@" && return 0
  APT_ERRORS=$((APT_ERRORS + 1))
  return 2
}

# Narrow the source list to the pinned release before anything installs.
# Only a newly added suite needs an apt update.
narrow_ubuntu_sources() {
  [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != "auto" ] || return 0
  local before rc=0
  before="$(grep '^deb ' "$UBUNTU_LIST" 2>/dev/null)"
  write_ubuntu_sources "$UBUNTU_CODENAME" || rc=$?
  [ "$rc" -eq 2 ] && return 0
  remove_unattended_origins
  if [ "$rc" -eq 0 ] \
     && grep '^deb ' "$UBUNTU_LIST" | grep -qvxF -f <(printf '%s\n' "$before"); then
    if ! apt_update_ubuntu_only; then
      # A mirror without universe would break apt update: stay on main this time.
      local _tmp
      _tmp="$(mktemp)"
      if grep -q '/universe' <<< "$APT_UPDATE_OUTPUT" \
         && sed "s/^\(deb .*\) ${UBUNTU_PINNED_COMPONENTS}\$/\1 ${UBUNTU_COMPONENTS}/" "$UBUNTU_LIST" > "$_tmp" \
         && ! cmp -s "$_tmp" "$UBUNTU_LIST" && sudo install -m 0644 "$_tmp" "$UBUNTU_LIST"; then
        STATUS_FAILED+=("apt update failed for ${UBUNTU_CODENAME}'s universe — the source stays on main; humanity-icon-theme may be missing")
      else
        STATUS_FAILED+=("apt update failed for ${UBUNTU_CODENAME}'s sources")
      fi
      rm -f "$_tmp"
      APT_ERRORS=$((APT_ERRORS + 1))
    fi
  fi
  if [ "$(cat "$UBUNTU_LIST" 2>/dev/null)" != "${INITIAL_UBUNTU_LIST:-}" ]; then
    local comps="$UBUNTU_COMPONENTS"
    grep -q " ${UBUNTU_PINNED_COMPONENTS}\$" "$UBUNTU_LIST" && comps="$UBUNTU_PINNED_COMPONENTS"
    STATUS_CHANGES+=("Ubuntu apt sources: ${UBUNTU_CODENAME} (${comps})")
  else
    STATUS_NOCHANGE+=("Ubuntu apt sources already current")
  fi
}

# Ubuntu packages are never updated unattended; the file earlier versions
# wrote for unattended-upgrades is removed.
remove_unattended_origins() {
  [ -f "$UNATTENDED_ORIGINS" ] || return 0
  sudo rm -f "$UNATTENDED_ORIGINS" \
    && STATUS_CHANGES+=("unattended-upgrades no longer updates the Ubuntu look packages — 'apt upgrade' does")
}

# Codenames the Ubuntu source list names (the field after the URL).
configured_codenames() {
  awk '/^deb /{ for (i = 2; i < NF; i++) if ($i ~ /:\/\//) { print $(i + 1); break } }' \
    "$UBUNTU_LIST" 2>/dev/null | sed 's/-updates$//' | sort -u
}

# apt-get update for the Ubuntu sources only, waiting for a lock. The output
# is kept in APT_UPDATE_OUTPUT.
apt_update_ubuntu_only() {
  local log rc try=1
  log="$(mktemp)" || return 1
  while :; do
    # shellcheck disable=SC2024  # the log is this user's file
    LC_ALL=C sudo apt-get update -o Dir::Etc::sourcelist="$UBUNTU_LIST" \
      -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 > "$log" 2>&1
    rc=$?
    [ "$rc" -ne 0 ] && [ "$try" -lt 5 ] \
      && grep -q 'Could not get lock' "$log" || break
    message "apt is busy — trying again in a minute"
    try=$((try + 1)); sleep 60
  done
  APT_UPDATE_OUTPUT="$(cat "$log")"
  rm -f "$log"
  return "$rc"
}

# apt-get update that waits for a lock and tolerates other repositories' errors.
apt_update() {
  local log rc try=1
  log="$(mktemp)"
  while :; do
    LC_ALL=C sudo apt-get update 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    [ "$rc" -ne 0 ] && [ "$try" -lt 5 ] \
      && grep -q 'Could not get lock' "$log" || break
    message "apt is busy — trying again in a minute"
    try=$((try + 1)); sleep 60
  done
  [ "$rc" -eq 0 ] && { rm -f "$log"; return 0; }
  # Still locked after five tries.
  grep -q 'Could not get lock' "$log" && { rm -f "$log"; return "$rc"; }
  rm -f "$log"

  # Another repository failed; the Ubuntu part is what matters.
  if [ -f "$UBUNTU_LIST" ] && apt_update_ubuntu_only; then
    message warn "apt update reported errors for another repository — continuing"
    STATUS_NOCHANGE+=("apt update: another repository reported an error (see above)")
    return 0
  fi
  return "$rc"
}

# Newest candidate release whose shell theme and dock both install here.
# Empty when nothing fits.
resolve_ubuntu_codename() {
  local cn pkg ver sim ok allowed
  for cn in $(echo "$UBUNTU_CANDIDATE_CODENAMES" | tr ' ' '\n' | tac); do
    ok=1
    # The dock comes as its own package, or in the combined one.
    for pkg in yaru-theme-gnome-shell gnome-shell-extension-ubuntu-dock "$COMBINED_EXT_PKG"; do
      ver="$(LC_ALL=C apt-cache madison "$pkg" 2>/dev/null \
        | awk -F'|' -v c="$cn" '$3 ~ ("[ /]" c "(-updates)?/") { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }')"
      if [ -z "$ver" ]; then
        # The theme is required; the dock is optional.
        [ "$pkg" = yaru-theme-gnome-shell ] && { ok=0; break; }
        continue
      fi
      message "  checking ${pkg} on ${cn} (${ver})..." >&2
      allowed=""
      [ "$pkg" = "$COMBINED_EXT_PKG" ] && allowed="$SEPARATE_EXT_PKGS"
      if ! sim="$(LC_ALL=C apt-get install -s "${pkg}=${ver}" 2>&1)" \
         || [ -n "$(ALLOWED_REMOVALS="$allowed" unexpected_removals "$sim")" ]; then
        ok=0; break
      fi
      [ "$pkg" = gnome-shell-extension-ubuntu-dock ] && break
    done
    [ "$ok" -eq 1 ] && { echo "$cn"; return 0; }
  done
  return 0
}

# apt-cache madison $1 as trimmed "<version>|<source>" lines.
madison_rows() {
  LC_ALL=C apt-cache madison "$1" 2>/dev/null | awk -F'|' '
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

# Warn about installed packages the running gnome-shell has moved past.
check_shell_coupling_drift() {
  local running pkg bound drift=0
  running="$(shell_major)"
  [ -n "$running" ] || return 0

  for pkg in $SEPARATE_EXT_PKGS $COMBINED_EXT_PKG; do
    is_installed "$pkg" || continue
    bound="$(pkg_shell_upper_bound "$pkg")"
    [ -n "$bound" ] || continue
    if [ "$running" -ge "$bound" ]; then
      message warn "${pkg} is built for gnome-shell < ${bound}, but ${running} is running"
      STATUS_FAILED+=("${pkg} does not support gnome-shell ${running} — it will not load")
      drift=1
    fi
  done

  # Every Ubuntu-built look package should be the pinned release's build
  # (-updates included).
  local themepkg themed want
  if [ -n "$UBUNTU_CODENAME" ] && [ "$UBUNTU_CODENAME" != "auto" ]; then
    for themepkg in $LOOK_PACKAGES; do
      pkg_origin_is_ubuntu "$themepkg" || continue
      themed="$(pkg_installed_version "$themepkg")"
      pkg_version_in_codename "$themepkg" "$themed" "$UBUNTU_CODENAME" && continue
      [ "$MODE" = offline ] && bundle_has_version "$themepkg" "$PACKAGES_DIR" "$themed" >/dev/null && continue
      want="$(LC_ALL=C apt-cache "${APT_OPTS[@]}" madison "$themepkg" 2>/dev/null \
              | grep -E "[ /]${UBUNTU_CODENAME}(-updates)?/|^ *${themepkg} *\| .* \| file:" \
              | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -V | tail -1)"
      message warn "${themepkg} ${themed} is not the build for ${UBUNTU_CODENAME}"
      # apt does not downgrade by itself.
      if [ -n "$want" ]; then
        message warn "  to align it: sudo apt install --allow-downgrades ${themepkg}=${want}"
        STATUS_FAILED+=("${themepkg} is ${themed}, but ${UBUNTU_CODENAME} ships ${want} — see the command above")
      else
        message warn "  ${UBUNTU_CODENAME} offers no build of it in the configured sources"
      fi
      drift=1
    done
  fi

  # The Ubuntu extensions hold back a newer gnome-shell major.
  local cand_major
  cand_major="$(LC_ALL=C apt-cache policy gnome-shell 2>/dev/null \
    | awk '/^  Candidate:/ { if ($2 != "(none)") print $2; exit }' | grep -oE '^[0-9]+')"
  if [ -n "$cand_major" ] && [ "$cand_major" -gt "$running" ]; then
    for pkg in $UBUNTU_SHELL_EXT_PKGS; do
      bound="$(pkg_shell_upper_bound "$pkg")"
      if [ -n "$bound" ] && [ "$cand_major" -ge "$bound" ]; then
        STATUS_FAILED+=("gnome-shell ${cand_major} is available but ${pkg} holds it back — run 'bash ubuntu-look.sh --prepare-upgrade', upgrade, then re-run")
        break
      fi
    done
  fi

  [ "$drift" -eq 1 ] && message warn "re-run this script to resolve the theme against the running gnome-shell"
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

# Without a pin, write one that blocks every Ubuntu package. Returns 1 when a
# pin exists.
write_provisional_pin() {
  [ ! -f "$UBUNTU_PIN" ] || return 1
  printf '%s\n' \
    "# provisional — written before the Ubuntu sources, replaced once the codename resolves" \
    "Package: *" \
    "Pin: release o=Ubuntu" \
    "Pin-Priority: -1" | sudo tee "$UBUNTU_PIN" > /dev/null
}

# Write the Ubuntu pin for UBUNTU_CODENAME to $1 (default: UBUNTU_PIN).
# Returns 0 when the file changed, 1 when already current.
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
  if readable_regular_file "$dest" && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  if [ "$dest" = "$UBUNTU_PIN" ]; then sudo install -m 0644 "$tmp" "$dest"; else install -m 0644 "$tmp" "$dest"; fi
  rm -f "$tmp"
  return 0
}

# Remove the keyring earlier versions wrote, once no source names it.
remove_legacy_keyring() {
  [ -f "$LEGACY_UBUNTU_KEYRING" ] || return 0
  grep -rqsF "$LEGACY_UBUNTU_KEYRING" /etc/apt/sources.list /etc/apt/sources.list.d/ && return 0
  sudo rm -f "$LEGACY_UBUNTU_KEYRING"
}

# The package list before this script installs anything, taken once.
record_packages_before() {
  local tmp
  if [ ! -f "$PACKAGES_BEFORE" ]; then
    tmp="$(mktemp)"
    sys_records_dir
    apt-mark showmanual 2>/dev/null | sort > "$tmp"
    sudo install -m 0644 "$tmp" "$MANUAL_BEFORE"
    installed_package_list > "$tmp"
    sudo install -m 0644 "$tmp" "$PACKAGES_BEFORE"
    dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
      | awk '$4 == "config-files" { print $1 }' | sort > "$tmp"
    sudo install -m 0644 "$tmp" "$CONFIG_FILES_BEFORE"
    rm -f "$tmp"
    STATUS_CHANGES+=("Pre-install package list saved → ${PACKAGES_BEFORE}")
  fi
  [ -f "$MANUAL_BEFORE" ] \
    || STATUS_NOCHANGE+=("No record of package marks from before the first install — the uninstall leaves the marks as they are")
}

# Configure the older releases $1 beside the window, and resolve again.
try_older_releases() {
  local window="$UBUNTU_CANDIDATE_CODENAMES"
  message "looking further back: $1"
  UBUNTU_CANDIDATE_CODENAMES="$1 $window"
  if write_ubuntu_sources; then apt_update_ubuntu_only || true; fi
  UBUNTU_CODENAME="$(resolve_ubuntu_codename)"
  if [ -n "$UBUNTU_CODENAME" ]; then
    # Keep only the release found, beside the window.
    UBUNTU_CANDIDATE_CODENAMES="$UBUNTU_CODENAME $window"
    STATUS_CHANGES+=("Reached back to ${UBUNTU_CODENAME} for a gnome-shell-compatible theme")
  else
    UBUNTU_CANDIDATE_CODENAMES="$window"
  fi
}

# gnome-shell major of Ubuntu release $1.
ubuntu_shell_major() {
  LC_ALL=C apt-cache madison gnome-shell 2>/dev/null \
    | awk -F'|' -v c="$1" '$3 ~ ("[ /]" c "(-updates)?/") { gsub(/ /, "", $2); split($2, v, "."); print v[1]; exit }'
}

# Put back the Ubuntu source list saved in PREV_UBUNTU_LIST.
restore_prev_ubuntu_list() {
  if [ -s "$PREV_UBUNTU_LIST" ]; then
    sudo install -m 0644 "$PREV_UBUNTU_LIST" "$UBUNTU_LIST"
  else
    sudo rm -f "$UBUNTU_LIST"
  fi
  rm -f "$PREV_UBUNTU_LIST"
}

# Record that $1 replaced version $2, so the uninstall reinstalls it. The first
# entry per package is kept.
record_upgraded_pkg() {
  local pkg="$1" was="$2"
  [ -n "$pkg" ] && [ -n "$was" ] || return 0
  awk -v p="$pkg" '$1 == p { f = 1 } END { exit !f }' "$UPGRADED_MANIFEST" 2>/dev/null && return 0
  grep -qxF "$pkg" "$INSTALLED_MANIFEST" 2>/dev/null && return 0
  predates_install "$pkg" || pkg_version_is_debian "$pkg" "$was" || return 0
  sys_record_append "$UPGRADED_MANIFEST" "${pkg} ${was}"
  sys_record_sort "$UPGRADED_MANIFEST"
}

###############################################################################
# 3. Desktop: Ubuntu's settings, extensions, terminal, login screen
###############################################################################

# Remove the user-local desktop-icons copy of earlier versions; it shadows
# Debian's package. Returns 0 when something was removed.
remove_legacy_ding() {
  local record="${BACKUP_DIR}/ubuntu-ding-version.txt"
  local d="${HOME}/.local/share/gnome-shell/extensions/ding@rastersoft.com"
  local sd="${HOME}/.local/share/glib-2.0/schemas"
  [ -f "$record" ] || return 1
  rm -rf "$d" "${sd}/org.gnome.shell.extensions.ding.gschema.xml"
  if ls "${sd}"/*.gschema.xml >/dev/null 2>&1; then
    glib-compile-schemas "$sd" 2>/dev/null || true
  else
    rm -f "${sd}/gschemas.compiled"
    rmdir "$sd" "${HOME}/.local/share/glib-2.0" 2>/dev/null || true
  fi
  rmdir "${HOME}/.local/share/gnome-shell/extensions" \
        "${HOME}/.local/share/gnome-shell" 2>/dev/null || true
  rm -f "$record"
  return 0
}

# Print the look profile: the system's user profile with the look database
# right after the user database.
look_profile_content() {
  local base="" line added=0
  for base in "$DCONF_USER_PROFILE" /usr/share/dconf/profile/user ""; do
    [ -z "$base" ] || [ -f "$base" ] && break
  done
  if [ -n "$base" ] && grep -q '^user-db:' "$base" 2>/dev/null; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line"
      if [ "$added" -eq 0 ] && [ "${line#user-db:}" != "$line" ]; then
        printf 'system-db:%s\n' "$LOOK_DB_NAME"
        added=1
      fi
    done < "$base"
  else
    printf 'user-db:user\nsystem-db:%s\n' "$LOOK_DB_NAME"
    [ -n "$base" ] && grep -v '^user-db:' "$base"
  fi
  return 0
}

# Write the look profile. Returns 0 = changed, 1 = current, 2 = failed.
write_look_profile() {
  local tmp rc=1
  # A pending boot-time removal would delete the new profile.
  [ -f "$LOOK_CLEANUP_CONF" ] && sudo rm -f "$LOOK_CLEANUP_CONF"
  tmp="$(mktemp)"
  look_profile_content > "$tmp"
  if ! { [ -f "$LOOK_PROFILE" ] && cmp -s "$tmp" "$LOOK_PROFILE"; }; then
    if sudo install -D -m 0644 "$tmp" "$LOOK_PROFILE"; then rc=0; else rc=2; fi
  fi
  rm -f "$tmp"
  return $rc
}

# Mask session-migration. Returns 0 = masked now, 1 = already masked,
# 2 = failed or an admin's own unit file is there.
mask_session_migration() {
  [ "$(readlink "$SESSION_MIGRATION_MASK" 2>/dev/null)" = /dev/null ] && return 1
  [ -e "$SESSION_MIGRATION_MASK" ] || [ -L "$SESSION_MIGRATION_MASK" ] && return 2
  sys_records_dir && sudo touch "$SESSION_MIGRATION_MASKED" || return 2
  sudo mkdir -p "$(dirname "$SESSION_MIGRATION_MASK")" \
    && sudo ln -s /dev/null "$SESSION_MIGRATION_MASK" && return 0
  sudo rm -f "$SESSION_MIGRATION_MASKED"
  return 2
}

# The per-user switch file's content; $1 names the uninstall command.
look_env_content() {
  local by="${1:-"'ubuntu-look.sh --uninstall'"}"
  printf '# Written by ubuntu-look.sh; removed by %s.\nDCONF_PROFILE=%s' "$by" "$LOOK_PROFILE_NAME"
}

# Make this user's sessions read the look profile from the next login.
# Returns 0 = changed, 1 = current, 2 = failed.
enable_look_for_user() {
  local want have
  want="$(look_env_content)"
  have="$(cat "$LOOK_ENV_FILE" 2>/dev/null)"
  [ "$have" = "$want" ] && return 1
  # Only the comment of earlier versions differs: the switch is already on.
  if [ "$have" = "$(look_env_content uninstall.sh)" ]; then
    printf '%s\n' "$want" > "$LOOK_ENV_FILE" && return 1
    return 2
  fi
  mkdir -p "$(dirname "$LOOK_ENV_FILE")" && printf '%s\n' "$want" > "$LOOK_ENV_FILE" && return 0
  return 2
}

# Remove the machine-wide defaults (local.d) of earlier versions and their
# user profile changes. Returns 0 = removed, 1 = none, 2 = failed.
retire_legacy_defaults() {
  local changed=1 failed=0 only_ours=1 f
  # An admin's own local database keeps system-db:local in place.
  for f in /etc/dconf/db/local.d/*; do
    [ -e "$f" ] || continue
    [ "$f" = "$LEGACY_DB_FILE" ] || only_ours=0
  done
  if [ -f "$LEGACY_DB_FILE" ]; then
    if sudo rm -f "$LEGACY_DB_FILE"; then changed=0; else failed=1; fi
  fi
  if [ "$only_ours" -eq 1 ]; then
    if [ -f "${SYS_RECORDS}/dconf-user-profile-created" ]; then
      if sudo rm -f "$DCONF_USER_PROFILE"; then
        sudo rm -f "${SYS_RECORDS}/dconf-user-profile-created"; changed=0
      else failed=1; fi
    elif [ -f "${SYS_RECORDS}/dconf-user-profile-appended" ]; then
      if sudo sed -i '/^system-db:local$/d' "$DCONF_USER_PROFILE"; then
        sudo rm -f "${SYS_RECORDS}/dconf-user-profile-appended"; changed=0
      else failed=1; fi
    elif [ "$changed" -eq 0 ] && [ -f "$DCONF_USER_PROFILE" ] \
         && [ "$(tr -d '[:space:]' < "$DCONF_USER_PROFILE")" = "user-db:usersystem-db:local" ]; then
      # The oldest versions kept no record; this is the profile they wrote.
      sudo rm -f "$DCONF_USER_PROFILE" || failed=1
    fi
  fi
  if [ -f "${SYS_RECORDS}/dconf-local-dir-created" ] && [ "$only_ours" -eq 1 ]; then
    sudo rmdir /etc/dconf/db/local.d 2>/dev/null && sudo rm -f /etc/dconf/db/local
    sudo rm -f "${SYS_RECORDS}/dconf-local-dir-created"
    changed=0
  fi
  # Unrecorded leftovers: an empty, unowned local.d and system-db:local.
  if [ -d /etc/dconf/db/local.d ] && [ -z "$(ls -A /etc/dconf/db/local.d 2>/dev/null)" ] \
     && ! dpkg -S /etc/dconf/db/local.d > /dev/null 2>&1; then
    if [ -f "$DCONF_USER_PROFILE" ] && grep -qx 'system-db:local' "$DCONF_USER_PROFILE"; then
      sudo sed -i '/^system-db:local$/d' "$DCONF_USER_PROFILE" || failed=1
    fi
    # The look profile is rewritten without it later in this run.
    local p in_use=0
    for p in /etc/dconf/profile/*; do
      [ "$p" = "$LOOK_PROFILE" ] && continue
      grep -qsx 'system-db:local' "$p" && in_use=1
    done
    if [ "$in_use" -eq 0 ]; then
      sudo rmdir /etc/dconf/db/local.d && sudo rm -f /etc/dconf/db/local && changed=0
    fi
  fi
  if [ "$changed" -eq 0 ]; then sudo dconf update || failed=1; fi
  [ "$failed" -eq 1 ] && return 2
  return $changed
}

# Remove the shell theme follower user services of earlier versions.
# Returns 0 = removed, 1 = none.
remove_theme_followers() {
  local name unit bin rc=1
  for name in yaru-shell-theme yaru-color-scheme-sync; do
    unit="$HOME/.config/systemd/user/${name}.service"
    bin="$HOME/.local/bin/${name}"
    [ -f "$unit" ] || [ -f "${bin}.sh" ] || [ -f "${bin}.js" ] || continue
    systemctl --user disable --now "${name}.service" 2>/dev/null || true
    rm -f "$unit" "${bin}.sh" "${bin}.js" \
          "$HOME/.config/systemd/user/graphical-session.target.wants/${name}.service"
    rc=0
  done
  [ "$rc" -eq 0 ] && { systemctl --user daemon-reload 2>/dev/null || true; }
  return $rc
}

# Keep only valid extension uuids (name@domain).
extension_uuids() {
  local e out=""
  for e in $(dconf_array_items "$1"); do
    case "$e" in ?*@?*) out="$out $e" ;; esac
  done
  echo "$out"
}

# True when Ubuntu Dock is installed and built for the running gnome-shell.
ubuntu_dock_usable() {
  local bound major pkg=gnome-shell-extension-ubuntu-dock
  is_installed "$COMBINED_EXT_PKG" && pkg="$COMBINED_EXT_PKG"
  is_installed "$pkg" || return 1
  bound="$(pkg_shell_upper_bound "$pkg")"
  [ -n "$bound" ] || return 0
  major="$(shell_major)"
  [ -n "$major" ] && [ "$major" -lt "$bound" ]
}

# Turn a Dash-to-Dock this script turned off back on, as Ubuntu Dock cannot
# run. Without a session, the autostart does it at the next login.
dash_to_dock_back_on() {
  [ -f "$DASH_TO_DOCK_OFF" ] || return 0
  local en dis keep
  if ! extension_installed "$DASH_TO_DOCK_UUID"; then
    rm -f "$DASH_TO_DOCK_OFF"
    return 0
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DASH_TO_DOCK_PENDING=1
    STATUS_CHANGES+=("Dash-to-Dock is turned back on at your next login — Ubuntu Dock cannot run on this gnome-shell")
    return 0
  fi
  en="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  dis="$(extension_uuids /org/gnome/shell/disabled-extensions)"
  keep="$(word_list_without "$dis" "$DASH_TO_DOCK_UUID")"
  in_word_list "$DASH_TO_DOCK_UUID" "$en" || en="$en $DASH_TO_DOCK_UUID"
  if dconf write /org/gnome/shell/enabled-extensions "$(gvariant_string_array "$en")" 2>/dev/null \
     && { [ "$(echo "$keep" | xargs)" = "$(echo "$dis" | xargs)" ] \
          || dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$keep")" 2>/dev/null; }; then
    rm -f "$DASH_TO_DOCK_OFF"
    STATUS_CHANGES+=("Dash-to-Dock turned back on — Ubuntu Dock cannot run on this gnome-shell")
  else
    STATUS_FAILED+=("Dash-to-Dock could not be turned back on — Ubuntu Dock cannot run on this gnome-shell")
  fi
}

# Ubuntu Dock stands aside while Dash-to-Dock is on, so turn that off for
# this user; the uninstall turns it back on.
turn_off_dash_to_dock() {
  local en
  if ! ubuntu_dock_usable; then dash_to_dock_back_on; return 0; fi
  en="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  in_word_list "$DASH_TO_DOCK_UUID" "$en" || return 0
  mkdir -p "$BACKUP_DIR" && touch "$DASH_TO_DOCK_OFF"
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    DASH_TO_DOCK_PENDING=1
    STATUS_CHANGES+=("Dash-to-Dock is turned off at your next login — Ubuntu Dock takes its place")
    return 0
  fi
  if dconf write /org/gnome/shell/enabled-extensions \
       "$(gvariant_string_array "$(word_list_without "$en" "$DASH_TO_DOCK_UUID")")" 2>/dev/null; then
    STATUS_CHANGES+=("Dash-to-Dock turned off for you — Ubuntu Dock takes its place; the uninstall turns it back on")
  else
    STATUS_FAILED+=("Dash-to-Dock could not be turned off — Ubuntu Dock stays hidden while it is on")
  fi
}

# Enable extensions $@ in the user's dconf database, keeping the others.
enable_shell_extensions() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 0
  command -v dconf >/dev/null 2>&1 || return 0
  [ $# -gt 0 ] || return 0

  local own now merged keep="" e dis want=" $* "
  # Start from the user's own list, not the one the defaults supply.
  own="$(user_dconf_read /org/gnome/shell/enabled-extensions)"
  if [ -n "$own" ]; then
    now="$(array_items "$own")"
  else
    now="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  fi
  merged="$(echo "$now $*" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  # Skip an unchanged list: each write reloads the shell theme.
  if [ -z "$own" ] || [ "$(echo $now)" != "$(echo $merged)" ]; then
    dconf write /org/gnome/shell/enabled-extensions "$(gvariant_string_array "$merged")" 2>/dev/null || return 0
  fi

  dis="$(extension_uuids /org/gnome/shell/disabled-extensions)"
  for e in $dis; do in_word_list "$e" "$want" || keep="$keep $e"; done
  [ "$(echo $keep)" = "$(echo $dis)" ] && return 0
  dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$keep")" 2>/dev/null || true
}

# Restore the dock favourites of the snapshot once, undoing the apps earlier
# versions pinned.
restore_dock_favourites() {
  local marker="${BACKUP_ORIGINAL}/favourites-restored"
  local dump="${BACKUP_ORIGINAL}/dconf-dump.ini"
  local was now
  [ ! -f "$marker" ] && [ -f "$dump" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || return 0
  command -v dconf >/dev/null 2>&1 || return 0

  was="$(ini_value "$dump" org/gnome/shell favorite-apps)"
  now="$(dconf read /org/gnome/shell/favorite-apps 2>/dev/null)"

  if [ "$(printf '%s' "$was" | tr -d '[:space:]')" \
     != "$(printf '%s' "$now" | tr -d '[:space:]')" ]; then
    if [ -z "$was" ]; then
      # An unset key and a failed snapshot look the same: leave them alone.
      STATUS_NOCHANGE+=("Dock favourites left as they are — the snapshot recorded none to put back")
    else
      dconf write /org/gnome/shell/favorite-apps "$was" 2>/dev/null || return 0
      STATUS_CHANGES+=("Dock favourites put back to what they were before this script first ran")
      RELOGIN_NEEDED=1
    fi
  fi
  : > "$marker"
}

# True when extension $1 is installed system-wide, under /usr/local, or for this user.
extension_installed() {
  [ -d "/usr/share/gnome-shell/extensions/$1" ] \
    || [ -d "/usr/local/share/gnome-shell/extensions/$1" ] \
    || [ -d "$HOME/.local/share/gnome-shell/extensions/$1" ]
}

# True when gnome-shell reports extension $1 as active.
extension_active() { LC_ALL=C gnome-extensions info "$1" 2>/dev/null | grep -q 'State: ACTIVE'; }

# The look's installed extensions not yet switched on for this user; with
# "all", also those not installed.
extensions_to_switch_on() {
  local e out=""
  for e in $SHELL_EXTENSIONS; do
    [ "${1:-}" = all ] || extension_installed "$e" || continue
    grep -qxF "$e" "$EXTENSIONS_ON_RECORD" 2>/dev/null || out="${out} ${e}"
  done
  echo $out
}

record_extensions_on() {
  [ $# -gt 0 ] || return 0
  mkdir -p "$BACKUP_DIR" && printf '%s\n' "$@" >> "$EXTENSIONS_ON_RECORD"
}

# Start the record from the user's extension lists, for users of earlier
# versions, which kept none.
seed_extensions_record() {
  [ -f "$EXTENSIONS_ON_RECORD" ] || [ "${FIRST_RUN_FOR_USER:-0}" = 1 ] && return 0
  [ -f "$HOME/.config/autostart/ubuntu-look-enable-extensions.desktop" ] && return 0
  command -v dconf >/dev/null 2>&1 || return 0
  local lists e seen=()
  lists="$(user_dconf_read /org/gnome/shell/enabled-extensions)
$(user_dconf_read /org/gnome/shell/disabled-extensions)"
  for e in $SHELL_EXTENSIONS; do
    case "$lists" in *"'${e}'"*) seen+=("$e") ;; esac
  done
  mkdir -p "$BACKUP_DIR" && : > "$EXTENSIONS_ON_RECORD"
  record_extensions_on "${seen[@]}"
}

# Enable the extensions at the next login through a one-shot autostart entry;
# a running Wayland shell cannot rescan them.
install_extension_autostart() {
  local dir="$HOME/.local/share/ubuntu-look"
  local script="${dir}/enable-extensions.sh"
  local desktop="$HOME/.config/autostart/ubuntu-look-enable-extensions.desktop"
  local todo tmp e all_on=1 want='State: ACTIVE' _dock_usable=0 _wrote=0 _rc
  seed_extensions_record
  todo="$(extensions_to_switch_on)"
  if [ -z "$todo" ] && [ "$USER_THEME_RETIRE" != 1 ] \
     && [ "${DASH_TO_DOCK_PENDING:-0}" != 1 ]; then
    rm -f "$desktop" "$script"
    rmdir "$dir" 2>/dev/null || true
    [ "${EXT_RECORDED:-0}" = 1 ] || [ ! -s "$EXTENSIONS_ON_RECORD" ] \
      || STATUS_NOCHANGE+=("Extensions were switched on before — any you turn off later stay off")
    return 0
  fi

  # Nothing to schedule when the running session has all of them on.
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gnome-extensions >/dev/null 2>&1; then
    # A locked screen switches extensions off until unlock.
    gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver \
      --method org.gnome.ScreenSaver.GetActive 2>/dev/null | grep -q true && want='Enabled: Yes'
    for e in $todo; do
      LC_ALL=C gnome-extensions info "$e" 2>/dev/null | grep -q "$want" || { all_on=0; break; }
    done
    if [ $all_on -eq 1 ] && [ "$USER_THEME_RETIRE" != 1 ]; then
      # shellcheck disable=SC2086
      record_extensions_on $todo
      rm -f "$desktop" "$script"
      rmdir "$dir" 2>/dev/null || true
      STATUS_NOCHANGE+=("Extensions are already on — no autostart entry needed")
      return 0
    fi
  fi

  ubuntu_dock_usable && _dock_usable=1
  tmp="$(mktemp)"

  cat << EOF > "$tmp"
#!/bin/bash
# One-shot, written by ubuntu-look.sh: switches on the look's extensions at
# login, then removes itself.
SHELL_EXTENSIONS="${todo}"

# Wait up to 30 seconds for the shell to answer about an extension.
for _i in \$(seq 1 30); do
  for _e in \$SHELL_EXTENSIONS ${DASH_TO_DOCK_UUID} ${USER_THEME_UUID}; do
    gnome-extensions info "\$_e" >/dev/null 2>&1 && break 2
  done
  sleep 1
done

# Ubuntu Dock stands aside while Dash-to-Dock is on; the installer recorded it.
# Where Ubuntu Dock cannot run, Dash-to-Dock goes back on instead.
if [ -f "${DASH_TO_DOCK_OFF}" ]; then
  if [ "${_dock_usable}" = 1 ]; then
    gnome-extensions disable ${DASH_TO_DOCK_UUID} 2>/dev/null || true
  else
    gnome-extensions enable ${DASH_TO_DOCK_UUID} 2>/dev/null && rm -f "${DASH_TO_DOCK_OFF}"
  fi
fi

# Enable through gnome-shell only; a dconf write as well would enable an
# extension twice.
for e in \$SHELL_EXTENSIONS; do
  gnome-extensions enable "\$e" 2>/dev/null || true
done

# user-theme carried Yaru before the theme extension did; it goes once that runs.
if [ "${USER_THEME_RETIRE}" = 1 ]; then
  gnome-extensions disable ${USER_THEME_UUID} 2>/dev/null \
    && dconf reset /org/gnome/shell/extensions/user-theme/name
fi

# Fallback: remove any of them still listed in disabled-extensions.
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
  # if/else: a failed write must not fall through to the empty list.
  if [ -n "\$keep" ]; then
    dconf write /org/gnome/shell/disabled-extensions "[\${keep%,}]" 2>/dev/null || true
  else
    dconf write /org/gnome/shell/disabled-extensions "@as []" 2>/dev/null || true
  fi
fi

# Each one now on is recorded: switched on once, the user's later choices stand.
on="\$(dconf read /org/gnome/shell/enabled-extensions 2>/dev/null)"
for e in \$SHELL_EXTENSIONS; do
  case "\$on" in
    *"'\$e'"*) mkdir -p "${BACKUP_DIR}" && printf '%s\n' "\$e" >> "${EXTENSIONS_ON_RECORD}" ;;
  esac
done
rm -f "${desktop}" "${script}"
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

  effective="$(dconf read "$full" 2>/dev/null)"
  default="$(dconf read -d "$full" 2>/dev/null)"

  if [ "$effective" = "$default" ]; then
    dconf reset "$full" 2>/dev/null || true
    GSETTINGS_UNCHANGED=$((GSETTINGS_UNCHANGED + 1))
  else
    GSETTINGS_KEPT=$((GSETTINGS_KEPT + 1))
    SETTINGS_KEPT+=("${full} — yours: ${effective:-unset}, Ubuntu's: ${default:-unset}")
  fi
}

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

# True when this user's running gnome-shell reads the look profile.
session_on_look_profile() {
  local pid
  pid="$(pgrep -u "$(id -u)" -x gnome-shell 2>/dev/null | head -1)"
  [ -n "$pid" ] && tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null \
    | grep -qxF "DCONF_PROFILE=${LOOK_PROFILE_NAME}"
}

# Hand the table's keys and the wallpaper keys back to the look profile,
# keeping the user's own values.
reclaim_live_settings() {
  local line path key value
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    case "$DCONF_ONLY_KEYS" in *" $key "*) continue ;; esac
    # Yaru-dark is the theme extension's value for the dark style.
    case "$key" in
      gtk-theme|icon-theme) [ "$(dconf read "/${path}/${key}" 2>/dev/null)" = "'Yaru-dark'" ] && continue ;;
    esac
    reclaim_dconf_key "$path" "$key"
  done
  for line in "${WALLPAPER_KEYS[@]}"; do
    IFS='|' read -r path key <<< "$line"
    reclaim_dconf_key "$path" "$key"
  done
}

# Fresh install: clear the user's own values of the look's keys, the wallpaper
# and the dock, so Ubuntu's defaults apply. Dock favourites stay.
apply_ubuntu_defaults() {
  local line path key cleared="" failed=0
  command -v dconf >/dev/null 2>&1 || return 0
  for line in "${GNOME_SETTINGS[@]}" "$COLOR_SCHEME_KEY" "${WALLPAPER_KEYS[@]}"; do
    IFS='|' read -r path key _ <<< "$line"
    case "$DCONF_ONLY_KEYS" in *" $key "*) continue ;; esac
    [ "$path" = org/gnome/shell/extensions/dash-to-dock ] && continue
    [ -n "$(user_dconf_read "/${path}/${key}")" ] || continue
    if dconf reset "/${path}/${key}" 2>/dev/null; then cleared="${cleared}${cleared:+, }${key}"; else failed=1; fi
  done
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
  rm -f "$DEFAULTS_PENDING"
  if [ -n "$cleared" ]; then
    STATUS_CHANGES+=("Ubuntu's defaults replace your own: ${cleared} — dock favourites kept; the uninstall returns Debian's defaults")
    RELOGIN_NEEDED=1
  fi
}

# True when user $1 has the per-user switch.
look_enabled_for() {
  local home
  home="$(getent passwd "$1" | cut -d: -f6)"
  [ -n "$home" ] && sudo test -f "${home}/${LOOK_ENV_REL}"
}

# Add the per-user switch for another registered user, written as that user.
enable_look_for_other_user() {
  sudo -u "$1" -H sh -c 'f="$HOME/$2"; mkdir -p "${f%/*}" && printf "%s\n" "$1" > "$f"' \
    _ "$(look_env_content)" "$LOOK_ENV_REL" 2>/dev/null
}

# The system side of the look: Ubuntu's defaults database, the look profile,
# the session-migration mask and the retirement of earlier versions' defaults.
write_dconf_profile() {
  local wp_light="$1" wp_dark="$2" bg_block=""
  # A missing dark wallpaper falls back to the light one.
  [ -f "$wp_dark" ] || wp_dark="$wp_light"
  # Background keys only when the wallpaper file exists.
  if [ -f "$wp_light" ]; then
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

  # Earlier versions applied the defaults to every user. Registered users get
  # the per-user switch; the old defaults go once every session reads it.
  local u _pid pending=""
  if [ -f "$LEGACY_DB_FILE" ]; then
    for u in $(cat "$SYS_USERS" 2>/dev/null); do
      [ "$u" = "$RUN_USER" ] && continue
      getent passwd "$u" > /dev/null || continue
      look_enabled_for "$u" && continue
      if [ "$REFRESH" != 1 ] && enable_look_for_other_user "$u"; then
        STATUS_CHANGES+=("The look stays enabled for ${u} (per-user switch added)")
      else
        pending="${pending} ${u}"
      fi
    done
    # A session still on the old defaults would lose the look; wait for re-login.
    for u in $(cat "$SYS_USERS" 2>/dev/null) "$RUN_USER"; do
      _pid="$(pgrep -u "$u" -x gnome-shell 2>/dev/null | head -1)"
      [ -n "$_pid" ] || continue
      sudo grep -qa "DCONF_PROFILE=${LOOK_PROFILE_NAME}" "/proc/${_pid}/environ" 2>/dev/null \
        || { pending="${pending} ${u}"; break; }
    done
  fi
  if [ -n "$pending" ]; then
    STATUS_NOCHANGE+=("The machine-wide defaults of earlier versions stay until every user of the look has logged in again; a later run removes them")
  else
    retire_legacy_defaults
    case $? in
      0) STATUS_CHANGES+=("Removed the machine-wide defaults of earlier versions — other users keep Debian's look") ;;
      2) STATUS_FAILED+=("The machine-wide defaults of earlier versions could not all be removed") ;;
    esac
  fi
  write_look_profile
  case $? in
    0) STATUS_CHANGES+=("dconf profile for users of the look → ${LOOK_PROFILE}") ;;
    2) STATUS_FAILED+=("${LOOK_PROFILE} could not be written — the look cannot apply") ;;
  esac
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

  if [ ! -f "$LOOK_DB_FILE" ] || ! cmp -s "$tmp" "$LOOK_DB_FILE"; then
    if ! sudo install -D -m 0644 "$tmp" "$LOOK_DB_FILE"; then
      STATUS_FAILED+=("${LOOK_DB_FILE} could not be written — Ubuntu's defaults are not updated")
    elif compile_dconf; then
      STATUS_CHANGES+=("Ubuntu's defaults written → ${LOOK_DB_FILE}")
      RELOGIN_NEEDED=1
    fi
  elif dconf_db_stale "$LOOK_DB_NAME"; then
    # A run stopped before dconf update.
    compile_dconf && { STATUS_CHANGES+=("Ubuntu's defaults compiled → /etc/dconf/db/${LOOK_DB_NAME}"); RELOGIN_NEEDED=1; }
  else
    STATUS_NOCHANGE+=("Ubuntu's defaults already current")
  fi
  rm -f "$tmp"

  # Remove the database under its earlier name.
  if [ -e "/etc/dconf/db/${OLD_LOOK_DB_NAME}.d" ] || [ -e "/etc/dconf/db/${OLD_LOOK_DB_NAME}" ]; then
    sudo rm -rf "/etc/dconf/db/${OLD_LOOK_DB_NAME}.d" "/etc/dconf/db/${OLD_LOOK_DB_NAME}" \
      && STATUS_CHANGES+=("Ubuntu's defaults moved to /etc/dconf/db/${LOOK_DB_NAME}")
  fi
}

install_greeter_extension() {
  install_local_extension "$GREETER_EXT_UUID" "Login screen extension" \
    "Ubuntu look for the login screen" "Draws the login screen with Yaru, as Ubuntu does." \
    '"gdm"' << 'EOF'
import Gio from 'gi://Gio';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const STYLESHEET = '/usr/share/themes/Yaru-dark/gnome-shell/gnome-shell.css';

export default class UbuntuLookGreeter extends Extension {
    enable() {
        // Without the Yaru shell theme the greeter keeps Debian's stylesheet.
        if (!Gio.File.new_for_path(STYLESHEET).query_exists(null))
            return;
        Main.setThemeStylesheet(STYLESHEET);
        Main.loadTheme();
    }

    disable() {
        Main.setThemeStylesheet(null);
        Main.loadTheme();
    }
}
EOF
}

# Install shell extension $1 (uuid) under /usr/local. $2 labels it, $3 and $4
# are name and description, $5 its session modes; extension.js on stdin.
# It declares only the running gnome-shell major.
install_local_extension() {
  local uuid="$1" label="$2" dir="/usr/local/share/gnome-shell/extensions/$1"
  local major tmp f changed=0 failed=0
  major="$(shell_major)"
  if [ -z "$major" ]; then
    cat > /dev/null
    STATUS_FAILED+=("${label} skipped — the gnome-shell version is unknown")
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
    [ -d /usr/local/share/gnome-shell/extensions ] \
      || _made="/usr/local/share/gnome-shell/extensions"
    [ -d /usr/local/share/gnome-shell ] || _made="${_made} /usr/local/share/gnome-shell"
    sys_records_dir
    printf '%s\n' $_made | sudo tee "$LOCAL_SHELL_DIRS_FILE" > /dev/null
  fi
  for f in metadata.json extension.js; do
    if ! readable_regular_file "${dir}/${f}" || ! cmp -s "${tmp}/${f}" "${dir}/${f}" 2>/dev/null; then
      if sudo install -Dm 0644 "${tmp}/${f}" "${dir}/${f}"; then changed=1; else failed=1; fi
    fi
  done
  rm -rf "$tmp"
  if [ "$failed" -eq 1 ]; then
    STATUS_FAILED+=("${label} could not be written to ${dir}")
    return 1
  elif [ $changed -eq 1 ]; then
    STATUS_CHANGES+=("${label} → ${dir}")
  else
    STATUS_NOCHANGE+=("${label} already current")
  fi
}

# Ubuntu's shell theme: Yaru light or dark following the colour scheme, also in
# the lock screen. Moves the GTK and icon themes between Yaru and Yaru-dark;
# any other theme is left alone.
install_theme_extension() {
  install_local_extension "$THEME_EXT_UUID" "Shell theme extension" \
    "Ubuntu look" "Yaru on the desktop and the lock screen, light or dark, as on Ubuntu." \
    '"user", "unlock-dialog"' << 'EOF'
import Gio from 'gi://Gio';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// The three values of Ubuntu's session mode that make up its theme.
const SESSION = {
    themeResourceName: 'theme/Yaru/gnome-shell-theme.gresource',
    stylesheetName: 'Yaru/gnome-shell.css',
    colorScheme: 'prefer-light',
};

// Set by Ubuntu's Appearance panel along with the colour scheme.
const FOLLOWERS = ['gtk-theme', 'icon-theme'];

export default class UbuntuLookTheme extends Extension {
    enable() {
        const resource = `${global.datadir}/${SESSION.themeResourceName}`;
        if (Gio.File.new_for_path(resource).query_exists(null)) {
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
        this._schemeId = this._interface.connect('changed::color-scheme',
            () => this._syncThemes());
        this._syncThemes();
    }

    disable() {
        if (this._interface) {
            this._interface.disconnect(this._schemeId);
            this._interface = null;
        }
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

    _syncThemes() {
        const want = this._interface.get_string('color-scheme') === 'prefer-dark'
            ? 'Yaru-dark' : 'Yaru';
        for (const key of FOLLOWERS) {
            const now = this._interface.get_string(key);
            if (now === want || (now !== 'Yaru' && now !== 'Yaru-dark'))
                continue;
            if (this._interface.get_default_value(key)?.unpack() === want)
                this._interface.reset(key);
            else
                this._interface.set_string(key, want);
        }
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

# Point greeter profile $1 at the gdm database, keeping Debian's file-db line
# after it. $2 records the creation.
write_greeter_dconf_profile() {
  local name="$1" created="$2" target="/etc/dconf/profile/$1" want
  want="$(
    printf 'user-db:user\nsystem-db:gdm\n'
    if readable_regular_file "/usr/share/dconf/profile/${name}"; then
      sed -n '/^file-db:/p' "/usr/share/dconf/profile/${name}" 2>/dev/null
    fi
  )"
  # Never write through a symlink; report it instead.
  if [ -L "$target" ]; then
    message warn "${target} is a symlink — leaving it alone"
    STATUS_NOCHANGE+=("${target} is a symlink and was left alone; the login screen may not pick up the theme")
    return 0
  fi

  if [ ! -e "$target" ]; then
    sudo install -d -m 0755 /etc/dconf/profile
    # Record first, so an interrupted run still leaves a record.
    sys_records_dir
    sudo touch "$created"
    # install creates the file itself rather than opening an existing path.
    if printf '%s\n' "$want" | sudo install -m 0644 /dev/stdin "$target"; then
      STATUS_CHANGES+=("Created ${target} so the login screen reads its database")
    else
      sudo rm -f "$created"
      STATUS_FAILED+=("${target} could not be created — the login screen keeps Debian's look")
    fi
  elif [ ! -f "$target" ]; then
    message warn "${target} is not a regular file — leaving it alone"
    STATUS_NOCHANGE+=("${target} is not a regular file and was left alone; the login screen may not pick up the theme")
    return 0
  elif [ -f "$created" ] && ! printf '%s\n' "$want" | cmp -s - "$target"; then
    # Only a profile this script created is repaired.
    if printf '%s\n' "$want" | sudo install -m 0644 /dev/stdin "$target"; then
      STATUS_CHANGES+=("Repaired ${target} so the login screen reads its database")
    else
      STATUS_FAILED+=("${target} could not be repaired")
    fi
  fi
}

write_gdm_profile() {
  local wp_light="${1:-}" wp_dark="${2:-}" bg_block="" ext_block=""
  if ! is_installed gdm3; then
    STATUS_NOCHANGE+=("GDM is not installed — login screen left alone")
    return 0
  fi
  [ -f "$wp_dark" ] || wp_dark="$wp_light"

  # The login screen reads the profile of Debian's greeter user, Debian-gdm;
  # the gdm profile is written too, so the two agree.
  write_greeter_dconf_profile gdm "${SYS_RECORDS}/gdm-profile-created"
  if getent passwd Debian-gdm > /dev/null; then
    write_greeter_dconf_profile Debian-gdm "${SYS_RECORDS}/gdm-profile-Debian-gdm-created"
  fi

  # Ubuntu sets the wallpaper on the greeter as well.
  if [ -f "$wp_light" ]; then
    bg_block="
[org/gnome/desktop/background]
picture-uri='file://${wp_light}'
picture-uri-dark='file://${wp_dark}'
show-desktop-icons=false"
  fi

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

  # The theme and font values of Ubuntu's defaults, as Ubuntu's greeter has them.
  local tmp line path key value iface=""
  for line in "${GNOME_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    [ "$path" = org/gnome/desktop/interface ] || continue
    case "$key" in
      gtk-theme|accent-color|icon-theme|cursor-theme|font-name|monospace-font-name|font-antialiasing)
        iface="${iface}${key}=${value}"$'\n' ;;
    esac
  done
  tmp="$(mktemp)"
  cat << EOF > "$tmp"
# ubuntu-look.sh - login screen theme. Safe to delete.
[org/gnome/desktop/interface]
${iface%$'\n'}
${ext_block}
${bg_block}
EOF

  if readable_regular_file "$GDM_PROFILE_FILE" && cmp -s "$tmp" "$GDM_PROFILE_FILE"; then
    rm -f "$tmp"
    if dconf_db_stale gdm; then
      compile_dconf && STATUS_CHANGES+=("Login screen defaults compiled → /etc/dconf/db/gdm")
    elif [ "$_reader" -eq 1 ]; then
      STATUS_NOCHANGE+=("Login screen theme already current")
    else
      STATUS_NOCHANGE+=("${GDM_PROFILE_FILE} is current, but no greeter profile reads it — login screen unchanged")
    fi
    return 0
  fi

  if [ ! -d "$GDM_PROFILE_DIR" ]; then
    sys_records_dir; sudo touch "${SYS_RECORDS}/dconf-gdm-dir-created"
  fi
  if ! sudo install -Dm 0644 "$tmp" "$GDM_PROFILE_FILE"; then
    rm -f "$tmp"
    STATUS_FAILED+=("${GDM_PROFILE_FILE} could not be written — login screen unchanged")
    return 0
  fi
  rm -f "$tmp"
  compile_dconf || return 0
  if [ "$_reader" -eq 1 ]; then
    STATUS_CHANGES+=("Login screen themed → ${GDM_PROFILE_FILE}")
  else
    STATUS_NOCHANGE+=("${GDM_PROFILE_FILE} written, but no greeter profile reads it — login screen unchanged")
  fi
}

retire_user_theme() {
  local en name
  en="$(extension_uuids /org/gnome/shell/enabled-extensions)"
  in_word_list "$USER_THEME_UUID" "$en" || return 0
  name="$(dconf read /org/gnome/shell/extensions/user-theme/name 2>/dev/null | tr -d "'")"
  case "$name" in ''|Yaru|Yaru-dark) ;; *) return 0 ;; esac
  # Without the theme extension (GNOME Shell before 45), user-theme keeps Yaru.
  extension_installed "$THEME_EXT_UUID" || return 0
  if ! extension_active "$THEME_EXT_UUID"; then
    USER_THEME_RETIRE=1
    STATUS_CHANGES+=("user-theme is switched off at your next login — the theme extension takes its place")
    return 0
  fi
  if dconf write /org/gnome/shell/enabled-extensions \
       "$(gvariant_string_array "$(word_list_without "$en" "$USER_THEME_UUID")")" 2>/dev/null; then
    dconf reset /org/gnome/shell/extensions/user-theme/name 2>/dev/null || true
    STATUS_CHANGES+=("user-theme switched off — the theme extension carries Yaru now")
  else
    STATUS_FAILED+=("user-theme could not be switched off — it draws over the theme extension")
  fi
}

install_terminal_profile() {
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || ! command -v dconf >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("No live session — terminal colours left for the next run")
    return 0
  fi
  if ! command -v gnome-terminal >/dev/null 2>&1; then
    STATUS_NOCHANGE+=("gnome-terminal is not installed — terminal colours left alone")
    return 0
  fi

  local uuid created=0
  uuid="$(sed -n 's/^uuid=//p' "$TERMINAL_PROFILE_RECORD" 2>/dev/null | head -1 | tr -d '\r')"

  # No record: adopt a profile marked as ours, else an unmarked "Ubuntu" one
  # whose colours all match; otherwise make a new one.
  if [ -z "$uuid" ]; then
    local _cand _p _best="" _marked=""
    for _cand in $(dconf list "${TERMINAL_PROFILES}/" 2>/dev/null | sed -n 's#^:\(.*\)/$#\1#p'); do
      _p="${TERMINAL_PROFILES}/:${_cand}"
      if [ "$(dconf read "${_p}/ubuntu-look-managed" 2>/dev/null)" = true ]; then
        _marked="$_cand"
        break
      fi
      [ -n "$_best" ] && continue
      [ "$(dconf read "${_p}/visible-name" 2>/dev/null | tr -d \')" = Ubuntu ] || continue
      [ "$(dconf read "${_p}/use-theme-colors" 2>/dev/null)" = false ] || continue
      [ "$(dconf read "${_p}/background-color" 2>/dev/null | tr -d \')" = "$TERMINAL_BACKGROUND" ] || continue
      [ "$(dconf read "${_p}/foreground-color" 2>/dev/null | tr -d \')" = "$TERMINAL_FOREGROUND" ] || continue
      [ "$(dconf read "${_p}/palette" 2>/dev/null | tr -d ' ')" = "$(printf '%s' "$TERMINAL_PALETTE" | tr -d ' ')" ] || continue
      _best="$_cand"
    done
    uuid="${_marked:-$_best}"
    if [ -z "$uuid" ]; then
      uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
      if [ -z "$uuid" ]; then
        STATUS_FAILED+=("Could not generate a terminal profile id")
        return 0
      fi
      created=1
    fi
    mkdir -p "$BACKUP_DIR"
    printf 'uuid=%s\n' "$uuid" > "$TERMINAL_PROFILE_RECORD"
    [ "$created" -eq 1 ] || message "adopting the existing Ubuntu terminal profile (${uuid})"
  fi

  local base="${TERMINAL_PROFILES}/:${uuid}" changed=0 key val _write_failed=0
  for key in "ubuntu-look-managed|true" \
             "visible-name|'Ubuntu'" \
             "use-theme-colors|false" \
             "background-color|'${TERMINAL_BACKGROUND}'" \
             "foreground-color|'${TERMINAL_FOREGROUND}'" \
             "palette|${TERMINAL_PALETTE}"; do
    val="${key#*|}"; key="${key%%|*}"
    # Compared without spacing, to avoid a needless rewrite.
    [ "$(dconf read "${base}/${key}" 2>/dev/null | tr -d '[:space:]')" \
      = "$(printf '%s' "$val" | tr -d '[:space:]')" ] && continue
    if dconf write "${base}/${key}" "$val" 2>/dev/null; then changed=1; else _write_failed=1; fi
  done

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

  [ "$_write_failed" -eq 1 ] \
    && STATUS_FAILED+=("Terminal profile not fully written — dconf refused at least one key")

  if [ $changed -eq 1 ]; then
    if [ "$_made_default" -eq 1 ]; then
      STATUS_CHANGES+=("Terminal: Ubuntu profile applied and made the default")
    else
      STATUS_CHANGES+=("Terminal: Ubuntu profile applied")
    fi
    RELOGIN_NEEDED=1
  else
    [ "$_write_failed" -eq 0 ] \
      && STATUS_NOCHANGE+=("Terminal: Ubuntu profile already current")
  fi
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
  local src="" c tmp _icon_rc=0 _icon_raw=0
  remove_user_icon "$APP_GRID_ICON_OLD" \
    && STATUS_CHANGES+=("Show Applications icon moved into the Yaru theme; plain Debian sessions keep their own")
  for c in /usr/share/desktop-base/debian-logos/logo.svg \
           /usr/share/desktop-base/debian-logos/openlogo-nd.svg \
           /usr/share/desktop-base/debian-logos/openlogo.svg \
           /usr/share/desktop-base/debian-logos/logo-debian.svg \
           /usr/share/icons/hicolor/scalable/apps/debian-logo.svg \
           /usr/share/icons/hicolor/scalable/places/debian-swirl.svg; do
    [ -f "$c" ] && { src="$c"; break; }
  done

  # Fall back to any system logo without lettering.
  if [ -z "$src" ]; then
    src="$(find /usr/share/desktop-base /usr/share/icons/hicolor/scalable \
                -maxdepth 4 -iname '*logo*.svg' 2>/dev/null \
           | grep -viE 'text|version' | head -1)"
  fi

  if [ -z "$src" ]; then
    STATUS_NOCHANGE+=("No Debian logo on this system — Show Applications keeps the generic grid")
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
    _icon_raw=1
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
    if [ "$_icon_raw" -eq 1 ]; then
      STATUS_CHANGES+=("Show Applications button now uses $(basename "$src") — copied unscaled, its viewBox could not be read")
    else
      STATUS_CHANGES+=("Show Applications button now uses $(basename "$src")")
    fi
    RELOGIN_NEEDED=1
  else
    if [ "$_icon_raw" -eq 1 ]; then
      STATUS_NOCHANGE+=("Show Applications button icon already current — an unscaled copy; its viewBox could not be read")
    else
      STATUS_NOCHANGE+=("Show Applications button icon already current")
    fi
  fi
  rm -f "$tmp"
}

###############################################################################
# 4. Boot: GRUB command line and boot splash
###############################################################################

# The splash needs GRUB and update-initramfs.
has_boot_splash_tools() {
  [ -f /etc/default/grub ] && command -v update-grub >/dev/null 2>&1 \
    && command -v update-initramfs >/dev/null 2>&1
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

# Read GRUB_CMDLINE_LINUX_DEFAULT from /etc/default/grub. Prints
# "<state> <value>"; state is active (value follows), commented, absent, or
# unparsable (not safe to rewrite). Strict, because a grub file that no
# longer parses as shell breaks every later update-grub.
read_grub_cmdline() {
  local file=/etc/default/grub n line val q body rest
  # Unreadable is not absent: callers drop their record on absent.
  if [ -e "$file" ] && [ ! -r "$file" ]; then
    printf 'unparsable \n'; return 0
  fi
  [ -r "$file" ] || { printf 'absent \n'; return 0; }

  n="$(grep -cE '^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=' "$file" 2>/dev/null)"
  # Two active assignments are not safe to rewrite.
  if [ "${n:-0}" -gt 1 ]; then
    printf 'unparsable \n'; return 0
  fi
  if [ "${n:-0}" -eq 0 ]; then
    if grep -qE '^[[:space:]]*#[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=' "$file" 2>/dev/null; then
      printf 'commented \n'
    else
      printf 'absent \n'
    fi
    return 0
  fi

  line="$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=' "$file")"
  val="${line#*=}"

  # An unquoted value is one word with nothing after it; a comment or shell
  # syntax is refused.
  case "$val" in
    \"*) q='"' ;;
    \'*) q="'" ;;
    *)   rest="${val#"${val%%[[:space:]]*}"}"
         case "$val" in *"#"*|*[\;\&\|\<\>\(\)\`\$\\]*) printf 'unparsable \n'; return 0 ;; esac
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
  val="$val" awk '
    BEGIN { swapped = 0; val = ENVIRON["val"] }
    !swapped && /^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=/ {
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

  if [ ! -s "$tmp" ] || ! grep -qE '^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=' "$tmp"; then
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
  awk '!done && /^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=/ { done = 1; next } { print }' \
    /etc/default/grub > "$tmp"
  install_grub_file "$tmp"
}

# Install temporary file $1 as /etc/default/grub and run update-grub; put the
# original back if update-grub fails.
install_grub_file() {
  local tmp="$1" backup=""
  # grub-mkconfig sources the file, so it must parse as shell.
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    message warn "the rewritten /etc/default/grub would not parse as shell — leaving it alone"
    return 1
  fi

  # Kept in SYS_RECORDS, which survives a reboot.
  sys_records_dir 2>/dev/null \
    && backup="$(sudo mktemp "${SYS_RECORDS}/grub.before-failed-update-grub.XXXXXX")"
  [ -n "$backup" ] || backup="$(mktemp)" || { rm -f "$tmp"; return 1; }
  sudo cp /etc/default/grub "$backup" 2>/dev/null || { rm -f "$tmp"; sudo rm -f "$backup"; return 1; }

  sudo cp "$tmp" /etc/default/grub || { rm -f "$tmp"; sudo rm -f "$backup"; return 1; }
  rm -f "$tmp"

  if sudo update-grub; then
    sudo rm -f "$backup"
    return 0
  fi

  message warn "update-grub failed — putting /etc/default/grub back as it was"
  if sudo cp "$backup" /etc/default/grub; then
    sudo rm -f "$backup"
  else
    message warn "could not restore /etc/default/grub — the original is kept at ${backup}"
    GRUB_BACKUP_KEPT="$backup"
  fi
  return 1
}

# Remove line $1 from the grub record; with $2 = "line", also the note that
# this script added the whole line.
drop_grub_record() {
  local rec
  rec="$(mktemp)"
  grep -vxF -- "$1" "$GRUB_ADDED_FILE" > "$rec" 2>/dev/null || true
  if [ -s "$rec" ]; then sudo install -m 0644 "$rec" "$GRUB_ADDED_FILE"; else sudo rm -f "$GRUB_ADDED_FILE"; fi
  rm -f "$rec"
  [ "${2:-}" != line ] || sudo rm -f "${SYS_RECORDS}/grub-line-added"
}

rebuild_initramfs() { sudo update-initramfs -u -k all 2>/dev/null || sudo update-initramfs -u; }

# Add "quiet splash" to the kernel command line and set the Plymouth theme.
apply_boot_splash() {
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

  # A drop-in in /etc/default/grub.d is read after this file and wins.
  if grep -qsE '^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub.d/*.cfg; then
    STATUS_NOCHANGE+=("/etc/default/grub.d sets GRUB_CMDLINE_LINUX_DEFAULT — it overrides /etc/default/grub")
  fi

  # An earlier run stopped between recording its words and update-grub:
  # finish it if the file was written, else drop the record.
  local pending="${SYS_RECORDS}/grub-add-pending" pend p_line
  if [ -f "$pending" ]; then
    pend="$(sed -n 1p "$pending")"; p_line="$(sed -n 2p "$pending")"
    case " ${val//$'\t'/ } " in
      *" ${pend%% *} "*)
        if sudo update-grub; then
          sudo rm -f "$pending"; REBOOT_NEEDED=1
        else
          STATUS_FAILED+=("update-grub failed — run: sudo update-grub")
        fi ;;
      *)
        drop_grub_record "$pend" "$p_line"
        sudo rm -f "$pending" ;;
    esac
  fi

  # Add the missing words, except recorded ones the user has since removed.
  before="$(tr '\n' ' ' 2>/dev/null < "$GRUB_ADDED_FILE")"
  new="$val"
  for opt in quiet splash; do
    # Tabs separate parameters as spaces do.
    case " ${new//$'\t'/ } " in
      *" $opt "*) continue ;;
    esac
    case " $before " in
      *" $opt "*) kept_out="${kept_out:+${kept_out} }${opt}"; continue ;;
    esac
    new="${new:+${new} }${opt}"; added="${added:+${added} }${opt}"
  done

  [ -n "$kept_out" ] && STATUS_NOCHANGE+=("'${kept_out}' left off the kernel command line — you took it off after the install")

  if [ -z "$added" ]; then
    [ -z "$kept_out" ] && STATUS_NOCHANGE+=("/etc/default/grub already boots with 'quiet splash'")
  else
    message "adding '${added}' to GRUB_CMDLINE_LINUX_DEFAULT"
    # Record first; the pending note tells an interrupted run's successor
    # whether the file was written. With no active line before, the uninstall
    # removes the whole line.
    local line_marker=""
    sys_records_dir
    [ "$where" != active ] && [ ! -f "${SYS_RECORDS}/grub-line-added" ] && line_marker=line
    printf '%s\n%s\n' "$added" "$line_marker" | sudo tee "$pending" > /dev/null
    sys_record_append "$GRUB_ADDED_FILE" "$added"
    [ -z "$line_marker" ] || sudo touch "${SYS_RECORDS}/grub-line-added"
    if write_grub_cmdline "$new"; then
      sudo rm -f "$pending"
      STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"${new}\"")
      REBOOT_NEEDED=1
    else
      sudo rm -f "$pending"
      [ -n "$GRUB_BACKUP_KEPT" ] || drop_grub_record "$added" "$line_marker"
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

  local before_file="$PLYMOUTH_BEFORE_FILE"
  local current new_record=0
  current="$(plymouth_current_theme)"

  if [ -z "$current" ]; then
    STATUS_NOCHANGE+=("Could not read the current boot splash theme — left as it is")
  elif [ "$current" = "$PLYMOUTH_THEME" ]; then
    # Record it, so a later user choice is left alone.
    if [ ! -f "$before_file" ]; then
      sys_records_dir
      sys_record_write "$before_file" "$current"
      sys_record_write "${SYS_RECORDS}/plymouth-theme-set.txt" "$current"
    fi
    STATUS_NOCHANGE+=("Boot splash theme already '${PLYMOUTH_THEME}'")
  elif [ -f "$before_file" ] && [ -z "$PLYMOUTH_THEME_GIVEN" ]; then
    # Changed by the user since; a PLYMOUTH_THEME given to this run overrides.
    STATUS_NOCHANGE+=("Boot splash theme left as you set it ('${current}')")
  elif ! plymouth-set-default-theme -l 2>/dev/null | grep -qxF -- "$PLYMOUTH_THEME"; then
    STATUS_NOCHANGE+=("Boot splash theme '${PLYMOUTH_THEME}' is not installed — left as it is")
  else
    message "setting the boot splash theme to '${PLYMOUTH_THEME}'"
    if [ ! -f "$before_file" ]; then
      sys_records_dir
      sys_record_write "$before_file" "$current"
      new_record=1
    fi
    if sudo plymouth-set-default-theme "$PLYMOUTH_THEME"; then
      sys_record_write "${SYS_RECORDS}/plymouth-theme-set.txt" "$PLYMOUTH_THEME"
      if rebuild_initramfs; then
        STATUS_CHANGES+=("Boot splash theme set to '${PLYMOUTH_THEME}' (was '${current}')")
      else
        STATUS_FAILED+=("Boot splash theme changed, but the initramfs rebuild failed — run: sudo update-initramfs -u")
      fi
      REBOOT_NEEDED=1
    else
      # Drop only a record made by this attempt; an older one is the original.
      [ "$new_record" -eq 1 ] && sudo rm -f "$before_file"
      message warn "could not set the boot splash theme to '${PLYMOUTH_THEME}'"
      STATUS_FAILED+=("Boot splash theme could not be set to '${PLYMOUTH_THEME}'")
    fi
  fi
}

# Remove the recorded words from GRUB_CMDLINE_LINUX_DEFAULT; a line this
# script appended goes whole once nothing else is on it. Sets GRUB_CMDLINE_NEW.
# Returns 0 = done, 1 = words already gone, 2 = file unparsable, 3 = write failed.
strip_grub_words() {
  local added where val
  added="$(tr '\n' ' ' < "$GRUB_ADDED_FILE")"
  where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"
  [ "$where" = unparsable ] && return 2
  if ! GRUB_CMDLINE_NEW="$(grub_without_words "$val" "$added")" || [ "$where" != active ]; then
    sudo rm -f "$GRUB_ADDED_FILE" "${SYS_RECORDS}/grub-line-added"
    return 1
  fi
  message "removing '${added% }' from GRUB_CMDLINE_LINUX_DEFAULT"
  if [ -z "$GRUB_CMDLINE_NEW" ] && [ -f "${SYS_RECORDS}/grub-line-added" ]; then
    remove_grub_cmdline_line || return 3
  else
    write_grub_cmdline "$GRUB_CMDLINE_NEW" || return 3
  fi
  sudo rm -f "$GRUB_ADDED_FILE" "${SYS_RECORDS}/grub-line-added"
  return 0
}

# UBUNTU_BOOT_SPLASH=0: remove the recorded words from the kernel command line
# and restore the previous Plymouth theme.
revert_boot_splash() {
  local before_file="$PLYMOUTH_BEFORE_FILE" added

  if [ -f "$GRUB_ADDED_FILE" ]; then
    added="$(tr '\n' ' ' < "$GRUB_ADDED_FILE")"
    strip_grub_words
    case $? in
      0) STATUS_CHANGES+=("/etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\"")
         REBOOT_NEEDED=1 ;;
      1) STATUS_NOCHANGE+=("/etc/default/grub no longer carries what this script added") ;;
      2) message warn "/etc/default/grub is not in a shape this script will edit — leaving it alone"
         STATUS_NOCHANGE+=("/etc/default/grub left alone — remove '${added% }' by hand if you want it gone") ;;
      *) STATUS_FAILED+=("/etc/default/grub could not be updated — '${added% }' is still on the kernel command line")
         [ -n "$GRUB_BACKUP_KEPT" ] \
           && STATUS_FAILED+=("the file as it was before that attempt is at ${GRUB_BACKUP_KEPT}") ;;
    esac
  else
    STATUS_NOCHANGE+=("Nothing of this script's is on the kernel command line")
  fi

  # Restore the previous theme, unless the user has chosen another since.
  if command -v plymouth-set-default-theme >/dev/null 2>&1 && [ -f "$before_file" ]; then
    local was current set_theme
    was="$(cat "$before_file" 2>/dev/null)"
    current="$(plymouth_current_theme)"
    set_theme="$(head -1 "${SYS_RECORDS}/plymouth-theme-set.txt" 2>/dev/null)"
    if [ -n "$was" ] && [ "$was" != "$current" ] && [ "$current" = "${set_theme:-$PLYMOUTH_THEME}" ]; then
      if ! sudo plymouth-set-default-theme "$was"; then
        message warn "could not set the Plymouth theme back to '${was}' — it may no longer be installed"
        STATUS_FAILED+=("Boot splash theme still not '${was}' — the record is kept at ${before_file}")
        return 0
      fi
      if rebuild_initramfs; then
        STATUS_CHANGES+=("Boot splash theme restored to '${was}'")
      else
        STATUS_FAILED+=("Boot splash theme restored to '${was}', but the initramfs rebuild failed — run: sudo update-initramfs -u")
      fi
      REBOOT_NEEDED=1
    fi
    sudo rm -f "$before_file" "${SYS_RECORDS}/plymouth-theme-set.txt"
  fi
}

###############################################################################
# 5. Records: migration, daily refresh, summary
###############################################################################

# Move the system records that earlier versions kept in the user's
# home into SYS_RECORDS.
migrate_home_records() {
  local legacy dest tmp p f legacy_manifest=0 found=0
  [ -d "$BACKUP_DIR" ] || return 0
  for f in "${BACKUP_DIR}"/{installed,removed,upgraded}-by-script.txt \
           "${BACKUP_ORIGINAL}"/{grub-cmdline-added.txt,packages-before.txt,plymouth-theme-before.txt} \
           "${BACKUP_ORIGINAL}"/gdm-profile{,-Debian-gdm}-created; do
    [ -f "$f" ] && { found=1; break; }
  done
  [ "$found" -eq 1 ] || return 0
  tmp="$(mktemp)"
  # Plain lists: merged with the system record.
  for legacy in "${BACKUP_DIR}/installed-by-script.txt" "${BACKUP_DIR}/removed-by-script.txt" \
                "${BACKUP_ORIGINAL}/grub-cmdline-added.txt"; do
    [ -f "$legacy" ] && [ ! -L "$legacy" ] || continue
    dest="${SYS_RECORDS}/${legacy##*/}"
    [ "$dest" = "$INSTALLED_MANIFEST" ] && legacy_manifest=1
    cat "$legacy" "$dest" 2>/dev/null | sed '/^$/d' | sort -u > "$tmp"
    move_to_sys_record "$tmp" "$dest" "$legacy"
  done
  # The first entry per package holds the original version.
  legacy="${BACKUP_DIR}/upgraded-by-script.txt"
  if [ -f "$legacy" ] && [ ! -L "$legacy" ]; then
    cat "$UPGRADED_MANIFEST" "$legacy" 2>/dev/null | awk 'NF && !seen[$1]++' | sort > "$tmp"
    move_to_sys_record "$tmp" "$UPGRADED_MANIFEST" "$legacy"
  fi
  # A package predates the install only if every snapshot has it.
  legacy="${BACKUP_ORIGINAL}/packages-before.txt"
  if [ -f "$legacy" ] && [ ! -L "$legacy" ]; then
    if [ -f "$PACKAGES_BEFORE" ]; then
      sort "$legacy" | comm -12 - <(sort "$PACKAGES_BEFORE") > "$tmp"
    else
      sort "$legacy" > "$tmp"
    fi
    move_to_sys_record "$tmp" "$PACKAGES_BEFORE" "$legacy"
  fi
  # An existing system record is the older, original theme.
  legacy="${BACKUP_ORIGINAL}/plymouth-theme-before.txt"
  if [ -f "$legacy" ] && [ ! -L "$legacy" ]; then
    if [ -f "$PLYMOUTH_BEFORE_FILE" ]; then
      rm -f "$legacy"
    else
      move_to_sys_record "$legacy" "$PLYMOUTH_BEFORE_FILE" "$legacy"
    fi
  fi
  for f in gdm-profile-created gdm-profile-Debian-gdm-created; do
    [ -f "${BACKUP_ORIGINAL}/${f}" ] || continue
    sys_records_dir; sudo touch "${SYS_RECORDS}/${f}" && rm -f "${BACKUP_ORIGINAL}/${f}"
  done
  if [ "$legacy_manifest" -eq 1 ] && [ -f "$PACKAGES_BEFORE" ]; then
    for p in $LEGACY_STAGE_PACKAGES; do
      is_installed "$p" || continue
      grep -qxF "$p" "$PACKAGES_BEFORE" "$INSTALLED_MANIFEST" 2>/dev/null && continue
      sys_record_append "$INSTALLED_MANIFEST" "$p"
    done
  fi
  # These records came from this home, so this user has the look.
  grep -qxF "$(id -un)" "$SYS_USERS" 2>/dev/null || sys_record_append "$SYS_USERS" "$(id -un)"
  rm -f "$tmp"
}

# What the refresh compares: Debian, gnome-shell, architecture, options and
# the Ubuntu releases.
refresh_fingerprint() {
  local pinned pinned_ver configured
  echo "debian $(debian_codename)"
  echo "shell $(shell_major)"
  echo "arch ${UBUNTU_ARCH}"
  # A new pin format counts as a change.
  echo "format ${PIN_VERSION}"
  sed -n 's/^\([A-Z_]*=.*\)$/option \1/p' "$SAVED_OPTIONS" 2>/dev/null
  pinned="$(pinned_codename)"
  pinned_ver="$(awk -v c="$pinned" '$1 == c { print $2; exit }' "$UBUNTU_RELEASE_CACHE" 2>/dev/null)"
  configured=" $(configured_codenames | xargs) "
  # "newer" only for listed releases: a refresh does not probe retired ones.
  awk -v conf="$configured" -v known=" ${UBUNTU_ALL_CODENAMES:-} " -v pv="${pinned_ver:-0}" '
    index(conf, " " $1 " ")                            { print "configured", $1, $4 }
    index(known, " " $1 " ") && ($2 + 0) > (pv + 0)    { print "newer", $1, $3 }
  ' "$UBUNTU_RELEASE_CACHE" 2>/dev/null
}

# True when nothing changed since the last full run; sets KEPT_CODENAME.
unchanged_since_last_run() {
  local pinned tmp rc=1
  [ -f "$UBUNTU_LIST" ] && readable_regular_file "$REFRESH_STATE" || return 1
  # Only when the last full run also chose automatically.
  grep -qx 'UBUNTU_CODENAME=auto' "$SAVED_OPTIONS" 2>/dev/null || return 1
  grep -q "# pin-version: ${PIN_VERSION}" "$UBUNTU_PIN" 2>/dev/null || return 1
  pinned="$(pinned_codename)"
  [ -n "$pinned" ] && configured_codenames | grep -qxF "$pinned" || return 1
  tmp="$(fingerprint_file)"
  cmp -s "$tmp" "$REFRESH_STATE" && { KEPT_CODENAME="$pinned"; rc=0; }
  rm -f "$tmp"
  return $rc
}

# The current fingerprint in a new temporary file; prints its path.
fingerprint_file() {
  local tmp
  tmp="$(mktemp)" && refresh_fingerprint | sort -u > "$tmp" && echo "$tmp"
}

# Save the fingerprint that later runs and the refresh timer compare against.
save_refresh_state() {
  local tmp
  tmp="$(fingerprint_file)"
  if ! { readable_regular_file "$REFRESH_STATE" && cmp -s "$tmp" "$REFRESH_STATE"; }; then
    sudo install -Dm 0644 "$tmp" "$REFRESH_STATE" || true
  fi
  sudo rm -f "$REFRESH_ATTEMPT"
  rm -f "$tmp"
}

# True when release $1 is in the release cache.
release_cached() {
  awk -v c="$1" '$1 == c { f = 1 } END { exit !f }' "$UBUNTU_RELEASE_CACHE"
}

# In --refresh mode: exit here unless something relevant has changed.
refresh_gate() {
  [ "$REFRESH" = 1 ] || return 0
  local cn tmp
  # A timer left by an earlier version, which had it on by default.
  if [ "${UBUNTU_LOOK_AUTO_REFRESH:-0}" != 1 ]; then
    message "the daily refresh was not chosen (UBUNTU_LOOK_AUTO_REFRESH=1) — removing it"
    remove_refresh_timer || true
    REFRESH_NOOP=1
    exit 0
  fi
  # Finish a compile an earlier run left undone.
  if dconf_db_stale "$LOOK_DB_NAME" || dconf_db_stale gdm; then
    compile_dconf || message warn "dconf update failed — the look's defaults may be out of date"
  fi
  # A release that did not answer is a network problem, never a retirement.
  for cn in $(configured_codenames) \
            $(awk '$1 == "newer" { print $2 }' "$REFRESH_STATE" 2>/dev/null); do
    # A release not probed yet (no longer listed) is probed now.
    release_cached "$cn" || ubuntu_mirror_for "$cn" >/dev/null 2>&1
    if ! release_cached "$cn"; then
      message warn "Ubuntu '${cn}' did not answer — trying again at the next refresh"
      REFRESH_NOOP=1
      exit 0
    fi
  done
  tmp="$(fingerprint_file)"
  if readable_regular_file "$REFRESH_STATE" && cmp -s "$tmp" "$REFRESH_STATE"; then
    rm -f "$tmp"
    message "no new Ubuntu release, no archive move, no gnome-shell change — nothing to do"
    REFRESH_NOOP=1
    exit 0
  fi
  # The same change tried within the last week and not finished: wait.
  if readable_regular_file "$REFRESH_ATTEMPT" && cmp -s "$tmp" "$REFRESH_ATTEMPT" \
     && [ -n "$(find "$REFRESH_ATTEMPT" -mtime -7 2>/dev/null)" ]; then
    rm -f "$tmp"
    message warn "the last refresh for this change did not finish — retrying it weekly; see: journalctl -u ubuntu-look-refresh"
    REFRESH_NOOP=1
    exit 0
  fi
  message "the releases this look was resolved against have changed:"
  diff "$REFRESH_STATE" "$tmp" 2>/dev/null | sed -n 's/^[<>] /  /p'
  sudo install -Dm 0644 "$tmp" "$REFRESH_ATTEMPT"
  rm -f "$tmp"
}

# Install the daily refresh with UBUNTU_LOOK_AUTO_REFRESH=1; otherwise remove it.
install_refresh_timer() {
  if [ "${UBUNTU_LOOK_AUTO_REFRESH:-0}" = "0" ]; then
    if remove_refresh_timer; then
      STATUS_CHANGES+=("Daily refresh timer removed — apt changes only when you run this script (UBUNTU_LOOK_AUTO_REFRESH=1 for a timer)")
    else
      STATUS_NOCHANGE+=("No daily refresh timer — re-run this script after a Debian release upgrade (UBUNTU_LOOK_AUTO_REFRESH=1 for a timer)")
    fi
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    STATUS_NOCHANGE+=("No systemd — re-run this script after Ubuntu or Debian releases")
    return 0
  fi
  # Started from a pipe or process substitution: there is no file to copy.
  if [ ! -f "${BASH_SOURCE[0]}" ]; then
    STATUS_NOCHANGE+=("Daily refresh timer not installed — run the script from a file")
    return 0
  fi

  local tmp changed=0 exec_start="/bin/bash ${REFRESH_SCRIPT} --refresh"
  tmp="$(mktemp)"
  if ! { readable_regular_file "$REFRESH_SCRIPT" && cmp -s "${BASH_SOURCE[0]}" "$REFRESH_SCRIPT"; }; then
    sudo install -Dm 0755 "${BASH_SOURCE[0]}" "$REFRESH_SCRIPT" && changed=1
  fi

  cat << EOF > "$tmp"
# Written by ubuntu-look.sh; removed by 'ubuntu-look.sh --uninstall'.
[Unit]
Description=Keep the Ubuntu look on the newest Ubuntu release this Debian can run
Wants=network-online.target
After=network-online.target apt-daily.service apt-daily-upgrade.service
# Guards against a unit left without the pin or the script.
ConditionPathExists=${UBUNTU_PIN}
ConditionPathExists=${REFRESH_SCRIPT}

[Service]
Type=oneshot
Environment=UBUNTU_LOOK_LOG=0
ExecStart=${exec_start}
Nice=19
CPUSchedulingPolicy=batch
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=2h
# On stop, let a running dpkg finish.
KillMode=process
TimeoutStopSec=15min
EOF
  if ! { readable_regular_file "$REFRESH_SERVICE" && cmp -s "$tmp" "$REFRESH_SERVICE"; }; then
    sudo install -m 0644 "$tmp" "$REFRESH_SERVICE" && changed=1
  fi

  cat << 'EOF' > "$tmp"
# Written by ubuntu-look.sh; removed by 'ubuntu-look.sh --uninstall'.
[Unit]
Description=Daily check for Ubuntu and Debian releases that affect the Ubuntu look

[Timer]
OnCalendar=daily
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  if ! { readable_regular_file "$REFRESH_TIMER" && cmp -s "$tmp" "$REFRESH_TIMER"; }; then
    sudo install -m 0644 "$tmp" "$REFRESH_TIMER" && changed=1
  fi
  rm -f "$tmp"

  [ "$changed" -eq 1 ] && sudo systemctl daemon-reload
  if ! systemctl is-enabled --quiet ubuntu-look-refresh.timer 2>/dev/null \
     || ! systemctl is-active --quiet ubuntu-look-refresh.timer 2>/dev/null; then
    if sudo systemctl enable --now ubuntu-look-refresh.timer >/dev/null 2>&1; then
      changed=1
    else
      STATUS_FAILED+=("Daily refresh timer could not be enabled — see: systemctl status ubuntu-look-refresh.timer")
      return 0
    fi
  fi

  if [ "$changed" -eq 1 ]; then
    STATUS_CHANGES+=("Daily refresh timer in place — follows Ubuntu and Debian releases on its own")
  else
    STATUS_NOCHANGE+=("Daily refresh timer already in place")
  fi
}

# Returns 0 when something was removed. The uninstall records are kept.
# Remove the timer, its service and its copy of the script. The fingerprint
# stays for later runs. Returns 0 when a timer was there.
remove_refresh_timer() {
  local removed=1
  if [ -f "$REFRESH_TIMER" ] || [ -f "$REFRESH_SERVICE" ]; then
    sudo systemctl disable --now ubuntu-look-refresh.timer >/dev/null 2>&1 || true
    sudo rm -f "$REFRESH_TIMER" "$REFRESH_SERVICE"
    sudo systemctl daemon-reload 2>/dev/null || true
    removed=0
  fi
  sudo rm -rf "$REFRESH_LIB_DIR"
  sudo rm -f "$REFRESH_ATTEMPT"
  return $removed
}

# Log what is installed, the pinned release and the extension and terminal state.
log_final_state() {
  local p e state v

  echo ""
  echo "--- state after this run ---"
  for p in $ALL_STAGE_PACKAGES; do
    printf '  %-46s %s\n' "$p" "$(pkg_installed_version "$p" || echo 'not installed')"
  done
  v="$(pkg_installed_version "$COMBINED_EXT_PKG")" \
    && printf '  %-46s %s\n' "$COMBINED_EXT_PKG" "$v"

  echo "  pin            : $(grep -m1 '^Pin: release o=Ubuntu, n=' "$UBUNTU_PIN" 2>/dev/null || echo 'none')"
  # Root's dconf says nothing about the user's desktop.
  [ "$REFRESH" = 1 ] && { echo "--- end of state ---"; return 0; }
  echo "  enabled-ext    : $(dconf_show /org/gnome/shell/enabled-extensions)"
  echo "  disabled-ext   : $(dconf_show /org/gnome/shell/disabled-extensions)"
  for e in $SHELL_EXTENSIONS; do
    # The running shell knows only the extensions present at login.
    state="$(LC_ALL=C gnome-extensions info "$e" 2>/dev/null | awk -F': ' '/State/{print $2}')"
    if [ -z "$state" ]; then
      if extension_installed "$e"; then state="loads at the next login"; else state="not installed"; fi
    fi
    printf '  %-46s %s\n' "$e" "$state"
  done

  echo "  plymouth theme : $(plymouth_current_theme)"
  echo "  kernel cmdline : $(read_grub_cmdline)"
  echo "  gtk-theme      : $(dconf_show /org/gnome/desktop/interface/gtk-theme)"
  echo "  term profile   : $(dconf_show /org/gnome/terminal/legacy/profiles:/default)"
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

print_summary() {
  local rc=$?
  # A refresh with nothing to do reports one line.
  [ "${REFRESH_NOOP:-0}" = 1 ] && [ $rc -eq 0 ] && return 0
  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  echo -e "${GREEN}                        SUMMARY${ENDCOLOR}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"

  summary_block "$GREEN"  "Installed this run (${#STATUS_INSTALLED[@]}):" + "" "${STATUS_INSTALLED[@]}"
  summary_block "$GREEN"  "Upgraded this run (${#STATUS_UPGRADED[@]}):" "^" "" "${STATUS_UPGRADED[@]}"
  summary_block "$YELLOW" "Already installed and current (${#STATUS_ALREADY[@]}):" = "" "${STATUS_ALREADY[@]}"
  summary_block "$YELLOW" "Kept at the last compatible build (${#STATUS_HELD[@]}):" = \
    "A newer Ubuntu build exists but will not install on this Debian — what you have is the newest that fits." \
    "${STATUS_HELD[@]}"
  summary_block "$RED" "Not in the bundle — skipped (${#STATUS_UNAVAIL[@]}):" "!" \
    "Refresh it on an online machine: bash ubuntu-look.sh --download" "${STATUS_UNAVAIL[@]}"
  summary_block "$RED" "Not done (${#STATUS_FAILED[@]}):" "!" \
    "Everything else was applied. Each line gives the reason." "${STATUS_FAILED[@]}"
  summary_block "$RED" "Extensions the setting did not reach (${#STATUS_EXT_FAILED[@]}):" "!" \
    "Writing enabled-extensions needs a live GNOME session; run this from your desktop, not over SSH." \
    "${STATUS_EXT_FAILED[@]}"
  summary_block "$GREEN"  "Configuration changes:" + "" "${STATUS_CHANGES[@]}"
  summary_block "$YELLOW" "Already in place (no change):" = "" "${STATUS_NOCHANGE[@]}"

  echo ""
  if [ $((GSETTINGS_UNCHANGED + GSETTINGS_KEPT)) -gt 0 ]; then
    echo -e "GNOME settings: ${GREEN}${GSETTINGS_UNCHANGED} answered by the system profile${ENDCOLOR}, ${YELLOW}${GSETTINGS_KEPT} left on your own value${ENDCOLOR}"
    echo ""
  fi
  [ ${#SETTINGS_KEPT[@]} -gt 0 ] && {
    echo -e "${YELLOW}Your own settings, kept as they are (${#SETTINGS_KEPT[@]}):${ENDCOLOR}"
    printf '   = %s\n' "${SETTINGS_KEPT[@]}"
    echo -e "   ${YELLOW}Ubuntu's value is the system default; yours overrides it. 'dconf reset <key>' takes Ubuntu's.${ENDCOLOR}"
    echo ""
  }

  log_final_state

  if [ $rc -ne 0 ]; then
    echo -e "${RED}✗  Script exited with errors (rc=$rc). See ERROR line above.${ENDCOLOR}"
  elif [ $REBOOT_NEEDED -eq 1 ]; then
    echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for GRUB / Plymouth changes."
    echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
  elif [ $RELOGIN_NEEDED -eq 1 ]; then
    echo -e "${YELLOW}⚠  Log out and back in${ENDCOLOR} so the new theme + extensions fully apply."
    echo -e "   The system defaults are already compiled; one new login applies them."
  elif [ ${#STATUS_CHANGES[@]} -gt 0 ]; then
    echo -e "${GREEN}✓  Done — no re-login needed.${ENDCOLOR}"
  else
    echo -e "${GREEN}✓  Nothing changed — system was already in Ubuntu-look state.${ENDCOLOR}"
  fi
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
}

# Cleanup must preserve the exit status for print_summary.
_on_exit() {
  local rc=$?
  rm -f "${UBUNTU_RELEASE_CACHE:-}" "${LOCAL_LIST:-}"
  rm -rf "$PARTIAL_DIR"
  # Ending the inhibitor's child ends the inhibitor.
  if [ -n "${INHIBIT_PID:-}" ]; then
    pkill -P "$INHIBIT_PID" 2>/dev/null
    kill "$INHIBIT_PID" 2>/dev/null
  fi
  return $rc
}

# Make the refresh timer re-evaluate the state this script left.
invalidate_refresh_state() {
  [ ! -e "$REFRESH_STATE" ] || sudo rm -f "$REFRESH_STATE"
}

###############################################################################
# 6. Offline: --download, --offline, --prepare-upgrade
###############################################################################

# Take foreign packages off before a release upgrade; a re-run restores the look.
prepare_debian_upgrade() {
  local pkg drop=""

  message "Preparing this system for a Debian release upgrade."
  message ""
  message "This removes the Ubuntu apt source, the pin, the refresh timer (if any) and"
  message "the packages tied to the running gnome-shell. The Yaru GTK and icon themes,"
  message "the fonts and the wallpapers stay, so the desktop keeps its look during the upgrade."
  message ""
  confirm_continue
  sudo -v || error "sudo is required."
  take_run_lock wait || error "Could not take the run lock ${UBUNTU_LOOK_LOCK}."

  # Without the Ubuntu source, the version string tells Ubuntu builds apart.
  local origin_test=apt
  if [ ! -f "$UBUNTU_LIST" ]; then
    origin_test=version
    message warn "the Ubuntu apt source is already gone — going by version strings instead"
  fi

  for pkg in $UBUNTU_SHELL_EXT_PKGS yaru-theme-gnome-shell; do
    is_installed "$pkg" || continue
    if [ "$origin_test" = apt ]; then
      pkg_origin_is_ubuntu "$pkg" && drop="${drop} ${pkg}"
    else
      case "$(pkg_installed_version "$pkg")" in
        *ubuntu*) drop="${drop} ${pkg}" ;;
      esac
    fi
  done
  drop="$(echo "$drop" | xargs)"

  if [ -n "$drop" ]; then
    # Simulated first; anything more it would take needs confirmation.
    local _rm_sim _rm_extra
    # shellcheck disable=SC2086
    _rm_sim="$(LC_ALL=C apt-get -s remove $drop 2>&1)" \
      || error "apt cannot remove ${drop} — resolve that before upgrading Debian."
    _rm_extra="$(printf '%s\n' "$_rm_sim" | awk '/^Remv /{print $2}' \
                 | grep -vxF -e "${drop// /$'\n'}" | xargs)"
    if [ -n "$_rm_extra" ]; then
      message warn "removing those would also take: ${_rm_extra}"
      confirm_continue
    fi

    message "removing gnome-shell-coupled Ubuntu packages: ${drop}"
    # Recorded so the uninstall reinstalls Debian's builds.
    # shellcheck disable=SC2086
    sudo apt-get remove -y $drop \
      || error "Could not remove ${drop} — resolve that before upgrading Debian."
    for pkg in $drop; do sys_record_append "$REMOVED_FOR_UPGRADE" "$pkg"; done
    STATUS_CHANGES+=("Removed gnome-shell-coupled Ubuntu packages: ${drop}")
  else
    message "no gnome-shell-coupled Ubuntu packages installed"
  fi

  # The keyring stays: no source names it now, and a re-run needs it.
  local f removed_cfg=0
  for f in "$UBUNTU_LIST" "$UBUNTU_PIN"; do
    [ -f "$f" ] || continue
    sudo rm -f "$f"; removed_cfg=1
    STATUS_CHANGES+=("Removed ${f}")
  done
  # Saved copies from an interrupted --download would bring them back.
  sudo rm -rf "$DOWNLOAD_SAVED"
  if [ -f "$OFFLINE_LOCAL_LIST" ]; then
    sudo rm -f "$OFFLINE_LOCAL_LIST"; removed_cfg=1
    STATUS_CHANGES+=("Removed the leftover offline bundle apt source")
  fi

  # Otherwise the refresh would restore the sources mid-upgrade.
  remove_refresh_timer && STATUS_CHANGES+=("Removed the daily refresh timer; a later run with UBUNTU_LOOK_AUTO_REFRESH=1 restores it")
  remove_unattended_origins

  [ "$removed_cfg" -eq 1 ] && { sudo apt-get update || message warn "apt update reported an error"; }

  message ""
  local codename
  codename="$(debian_codename)"
  message "${GREEN}Done.${ENDCOLOR} The Ubuntu source, pin and shell-tied packages are removed; the rest of the look stays. Now:"
  message "  1. point your Debian sources at the new release: replace '${codename:-<current codename>}'"
  message "     with the next codename in /etc/apt/sources.list and /etc/apt/sources.list.d/*"
  message "  2. sudo apt update && sudo apt full-upgrade     # the Debian release upgrade"
  message "  3. reboot"
  message "  4. bash ubuntu-look.sh                          # restores the Ubuntu look"
  message ""
  message "Step 4 re-resolves everything against the new gnome-shell."
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

bundle_discard_restore() {
  local f rel
  [ -d "$DISCARD_DIR" ] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"$DISCARD_DIR"/}"
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

# Move builds of $1 in $2 other than version $3 out of the bundle.
drop_superseded() {
  local f keep rc=1
  keep="$(bundle_has_version "$1" "$2" "$3")" || return 1
  while read -r f; do
    [ -n "$f" ] && [ "$f" != "$keep" ] || continue
    bundle_discard "$f" && rc=0
  done < <(bundle_debs "$1" "$2")
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

# Candidate version of $1 as a clean machine would get it; empty if none.
clean_candidate() {
  LC_ALL=C apt-cache "${CLEAN_APT_OPTS[@]}" policy "$1" 2>/dev/null \
    | awk '/^  Candidate:/ { if ($2 != "(none)") print $2; exit }'
}

# Download $1 at version $2 into $3, checked against the archive's SHA256;
# one retry. Sets FETCHED_DEB.
fetch_deb() {
  local pkg="$1" ver="$2" dest="$3" f sums try
  FETCHED_DEB=""
  sums="$(LC_ALL=C apt-cache show "${pkg}=${ver}" 2>/dev/null | awk '/^SHA256:/ { print $2 }')"
  for try in 1 2; do
    rm -rf "$PARTIAL_DIR"
    mkdir -p "$PARTIAL_DIR" "$dest" || return 1
    ( cd "$PARTIAL_DIR" && apt-get download "${pkg}=${ver}" > /dev/null 2>&1 ) || continue
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
  local tmp raw f bundle_mirror
  tmp="$(mktemp "${PACKAGES_DIR}/.Packages.XXXXXX")" || return 1
  if command -v apt-ftparchive > /dev/null 2>&1; then
    raw="$(cd "$PACKAGES_DIR" && apt-ftparchive packages . 2>/dev/null)" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$raw" | awk -v RS= -v ORS='\n\n' '
      { fn = $0; sub(/^(.*\n)?Filename: /, "", fn); sub(/\n.*/, "", fn); sub(/^\.\//, "", fn)
        if (fn !~ /\//) print }' > "$tmp"
  else
    for f in "$PACKAGES_DIR"/*.deb; do
      [ -f "$f" ] || continue
      dpkg-deb -f "$f" > "${tmp}.one" 2>/dev/null || continue
      sed '/^$/d' "${tmp}.one"
      printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' "${f##*/}" \
        "$(stat -c %s "$f")" "$(sha256sum < "$f" | cut -d' ' -f1)"
    done > "$tmp"
    rm -f "${tmp}.one"
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
  } > "$BUNDLE_INFO"
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

discard_saved_apt_files() {
  sudo rm -rf "$DOWNLOAD_SAVED"
  sudo rmdir "$SYS_DIR" 2>/dev/null || true
}

# Put back the apt files a killed --download left changed.
restore_stale_apt_files() {
  [ -d "$DOWNLOAD_SAVED" ] || return 0
  local f saved
  for f in "$UBUNTU_LIST" "$UBUNTU_PIN"; do
    saved="${DOWNLOAD_SAVED}/${f##*/}"
    if [ -f "$saved" ]; then
      restore_apt_file "$saved" "$f" || return 1
    elif [ -e "${saved}.absent" ]; then
      restore_apt_file absent "$f" || return 1
    fi
  done
  message warn "an earlier bundle build was stopped — the apt files it changed are put back"
  discard_saved_apt_files
}

# Put apt file $2 back as save_apt_file found it ($1). Returns 1 on failure.
restore_apt_file() {
  case "$1" in
    "") return 0 ;;
    absent) [ -e "$2" ] || return 0; sudo rm -f "$2" ;;
    *) [ -f "$1" ] || return 0
       cmp -s "$1" "$2" 2>/dev/null || sudo install -m 0644 "$1" "$2" ;;
  esac
}

# --download's exit: put the Ubuntu source and pin back, and keep the index in
# step with the .debs. An unfinished run undoes its bundle changes.
_download_exit() {
  local rc=$? f n pkg a added restored=1
  # A second Ctrl-C must not cut the clean-up short.
  trap '' INT HUP TERM
  # Copies not put back stay in DOWNLOAD_SAVED for the next run.
  restore_apt_file "$PREV_PIN_FILE" "$UBUNTU_PIN" \
    || { restored=0; message warn "could not put back ${UBUNTU_PIN} — the next --download retries"; }
  restore_apt_file "$PREV_LIST_FILE" "$UBUNTU_LIST" \
    || { restored=0; message warn "could not put back ${UBUNTU_LIST} — the next --download retries"; }
  [ "$restored" = 1 ] && [ "$DOWNLOAD_DONE" = 1 ] \
    && message "this machine's Ubuntu apt source and pin are put back as they were"
  [ "$restored" = 1 ] && [ -n "${PREV_LIST_FILE}${PREV_PIN_FILE}" ] && discard_saved_apt_files
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    pkill -P "$SUDO_KEEPALIVE_PID" 2>/dev/null
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  fi
  rm -rf "$PARTIAL_DIR" "${BUILD_PREFS_DIR:-}"
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
    if [ "$DOWNLOAD_DONE" = 1 ]; then write_bundle_index; else write_bundle_index index-only; fi \
      || message warn "could not rewrite ${PACKAGES_DIR}/Packages"
  fi
  rm -f "${UBUNTU_RELEASE_CACHE:-}"
  return $rc
}

download_mode() {
  [ "$(id -u)" -eq 0 ] && error "Do not run as root. Run as a normal user with sudo rights."

  message "Building or refreshing the offline bundle at ${GREEN}${PACKAGES_DIR}${ENDCOLOR}"
  message warn "This needs internet access. Ubuntu's archive is added to apt for the build"
  message warn "and this machine's Ubuntu source and pin are put back as they were afterwards."
  confirm_continue
  sudo -v || error "User ${RUN_USER} cannot use sudo."
  # Keep sudo alive for the long download.
  ( while sleep 60 && kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || exit 0; done ) \
    > /dev/null 2>&1 9>&- &
  SUDO_KEEPALIVE_PID=$!
  take_run_lock wait || error "Could not take the run lock ${UBUNTU_LOOK_LOCK}."
  [ -f "$OFFLINE_LOCAL_LIST" ] && sudo rm -f "$OFFLINE_LOCAL_LIST"
  migrate_home_records

  trap '_download_exit' EXIT
  trap 'echo ""; message warn "interrupted — stopping here"; exit 130' INT
  trap 'exit 129' HUP; trap 'exit 143' TERM
  restore_stale_apt_files || error "Could not put back what an earlier --download changed (${DOWNLOAD_SAVED})"
  mkdir -p "$PACKAGES_DIR" || error "Cannot create ${PACKAGES_DIR}"
  rm -rf "$PARTIAL_DIR"

  record_packages_before

  # Generic tools, not recorded: uninstall keeps them.
  local _missing_prereqs prereq
  _missing_prereqs="$(missing_packages "curl ca-certificates")"
  if [ -n "$_missing_prereqs" ]; then
    sudo apt-get update -qq || message warn "apt update reported an error"
    for prereq in $_missing_prereqs; do
      installs_cleanly "$prereq" \
        || error "Installing prerequisite ${prereq} would remove packages or cannot be done — install it by hand"
      sudo apt-get install -y "$prereq" < /dev/null \
        || error "Failed to install prerequisite: $prereq"
      message "installed prerequisite ${prereq} (kept on uninstall)"
      STATUS_CHANGES+=("Installed prerequisite: $prereq (kept on uninstall)")
    done
  fi

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
  message "reading published Ubuntu releases from ${UBUNTU_MIRROR}..."
  UBUNTU_ALL_CODENAMES="$(discover_ubuntu_codenames)"
  [ -z "$UBUNTU_ALL_CODENAMES" ] && error "No Ubuntu release reachable at ${UBUNTU_MIRROR} — check your internet connection."
  UBUNTU_CANDIDATE_CODENAMES="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' \
    | tail -n "$MAX_UBUNTU_CANDIDATES" | xargs)"

  # A requested UBUNTU_CODENAME is configured even outside that window.
  [ "$REQUESTED_CODENAME" = auto ] || [[ "$REQUESTED_CODENAME" =~ ^[a-z]+$ ]] \
    || error "UBUNTU_CODENAME must be a codename in lower case letters, or auto."
  if [ "$REQUESTED_CODENAME" != auto ] && ! in_word_list "$REQUESTED_CODENAME" "$UBUNTU_CANDIDATE_CODENAMES"; then
    ubuntu_release_info "$REQUESTED_CODENAME" >/dev/null \
      || error "UBUNTU_CODENAME=${REQUESTED_CODENAME} is not published on ${UBUNTU_MIRROR} or ${UBUNTU_OLD_MIRROR}"
    UBUNTU_CANDIDATE_CODENAMES="$UBUNTU_CANDIDATE_CODENAMES $REQUESTED_CODENAME"
  fi
  message "candidate Ubuntu releases (oldest to newest): ${UBUNTU_CANDIDATE_CODENAMES}"

  step "Configure Ubuntu archive apt sources"
  if ! is_installed ubuntu-keyring; then
    sudo apt-get update -qq || message warn "apt update reported an error"
    installs_cleanly ubuntu-keyring && apt_install_recorded ubuntu-keyring >/dev/null \
      || error "Could not install Debian's ubuntu-keyring package (Ubuntu's archive keys)."
    STATUS_CHANGES+=("Installed ubuntu-keyring (Ubuntu's archive keys, from Debian)")
  fi
  [ -s "$UBUNTU_KEYRING" ] || error "${UBUNTU_KEYRING} is missing — reinstall ubuntu-keyring."

  # Kept so the source list and pin can be restored.
  PREV_LIST_FILE="$(save_apt_file "$UBUNTU_LIST")" || error "Could not save ${UBUNTU_LIST}"
  PREV_PIN_FILE="$(save_apt_file "$UBUNTU_PIN")" || error "Could not save ${UBUNTU_PIN}"

  # Block every Ubuntu package until the full pin exists (this run only).
  write_provisional_pin || true
  PINNED_BEFORE="$(pinned_codename)"
  write_ubuntu_sources || true

  step "Refresh package lists"
  apt_update || error "apt update failed for the Ubuntu sources — they are put back as they were."
  # An unserved architecture yields an empty Ubuntu index.
  LC_ALL=C apt-cache madison gnome-shell-extension-ubuntu-dock yaru-theme-icon 2>/dev/null \
    | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); if ($3 ~ re) f = 1 } END { exit !f }' \
    || error "${UBUNTU_MIRROR} serves no Ubuntu packages for ${UBUNTU_ARCH} — the sources are put back as they were."

  step "Resolve the gnome-shell-compatible Ubuntu release"
  local _older _newest _debian_shell _newest_shell _pinned_now _newest_forced=0
  if [ "$REQUESTED_CODENAME" != auto ]; then
    UBUNTU_CODENAME="$REQUESTED_CODENAME"
    message "using the requested Ubuntu release ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} (UBUNTU_CODENAME)"
  else
    UBUNTU_CODENAME="$(resolve_ubuntu_codename)"
    _newest="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $NF}')"
    _debian_shell="$(shell_major)"
    _newest_shell="$(ubuntu_shell_major "$_newest")"
    if [ -z "$UBUNTU_CODENAME" ] && [ -n "$_debian_shell" ] && [ -n "$_newest_shell" ] \
       && [ "$_debian_shell" -gt "$_newest_shell" ]; then
      # gnome-shell is newer than every Ubuntu release.
      UBUNTU_CODENAME="$_newest"; _newest_forced=1
      message warn "gnome-shell ${_debian_shell} is newer than any Ubuntu release — using the newest, ${UBUNTU_CODENAME}"
    elif [ -z "$UBUNTU_CODENAME" ]; then
      message warn "no Ubuntu release in the current window has a theme this gnome-shell can load"
      # The pinned release first, then older listed releases, then retired ones.
      _pinned_now="$PINNED_BEFORE"
      [ -n "$_pinned_now" ] || _pinned_now="$(sed -n 's/^UBUNTU_CODENAME=//p' "$BUNDLE_INFO" 2>/dev/null | head -1)"
      if [[ "$_pinned_now" =~ ^[a-z]+$ ]] && ! in_word_list "$_pinned_now" "$UBUNTU_CANDIDATE_CODENAMES"; then
        try_older_releases "$_pinned_now"
      fi
      if [ -z "$UBUNTU_CODENAME" ]; then
        _older="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' \
          | head -n -"$MAX_UBUNTU_CANDIDATES" | tail -n "$MAX_UBUNTU_LOOKBACK" | xargs)"
        [ -n "$_older" ] && try_older_releases "$_older"
      fi
      if [ -z "$UBUNTU_CODENAME" ]; then
        _older="$(discover_retired_codenames)"
        [ -n "$_older" ] && try_older_releases "$_older"
      fi
    fi
    if [ -z "$UBUNTU_CODENAME" ]; then
      UBUNTU_CODENAME="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $1}')"
      message warn "no Ubuntu release ships a shell theme for this gnome-shell — using ${UBUNTU_CODENAME}"
    elif [ "$_newest_forced" = 0 ]; then
      message "resolved Ubuntu release: ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} ($(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')) — verified via simulated install"
    fi
  fi

  step "Apply the Ubuntu pin to this build"
  # The machine's pin stays; this run's apt reads the full pin from a copy.
  local f
  BUILD_PREFS_DIR="$(mktemp -d)" || error "Could not create a temporary directory"
  for f in /etc/apt/preferences.d/*; do
    [ -f "$f" ] && [ "$f" != "$UBUNTU_PIN" ] && cp "$f" "${BUILD_PREFS_DIR}/" 2>/dev/null
  done
  write_ubuntu_pin "${BUILD_PREFS_DIR}/${UBUNTU_PIN##*/}" || true
  BUILD_APT_OPTS=(-o "Dir::Etc::preferencesparts=${BUILD_PREFS_DIR}")
  # Versions as a clean machine would get them.
  CLEAN_APT_OPTS=("${BUILD_APT_OPTS[@]}" -o Dir::State::status=/dev/null)

  # The chosen release gets universe, as on Ubuntu.
  local _rc=0
  write_ubuntu_sources || _rc=$?
  [ "$_rc" -eq 2 ] && error "Ubuntu ${UBUNTU_CODENAME} did not answer — run --download again"
  if [ "$_rc" -eq 0 ]; then
    apt_update_ubuntu_only \
      || error "apt update failed for Ubuntu ${UBUNTU_CODENAME} — run --download again"
  fi

  step "Resolve the full package set"
  local all_pkgs resolvable="" pkg combined="" ccand
  # The combined extension package where offered, beside the separate ones.
  ccand="$(clean_candidate "$COMBINED_EXT_PKG")"
  [ -n "$ccand" ] && LC_ALL=C apt-cache "${CLEAN_APT_OPTS[@]}" show "${COMBINED_EXT_PKG}=${ccand}" 2>/dev/null \
    | grep -q '^Provides:.*gnome-shell-extension-ubuntu-dock' && combined="$COMBINED_EXT_PKG"
  # The target decides on the boot splash; ubuntu-keyring signs its source.
  # shellcheck disable=SC2086
  all_pkgs="$(printf '%s\n' ubuntu-keyring plymouth plymouth-themes \
    ${packages[0-base]} ${packages[1-desktop-base]} ${packages[2-desktop-gnome]} \
    $combined | sort -u | xargs)"
  # Drop anything apt cannot see.
  for pkg in $all_pkgs; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      resolvable="$resolvable $pkg"
    else
      STATUS_UNAVAIL+=("$pkg (not in any configured Ubuntu/Debian repo)")
    fi
  done
  resolvable="$(echo "$resolvable" | xargs)"

  local -A CANDIDATE_VER=()
  local needed="" sim_pkgs="" cand bver dep_pkg dep_ver

  step "Check for package updates (bundle vs. Ubuntu/Debian archive)"
  # Fetch what the bundle lacks, or holds at a version other than the candidate.
  for pkg in $resolvable; do
    cand="$(clean_candidate "$pkg")"
    [ -n "$cand" ] || continue
    CANDIDATE_VER[$pkg]="$cand"
    sim_pkgs="$sim_pkgs $pkg"
    bver="$(bundled_version "$pkg")"
    if [ -z "$bver" ]; then
      needed="$needed $pkg"
      message "  ${pkg}: not in bundle yet → ${cand}"
    elif [ "$bver" != "$cand" ]; then
      needed="$needed $pkg"
      message "  ${pkg}: update available ${bver} → ${cand}"
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
  for dep_pkg in $(echo "$sim_out" | awk '/^Inst /{print $2}' | grep -v ':' | sort -u); do
    [ -n "${CANDIDATE_VER[$dep_pkg]:-}" ] && continue
    dep_ver="$(clean_candidate "$dep_pkg")"
    [ -n "$dep_ver" ] || continue
    CANDIDATE_VER[$dep_pkg]="$dep_ver"
    if [ "$(bundled_version "$dep_pkg")" != "$dep_ver" ]; then
      needed="$needed $dep_pkg"
      message "  ${dep_pkg}: new dependency, not in bundle → ${dep_ver}"
    fi
  done
  needed="$(echo "$needed" | xargs)"

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
  for pkg in $LOOK_PACKAGES; do
    dvers="$(LC_ALL=C apt-cache madison "$pkg" 2>/dev/null | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '
      { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
        if ($3 !~ re) print $2 }' | sort -u)"
    [ -n "$dvers" ] || continue
    for dver in $dvers; do
      bundle_has_version "$pkg" "$DEBIAN_DEBS_DIR" "$dver" > /dev/null && continue
      if fetch_deb "$pkg" "$dver" "$DEBIAN_DEBS_DIR"; then
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
    if drop_superseded "$pkg" "$PACKAGES_DIR" "${CANDIDATE_VER[$pkg]}"; then
      BUNDLE_DIRTY=1
      message "  removed older builds of ${pkg}"
      pruned=$((pruned + 1))
    fi
  done
  # The rest only when every stage package resolved.
  for pkg in $all_pkgs; do
    [ -n "${CANDIDATE_VER[$pkg]:-}" ] || unresolved="$unresolved $pkg"
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
  # A gap is reported, not fatal.
  local missing=""
  for pkg in $all_pkgs; do
    [ -n "$(bundled_version "$pkg")" ] || missing="$missing $pkg"
  done
  missing="$(echo "$missing" | xargs)"
  if [ -n "$missing" ]; then
    message warn "these packages are NOT in the bundle: ${missing}"
    message warn "an install from it will skip them and say so in its summary"
  else
    message "all $(echo "$all_pkgs" | wc -w) stage packages are present in the bundle"
  fi

  step "Write the package index"
  # The key file older bundles carried; ubuntu-keyring replaces it.
  rm -f "${PACKAGES_DIR}/ubuntu-archive.gpg"
  write_bundle_index || error "could not write ${PACKAGES_DIR}/Packages"
  DOWNLOAD_DONE=1

  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  echo -e "${GREEN}Bundle ready: ${PACKAGES_DIR}${ENDCOLOR}"
  echo -e "${GREEN}  $(grep -c '^Package:' "${PACKAGES_DIR}/Packages") package(s), Ubuntu ${UBUNTU_CODENAME}, ${UBUNTU_ARCH}, Debian $(debian_codename), gnome-shell $(shell_major)${ENDCOLOR}"
  summary_block "$YELLOW" "Not resolvable from any configured repo (${#STATUS_UNAVAIL[@]}):" "!" "" "${STATUS_UNAVAIL[@]}"
  summary_block "$RED" "Not done (${#STATUS_FAILED[@]}):" "!" "" "${STATUS_FAILED[@]}"
  summary_block "$GREEN" "Changes to this machine:" "+" "" "${STATUS_CHANGES[@]}"
  echo -e "${GREEN}Copy ubuntu-look.sh and packages/ to an offline machine with the same Debian release, architecture and gnome-shell, then run: bash ubuntu-look.sh --offline${ENDCOLOR}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  exit 0
}

# Read BUNDLE_INFO (parsed, never sourced) and check it fits this system.
# Sets UBUNTU_CODENAME and UBUNTU_MIRROR.
load_bundle() {
  [ -d "$PACKAGES_DIR" ] || error "Local bundle not found: ${PACKAGES_DIR}
  Build it with 'bash ubuntu-look.sh --download' on an online machine with
  the same Debian release, architecture and gnome-shell, then copy this script
  and packages/ here."
  [ -f "${PACKAGES_DIR}/Packages" ] || error "Packages index missing: ${PACKAGES_DIR}/Packages
  The bundle looks incomplete — rebuild it with --download."
  [ -f "$BUNDLE_INFO" ] || error "${BUNDLE_INFO} is missing — rebuild the bundle with --download."

  local key val b_codename="" b_mirror="" b_debian="" b_arch="" b_shell=""
  while IFS='=' read -r key val || [ -n "$key" ]; do
    [[ "$val" =~ ^[A-Za-z0-9._:/+-]*$ ]] || continue
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
    || mismatch="${mismatch:+${mismatch}, }gnome-shell ${b_shell:-unknown} (this system: ${t_shell:-none})"
  if [ -n "$mismatch" ]; then
    if [ "${UBUNTU_LOOK_FORCE_BUNDLE:-0}" = "1" ]; then
      message warn "the bundle was built for ${mismatch} — continuing (UBUNTU_LOOK_FORCE_BUNDLE=1)"
      STATUS_NOCHANGE+=("Bundle built for ${mismatch}; used anyway (UBUNTU_LOOK_FORCE_BUNDLE=1)")
    else
      error "The bundle was built for ${mismatch}.
  Rebuild it with --download on a matching machine, or set UBUNTU_LOOK_FORCE_BUNDLE=1."
    fi
  fi

  UBUNTU_CODENAME="$b_codename"
  if [ -n "$b_mirror" ]; then
    UBUNTU_MIRROR="${b_mirror%/}"
    add_mirror_to_hosts_re "$UBUNTU_MIRROR"
  fi
}

prepare_offline() {
  step "Register the local bundle as apt source"
  local f n=0 apt_before
  # Clean up after a killed --download.
  if [ -d "$DISCARD_DIR" ] && [ -w "$PACKAGES_DIR" ]; then
    for f in "$PACKAGES_DIR"/*.deb; do
      [ -f "$f" ] || continue
      grep -qxF "Filename: ./${f##*/}" "${PACKAGES_DIR}/Packages" 2>/dev/null \
        || { rm -f "$f" && BUNDLE_DIRTY=1; }
    done
    bundle_discard_restore
    [ "$BUNDLE_DIRTY" = 1 ] && { write_bundle_index index-only || error "Could not rewrite ${PACKAGES_DIR}/Packages"; }
  elif [ -d "$DISCARD_DIR" ]; then
    error "${PACKAGES_DIR} holds an unfinished --download and cannot be written here.
  Run this from a writable copy, or rebuild the bundle with --download."
  fi
  restore_stale_apt_files || error "Could not put back what an earlier --download changed (${DOWNLOAD_SAVED})"

  LOCAL_LIST="$(mktemp --suffix=.list)" || error "Could not create a temporary apt source"
  printf 'deb [trusted=yes] file://%s ./\n' "$(uri_path_encode "$PACKAGES_DIR")" > "$LOCAL_LIST"
  APT_OPTS=(-o "Dir::Etc::sourcelist=${LOCAL_LIST}" -o "Dir::Etc::sourceparts=-")
  sudo apt-get update "${APT_OPTS[@]}" -o APT::Get::List-Cleanup=0 2>/dev/null \
    || error "Failed to load the package index of ${PACKAGES_DIR}"
  message "bundle: $(grep -c '^Package:' "${PACKAGES_DIR}/Packages") packages, Ubuntu ${UBUNTU_CODENAME}${BUNDLE_DATE:+, built ${BUNDLE_DATE}}"

  # Debian's builds of the look packages go into apt's cache, for the uninstall.
  for f in "$DEBIAN_DEBS_DIR"/*_"$UBUNTU_ARCH".deb "$DEBIAN_DEBS_DIR"/*_all.deb; do
    [ -f "$f" ] && [ ! -f "/var/cache/apt/archives/${f##*/}" ] || continue
    if deb_intact "$f" && sudo install -m 0644 "$f" /var/cache/apt/archives/; then
      sys_record_append "$CACHED_DEBS" "/var/cache/apt/archives/${f##*/}"
      n=$((n + 1))
    fi
  done
  [ "$n" -gt 0 ] && STATUS_CHANGES+=("Debian's builds of ${n} look package(s) placed in apt's cache, for the uninstall")

  step "Write the Ubuntu pin"
  apt_before="$(apt_config_sum)"
  if ! is_installed ubuntu-keyring; then
    if installs_cleanly ubuntu-keyring && apt_install_recorded ubuntu-keyring >/dev/null; then
      STATUS_CHANGES+=("Installed ubuntu-keyring (Ubuntu's archive keys, from Debian)")
    else
      message warn "ubuntu-keyring could not be installed from the bundle"
    fi
  fi
  if write_ubuntu_pin; then
    STATUS_CHANGES+=("Ubuntu theme pin applied (${UBUNTU_CODENAME})")
  else
    STATUS_NOCHANGE+=("Ubuntu theme pin already current")
  fi
  remove_unattended_origins
  # An existing Ubuntu source list is kept, and narrowed after aligning.
  if [ -f "$UBUNTU_LIST" ] && configured_codenames | grep -qxF "$UBUNTU_CODENAME"; then
    NARROW_WITHOUT_ARCHIVE=1
  elif [ -f "$UBUNTU_LIST" ]; then
    STATUS_NOCHANGE+=("Ubuntu apt source left as it is (it does not name ${UBUNTU_CODENAME}) — an online run updates it")
  else
    STATUS_NOCHANGE+=("No Ubuntu apt source written offline — an online run adds it")
  fi
  [ "$(apt_config_sum)" != "$apt_before" ] && invalidate_refresh_state
  return 0
}

# --offline: keep only the bundle's release in the source list.
narrow_without_archive() {
  [ "${NARROW_WITHOUT_ARCHIVE:-0}" = 1 ] && [ -f "$UBUNTU_LIST" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v cn="$UBUNTU_CODENAME" '
    /^# configured: / { print "# configured: " cn; next }
    /^deb / { r = ""
              for (i = 2; i < NF; i++) if ($i ~ /:\/\//) { r = $(i + 1); break }
              sub(/-updates$/, "", r); if (r != cn) next }
    { print }' "$UBUNTU_LIST" > "$tmp"
  if ! cmp -s "$tmp" "$UBUNTU_LIST" && sudo install -m 0644 "$tmp" "$UBUNTU_LIST"; then
    STATUS_CHANGES+=("Ubuntu apt source narrowed to ${UBUNTU_CODENAME}")
    invalidate_refresh_state
  fi
  rm -f "$tmp"
}

# --offline: cache Debian's builds the combined package replaced, for the uninstall.
cache_replaced_debs() {
  [ -f "$REPLACED_BY_COMBINED" ] || return 0
  local p f
  while read -r p; do
    [ -n "$p" ] || continue
    while read -r f; do
      [ -n "$f" ] && [ ! -f "/var/cache/apt/archives/${f##*/}" ] && deb_intact "$f" \
        && sudo install -m 0644 "$f" /var/cache/apt/archives/ \
        && sys_record_append "$CACHED_DEBS" "/var/cache/apt/archives/${f##*/}"
    done < <(bundle_debs "$p")
  done < "$REPLACED_BY_COMBINED"
}

###############################################################################
# 7. Setup: help, run log, mode, options, variables
###############################################################################

# --help prints the Usage to Undo sections above.
for _arg in "$@"; do
  case "$_arg" in
    -h|--help) sed -n '/^# Usage/,/^# Requires/{/^# Requires/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
  esac
done

if [ "${UBUNTU_LOOK_LOG:-1}" != "0" ] && [ -z "${UBUNTU_LOOK_LOGGING:-}" ]; then
  _log_name=ubuntu-look
  case " $* " in *" --uninstall "*|*" uninstall "*) _log_name=uninstall ;; esac
  _log_file="${HOME}/${_log_name}-$(date +%Y%m%d-%H%M%S).log"

  # Pass on the shell options -u, -e and -x.
  _opts=()
  for _o in u e x; do
    case "$-" in *"$_o"*) _opts+=("-$_o") ;; esac
  done

  export UBUNTU_LOOK_LOGGING=1
  echo "Recording this run to ${_log_file}"
  # tee and sed ignore Ctrl-C, so the summary still reaches the log.
  bash "${_opts[@]}" "${BASH_SOURCE[0]}" "$@" 2>&1 \
    | (trap '' INT; tee >(trap '' INT; sed -r 's/\x1b\[[0-9;]*[mK]//g' > "$_log_file"))
  _rc=${PIPESTATUS[0]}
  echo "Log written to ${_log_file}"
  exit "$_rc"
fi

# Debian leaves sbin (update-grub, plymouth tools) off a user's PATH.
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" ;;
esac

# Facts for the log.
{
  echo "### $(basename "${BASH_SOURCE[0]}")  $(sha256sum "${BASH_SOURCE[0]}" 2>/dev/null | cut -c1-16)"
  echo "### date    : $(date -Iseconds)"
  echo "### args    : ${*:-<none>}"
  echo "### system  : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "### gnome   : $(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')"
  echo "### session : ${XDG_SESSION_TYPE:-?} / ${XDG_CURRENT_DESKTOP:-?}"
  echo "### dbus    : $([ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && echo present || echo absent)"
  echo "### kernel  : $(uname -r) / $(dpkg --print-architecture 2>/dev/null || uname -m)"
  # Debian ships no mutter binary; its library package names the version.
  _wm="$(mutter --version 2>/dev/null | head -1)"
  [ -n "$_wm" ] ||
    _wm="$(dpkg-query -W -f='${Package} ${Version}\n' 'libmutter-*' 2>/dev/null | head -1)"
  echo "### wm      : ${_wm:-unknown}"
  # The pinned release, and the release yaru-theme-gtk came from.
  _rel_version() {
    [ -n "$1" ] || return 0
    sed -n 's/^Version: //p' /var/lib/apt/lists/*_dists_"$1"_InRelease 2>/dev/null | head -1
  }
  _pinned="$(pinned_codename /etc/apt/preferences.d/ubuntu-themes)"
  # The line after "***" is the installed version's source.
  _float="$(apt-cache policy yaru-theme-gtk 2>/dev/null |
    awk '/^ \*\*\*/{getline; if ($0 ~ /:\/\//) print $3; exit}')"
  _float="${_float%%/*}"
  _pv="$(_rel_version "$_pinned")"
  _fv="$(_rel_version "$_float")"
  _u1="${_pv:+${_pv} (${_pinned})}"; _u1="${_u1:-${_pinned}}"
  _u2="${_fv:+${_fv} (${_float})}"; _u2="${_u2:-${_float}}"
  echo "### pinned  : ${_u1:+ubuntu }${_u1:-none pinned yet}"
  echo "### themes  : ${_u2:+from }${_u2:-not installed yet}"
  echo ""
}

set -u

# Mode flags may appear anywhere; other words are stage names. The bare
# words of earlier versions (download, uninstall, prepare-upgrade), and
# --no-refresh for --offline, still work.
MODE=online
arguments=""
for _arg in "$@"; do
  case "$_arg" in
    --download|download)     _mode=download ;;
    --offline|--no-refresh)  _mode=offline ;;
    --uninstall|uninstall)   _mode=uninstall ;;
    *)                       arguments="${arguments:+${arguments} }${_arg}"; continue ;;
  esac
  [ "$MODE" = online ] || [ "$MODE" = "$_mode" ] \
    || { echo "Give only one of --download, --offline and --uninstall." >&2; exit 1; }
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
REMOVED_RECORD="${SYS_RECORDS}/removed-by-script.txt"
REMOVED_FOR_UPGRADE="${SYS_RECORDS}/removed-for-upgrade.txt"
GRUB_ADDED_FILE="${SYS_RECORDS}/grub-cmdline-added.txt"
PLYMOUTH_BEFORE_FILE="${SYS_RECORDS}/plymouth-theme-before.txt"
# Debian .debs an offline install placed in apt's cache, one path per line.
CACHED_DEBS="${SYS_RECORDS}/debs-in-apt-cache.txt"
BACKUP_REL=.ubuntu-look-backup
BACKUP_DIR="${HOME:-}/${BACKUP_REL}"
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
DASH_TO_DOCK_UUID=dash-to-dock@micxgx.gmail.com
# Present when the installer turned Dash-to-Dock off for this user.
DASH_TO_DOCK_OFF="${BACKUP_DIR}/dash-to-dock-turned-off"
# Present from a fresh install until Ubuntu's defaults replace the user's own.
DEFAULTS_PENDING="${BACKUP_ORIGINAL}/ubuntu-defaults-pending"
# Stage packages. Manifests of earlier versions may lack some of them;
# migration adds those that were not installed before.
LEGACY_STAGE_PACKAGES="plymouth plymouth-themes dconf-cli fonts-ubuntu ubuntu-wallpapers
  gnome-shell-extension-user-theme gnome-shell-extension-desktop-icons-ng
  gnome-shell-extension-ubuntu-dock gnome-shell-extension-ubuntu-tiling-assistant
  gnome-shell-extension-appindicator gir1.2-dbusmenu-gtk3-0.4 humanity-icon-theme
  yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound"

# Marks an options file whose UBUNTU_LOOK_AUTO_REFRESH is the user's choice.
REFRESH_OPT_IN_MARK="# auto-refresh: opt-in"
SAVED_OPTION_NAMES="UBUNTU_CODENAME UBUNTU_INCLUDE_DEVEL UBUNTU_MIRROR UBUNTU_BOOT_SPLASH PLYMOUTH_THEME UBUNTU_LOOK_AUTO_REFRESH"

# --refresh: the unattended root run of ubuntu-look-refresh.service. It
# updates system state only: sources, pin, look packages, dconf databases.
REFRESH=0
in_word_list --refresh "$arguments" && REFRESH=1
# Set when this run was given PLYMOUTH_THEME (not only a saved one).
PLYMOUTH_THEME_GIVEN=""
if [ "$REFRESH" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "--refresh is run by ubuntu-look-refresh.service, as root" >&2; exit 1; }
  [ "$MODE" = online ] || { echo "--refresh takes no mode flag" >&2; exit 1; }
  # A system service has no HOME; curl and apt need one.
  HOME="$(getent passwd root | cut -d: -f6)"
  export HOME
  arguments=""
  # shellcheck disable=SC2086
  unset $SAVED_OPTION_NAMES
  sudo() { "$@"; }
  # No prompts; conffile questions keep the admin's file.
  export DEBIAN_FRONTEND=noninteractive
  apt-get() {
    command apt-get -o DPkg::Lock::Timeout=900 \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
  }
else
  PLYMOUTH_THEME_GIVEN="${PLYMOUTH_THEME:+1}"
  # Wait for an apt lock instead of failing.
  sudo() {
    if [ "${1:-}" = apt-get ]; then
      shift
      command sudo apt-get -o DPkg::Lock::Timeout=300 "$@"
    else
      command sudo "$@"
    fi
  }
fi
load_saved_options

# The bundle: --download builds it, --offline installs from it.
PACKAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packages"
BUNDLE_INFO="${PACKAGES_DIR}/BUNDLE_INFO"
# Downloads land here and move into the bundle only once verified.
PARTIAL_DIR="${PACKAGES_DIR}/.partial"
# Files a --download run takes out; deleted once the new index is written.
DISCARD_DIR="${PACKAGES_DIR}/.discard"
# Debian's own builds of the look packages, for an uninstall without network.
DEBIAN_DEBS_DIR="${PACKAGES_DIR}/debian"
BUNDLE_DATE=""
# --offline: the bundle as the only apt source, through a temporary list.
LOCAL_LIST=""
# Options for every apt call of the stages (the bundle's source, --offline).
APT_OPTS=()
# --download state, for _download_exit.
BUNDLE_DIRTY=0
FETCHED_NEW=()       # .debs this run added; removed if it does not finish
FETCHED_ADDED=()     # of those, packages new to the bundle
SUDO_KEEPALIVE_PID=""
DOWNLOAD_DONE=0
PREV_LIST_FILE=""    # the machine's Ubuntu source list and pin, to restore
PREV_PIN_FILE=""
BUILD_APT_OPTS=()    # the full pin, for the build's own apt calls only
CLEAN_APT_OPTS=()
BUILD_PREFS_DIR=""

declare -A packages

# dconf-cli compiles the look's database; Plymouth is added below.
packages[0-base]="dconf-cli"
packages[1-desktop-base]="fonts-ubuntu ubuntu-wallpapers"
# gir1.2-dbusmenu-gtk3-0.4 gives tray icons their menus; Yaru inherits from
# humanity-icon-theme.
packages[2-desktop-gnome]="gnome-shell-extension-desktop-icons-ng
gnome-shell-extension-ubuntu-dock
gnome-shell-extension-ubuntu-tiling-assistant
gnome-shell-extension-appindicator
gir1.2-dbusmenu-gtk3-0.4
humanity-icon-theme
yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound"

# Ubuntu release supplying the look; see resolve_ubuntu_codename().
UBUNTU_CODENAME="${UBUNTU_CODENAME:-auto}"
REQUESTED_CODENAME="$UBUNTU_CODENAME"

# amd64 and i386 use archive.ubuntu.com, others ports.ubuntu.com.
UBUNTU_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
case "$UBUNTU_ARCH" in
  amd64|i386) UBUNTU_DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
  *)          UBUNTU_DEFAULT_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
esac
REQUESTED_MIRROR="${UBUNTU_MIRROR:-}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-$UBUNTU_DEFAULT_MIRROR}"
UBUNTU_MIRROR="${UBUNTU_MIRROR%/}"
UBUNTU_OLD_MIRROR="http://old-releases.ubuntu.com/ubuntu"

# Regex for Ubuntu archive URLs in apt-cache madison: any ubuntu.com host,
# plus the mirrors added below.
UBUNTU_COM_RE="://([a-z0-9.-]+[.])?ubuntu[.]com/"
UBUNTU_HOSTS_RE="$UBUNTU_COM_RE"
add_mirror_to_hosts_re "$UBUNTU_MIRROR"

# curl ignores apt's proxy; use it when no proxy is set.
if [ -z "${http_proxy:-}${https_proxy:-}" ]; then
  _apt_proxy="$(apt-config dump 2>/dev/null | sed -n 's/^Acquire::http::Proxy "\(.*\)";$/\1/p' | head -1)"
  [ -n "$_apt_proxy" ] && export http_proxy="$_apt_proxy" https_proxy="$_apt_proxy"
fi

# Candidates come from main; the pinned release also gets universe.
UBUNTU_COMPONENTS="main"
UBUNTU_PINNED_COMPONENTS="main universe"
APT_UPDATE_OUTPUT=""

# "quiet splash" and Plymouth; UBUNTU_BOOT_SPLASH=0 reverts them.
UBUNTU_BOOT_SPLASH="${UBUNTU_BOOT_SPLASH:-1}"
# Ubuntu's splash (firmware logo and spinner), also shipped by Debian.
PLYMOUTH_THEME="${PLYMOUTH_THEME:-bgrt}"

[ "$UBUNTU_BOOT_SPLASH" != "0" ] && has_boot_splash_tools \
  && packages[0-base]="plymouth plymouth-themes ${packages[0-base]}"

# 1 = also consider the Ubuntu series in development.
UBUNTU_INCLUDE_DEVEL="${UBUNTU_INCLUDE_DEVEL:-0}"
# Recent releases configured as sources; few, to keep apt update fast.
MAX_UBUNTU_CANDIDATES=4
# Older releases to try when none of those fits this gnome-shell.
MAX_UBUNTU_LOOKBACK=6
# Bump when the pin or source content changes, so re-runs rewrite them.
PIN_VERSION="v22-2026-09-26"

# The look's extensions, for the profile, enabling and verification.
THEME_EXT_UUID="ubuntu-look-theme@ubuntu-look"
SHELL_EXTENSIONS="ubuntu-appindicators@ubuntu.com ubuntu-dock@ubuntu.com ding@rastersoft.com tiling-assistant@ubuntu.com ${THEME_EXT_UUID}"
# Earlier versions themed the shell through user-theme.
USER_THEME_UUID="user-theme@gnome-shell-extensions.gcampax.github.com"

# Ubuntu's defaults live in their own dconf database, read only by users of
# the look: their session's DCONF_PROFILE adds it after the user database.
# The database name has no hyphen: dconf's change signal uses it in a D-Bus path.
LOOK_PROFILE_NAME=ubuntu-look
LOOK_DB_NAME=ubuntu_look
LOOK_DB_DIR="/etc/dconf/db/${LOOK_DB_NAME}.d"
LOOK_DB_FILE="${LOOK_DB_DIR}/10-ubuntu-look"
LOOK_PROFILE="/etc/dconf/profile/${LOOK_PROFILE_NAME}"
# The database name of earlier versions.
OLD_LOOK_DB_NAME=ubuntu-look
LOOK_ENV_REL=.config/environment.d/90-ubuntu-look.conf
LOOK_ENV_FILE="${HOME:-}/${LOOK_ENV_REL}"
# Boot-time removal of the profile, left by an uninstall while it was in use.
LOOK_CLEANUP_CONF=/etc/tmpfiles.d/ubuntu-look-cleanup.conf
# session-migration (a Yaru dependency) would write color-scheme at login
# because of the look database, so it is masked.
SESSION_MIGRATION_MASK=/etc/systemd/user/session-migration.service
# Present when the installer made the mask; the uninstall removes only that.
SESSION_MIGRATION_MASKED="${SYS_RECORDS}/session-migration-masked"
DCONF_USER_PROFILE=/etc/dconf/profile/user
# Where earlier versions put the defaults, for every user.
LEGACY_DB_FILE=/etc/dconf/db/local.d/10-ubuntu-look

# Ubuntu's archive keys, from Debian's ubuntu-keyring package.
UBUNTU_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
# The keyring earlier versions fetched from a keyserver.
LEGACY_UBUNTU_KEYRING=/etc/apt/keyrings/ubuntu-archive.gpg
UBUNTU_LIST=/etc/apt/sources.list.d/ubuntu-themes.list
UBUNTU_PIN=/etc/apt/preferences.d/ubuntu-themes
# Left by offline installs of earlier versions.
OFFLINE_LOCAL_LIST=/etc/apt/sources.list.d/ubuntu-look-offline-local.list

# Per-run cache of "<codename> <version> <state> <mirror>".
UBUNTU_RELEASE_CACHE="$(mktemp)"

declare -a STATUS_INSTALLED=()
declare -a STATUS_UPGRADED=()
declare -a STATUS_ALREADY=()
# Packages with a newer Ubuntu build this Debian cannot take (not a failure).
declare -a STATUS_HELD=()
# Every package the stages name, for log_final_state().
ALL_STAGE_PACKAGES="$(printf '%s ' "${packages[@]}" | xargs -n1 | sort -u | xargs)"

declare -a STATUS_CHANGES=()
declare -a STATUS_NOCHANGE=()
declare -a STATUS_FAILED=()
declare -a STATUS_EXT_FAILED=()
# Builds ensure_package tried and turned down this run, as "pkg=version".
REJECTED_BUILDS=""
# Set by ensure_package: the version it settled on.
ENSURE_VERSION=""
# apt failures this run; a refresh with any is retried rather than recorded.
APT_ERRORS=0
# Requested but absent from the bundle (--offline).
declare -a STATUS_UNAVAIL=()
GSETTINGS_UNCHANGED=0
GSETTINGS_KEPT=0
declare -a SETTINGS_KEPT=()
REBOOT_NEEDED=0
RELOGIN_NEEDED=0
STEP=0

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"
# No colours in the journal.
[ "$REFRESH" = 1 ] && { RED=""; GREEN=""; YELLOW=""; ENDCOLOR=""; }

# The look itself. Only these may replace an installed Debian build; the
# uninstall restores the recorded version.
LOOK_PACKAGES="yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound fonts-ubuntu ubuntu-wallpapers"

# Every package the pin admits from the pinned release.
UBUNTU_PINNED_PACKAGES="${LOOK_PACKAGES} gnome-shell-extension-ubuntu-dock"
UBUNTU_PINNED_PACKAGES+=" gnome-shell-extension-ubuntu-tiling-assistant session-migration humanity-icon-theme"
UBUNTU_PINNED_PACKAGES+=" gnome-shell-ubuntu-extensions"

# One Ubuntu package that replaces the four below, used where offered.
COMBINED_EXT_PKG="gnome-shell-ubuntu-extensions"
SEPARATE_EXT_PKGS="gnome-shell-extension-desktop-icons-ng gnome-shell-extension-ubuntu-dock"
SEPARATE_EXT_PKGS+=" gnome-shell-extension-ubuntu-tiling-assistant gnome-shell-extension-appindicator"
# The Ubuntu packages that carry the dock and the tiling assistant.
UBUNTU_SHELL_EXT_PKGS="gnome-shell-extension-ubuntu-dock gnome-shell-extension-ubuntu-tiling-assistant"
UBUNTU_SHELL_EXT_PKGS+=" ${COMBINED_EXT_PKG}"
# Packages apt may remove this run: those the combined package replaces.
ALLOWED_REMOVALS=""

# The copy of /etc/default/grub a failed update-grub left behind; the caller
# reports it.
GRUB_BACKUP_KEPT=""

# The extensions already switched on once for this user.
EXTENSIONS_ON_RECORD="${BACKUP_DIR}/extensions-switched-on.txt"

# System profile only; enable_shell_extensions() merges into the user's list.
DCONF_ONLY_KEYS=" enabled-extensions "

# Keys Debian already sets to Ubuntu's values are not listed.
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
)

# The wallpaper keys; their values come with the wallpaper package.
WALLPAPER_KEYS=(
  "org/gnome/desktop/background|picture-uri"
  "org/gnome/desktop/background|picture-uri-dark"
  "org/gnome/desktop/background|picture-options"
  "org/gnome/desktop/screensaver|picture-uri"
)

# Ubuntu leaves the colour scheme at GNOME's default: the light style.
COLOR_SCHEME_KEY="org/gnome/desktop/interface|color-scheme"

# Written by earlier versions for unattended-upgrades; now only removed.
UNATTENDED_ORIGINS=/etc/apt/apt.conf.d/52ubuntu-look-unattended-upgrades

REFRESH_LIB_DIR=/usr/local/lib/ubuntu-look
REFRESH_SCRIPT="${REFRESH_LIB_DIR}/ubuntu-look.sh"
REFRESH_SERVICE=/etc/systemd/system/ubuntu-look-refresh.service
REFRESH_TIMER=/etc/systemd/system/ubuntu-look-refresh.timer
REFRESH_STATE="${SYS_DIR}/refresh-state"
REFRESH_ATTEMPT="${SYS_DIR}/refresh-attempt"

# The pinned release, set by unchanged_since_last_run() when nothing changed.
KEPT_CODENAME=""

# Yaru on the login screen. Debian's Shell ignores Ubuntu's gdm gresource, but
# loads extensions whose metadata lists the "gdm" mode; this one loads Yaru's
# stylesheet. Only the greeter's database enables it.
GREETER_EXT_UUID="ubuntu-look-greeter@ubuntu-look"
GREETER_EXT_DIR="/usr/local/share/gnome-shell/extensions/${GREETER_EXT_UUID}"
THEME_EXT_DIR="/usr/local/share/gnome-shell/extensions/${THEME_EXT_UUID}"
# The directories above the extensions that this script created.
LOCAL_SHELL_DIRS_FILE="${SYS_RECORDS}/local-shell-dirs.txt"

# Theme the login screen through a gdm database: theme, fonts, wallpaper and
# the greeter extension.
GDM_PROFILE_DIR="/etc/dconf/db/gdm.d"
GDM_PROFILE_FILE="${GDM_PROFILE_DIR}/10-ubuntu-look"

# 1 = user-theme still carries Yaru; the autostart turns it off at the next login.
USER_THEME_RETIRE=0

# Ubuntu's terminal colours (dark) go into a gnome-terminal profile named
# Ubuntu, made the default. Other profiles are left as they are.
TERMINAL_PROFILES="/org/gnome/terminal/legacy/profiles:"
TERMINAL_PROFILE_RECORD="${BACKUP_DIR}/terminal-profile.txt"
TERMINAL_BACKGROUND="#300A24"
TERMINAL_FOREGROUND="#FFFFFF"
TERMINAL_PALETTE="['#1B1B1B', '#CC1A12', '#4E9A06', '#C4A000', '#3667A6', '#7F5985', '#06989A', '#D5D5D5', '#838383', '#F93632', '#8AE234', '#FCE94F', '#729FCF', '#AD7FA8', '#34E2E2', '#EEEEEC']"

# The Debian logo on the Show Applications button, under Yaru only. The dock
# asks for view-app-grid-<mode>-symbolic, and Yaru has none for "user".
APP_GRID_ICON="$HOME/.local/share/icons/Yaru/scalable/actions/view-app-grid-user-symbolic.svg"
# Earlier location; hicolor applies to every theme, including Adwaita.
APP_GRID_ICON_OLD="$HOME/.local/share/icons/hicolor/scalable/actions/view-app-grid-user-symbolic.svg"

# How much of the canvas the artwork covers; fuller than Ubuntu's 0.742 so
# the button matches the icons beside it.
APP_GRID_INK_FRACTION=0.98

trap '_on_exit; print_summary' EXIT
# Ctrl-C and a closed terminal still print the summary and run the cleanup.
trap 'echo ""; message warn "interrupted — stopping here"; exit 130' INT
trap 'exit 129' HUP; trap 'exit 143' TERM

[ "$(id -u)" -eq 0 ] && [ "$REFRESH" != 1 ] \
  && error "Do not run as root. Run as a normal user with sudo rights."

# One run at a time, including the refresh timer. The lock lives in /run,
# which only root can write, so no other user can replace it.
UBUNTU_LOOK_LOCK=/run/ubuntu-look.lock

# Where --download keeps the machine's Ubuntu source and pin while it runs.
DOWNLOAD_SAVED="${SYS_DIR}/download-saved"
# The .deb fetch_deb placed last.
FETCHED_DEB=""

###############################################################################
# 8. Uninstall (--uninstall)
###############################################################################
# The look's settings go back to Debian's defaults; installed packages go,
# replaced ones get Debian's build back. System changes go with the last user.

if [ "$MODE" = uninstall ]; then
trap - INT TERM
trap 'rm -f "${UBUNTU_RELEASE_CACHE:-}"' EXIT
[ -z "$arguments" ] || error "--uninstall takes no other arguments (got '${arguments}')"
# A closed terminal must not stop the run between a purge and its cleanup.
trap '' HUP

# The records are read from $HOME, so it must be this user's home.
_home="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[ -n "$_home" ] && [ "${HOME%/}" = "${_home%/}" ] \
  || error "HOME is '${HOME:-}', but ${RUN_USER}'s home is '${_home}'. Run it from ${RUN_USER}'s own login."

declare -a DONE=()
declare -a SKIPPED=()
declare -a GUESSED=()

# Unfinished work keeps its records, so a later run can finish it.
USER_PENDING=0
SYSTEM_PENDING=0
PURGE_FAILED=0
PURGE_KEPT_CONFIG=""
# Packages left on Ubuntu's build because Debian's would not install.
RESTORE_FAILED=""

# Copies of system records, for the settings steps and a later run.
DCONF_PROFILE_COPY="${BACKUP_DIR}/dconf-system-profile.ini"
MANIFEST_COPY="${BACKUP_DIR}/look-packages.txt"
# user-theme: enabled by earlier versions.
SHELL_EXTENSIONS="${SHELL_EXTENSIONS} ${USER_THEME_UUID}"

# Ubuntu's archives also include each mirror in the source list.
for _u in $(awk '/^deb /{ for (i = 2; i <= NF; i++) if ($i ~ /:\/\//) print $i }' "$UBUNTU_LIST" 2>/dev/null | sort -u); do
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

have_session() { [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dconf >/dev/null 2>&1; }

# False without a desktop session; the step is then left for a later run.
need_session() {
  have_session && return 0
  SKIPPED+=("No desktop session — $1; run this again from your desktop")
  USER_PENDING=1
  return 1
}

# Removed, but its configuration files are still there.
is_config_only() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "deinstall ok config-files"
}

# Back to automatically installed, if it was before. One the user added
# later keeps its mark.
restore_auto_mark() {
  if [ -f "$MANUAL_BEFORE" ] && predates_install "$1" && ! grep -qxF "$1" "$MANUAL_BEFORE"; then
    sudo apt-mark auto "$1" >/dev/null 2>&1 || true
  fi
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
          # A backup alone counts only for installs from before the registry.
          { sudo test -f "${h}/${LOOK_ENV_REL}" \
            || { [ ! -f "$SYS_USERS" ] && sudo test -d "${h}/${BACKUP_REL}"; }; } 2>/dev/null && echo "$u"
        done
  } | sed '/^$/d' | sort -u | grep -vxF "$RUN_USER" \
    | while read -r u; do getent passwd "$u" > /dev/null && echo "$u"; done | xargs
}

# Show what a purge of $1 takes, apt's extra removals included, then purge.
# Returns 1 for an empty list. Declined or failed: recorded as unfinished.
purge_list() {
  [ -n "${1// /}" ] || return 1
  local p planned extra="" purge="" keepconf=""
  echo ""
  message "these packages will be removed:"
  # shellcheck disable=SC2086
  printf '   - %s\n' $1
  # shellcheck disable=SC2086
  planned="$(apt-get -s purge $1 2>/dev/null | awk '/^(Remv|Purg) /{print $2}')"
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

# Keys only earlier versions wrote.
EARLIER_LOOK_KEYS=(
  "org/gnome/shell/extensions/user-theme|name"
  "org/gnome/desktop/interface|gtk-enable-primary-paste"
  "org/gnome/desktop/background|primary-color"
  "org/gnome/desktop/background|secondary-color"
  "org/gnome/desktop/screensaver|primary-color"
  "org/gnome/desktop/screensaver|secondary-color"
)

# Every key the look writes or wrote, as "<path> <key>". The extension list and
# the dock have their own steps.
look_keys() {
  local line path key
  for line in "${GNOME_SETTINGS[@]}" "$COLOR_SCHEME_KEY" "${WALLPAPER_KEYS[@]}" "${EARLIER_LOOK_KEYS[@]}"; do
    IFS='|' read -r path key _ <<< "$line"
    case "$DCONF_ONLY_KEYS" in *" $key "*) continue ;; esac
    [ "$path" = org/gnome/shell/extensions/dash-to-dock ] && continue
    echo "$path $key"
  done
}

# Pre-install value of key $2 in path $1; empty when it was at the default.
snapshot_dconf_value() { ini_value "${BACKUP_ORIGINAL}/dconf-dump.ini" "$1" "$2"; }

# The value the look set for the key, from its defaults database.
our_dconf_value() {
  local f
  for f in "$LOOK_DB_FILE" "$LEGACY_DB_FILE" "$DCONF_PROFILE_COPY"; do
    [ -f "$f" ] && { ini_value "$f" "$1" "$2"; return; }
  done
}

# The package that provides extension $1.
ext_package() {
  case "$1" in
    ubuntu-dock@*|tiling-assistant@*|ubuntu-appindicators@*|ding@*)
      if grep -qxF gnome-shell-ubuntu-extensions "$INSTALLED_MANIFEST" "$MANIFEST_COPY" 2>/dev/null; then
        echo gnome-shell-ubuntu-extensions; return
      fi ;;
  esac
  case "$1" in
    ubuntu-dock@*)          echo gnome-shell-extension-ubuntu-dock ;;
    tiling-assistant@*)     echo gnome-shell-extension-ubuntu-tiling-assistant ;;
    ubuntu-appindicators@*) echo gnome-shell-extension-appindicator ;;
    ding@*)                 echo gnome-shell-extension-desktop-icons-ng ;;
    user-theme@*)           echo gnome-shell-extension-user-theme ;;
  esac
}

###############################################################################
# Per-user steps
###############################################################################

step_extensions() {
  step "Switching off the extensions ubuntu-look.sh enabled..."
  need_session "extensions not switched off" || return
  # A reinstall after an interrupted uninstall switches them on again.
  rm -f "$EXTENSIONS_ON_RECORD"
  local have_snap=0 now snap_en snap_dis e new="" dis dtd_on=0 add=""
  [ -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ] && have_snap=1
  now="$(array_items "$(user_dconf_read /org/gnome/shell/enabled-extensions)")"
  snap_en="$(array_items "$(snapshot_dconf_value org/gnome/shell enabled-extensions)")"
  snap_dis="$(array_items "$(snapshot_dconf_value org/gnome/shell disabled-extensions)")"

  # Drop the look's extensions, except those enabled before the install.
  for e in $now; do
    case "$e" in *@ubuntu-look) continue ;; esac
    if in_word_list "$e" "$SHELL_EXTENSIONS"; then
      if [ "$have_snap" -eq 1 ]; then
        in_word_list "$e" "$snap_en" || continue
      else
        grep -qxF "$(ext_package "$e")" "$INSTALLED_MANIFEST" "$MANIFEST_COPY" 2>/dev/null && continue
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
    # Nothing left and nothing set before: Debian's default.
    if [ -z "${new// /}" ] && [ -z "$snap_en" ]; then
      dconf reset /org/gnome/shell/enabled-extensions
    else
      dconf write /org/gnome/shell/enabled-extensions "$(gvariant_string_array "$new")"
    fi || { USER_PENDING=1; GUESSED+=("Could not write enabled-extensions"); return; }
    DONE+=("Switched off the look's extensions; your own stay on")
    [ "$dtd_on" -eq 1 ] && DONE+=("Dash-to-Dock turned back on")
  fi
  rm -f "$DASH_TO_DOCK_OFF"

  # The disabled list: Dash-to-Dock leaves it, earlier entries come back.
  dis="$(array_items "$(user_dconf_read /org/gnome/shell/disabled-extensions)")"
  if [ "$dtd_on" -eq 1 ] && in_word_list "$DASH_TO_DOCK_UUID" "$dis"; then
    dis="$(word_list_without "$dis" "$DASH_TO_DOCK_UUID" | xargs)"
    if [ -n "$dis" ] || [ -n "$snap_dis" ]; then
      dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$dis")" || USER_PENDING=1
    else
      dconf reset /org/gnome/shell/disabled-extensions || USER_PENDING=1
    fi
  fi
  # An empty list over an unset key goes back to unset.
  if [ -z "$dis" ] && [ -z "$snap_dis" ] && [ -n "$(user_dconf_read /org/gnome/shell/disabled-extensions)" ]; then
    dconf reset /org/gnome/shell/disabled-extensions || USER_PENDING=1
  fi
  for e in $snap_dis; do
    in_word_list "$e" "$SHELL_EXTENSIONS" && ! in_word_list "$e" "$dis" && add="${add} ${e}"
  done
  if [ -n "$add" ]; then
    if dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$dis $add")"; then
      DONE+=("Put back extensions you had disabled:${add}")
    else
      USER_PENDING=1
    fi
  fi
}

# Give back the keybindings the tiling assistant left empty.
step_restore_tiling_keybindings() {
  step "Restoring the keybindings the tiling assistant takes over..."
  need_session "tiling keybindings not checked" || return
  local entry path key now restored=0 active=0
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
      # Debian's default, as for every other key the look touched.
      if dconf reset "/${path}/${key}" 2>/dev/null; then
        restored=$((restored + 1))
      else
        USER_PENDING=1
      fi
    done
  done
  if [ "$restored" -gt 0 ]; then
    DONE+=("Gave back ${restored} tiling keybinding(s) (Super+Arrow, edge tiling)")
  else
    SKIPPED+=("Tiling keybindings already at Debian's default")
  fi
}

# Debian's desktop-base sets only picture-uri, so the dark style would show
# GNOME's wallpaper; picture-uri-dark gets Debian's picture-uri as well.
debian_dark_wallpaper() {
  local light dark
  command -v gsettings >/dev/null 2>&1 || return 0
  light="$(GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)"
  dark="$(GSETTINGS_BACKEND=memory gsettings get org.gnome.desktop.background picture-uri-dark 2>/dev/null)"
  case "$dark" in *"/backgrounds/gnome/"*) ;; *) return 0 ;; esac
  case "$light" in ''|*"/backgrounds/gnome/"*) return 0 ;; esac
  dconf write /org/gnome/desktop/background/picture-uri-dark "$light" 2>/dev/null && return 0
  USER_PENDING=1
  return 1
}

step_restore_gnome_settings() {
  step "Resetting GNOME settings and wallpaper to Debian's defaults..."
  need_session "GNOME settings not reset" || return
  # Every key the look writes goes back to Debian's default, whatever its
  # value, so no Yaru theme or Ubuntu font outlives its package. Settings the
  # look never writes, dock favourites among them, are left alone.
  local path key ours nudge=0 reset=0 failed=0
  # Only a session whose Ubuntu defaults are gone needs telling.
  [ "$LAST_USER" -eq 1 ] && session_on_look_profile && nudge=1
  while read -r path key; do
    if [ -n "$(user_dconf_read "/${path}/${key}")" ]; then
      if dconf reset "/${path}/${key}" 2>/dev/null; then
        reset=$((reset + 1))
      else
        USER_PENDING=1; failed=1
      fi
    elif [ "$nudge" -eq 1 ]; then
      # The running session was not told that Ubuntu's defaults went; a
      # write and a reset make it read Debian's value now.
      ours="$(our_dconf_value "$path" "$key")"
      [ -n "$ours" ] || continue
      dconf write "/${path}/${key}" "$ours" 2>/dev/null
      dconf reset "/${path}/${key}" 2>/dev/null || USER_PENDING=1
    fi
  done < <(look_keys)
  debian_dark_wallpaper || failed=1
  if [ "$failed" -eq 0 ]; then
    DONE+=("GNOME settings and wallpaper back to Debian's defaults (${reset} key(s) reset)")
  else
    GUESSED+=("Some GNOME settings could not be reset")
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
    DONE+=("Dock settings cleared; your dash favourites are kept")
  else
    USER_PENDING=1
    GUESSED+=("Could not clear the dock settings")
  fi
}

step_disable_look_profile() {
  step "Switching your sessions back to the default dconf profile..."
  [ -f "$LOOK_ENV_FILE" ] || return
  # Services started from now on no longer get it; running ones keep it.
  systemctl --user unset-environment DCONF_PROFILE 2>/dev/null || true
  rm -f "$LOOK_ENV_FILE"
  rmdir "$(dirname "$LOOK_ENV_FILE")" 2>/dev/null || true
  DONE+=("Removed ${LOOK_ENV_FILE} — Ubuntu's defaults no longer apply to you from the next login")
}

step_remove_extension_autostart() {
  step "Removing the one-shot extension autostart..."
  local d="$HOME/.config/autostart/ubuntu-look-enable-extensions.desktop"
  local s="$HOME/.local/share/ubuntu-look/enable-extensions.sh"
  if [ -f "$d" ] || [ -f "$s" ]; then
    rm -f "$d" "$s"
    DONE+=("Removed the one-shot extension autostart")
  fi
  rmdir "$HOME/.local/share/ubuntu-look" 2>/dev/null || true
}

step_remove_app_grid_icon() {
  step "Removing the Show Applications button icon..."
  local removed=0 f
  # Yaru now; hicolor in earlier versions.
  for f in "$APP_GRID_ICON" "$APP_GRID_ICON_OLD"; do
    remove_user_icon "$f" && removed=1
  done
  if [ "$removed" -eq 1 ]; then
    DONE+=("Removed the Show Applications button icon")
  else
    SKIPPED+=("No Show Applications button icon to remove")
  fi
}

step_remove_theme_followers() {
  step "Removing the shell theme follower..."
  if remove_theme_followers; then
    DONE+=("Removed the shell theme follower")
  else
    SKIPPED+=("No shell theme follower to remove")
  fi
}

# True when file $1 carries a mark of what earlier versions wrote.
written_by_us() {
  grep -q "ubuntu-look\.sh" "$1" 2>/dev/null && return 0
  grep -q "E95420" "$1" 2>/dev/null && grep -qE "accent_bg_color|selected_bg_color" "$1" 2>/dev/null
}

step_restore_gtk() {
  step "Restoring GTK CSS / gtkrc-2.0..."
  local pair name target
  for pair in \
    "gtk-3.0-gtk.css:$HOME/.config/gtk-3.0/gtk.css" \
    "gtk-4.0-gtk.css:$HOME/.config/gtk-4.0/gtk.css" \
    "gtkrc-2.0:$HOME/.gtkrc-2.0"
  do
    name="${pair%%:*}"; target="${pair#*:}"
    [ -f "$target" ] && written_by_us "$target" || continue
    if [ ! -f "${BACKUP_ORIGINAL}/${name}" ]; then
      rm -f "$target"
      DONE+=("Removed the $(basename "$target") an earlier version wrote")
    elif cp "${BACKUP_ORIGINAL}/${name}" "$target"; then
      DONE+=("Restored your own $(basename "$target") from the snapshot")
    else
      USER_PENDING=1; GUESSED+=("Could not restore ${target}")
    fi
  done
}

step_terminal_profile() {
  step "Removing the Ubuntu terminal profile..."
  local record="$TERMINAL_PROFILE_RECORD" base="$TERMINAL_PROFILES"
  local uuids keep="" one uuid stock="" rest="" before failed=0
  if ! have_session; then
    [ -f "$record" ] && need_session "terminal profile not removed"
    return
  fi
  # The recorded profile and any other marked as the look's.
  uuids="$(sed -n 's/^uuid=//p' "$record" 2>/dev/null | tr -d '\r')"
  for one in $(dconf list "${base}/" 2>/dev/null | sed -n 's#^:\(.*\)/$#\1#p'); do
    [ "$(dconf read "${base}/:${one}/ubuntu-look-managed" 2>/dev/null)" = true ] && uuids="${uuids} ${one}"
  done
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

step_restore_software_icon() {
  step "Restoring the software store launcher..."
  local target="$HOME/.local/share/applications/org.gnome.Software.desktop"
  # Only the launcher copy earlier versions wrote.
  [ -f "$target" ] && grep -q '^Icon=app-center$' "$target" 2>/dev/null || return 0
  if [ -f "${BACKUP_ORIGINAL}/org.gnome.Software.desktop" ]; then
    if cp "${BACKUP_ORIGINAL}/org.gnome.Software.desktop" "$target"; then
      DONE+=("Restored your own org.gnome.Software.desktop")
    else
      USER_PENDING=1; GUESSED+=("Could not restore ${target}")
    fi
  else
    rm -f "$target"
    DONE+=("Removed the GNOME Software launcher copy an earlier version wrote")
  fi
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
}

###############################################################################
# System steps (last user only)
###############################################################################

step_remove_refresh_timer() {
  step "Removing the daily refresh timer..."
  remove_refresh_timer && DONE+=("Removed the daily refresh timer and its copy of the script")
  if [ -f "$REFRESH_TIMER" ] || [ -d "$REFRESH_LIB_DIR" ]; then
    SYSTEM_PENDING=1
    GUESSED+=("The daily refresh timer could not be removed")
  fi
  return 0
}

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
  local f db found=""
  # Settings not restored yet: keep what a later run needs.
  if [ "$USER_PENDING" -eq 1 ] && [ ! -f "$DCONF_PROFILE_COPY" ]; then
    for f in "$LOOK_DB_FILE" "$LEGACY_DB_FILE"; do
      [ -f "$f" ] && { mkdir -p "$BACKUP_DIR" && cp "$f" "$DCONF_PROFILE_COPY"; break; }
    done
  fi
  # Running sessions keep a deleted database open, so compile it empty first.
  for db in "$LOOK_DB_NAME" "$OLD_LOOK_DB_NAME"; do
    [ -d "/etc/dconf/db/${db}.d" ] || [ -f "/etc/dconf/db/${db}" ] || continue
    must_sudo rm -rf "/etc/dconf/db/${db}.d" \
      && must_sudo mkdir "/etc/dconf/db/${db}.d" && found="${found} ${db}"
  done
  if [ -n "$found" ]; then
    must_sudo dconf update
    for db in $found; do
      must_sudo rm -rf "/etc/dconf/db/${db}.d" \
        && must_sudo rm -f "/etc/dconf/db/${db}" \
        && DONE+=("Removed Ubuntu's defaults (/etc/dconf/db/${db}.d)")
    done
  fi
  if [ -f "$LOOK_PROFILE" ]; then
    if sudo grep -qas "DCONF_PROFILE=${LOOK_PROFILE_NAME}" /proc/[0-9]*/environ; then
      # Still read by a running session: made plain now, removed at next boot.
      local plain clean
      plain="$(mktemp)"; clean="$(mktemp)"
      look_profile_content | grep -vx "system-db:${LOOK_DB_NAME}" > "$plain"
      printf 'r %s\nr %s\n' "$LOOK_PROFILE" "$LOOK_CLEANUP_CONF" > "$clean"
      must_sudo install -m 0644 "$plain" "$LOOK_PROFILE" \
        && must_sudo install -D -m 0644 "$clean" "$LOOK_CLEANUP_CONF" \
        && DONE+=("${LOOK_PROFILE} now has no Ubuntu defaults; it is removed at the next boot")
      rm -f "$plain" "$clean"
    else
      must_sudo rm -f "$LOOK_PROFILE" && DONE+=("Removed ${LOOK_PROFILE}")
    fi
  fi
  retire_legacy_defaults
  case $? in
    0) DONE+=("Removed the machine-wide defaults of an earlier version") ;;
    2) SYSTEM_PENDING=1; GUESSED+=("The machine-wide defaults of an earlier version could not all be removed") ;;
  esac
  return 0
}

step_remove_gdm_profile() {
  step "Removing the login screen theme and the shell theme extension..."
  local changed=0 ext=0 d dirs pair prof rec
  if [ -f "$GDM_PROFILE_FILE" ]; then
    must_sudo rm -f "$GDM_PROFILE_FILE" && { changed=1; DONE+=("Removed ${GDM_PROFILE_FILE}"); }
  fi
  if [ -d "$THEME_EXT_DIR" ]; then
    must_sudo rm -rf "$THEME_EXT_DIR" && { ext=1; DONE+=("Removed ${THEME_EXT_DIR}"); }
  fi
  if [ -d "$GREETER_EXT_DIR" ]; then
    must_sudo rm -rf "$GREETER_EXT_DIR" && { changed=1; DONE+=("Removed ${GREETER_EXT_DIR}"); }
  fi
  # Only the directories the installer made, when empty; older installs: both.
  dirs="/usr/local/share/gnome-shell/extensions /usr/local/share/gnome-shell"
  [ -f "$LOCAL_SHELL_DIRS_FILE" ] && dirs="$(cat "$LOCAL_SHELL_DIRS_FILE" 2>/dev/null)"
  for d in $dirs; do
    case "$d" in /usr/local/share/gnome-shell|/usr/local/share/gnome-shell/extensions) ;; *) continue ;; esac
    sudo rmdir "$d" 2>/dev/null || true
  done
  # The profiles the installer created; each record goes with its file.
  for pair in gdm:gdm-profile-created Debian-gdm:gdm-profile-Debian-gdm-created; do
    prof="/etc/dconf/profile/${pair%%:*}"; rec="${SYS_RECORDS}/${pair#*:}"
    [ -f "$rec" ] || continue
    if [ -e "$prof" ]; then
      must_sudo rm -f "$prof" && { changed=1; DONE+=("Removed ${prof}, which this script created"); }
    fi
    [ -e "$prof" ] || sudo rm -f "$rec"
  done
  # Created by the installer and owned by no package.
  if [ -d "$GDM_PROFILE_DIR" ] && [ -z "$(ls -A "$GDM_PROFILE_DIR" 2>/dev/null)" ] \
     && { [ -f "${SYS_RECORDS}/dconf-gdm-dir-created" ] \
          || ! dpkg -S "$GDM_PROFILE_DIR" > /dev/null 2>&1; }; then
    must_sudo rmdir "$GDM_PROFILE_DIR" && must_sudo rm -f /etc/dconf/db/gdm && changed=1
  fi
  [ -d "$GDM_PROFILE_DIR" ] || sudo rm -f "${SYS_RECORDS}/dconf-gdm-dir-created"
  # Also recompiles after an earlier failed dconf update.
  if [ $changed -eq 1 ]; then
    must_sudo dconf update
    REBOOT_NEEDED=1
  elif [ -d "$GDM_PROFILE_DIR" ] && [ "$GDM_PROFILE_DIR" -nt /etc/dconf/db/gdm ]; then
    must_sudo dconf update && DONE+=("Login screen database compiled without the Ubuntu look")
  else
    [ "$ext" -eq 1 ] || SKIPPED+=("No login screen theme to remove")
  fi
  return 0
}

step_restore_grub() {
  step "Restoring the kernel command line..."
  if [ ! -f "$GRUB_ADDED_FILE" ]; then
    SKIPPED+=("Kernel command line left alone — this script added nothing to it")
    return
  fi
  if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; then
    SKIPPED+=("GRUB is gone — the words this script added cannot be removed")
    sudo rm -f "$GRUB_ADDED_FILE"
    return
  fi
  local added
  added="$(tr '\n' ' ' < "$GRUB_ADDED_FILE")"
  strip_grub_words
  case $? in
    0) DONE+=("Removed '${added% }' from the kernel command line; the rest of /etc/default/grub is unchanged")
       REBOOT_NEEDED=1 ;;
    1) SKIPPED+=("/etc/default/grub no longer carries what ubuntu-look.sh added") ;;
    2) SKIPPED+=("/etc/default/grub is not in a shape this script will edit — remove '${added% }' by hand")
       SYSTEM_PENDING=1 ;;
    *) GUESSED+=("/etc/default/grub could not be updated — '${added% }' is still on the kernel command line")
       [ -n "$GRUB_BACKUP_KEPT" ] && GUESSED+=("the file as it was before that attempt is at ${GRUB_BACKUP_KEPT}")
       SYSTEM_PENDING=1 ;;
  esac
}

step_restore_plymouth() {
  step "Restoring the boot splash theme..."
  if [ ! -f "$PLYMOUTH_BEFORE_FILE" ]; then
    SKIPPED+=("Boot splash theme left as it is — this script did not change it")
    return
  fi
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    SKIPPED+=("Plymouth is gone — no theme to put back")
    sudo rm -f "$PLYMOUTH_BEFORE_FILE"
    return
  fi
  local current was ours pending="${SYS_RECORDS}/initramfs-pending"
  # The theme the install set: its record, else the saved option.
  ours="$(head -1 "${SYS_RECORDS}/plymouth-theme-set.txt" 2>/dev/null)"
  ours="${ours:-$PLYMOUTH_THEME}"
  current="$(plymouth_current_theme)"
  was="$(cat "$PLYMOUTH_BEFORE_FILE" 2>/dev/null)"
  if [ -z "$current" ]; then
    GUESSED+=("Could not read the boot splash theme — not restored")
    SYSTEM_PENDING=1
    return
  fi
  if [ -z "$was" ] || [ "$was" = "$current" ]; then
    # Set back by an earlier run whose initramfs rebuild failed.
    if [ ! -f "$pending" ] && [ -z "$was" ]; then
      SKIPPED+=("No earlier boot splash theme was recorded — left on '${current}'")
    elif [ ! -f "$pending" ]; then
      SKIPPED+=("Boot splash theme is already '${current}'")
    elif rebuild_initramfs; then
      sudo rm -f "$pending"
      DONE+=("Boot splash theme '${current}' rebuilt into the initramfs")
      REBOOT_NEEDED=1
    else
      GUESSED+=("The initramfs rebuild failed again — run: sudo update-initramfs -u")
      SYSTEM_PENDING=1
      return
    fi
  elif [ "$current" != "$ours" ]; then
    SKIPPED+=("Boot splash theme left on '${current}', which you chose after the install")
  elif ! sudo plymouth-set-default-theme "$was"; then
    GUESSED+=("Boot splash theme is still '${current}' — '${was}' may no longer be installed")
    SYSTEM_PENDING=1
    return
  elif rebuild_initramfs; then
    DONE+=("Boot splash theme restored to '${was}'")
    REBOOT_NEEDED=1
  else
    GUESSED+=("Boot splash theme set back, but the initramfs rebuild failed — run: sudo update-initramfs -u")
    sudo touch "$pending"
    SYSTEM_PENDING=1
    return
  fi
  sudo rm -f "$PLYMOUTH_BEFORE_FILE"
}

step_restore_removed_packages() {
  step "Putting back what an earlier version removed..."
  local pkg
  if [ ! -f "$REMOVED_RECORD" ]; then
    SKIPPED+=("No package was removed by an earlier version")
    return
  fi
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    is_installed "$pkg" && continue
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
      SKIPPED+=("${pkg}, removed by an earlier version, is no longer offered by any repository")
    elif installs_cleanly "$pkg" && sudo apt-get install -y "$pkg" < /dev/null; then
      restore_auto_mark "$pkg"
      DONE+=("Reinstalled ${pkg}")
    else
      GUESSED+=("Could not reinstall ${pkg}")
      SYSTEM_PENDING=1
    fi
  done < "$REMOVED_RECORD"
}

# The newest version of $1 not served by Ubuntu, i.e. Debian's.
debian_version_of() {
  LC_ALL=C apt-cache madison "$1" 2>/dev/null | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3)
      if ($3 !~ re) print $2 }' | sort -V | tail -1
}

# True when apt offers version $2 of $1 from any source.
version_available() {
  LC_ALL=C apt-cache madison "$1" 2>/dev/null | awk -F'|' -v v="$2" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2 == v) f = 1 } END { exit !f }'
}

# A Debian build the offline installer cached: version $2, else the newest.
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
    SYSTEM_PENDING=1
    return
  fi
  local pkg want deb
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    is_installed "$pkg" && continue
    want="$(debian_version_of "$pkg")"
    deb="$(cached_debian_deb "$pkg" "${want:-none}")" || deb=""
    if { [ -n "$want" ] && installs_cleanly "${pkg}=${want}" \
         && sudo apt-get install -y "${pkg}=${want}" < /dev/null; } \
       || { [ -n "$deb" ] && installs_cleanly "$deb" \
            && sudo apt-get install -y "$deb" < /dev/null; }; then
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
  local pkg ver now want deb restored=0 failed=0
  while read -r pkg ver; do
    [ -n "$pkg" ] && [ -n "$ver" ] || continue
    now="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
    if ! is_installed "$pkg"; then
      # Removed by the user: stays removed. Removed by prepare-upgrade: restored.
      grep -qxF "$pkg" "$REMOVED_FOR_UPGRADE" 2>/dev/null || continue
      now=""
    fi
    [ "$now" = "$ver" ] && continue
    # Keep a newer Debian build (a security update, say).
    if [ -n "$now" ] && [ ! -e "$UBUNTU_LIST" ] && [ ! -e "$OFFLINE_LOCAL_LIST" ] \
       && dpkg --compare-versions "$now" gt "$ver" && pkg_version_is_debian "$pkg" "$now"; then
      SKIPPED+=("${pkg} stays at ${now}, a newer Debian build than ${ver}")
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
    if { [ -n "$want" ] && installs_cleanly --allow-downgrades "${pkg}=${want}" \
         && sudo apt-get install -y --allow-downgrades "${pkg}=${want}" < /dev/null; } \
       || { [ -n "$deb" ] && want="$(dpkg-deb -f "$deb" Version)" \
            && installs_cleanly --allow-downgrades "$deb" \
            && sudo apt-get install -y --allow-downgrades "$deb" < /dev/null; }; then
      restore_auto_mark "$pkg"
      DONE+=("${pkg} back to ${want}${now:+ (was ${now})}")
      restored=$((restored + 1))
    else
      GUESSED+=("${pkg} is still ${now:-not installed} — ${want} will not install (it may need the network)")
      [ -n "$now" ] && RESTORE_FAILED="${RESTORE_FAILED} ${pkg}"
      SYSTEM_PENDING=1; failed=1
    fi
  done < "$UPGRADED_MANIFEST"
  [ "$restored" -eq 0 ] && [ "$failed" -eq 0 ] && SKIPPED+=("The earlier versions of replaced packages are already in place")
  return 0
}

step_remove_ubuntu_repo() {
  step "Removing the Ubuntu apt source, pin and keyring..."
  local changed=0 f
  for f in "$UBUNTU_LIST" "$UBUNTU_PIN" "$OFFLINE_LOCAL_LIST" "$UNATTENDED_ORIGINS"; do
    [ -f "$f" ] && must_sudo rm -f "$f" && changed=1
  done
  # The keyring of earlier versions, unless another source uses it.
  if [ -f "$LEGACY_UBUNTU_KEYRING" ]; then
    if grep -rqsF "$LEGACY_UBUNTU_KEYRING" /etc/apt/sources.list /etc/apt/sources.list.d/; then
      SKIPPED+=("${LEGACY_UBUNTU_KEYRING} kept — another apt source uses it")
    else
      must_sudo rm -f "$LEGACY_UBUNTU_KEYRING" && changed=1
    fi
  fi
  [ $changed -eq 1 ] && DONE+=("Removed the Ubuntu apt source and pin")
  # The apt files a killed --download saved; the next run would put them back.
  sudo rm -rf "$DOWNLOAD_SAVED"
  # Drop the Ubuntu lists, so restores take Debian's builds.
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

# Remove the installer's mask, kept while the look's session-migration stays.
step_unmask_session_migration() {
  if [ "$(readlink "$SESSION_MIGRATION_MASK" 2>/dev/null)" != /dev/null ]; then
    sudo rm -f "$SESSION_MIGRATION_MASKED"
    return 0
  fi
  [ -f "$SESSION_MIGRATION_MASKED" ] \
    || grep -qxF session-migration "$INSTALLED_MANIFEST" 2>/dev/null || return 0
  if is_installed session-migration && ! predates_install session-migration; then
    # Not unfinished work: the mask simply stays with the package.
    SKIPPED+=("session-migration stays masked while it is installed")
    return 0
  fi
  must_sudo rm -f "$SESSION_MIGRATION_MASK" \
    && sudo rm -f "$SESSION_MIGRATION_MASKED" && DONE+=("Unmasked session-migration")
}

# Remove the Debian builds the offline installer cached, and apt's downloads
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
  for pkg in $(cat "$INSTALLED_MANIFEST" 2>/dev/null; awk '{ print $1 }' "$UPGRADED_MANIFEST" 2>/dev/null); do
    have="$(pkg_installed_version "$pkg")"
    for f in /var/cache/apt/archives/"${pkg}"_*.deb; do
      [ -f "$f" ] || continue
      [ -n "$have" ] && [ "$(dpkg-deb -f "$f" Version 2>/dev/null)" = "$have" ] && continue
      sudo rm -f "$f" && m=$((m + 1))
    done
  done
  [ "$n" -gt 0 ] && DONE+=("Removed ${n} Debian package file(s) the offline install placed in apt's cache")
  [ "$m" -gt 0 ] && DONE+=("Removed ${m} downloaded package file(s) of the look from apt's cache")
  return 0
}

step_remove_packages() {
  step "Removing packages..."
  local list="" pkg keep="" dep extra cand changed=1

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

  if [ ! -s "$INSTALLED_MANIFEST" ]; then
    SKIPPED+=("No record of installed packages — no package removed")
    return
  fi
  for pkg in $(sort -u "$INSTALLED_MANIFEST"); do
    predates_install "$pkg" && continue
    in_word_list "$pkg" "$keep" && continue
    if is_config_only "$pkg"; then
      grep -qxF "$pkg" "$CONFIG_FILES_BEFORE" 2>/dev/null && continue
      list="${list} ${pkg}"
    elif is_installed "$pkg"; then
      list="${list} ${pkg}"
    fi
  done

  # Drop any candidate whose purge would take a non-candidate.
  while [ -n "${list// /}" ] && [ "$changed" -eq 1 ]; do
    changed=0
    # shellcheck disable=SC2086
    extra="$(LC_ALL=C apt-get -s purge $list 2>/dev/null | awk '/^(Remv|Purg) /{print $2}' \
             | while read -r pkg; do in_word_list "$pkg" "$list" || echo "$pkg"; done | xargs)"
    [ -n "$extra" ] || break
    for cand in $list; do
      if LC_ALL=C apt-get -s purge "$cand" 2>/dev/null | awk '/^(Remv|Purg) /{print $2}' \
           | grep -qxF -f <(printf '%s\n' $extra); then
        list="$(printf '%s\n' $list | grep -vxF "$cand" | xargs)"
        SKIPPED+=("${cand} kept — removing it would also remove: ${extra}")
        changed=1
      fi
    done
  done

  if ! purge_list "$list"; then
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
echo "    installed, apt source and pin, login screen, boot splash, refresh timer"
echo "Every setting it made goes back to Debian's default. Your dash favourites, and"
echo "the packages and apps you had before or installed later, are kept."
[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ ! -S "/run/user/$(id -u)/bus" ] \
  && message warn "No desktop session: your settings are reset on a later run from the desktop."
echo ""
confirm_continue

sudo -v || error "sudo is required."

adopt_session_bus

# Wait for any run in progress; from here no other run can start.
take_run_lock wait || error "Could not take the run lock ${UBUNTU_LOOK_LOCK}."

migrate_home_records
OTHERS="$(other_users)"
LAST_USER=1
[ -n "$OTHERS" ] && LAST_USER=0
# Stop the timer now, so no refresh waits on the lock and runs after the uninstall.
[ "$LAST_USER" -eq 1 ] && { sudo systemctl disable --now ubuntu-look-refresh.timer >/dev/null 2>&1 || true; }

# A user who never installed the look keeps their settings as they are.
if grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null || [ -d "$BACKUP_DIR" ] || [ -f "$LOOK_ENV_FILE" ]; then
  step_disable_look_profile
  [ "$LAST_USER" -eq 1 ] && step_empty_look_defaults
  step_extensions
  step_restore_tiling_keybindings
  step_restore_gnome_settings
  step_restore_dock_settings
  step_remove_extension_autostart
  step_remove_app_grid_icon
  step_remove_theme_followers
  step_restore_gtk
  step_terminal_profile
  step_restore_software_icon
  remove_legacy_ding && DONE+=("Removed the desktop-icons copy an earlier version installed")

  # session-migration's record, where the look brought session-migration in.
  grep -qxF session-migration "$INSTALLED_MANIFEST" 2>/dev/null \
    && rm -f "$HOME/.local/share/session_migration-gnome"

  # Directories the installer created, where now empty.
  for _d in "$HOME/.config/autostart" "$HOME/.config/systemd/user/graphical-session.target.wants" \
            "$HOME/.config/systemd/user" "$HOME/.config/systemd" \
            "$HOME/.local/bin" "$HOME/.local/share/icons"; do
    rmdir "$_d" 2>/dev/null || true
  done
else
  SKIPPED+=("No settings of the look recorded for ${RUN_USER} — settings left unchanged")
fi

# This user no longer uses the look.
if grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null; then
  _users_tmp="$(mktemp)"
  grep -vxF "$RUN_USER" "$SYS_USERS" > "$_users_tmp"
  must_sudo install -m 0644 "$_users_tmp" "$SYS_USERS"
  rm -f "$_users_tmp"
fi

if [ "$LAST_USER" -eq 1 ]; then
  step_remove_refresh_timer
  step_remove_dconf_profile
  step_remove_gdm_profile
  step_restore_grub
  step_restore_plymouth
  # Without the Ubuntu source and pin, restores take Debian's builds.
  step_remove_ubuntu_repo
  step_restore_removed_packages
  # Before any purge: Ubuntu's yaru-theme-gtk depends on session-migration.
  step_restore_upgraded_packages
  step_remove_packages
  step_restore_replaced_by_combined
  # Also retries a repair that failed earlier.
  repair_dashtodock
  step_unmask_session_migration
  step_remove_cached_debs
else
  SKIPPED+=("System changes kept — the look is still used by: ${OTHERS}")
fi

echo ""
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
echo -e "${GREEN}                    UNINSTALL SUMMARY${ENDCOLOR}"
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
[ ${#DONE[@]} -gt 0 ] && { echo -e "${GREEN}Restored/removed:${ENDCOLOR}"; printf '   + %s\n' "${DONE[@]}"; }
[ ${#GUESSED[@]} -gt 0 ] && { echo -e "${YELLOW}Could not finish:${ENDCOLOR}"; printf '   ? %s\n' "${GUESSED[@]}"; }
[ ${#SKIPPED[@]} -gt 0 ] && { echo -e "${YELLOW}Skipped:${ENDCOLOR}"; printf '   - %s\n' "${SKIPPED[@]}"; }
echo ""

# System records go once all system work is done.
if [ "$LAST_USER" -eq 1 ]; then
  if [ "$SYSTEM_PENDING" -eq 0 ]; then
    # Settings still to restore need to know which extensions came with the look.
    if [ "$USER_PENDING" -eq 1 ] && [ -f "$INSTALLED_MANIFEST" ]; then
      mkdir -p "$BACKUP_DIR" && cp "$INSTALLED_MANIFEST" "$MANIFEST_COPY"
    fi
    sudo rm -rf "$SYS_DIR"
    # The lock of earlier versions goes. The current one (/run/ubuntu-look.lock)
    # stays, as a waiting run may hold it; /run is cleared at boot.
    sudo rm -f /run/lock/ubuntu-look.lock
  else
    message warn "Keeping ${SYS_DIR}: system work is unfinished. Run this again to finish it."
  fi
fi

# User records go once the settings are restored.
if [ -d "$BACKUP_DIR" ]; then
  if [ "$USER_PENDING" -eq 1 ]; then
    message warn "Keeping ${BACKUP_DIR}: run 'bash ubuntu-look.sh --uninstall' again from your desktop to reset your settings."
  else
    rm -rf "$BACKUP_DIR"
    message "Removed ${BACKUP_DIR}"
  fi
fi

if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for the boot splash, kernel command line and login screen."
  echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
else
  echo -e "${YELLOW}Log out and back in for all changes to take effect.${ENDCOLOR}"
fi
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
exit $((USER_PENDING || SYSTEM_PENDING))
fi

###############################################################################
# 9. Install
###############################################################################

case "${arguments}" in
  prepare-upgrade|--prepare-upgrade)
    [ "$MODE" = online ] || error "--prepare-upgrade takes no mode flag."
    prepare_debian_upgrade
    exit 0
    ;;
esac

package_categories="$(echo "${arguments:-${!packages[*]}}" | xargs -n1 | sort -u | xargs)"
for category in $package_categories; do
  [ -n "${packages[$category]:-}" ] || error "Unknown stage '${category}'.
  Valid stages: $(echo "${!packages[@]}" | xargs -n1 | sort | xargs)"
done

[ "$MODE" = download ] && download_mode
# Check the bundle before changing anything.
[ "$MODE" = offline ] && load_bundle

if [ "$REFRESH" = 1 ]; then
  take_run_lock; _lock_rc=$?
  [ "$_lock_rc" -eq 2 ] && error "Could not create or open the run lock ${UBUNTU_LOOK_LOCK}."
  [ "$_lock_rc" -eq 1 ] && { message "another ubuntu-look run is in progress — leaving it to that one"; REFRESH_NOOP=1; exit 0; }
  message "unattended refresh"
  # Only a finished install is kept current.
  if [ ! -f "$PACKAGES_BEFORE" ] || ! grep -q '^# pin-version: ' "$UBUNTU_PIN" 2>/dev/null; then
    message "the Ubuntu look is not installed here — nothing to refresh"
    REFRESH_NOOP=1
    exit 0
  fi
else
  message "Welcome to ${GREEN}ubuntu-look${ENDCOLOR} — make Debian GNOME look like Ubuntu!"
  message ""
  message "Applies the Ubuntu look for user ${YELLOW}${RUN_USER}${ENDCOLOR}. Stages: ${YELLOW}${package_categories}${ENDCOLOR}"
  [ "$MODE" = offline ] && message "Offline: packages come from ${YELLOW}${PACKAGES_DIR}${ENDCOLOR} (Ubuntu ${UBUNTU_CODENAME})."
  if [ -d "$BACKUP_ORIGINAL" ] && [ ! -f "$DEFAULTS_PENDING" ]; then
    message "Re-run: your own theme, wallpaper, dock and other settings are kept."
  else
    message "First install: Ubuntu's defaults replace your theme, wallpaper, dock and other"
    message "settings, as on a fresh Ubuntu. Your dash favourites are kept."
  fi
  message "Safe to re-run. Undo with: bash ubuntu-look.sh --uninstall"
  message ""
  confirm_continue
  sudo -v || error "User ${RUN_USER} cannot use sudo."
  take_run_lock wait || error "Could not take the run lock ${UBUNTU_LOOK_LOCK}."
fi

# A bundle source left by an older offline run.
[ -f "$OFFLINE_LOCAL_LIST" ] && sudo rm -f "$OFFLINE_LOCAL_LIST"

if [ "$REFRESH" != 1 ]; then
  migrate_home_records

  adopt_session_bus

  # Per-user snapshot, taken once.
  FIRST_RUN_FOR_USER=0
  if [ ! -d "$BACKUP_ORIGINAL" ]; then
    FIRST_RUN_FOR_USER=1
    message "first run for ${RUN_USER} — saving your settings to ${BACKUP_ORIGINAL} (for the uninstall)"
    mkdir -p "$BACKUP_ORIGINAL"
    while read -r _src _dst; do
      [ -f "$HOME/$_src" ] && cp "$HOME/$_src" "${BACKUP_ORIGINAL}/$_dst" 2>/dev/null
    done <<'EOF'
.config/gtk-3.0/gtk.css gtk-3.0-gtk.css
.config/gtk-4.0/gtk.css gtk-4.0-gtk.css
.config/gtk-3.0/settings.ini gtk-3.0-settings.ini
.config/gtk-4.0/settings.ini gtk-4.0-settings.ini
.gtkrc-2.0 gtkrc-2.0
.local/share/applications/org.gnome.Software.desktop org.gnome.Software.desktop
EOF
    # dconf reads the database file itself; no session is needed.
    command -v dconf >/dev/null 2>&1 \
      && user_dconf dump / > "${BACKUP_ORIGINAL}/dconf-dump.ini"
    # Ubuntu's defaults are applied from a desktop session, now or on a later run.
    : > "$DEFAULTS_PENDING"
    echo "ubuntu-look.sh pre-install snapshot — $(date -Iseconds)" > "${BACKUP_ORIGINAL}/INFO"
    STATUS_CHANGES+=("Your pre-install settings saved → ${BACKUP_ORIGINAL}")
  else
    STATUS_NOCHANGE+=("Your pre-install settings snapshot already exists")
  fi

  # System snapshot, taken once.
  record_packages_before

  # Users with the look; system changes are undone when the last one uninstalls.
  grep -qxF "$RUN_USER" "$SYS_USERS" 2>/dev/null || sys_record_append "$SYS_USERS" "$RUN_USER"
fi

if [ "$MODE" = offline ]; then
  prepare_offline
else

step "Configure Ubuntu archive candidate sources"

# curl reads the archive. Generic tools, not recorded; a refresh installs none.
_missing_prereqs="$(missing_packages "curl ca-certificates")"
if [ -n "$_missing_prereqs" ]; then
  if [ "$REFRESH" = 1 ]; then
    message warn "missing: ${_missing_prereqs} — run ubuntu-look.sh by hand to install them"
    REFRESH_NOOP=1
    exit 0
  fi
  sudo apt-get update -qq || message warn "apt update reported an error"
  for prereq in $_missing_prereqs; do
    installs_cleanly "$prereq" \
      || error "Installing prerequisite ${prereq} would remove packages or cannot be done — install it by hand"
    sudo apt-get install -y "$prereq" || error "Failed to install prerequisite: $prereq"
    STATUS_CHANGES+=("Installed prerequisite: $prereq (kept on uninstall)")
  done
fi

# Read every run, so a new release is found at once.
message "reading published Ubuntu releases from ${UBUNTU_MIRROR}..."
UBUNTU_ALL_CODENAMES="$(discover_ubuntu_codenames)"
if [ -z "$UBUNTU_ALL_CODENAMES" ] && [ "$REFRESH" = 1 ]; then
  message warn "no Ubuntu release reachable — trying again at the next refresh"
  REFRESH_NOOP=1
  exit 0
fi
refresh_gate
# A refresh blocks shutdown, so dpkg is never cut off.
if [ "$REFRESH" = 1 ] && command -v systemd-inhibit >/dev/null 2>&1; then
  systemd-inhibit --what=shutdown:sleep --who=ubuntu-look \
    --why="Updating the Ubuntu look" sleep infinity 9<&- >/dev/null 2>&1 &
  INHIBIT_PID=$!
fi
[ -z "$UBUNTU_ALL_CODENAMES" ] \
  && error "No Ubuntu release reachable at ${UBUNTU_MIRROR} — check your internet connection."

UBUNTU_CANDIDATE_CODENAMES="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' \
  | tail -n "$MAX_UBUNTU_CANDIDATES" | xargs)"

# A forced UBUNTU_CODENAME is configured even outside that window.
[[ "$UBUNTU_CODENAME" =~ ^[a-z]+$ ]] \
  || error "UBUNTU_CODENAME must be a codename in lower case letters, or auto."
if [ "$UBUNTU_CODENAME" != "auto" ] && ! in_word_list "$UBUNTU_CODENAME" "$UBUNTU_CANDIDATE_CODENAMES"; then
  ubuntu_release_info "$UBUNTU_CODENAME" >/dev/null \
    || error "UBUNTU_CODENAME=${UBUNTU_CODENAME} is not published on ${UBUNTU_MIRROR} or ${UBUNTU_OLD_MIRROR}"
  UBUNTU_CANDIDATE_CODENAMES="$UBUNTU_CANDIDATE_CODENAMES $UBUNTU_CODENAME"
fi
message "Ubuntu releases in play (oldest to newest): ${GREEN}${UBUNTU_CANDIDATE_CODENAMES}${ENDCOLOR}"

# Nothing changed since the last full run: the sources are not widened.
KEEP_SOURCES=0
if [ "$REFRESH" != 1 ] && [ "$UBUNTU_CODENAME" = auto ] && unchanged_since_last_run; then
  KEEP_SOURCES=1
  UBUNTU_CODENAME="$KEPT_CODENAME"
  # A looked-back release stays in the list's header.
  in_word_list "$UBUNTU_CODENAME" "$UBUNTU_CANDIDATE_CODENAMES" \
    || UBUNTU_CANDIDATE_CODENAMES="$UBUNTU_CODENAME $UBUNTU_CANDIDATE_CODENAMES"
  message "no new Ubuntu release, no Debian or gnome-shell change — keeping ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} without fetching the other releases"
fi

# Ubuntu's archive keys, from Debian's own package.
if ! is_installed ubuntu-keyring; then
  [ "$REFRESH" = 1 ] && error "ubuntu-keyring is not installed — run ubuntu-look.sh by hand."
  sudo apt-get update -qq || message warn "apt update reported an error"
  installs_cleanly ubuntu-keyring && apt_install_recorded ubuntu-keyring >/dev/null \
    || error "Could not install Debian's ubuntu-keyring package (Ubuntu's archive keys)."
  STATUS_CHANGES+=("Installed ubuntu-keyring (Ubuntu's archive keys, from Debian)")
fi
[ -s "$UBUNTU_KEYRING" ] || error "${UBUNTU_KEYRING} is missing — reinstall ubuntu-keyring."

# Block every Ubuntu package until the full pin is written.
write_provisional_pin \
  && message "Ubuntu packages blocked by default until the theme pin is resolved"

# Saved so a failing source list can be put back.
PREV_UBUNTU_LIST="$(mktemp)"
cp "$UBUNTU_LIST" "$PREV_UBUNTU_LIST" 2>/dev/null || : > "$PREV_UBUNTU_LIST"
# Only a net change of the list is reported.
INITIAL_UBUNTU_LIST="$(cat "$UBUNTU_LIST" 2>/dev/null)"
PINNED_BEFORE="$(pinned_codename)"

if [ "$KEEP_SOURCES" = 1 ]; then
  message "Ubuntu sources not widened: $(configured_codenames | xargs)"
else
  write_ubuntu_sources
  case $? in
    0) message "configuring Ubuntu archive candidates: ${UBUNTU_CANDIDATE_CODENAMES}" ;;
    1) message "Ubuntu candidate sources already current" ;;
    *) message warn "no Ubuntu archive answered — the source list is left as it was" ;;
  esac
fi

step "Refresh package lists"
# A failing Ubuntu source would break every apt update.
if ! apt_update; then
  restore_prev_ubuntu_list
  error "apt update failed for the Ubuntu sources — they were put back as they were."
fi
# An unserved architecture yields an empty Ubuntu index.
if ! LC_ALL=C apt-cache madison gnome-shell-extension-ubuntu-dock yaru-theme-icon 2>/dev/null \
     | awk -F'|' -v re="$UBUNTU_HOSTS_RE" '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); if ($3 ~ re) f = 1 } END { exit !f }'; then
  restore_prev_ubuntu_list
  error "${UBUNTU_MIRROR} serves no Ubuntu packages for ${UBUNTU_ARCH} — the sources were put back as they were."
fi
rm -f "$PREV_UBUNTU_LIST"

# The keyring earlier versions wrote.
remove_legacy_keyring

step "Resolve Ubuntu theme codename"

if [ "$UBUNTU_CODENAME" = "auto" ]; then
  UBUNTU_CODENAME="$(resolve_ubuntu_codename)"
  _newest="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $NF}')"
  _debian_shell="$(shell_major)"
  _newest_shell="$(ubuntu_shell_major "$_newest")"

  if [ -z "$UBUNTU_CODENAME" ] && [ -n "$_debian_shell" ] && [ -n "$_newest_shell" ] \
     && [ "$_debian_shell" -gt "$_newest_shell" ]; then
    # gnome-shell is newer than every Ubuntu release.
    UBUNTU_CODENAME="$_newest"
    message warn "gnome-shell ${_debian_shell} is newer than any Ubuntu release — pinning the newest, ${UBUNTU_CODENAME}"
  elif [ -z "$UBUNTU_CODENAME" ]; then
    message warn "no Ubuntu release in the current window has a theme this gnome-shell can load"
    # The pinned release first, then older listed releases, then retired ones.
    if [ -n "$PINNED_BEFORE" ] && ! in_word_list "$PINNED_BEFORE" "$UBUNTU_CANDIDATE_CODENAMES"; then
      try_older_releases "$PINNED_BEFORE"
    fi
    if [ -z "$UBUNTU_CODENAME" ]; then
      _older="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' \
        | head -n -"$MAX_UBUNTU_CANDIDATES" | tail -n "$MAX_UBUNTU_LOOKBACK" | xargs)"
      [ -n "$_older" ] && try_older_releases "$_older"
    fi
    if [ -z "$UBUNTU_CODENAME" ]; then
      _older="$(discover_retired_codenames)"
      [ -n "$_older" ] && try_older_releases "$_older"
    fi
  fi

  # Still nothing: pin the oldest candidate; the theme and dock are reported.
  if [ -z "$UBUNTU_CODENAME" ]; then
    UBUNTU_CODENAME="$(echo "$UBUNTU_CANDIDATE_CODENAMES" | awk '{print $1}')"
    message warn "no Ubuntu release ships a shell theme for this gnome-shell — pinning ${UBUNTU_CODENAME}"
  elif ! { [ "$UBUNTU_CODENAME" = "$_newest" ] && [ -n "${_newest_shell:-}" ] \
           && [ "${_debian_shell:-0}" -gt "$_newest_shell" ]; }; then
    message "auto-detected Ubuntu codename ${GREEN}${UBUNTU_CODENAME}${ENDCOLOR} ($(gnome-shell --version 2>/dev/null || echo 'gnome-shell not installed')) — verified via simulated install"
  fi
fi

# Rewrite a missing, provisional, outdated or other-release pin.
NEED_PIN_REWRITE=1
if [ ! -f "$UBUNTU_PIN" ] || grep -q '^# provisional' "$UBUNTU_PIN"; then
  :
elif ! grep -q "# pin-version: ${PIN_VERSION}" "$UBUNTU_PIN"; then
  message warn "Ubuntu theme pin is from an older script version — rewriting"
elif ! grep -q "n=${UBUNTU_CODENAME}\$" "$UBUNTU_PIN"; then
  message warn "Ubuntu release changed to ${UBUNTU_CODENAME} — rewriting theme pin"
else
  NEED_PIN_REWRITE=0
fi
if [ "$NEED_PIN_REWRITE" = 1 ]; then
  write_ubuntu_pin
  STATUS_CHANGES+=("Ubuntu theme pin applied (${UBUNTU_CODENAME})")
else
  message "Ubuntu theme pin already current (${UBUNTU_CODENAME})"
  STATUS_NOCHANGE+=("Ubuntu theme pin already current")
fi

# Only the pinned release stays configured.
narrow_ubuntu_sources
# The apt files a killed --download saved; the sources and pin above replace them.
sudo rm -rf "$DOWNLOAD_SAVED"

fi

step "System upgrade (only with UBUNTU_LOOK_SYSTEM_UPGRADE=1)"
if [ "${UBUNTU_LOOK_SYSTEM_UPGRADE:-0}" = "1" ]; then
  upgradable_before="$(apt-get -s upgrade --with-new-pkgs "${APT_OPTS[@]}" 2>/dev/null | grep -c '^Inst ')"
  if [ "$upgradable_before" -gt 0 ]; then
    message warn "UBUNTU_LOOK_SYSTEM_UPGRADE=1 — upgrading ${upgradable_before} package(s) system-wide"
    # Not fatal: a held package or third-party repository must not stop the look.
    if sudo apt-get upgrade -y --with-new-pkgs "${APT_OPTS[@]}"; then
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
  message "  this script upgrades only the packages its stages name"
  STATUS_NOCHANGE+=("System-wide apt upgrade skipped (UBUNTU_LOOK_SYSTEM_UPGRADE=1 to enable)")
fi

use_combined_extensions_if_offered

for category in $package_categories; do
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

  # Split into installs and upgrades. A refresh installs nothing new: a missing
  # package may have been removed on purpose.
  declare -A PKG_BEFORE=()
  to_install=""
  to_upgrade=""
  for p in $available; do
    _have="$(pkg_installed_version "$p")"
    _cand="$(pkg_candidate_version "$p")"
    PKG_BEFORE[$p]="$_have"
    if [ -z "$_have" ]; then
      [ "$REFRESH" = 1 ] || to_install="$to_install $p"
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

    # Record replaced builds before apt runs.
    for p in $to_upgrade; do record_upgraded_pkg "$p" "${PKG_BEFORE[$p]:-}"; done

    # Simulate first; a batch that would remove something is never run.
    _batch_ok=1
    # shellcheck disable=SC2086
    _batch_sim="$(LC_ALL=C apt-get -s install "${APT_OPTS[@]}" $to_change 2>&1)" || _batch_ok=0
    _batch_removes="$(unexpected_removals "$_batch_sim")"
    [ "$_batch_ok" = 1 ] \
      || message warn "apt cannot resolve this stage as one batch — going package by package"
    if [ -n "$_batch_removes" ]; then
      message warn "installing this stage as one batch would REMOVE: ${_batch_removes}"
      message warn "not doing that — falling back to one package at a time"
    elif [ "$_batch_ok" = 1 ]; then
      record_planned_installs "$_batch_sim"
      # shellcheck disable=SC2086
      sudo apt-get install -y "${APT_OPTS[@]}" $to_change \
        || message warn "batch install failed — retrying one package at a time"
    fi

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
    prune_installed_manifest
  fi

  case $category in
    0-base)
      # A refresh never touches the bootloader.
      [ "$REFRESH" = 1 ] && continue
      if ! has_boot_splash_tools; then
        STATUS_NOCHANGE+=("No GRUB or update-initramfs on this system — boot splash left alone")
      elif [ "$UBUNTU_BOOT_SPLASH" = "0" ]; then
        revert_boot_splash
      else
        apply_boot_splash
      fi
      ;;

    2-desktop-gnome)
      # Ubuntu's default wallpaper; the file names are the same in every release.
      WP_LIGHT=/usr/share/backgrounds/warty-final-ubuntu.png
      WP_DARK=/usr/share/backgrounds/ubuntu-wallpaper-d.png

      # System defaults, read at the next login.
      message "writing Ubuntu's GNOME defaults"
      write_dconf_profile "$WP_LIGHT" "$WP_DARK"
      install_theme_extension

      # A refresh leaves the user's session and home alone.
      if [ "$REFRESH" = 1 ]; then
        write_gdm_profile "$WP_LIGHT" "$WP_DARK"
        continue
      fi

      # From the next login on; only with the profile in place, or dconf has no database.
      if [ -f "$LOOK_PROFILE" ]; then
        enable_look_for_user
        case $? in
          0) STATUS_CHANGES+=("The look is enabled for ${RUN_USER} → ${LOOK_ENV_FILE} (from the next login)")
             RELOGIN_NEEDED=1 ;;
          2) STATUS_FAILED+=("${LOOK_ENV_FILE} could not be written — your sessions keep Debian's defaults") ;;
        esac
        export DCONF_PROFILE="$LOOK_PROFILE_NAME"
      fi

      if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        message "live session detected — extensions and shell theme set now; the rest from the next login"

        # Fresh install: Ubuntu's defaults. Later runs keep the user's own values
        # and hand the rest back to the profile once the session reads it.
        if [ -f "$DEFAULTS_PENDING" ]; then
          apply_ubuntu_defaults
        elif [ -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ]; then
          if session_on_look_profile; then
            reclaim_live_settings
          else
            STATUS_NOCHANGE+=("Your own copies of Ubuntu's settings are handed back on the next run after you log in again")
          fi
        fi

        turn_off_dash_to_dock

        # Restart the tiling assistant when mutter's own tiling came back on beside it.
        if extension_active tiling-assistant@ubuntu.com \
           && [ "$(gsettings get org.gnome.mutter edge-tiling 2>/dev/null)" = true ]; then
          gnome-extensions disable tiling-assistant@ubuntu.com 2>/dev/null \
            && gnome-extensions enable tiling-assistant@ubuntu.com 2>/dev/null \
            && STATUS_CHANGES+=("Tiling assistant restarted — mutter's own tiling had come back on beside it")
        fi

        # Only extensions not switched on for this user before: the running shell
        # first, for an immediate effect, then the user database.
        seed_extensions_record
        EXT_TODO="$(extensions_to_switch_on all)"
        EXT_ON_BEFORE="$(user_dconf_read /org/gnome/shell/enabled-extensions)"
        for ext in $EXT_TODO; do
          gnome-extensions enable "$ext" 2>/dev/null
        done
        # shellcheck disable=SC2086
        enable_shell_extensions $EXT_TODO

        # Verify in the user database; the shell lists new packages only after re-login.
        ENABLED_NOW="$(user_dconf_read /org/gnome/shell/enabled-extensions)"
        EXT_FAILED_NOW=0; EXT_SWITCHED_ON=""; EXT_RECORDED=0
        for ext in $EXT_TODO; do
          case "$ENABLED_NOW" in
            *"'${ext}'"*) record_extensions_on "$ext"
                          EXT_RECORDED=1
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
        if [ -n "$EXT_SWITCHED_ON" ]; then
          STATUS_CHANGES+=("Extensions switched on:${EXT_SWITCHED_ON}")
        elif [ "$EXT_RECORDED" = 1 ] && [ "$EXT_FAILED_NOW" = 0 ]; then
          STATUS_NOCHANGE+=("The look's extensions are on — any you turn off later stay off")
        fi

        # The theme extension carries the shell theme now.
        retire_user_theme
      else
        message warn "No D-Bus session detected — your settings apply from the next login."
        [ -f "$DEFAULTS_PENDING" ] \
          && STATUS_FAILED+=("Ubuntu's defaults are not applied yet — run this script again from your desktop session")
        turn_off_dash_to_dock
      fi

      # Forced-dark GTK settings.
      for f in "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"; do
        grep -qs '^gtk-application-prefer-dark-theme=1$' "$f" || continue
        sed -i '/^gtk-application-prefer-dark-theme=1$/d' "$f"
        [ -z "$(grep -v '^\[Settings\]$' "$f" | tr -d '[:space:]')" ] && rm -f "$f"
        STATUS_CHANGES+=("Removed legacy gtk-application-prefer-dark-theme=1 from $(basename "$(dirname "$f")")")
        RELOGIN_NEEDED=1
      done

      # The user-local desktop-icons copy and the shell theme follower.
      remove_legacy_ding \
        && STATUS_CHANGES+=("Removed the desktop-icons copy an earlier version installed — Debian's is used")
      remove_theme_followers \
        && STATUS_CHANGES+=("Removed the shell theme follower of earlier versions — the theme extension follows light and dark")

      restore_dock_favourites

      # Debian packages an earlier version removed, reinstalled if nothing else goes.
      if [ -f "$REMOVED_RECORD" ]; then
        _restored_all=1
        while read -r _rpkg; do
          [ -n "$_rpkg" ] || continue
          is_installed "$_rpkg" && continue
          if installs_cleanly "$_rpkg" && sudo apt-get install -y "${APT_OPTS[@]}" "$_rpkg" < /dev/null; then
            STATUS_CHANGES+=("Reinstalled ${_rpkg}, which an earlier version had removed")
          else
            _restored_all=0
            STATUS_FAILED+=("${_rpkg}, removed by an earlier version, could not be reinstalled")
          fi
        done < "$REMOVED_RECORD"
        [ $_restored_all -eq 1 ] && sudo rm -f "$REMOVED_RECORD"
      fi

      message "applying Ubuntu's terminal colours"
      install_terminal_profile

      message "setting the Show Applications button icon"
      install_app_grid_icon

      message "theming the login screen"
      write_gdm_profile "$WP_LIGHT" "$WP_DARK"

      # Ubuntu writes no user GTK files: undo what earlier versions wrote there,
      # restoring the user's own gtk-3.0/gtk.css from the snapshot.
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
        STATUS_NOCHANGE+=("Your ~/.gtkrc-2.0 left alone, as on Ubuntu")
      fi

      # The GNOME Software launcher copy.
      SOFTWARE_DESKTOP_USER="$HOME/.local/share/applications/org.gnome.Software.desktop"
      if [ -f "$SOFTWARE_DESKTOP_USER" ] \
         && grep -q '^Icon=app-center$' "$SOFTWARE_DESKTOP_USER" 2>/dev/null; then
        rm -f "$SOFTWARE_DESKTOP_USER"
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
        STATUS_CHANGES+=("Removed the GNOME Software launcher copy an earlier version wrote")
        RELOGIN_NEEDED=1
      fi
      ;;
  esac
done

# Only the stage that adds the per-user switch turns extensions on.
case " $package_categories " in
  *" 2-desktop-gnome "*) [ "$REFRESH" = 1 ] || install_extension_autostart ;;
esac

# Every look package onto the pinned release.
align_look_packages
prune_installed_manifest
prune_replaced_by_combined
if [ "$MODE" = offline ]; then
  cache_replaced_debs
  narrow_without_archive
fi

# Report anything that no longer matches the running gnome-shell.
check_shell_coupling_drift

# A full run records its options for the refresh timer. A refresh with apt
# errors records nothing, so the change is retried.
if [ "$REFRESH" = 1 ]; then
  if [ "$APT_ERRORS" -gt 0 ]; then
    message warn "apt reported ${APT_ERRORS} error(s) — this change is retried in a week"
    exit 1
  fi
  save_refresh_state
elif [ -z "$arguments" ]; then
  # Packages prepare-upgrade removed and this run could not restore stay recorded.
  if [ -f "$REMOVED_FOR_UPGRADE" ]; then
    _left=""
    while read -r _p; do
      [ -n "$_p" ] && ! is_installed "$_p" && _left="${_left}${_p}"$'\n'
    done < "$REMOVED_FOR_UPGRADE"
    if [ -n "$_left" ]; then
      printf '%s' "$_left" | sudo tee "$REMOVED_FOR_UPGRADE" > /dev/null
    else
      sudo rm -f "$REMOVED_FOR_UPGRADE"
    fi
  fi
  save_options
  if [ "$MODE" = online ]; then
    install_refresh_timer
    save_refresh_state
  fi
fi

message "${GREEN}All steps finished. See SUMMARY below.${ENDCOLOR}"
