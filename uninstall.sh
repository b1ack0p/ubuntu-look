#!/bin/bash
# =============================================================================
# Title       : uninstall.sh
# Description : Reverts ubuntu-look.sh. Only what that script applied is undone:
#                 * Packages are taken from the manifest it writes, never by
#                   name pattern, and never if they predate the first install.
#                 * GNOME settings are restored key by key, and only where the
#                   key still holds the value the script set.
#                 * Orphaned dependencies are removed only if they appeared
#                   after the first install.
#
#               Without a snapshot, from an install predating that feature, the
#               script falls back to best-effort detection and reports each
#               step where it is guessing.
#
# Usage       : bash uninstall.sh
# Overrides   : UBUNTU_LOOK_LOG=0         do not write a run log
#
# Requires    : the system ubuntu-look.sh was run on, user in the 'sudo' group.
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
  _log_file="${HOME}/uninstall-$(date +%Y%m%d-%H%M%S).log"

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


# Ignore SIGHUP so the run cannot be aborted between a purge and the cleanup
# that follows it if the terminal window goes away.
trap '' HUP

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

message() {
  case $1 in
    warn)   MT="${YELLOW}WARN${ENDCOLOR}" ; shift ;;
    error)  MT="${RED}ERROR${ENDCOLOR}"   ; shift ;;
    info)   MT="${GREEN}INFO${ENDCOLOR}"  ; shift ;;
    *)      MT="${GREEN}INFO${ENDCOLOR}"  ;;
  esac
  echo -e "[${MT}] $*"
}

error() { message error "$@"; exit 1; }

confirm() {
  message warn "Type '${GREEN}y${ENDCOLOR}' or '${GREEN}yes${ENDCOLOR}' and hit [ENTER] to continue"
  local c
  echo "[y/N?] "
  read -r c
  [ "${c,,}" != "y" ] && [ "${c,,}" != "yes" ] && { message error "Aborted."; exit 1; }
  return 0
}

step() {
  echo ""
  echo -e "${YELLOW}━━━ $1${ENDCOLOR}"
}

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# True when a package was already installed before ubuntu-look.sh first ran.
# The snapshot holds the complete dpkg list from that moment, so distro packages
# and anything installed beforehand are never removed.
predates_us() {
  [ -f "${BACKUP_ORIGINAL}/packages-before.txt" ] || return 1
  grep -qx "$1" "${BACKUP_ORIGINAL}/packages-before.txt" 2>/dev/null
}

# True when purging $1 would also take a package that defines the desktop
# itself. Whatever apt answers that way was put there by the distro, not by
# this script and is never removed. Used only where there is no
# record of what was installed and the list is a guess.
part_of_the_desktop() {
  apt-get -s purge "$1" 2>/dev/null \
    | awk '/^Remv /{print $2}' \
    | grep -qxE 'gnome|gnome-core|gnome-shell|gnome-session|task-gnome-desktop|ubuntu-desktop'
}

# Show exactly what a purge would take -- the list itself, and separately what
# apt would pull out along with it -- then ask. Both removal paths go through
# here so neither can ever remove something without showing it first.
# Show the plan, then purge. Returns non-zero for an empty list, so the caller
# reports which list it was.
purge_list() {
  [ -n "$1" ] || return 1
  preview_purge "$1"
  # A purge that fails leaves packages behind, so the run has not finished what
  # it said it would. The status is kept rather than discarded, and apt keeps
  # its stderr, so the caller reports the truth and the reason is on screen.
  # shellcheck disable=SC2086
  sudo apt-get purge -y $1 || {
    PURGE_FAILED=1
    SNAPSHOT_STILL_NEEDED=1
    message warn "apt could not purge every package — see its output above"
  }
}

preview_purge() {
  local list="$1" planned extra="" pkg2
  echo ""
  message "these packages will be removed:"
  # shellcheck disable=SC2086
  [ -n "$list" ] && printf '   - %s\n' $list

  # apt will also take anything that depends on them. Ask it for the real plan
  # and show that collateral separately, so nothing is a surprise.
  if [ -n "$list" ]; then
    # shellcheck disable=SC2086
    planned="$(apt-get -s purge $list 2>/dev/null | awk '/^Remv /{print $2}')"
    for pkg2 in $planned; do
      case " $list " in *" $pkg2 "*) ;; *) extra="$extra $pkg2" ;; esac
    done
  fi
  if [ -n "$extra" ]; then
    echo ""
    message warn "apt would also remove these, because they depend on the above:"
    # shellcheck disable=SC2086
    printf '   ! %s\n' $extra
    message warn "stop here if you want to keep any of them"
  fi
  echo ""
  confirm
}

declare -a DONE=()
declare -a SKIPPED=()
declare -a GUESSED=()

[ "$(id -u)" -eq 0 ] && error "Do not run as root. Run as a normal user in the 'sudo' group."
# id -un always answers; $USER is unset under su and in minimal
# environments, which aborts outright when the script runs with set -u.
RUN_USER="$(id -un)"
id -nG | tr ' ' '\n' | grep -qx sudo || error "User $RUN_USER is not in the 'sudo' group."

###############################################################################
# Locate the pre-install snapshot and manifest ubuntu-look.sh may have left
###############################################################################

# Set when a step could not finish and the snapshot is the only way to try
# again. The backup is removed at the end unless this is on.
SNAPSHOT_STILL_NEEDED=0
# Set by purge_list when apt refuses or fails partway, so the summary reports a
# removal that did not fully happen as exactly that.
PURGE_FAILED=0
BACKUP_DIR="$HOME/.ubuntu-look-backup"
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
INSTALLED_MANIFEST="${BACKUP_DIR}/installed-by-script.txt"

HAVE_SNAPSHOT=0
[ -d "$BACKUP_ORIGINAL" ] && HAVE_SNAPSHOT=1

DCONF_PROFILE_FILE="/etc/dconf/db/local.d/10-ubuntu-look"
DCONF_USER_PROFILE="/etc/dconf/profile/user"
UBUNTU_KEYRING="/etc/apt/keyrings/ubuntu-archive.gpg"
UBUNTU_LIST="/etc/apt/sources.list.d/ubuntu-themes.list"
UBUNTU_PIN="/etc/apt/preferences.d/ubuntu-themes"
OFFLINE_LOCAL_LIST="/etc/apt/sources.list.d/ubuntu-look-offline-local.list"

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
echo -e "${YELLOW}       ubuntu-look UNINSTALL${ENDCOLOR}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
echo ""
if [ $HAVE_SNAPSHOT -eq 1 ]; then
  echo -e "${GREEN}Pre-install snapshot found:${ENDCOLOR} ${BACKUP_ORIGINAL}"
  echo "  Your GNOME settings, wallpaper and GTK config from before"
  echo "  ubuntu-look.sh ever ran will be restored."
else
  echo -e "${YELLOW}No pre-install snapshot found${ENDCOLOR} (ubuntu-look.sh predates the backup"
  echo "  feature, or this is a different user/machine). Falling back to"
  echo "  best-effort detection: files ubuntu-look.sh writes are recognized by"
  echo "  content/name and removed; settings are reset to GNOME defaults"
  echo "  instead of restored to your exact prior values."
fi
echo ""
echo -e "${GREEN}It only undoes what ubuntu-look.sh did.${ENDCOLOR} Packages it never installed are"
echo "  left alone, settings you changed after installing are left alone, and every"
echo "  key it did write goes back to the value it had beforehand."
echo ""
echo "This will:"
echo "  1. Switch off the five extensions ubuntu-look.sh enables"
echo "  2. Restore the GNOME settings + wallpaper ubuntu-look.sh changed"
echo "  3. Remove the dconf system profile"
echo "  4. Remove the theme-follower service an earlier version installed"
echo "  5. Restore (or remove) GTK CSS / gtkrc-2.0"
echo "  6. Remove the Ubuntu terminal profile and the App Center store icon"
echo "  7. Restore /etc/environment, GRUB, Plymouth theme"
echo "  8. Remove the Ubuntu apt repo, pin, and keyring"
echo "  9. Remove the packages ubuntu-look.sh installed, and only those — never"
echo "     anything that was already on the system when it first ran"
echo ""
confirm

###############################################################################
# The keys ubuntu-look.sh writes, as dconf paths. Nothing outside this list is
# touched.
###############################################################################
UBUNTU_LOOK_KEYS=(
  "org/gnome/shell:enabled-extensions disabled-extensions always-show-log-out"
  # Has to come back, or a user-theme extension that predates this script is
  # left pointing at a Yaru that has just been removed.
  "org/gnome/shell/extensions/user-theme:name"
  "org/gnome/desktop/interface:gtk-enable-primary-paste gtk-theme accent-color icon-theme cursor-theme font-name monospace-font-name document-font-name font-antialiasing enable-hot-corners"
  "org/gnome/desktop/wm/preferences:button-layout titlebar-uses-system-font action-middle-click-titlebar titlebar-font"
  "org/gnome/desktop/wm/keybindings:switch-applications switch-applications-backward switch-windows switch-windows-backward show-desktop"
  "org/gnome/desktop/sound:theme-name input-feedback-sounds"
  "org/gnome/desktop/peripherals/touchpad:click-method"
  "org/gnome/nautilus/icon-view:default-zoom-level"
  "org/gnome/nautilus/preferences:open-folder-on-dnd-hover"
  "org/gtk/settings/file-chooser:sort-directories-first startup-mode"
  "org/gnome/desktop/background:picture-uri picture-uri-dark picture-options"
  "org/gnome/desktop/screensaver:picture-uri"
  "org/gnome/shell/extensions/dash-to-dock:dock-position dock-fixed intellihide-mode icon-size-fixed custom-theme-shrink running-indicator-style extend-height scroll-action click-action shift-click-action shift-middle-click-action disable-overview-on-startup show-mounts-only-mounted show-mounts-network"
  "org/gnome/shell/extensions/ding:start-corner show-trash show-volumes arrangeorder"
)

# The value $3 has under group $2 in the ini-style file $1. dconf dumps and the
# system profile ubuntu-look.sh writes use the same shape, so one reader does
# for both.
# dconf read prints nothing and exits 0 for a key that is not set, so a
# fallback written as "|| echo unset" never fires and the line comes out blank.
dconf_show() {
  local v
  v="$(dconf read "$1" 2>/dev/null)"
  printf '%s' "${v:-${2:-unset}}"
}

ini_value() {
  [ -f "$1" ] || return 0
  awk -v grp="[$2]" -v key="$3" '
    $0 == grp { ingrp = 1; next }
    /^\[/     { ingrp = 0 }
    ingrp && index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
  ' "$1"
}

# The value $2 had under group $1 in the pre-install dconf dump; empty when the
# dump has no such key, meaning it sat at the GNOME default back then.
snapshot_dconf_value() {
  ini_value "${BACKUP_ORIGINAL}/dconf-dump.ini" "$1" "$2"
}

# What ubuntu-look.sh set this key to, from the system profile it wrote. Empty
# once that file is gone, or for a key it never supplied.
our_dconf_value() {
  ini_value "$DCONF_PROFILE_FILE" "$1" "$2"
}

# GVariant text differs only in spacing between the written value and what dconf
# reads back (['a', 'b'] vs ['a','b']), so compare with the spaces removed.
same_value() {
  [ "$(printf '%s' "$1" | tr -d '[:space:]')" = "$(printf '%s' "$2" | tr -d '[:space:]')" ]
}

###############################################################################
step_disable_extensions() {
  step "Disabling Ubuntu-specific extensions..."
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  fi
  # One of the five is Debian's own user-theme, from gnome-shell-extensions.
  # Switching them off is only safe while step_restore_gnome_settings can put
  # the list back; with no record left to restore from, an extension of the
  # user's would stay off for good.
  if [ ! -f "$DCONF_PROFILE_FILE" ] && [ $HAVE_SNAPSHOT -eq 0 ]; then
    SKIPPED+=("No record of an install on this system -- extensions left as they are")
    return
  fi

  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gnome-extensions >/dev/null 2>&1; then
    # The same five ubuntu-look.sh enables. Switching them off here only
    # makes it immediate in the running session; step_restore_gnome_settings
    # then puts enabled-extensions back to its pre-install value, so an
    # extension enabled before the install is switched back on.
    local exts="ubuntu-dock@ubuntu.com ubuntu-appindicators@ubuntu.com tiling-assistant@ubuntu.com"
    exts="$exts ding@rastersoft.com user-theme@gnome-shell-extensions.gcampax.github.com"
    for ext in $exts; do
      gnome-extensions disable "$ext" 2>/dev/null || true
    done
    DONE+=("Switched off the five extensions ubuntu-look.sh enables")
  else
    SKIPPED+=("No live session — extensions will simply not load after package removal")
  fi
}

###############################################################################
step_restore_gnome_settings() {
  step "Restoring GNOME settings and wallpaper..."

  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || ! command -v dconf >/dev/null 2>&1; then
    SKIPPED+=("No live D-Bus session — GNOME settings not restored; re-run this from your desktop")
    SNAPSHOT_STILL_NEEDED=1
    return
  fi

  # With the profile gone and no snapshot, nothing identifies which keys were
  # ever this script's, and resetting them would take the user's own values.
  if [ ! -f "$DCONF_PROFILE_FILE" ] && [ $HAVE_SNAPSHOT -eq 0 ]; then
    SKIPPED+=("No record of an install on this system -- GNOME settings left as they are")
    return
  fi

  # Key by key, and only where the value is still the one ubuntu-look.sh set; a
  # value changed since is left as it is. Keys still holding that value return to
  # their pre-install value, or to the GNOME default when the snapshot has none.
  local entry path key val ours now restored=0 reset=0 kept=0 kept_keys=""
  for entry in "${UBUNTU_LOOK_KEYS[@]}"; do
    path="${entry%%:*}"
    for key in ${entry#*:}; do
      case "$key" in
        # These two are merged into rather than overwritten, so what is in them
        # now never matches what the profile supplies. Always restored.
        enabled-extensions|disabled-extensions) ;;

        # The shell theme, which the follower moves between Yaru's two
        # variants: either of them is this script's own value, and has to come
        # back or the key is left naming a theme that has just been removed.
        # Any other name is one the user chose, and stays.
        name)
          case "$(dconf read "/${path}/${key}" 2>/dev/null | tr -d "'")" in
            # Unset counts as ours too: the key holds no choice of the
            # user's, so the snapshot value -- if there is one -- goes back.
            ''|Yaru|Yaru-dark) ;;
            *) kept=$((kept + 1))
               kept_keys="${kept_keys}${kept_keys:+, }${key}"
               continue ;;
          esac
          ;;
        *)
          ours="$(our_dconf_value "$path" "$key")"
          now="$(dconf read "/${path}/${key}" 2>/dev/null)"
          if [ -n "$ours" ] && [ -n "$now" ] && ! same_value "$now" "$ours"; then
            kept=$((kept + 1))
            kept_keys="${kept_keys}${kept_keys:+, }${key}"
            continue
          fi
          ;;
      esac

      val="$(snapshot_dconf_value "$path" "$key")"
      if [ -n "$val" ]; then
        dconf write "/${path}/${key}" "$val" 2>/dev/null && restored=$((restored + 1))
      else
        dconf reset "/${path}/${key}" 2>/dev/null && reset=$((reset + 1))
      fi
    done
  done

  # Named, not just counted, so the choice can be checked.
  [ $kept -gt 0 ] && SKIPPED+=("${kept} setting(s) no longer hold the value this script wrote and were left alone: ${kept_keys}")

  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ]; then
    DONE+=("GNOME settings: ${restored} key(s) put back to their pre-install value, ${reset} reset to the GNOME default")
  else
    GUESSED+=("No dconf snapshot — ${reset} ubuntu-look key(s) reset to GNOME defaults (original values unknown)")
  fi
}

###############################################################################
step_remove_dconf_profile() {
  step "Removing dconf system profile..."
  local removed=0
  if [ -f "$DCONF_PROFILE_FILE" ]; then
    sudo rm -f "$DCONF_PROFILE_FILE"
    removed=1
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
    removed=1
  fi
  # Always recompiled, not only where the profile file changed: the database is
  # built from the keyfile, and leaving it standing keeps every setting this
  # script supplied as a default long after the file that named them is gone.
  [ $removed -eq 1 ] && { sudo dconf update 2>/dev/null || true; }

  # Reported here rather than with the settings, which run before this: until
  # the database is rebuilt every key that was reset still reads back as the
  # value this script supplied, and the report would name it every time.
  DONE+=("Wallpaper is now: $(dconf_show /org/gnome/desktop/background/picture-uri '<the default your Debian ships>')")
}

###############################################################################
step_remove_extension_autostart() {
  step "Removing the one-shot extension autostart..."
  local d="$HOME/.config/autostart/ubuntu-look-enable-extensions.desktop"
  local s="$HOME/.local/share/ubuntu-look/enable-extensions.sh"
  if [ -f "$d" ] || [ -f "$s" ]; then
    rm -f "$d" "$s"
    rmdir "$HOME/.local/share/ubuntu-look" 2>/dev/null || true
    DONE+=("Removed the one-shot extension autostart")
  fi
}

###############################################################################
step_remove_ubuntu_ding() {
  step "Removing Ubuntu's desktop-icons build..."
  local d="$HOME/.local/share/gnome-shell/extensions/ding@rastersoft.com"
  local sd="$HOME/.local/share/glib-2.0/schemas"
  local record="${BACKUP_DIR}/ubuntu-ding-version.txt"

  # The record is what says the directory is this script's. One put there by
  # hand, before this script ever ran, is left alone.
  if [ ! -f "$record" ]; then
    SKIPPED+=("No Ubuntu desktop-icons build was installed by this script")
    return
  fi

  rm -rf "$d" "${sd}/org.gnome.shell.extensions.ding.gschema.xml"
  # A compiled file with no schemas left beside it is worse than none, so it
  # goes too, and the directories with it while they are empty.
  if ls "${sd}"/*.gschema.xml >/dev/null 2>&1; then
    glib-compile-schemas "$sd" 2>/dev/null || true
  else
    rm -f "${sd}/gschemas.compiled"
    rmdir "$sd" "$HOME/.local/share/glib-2.0" 2>/dev/null || true
  fi
  rmdir "$HOME/.local/share/gnome-shell/extensions" \
        "$HOME/.local/share/gnome-shell" 2>/dev/null || true
  rm -f "$record"
  DONE+=("Removed Ubuntu's desktop-icons build — Debian's own is in use again")
}

###############################################################################
step_remove_app_grid_icon() {
  step "Removing the Show Applications button icon..."
  local f="$HOME/.local/share/icons/hicolor/scalable/actions/view-app-grid-user-symbolic.svg"
  if [ -f "$f" ]; then
    rm -f "$f"
    # Only directories this script created are left behind, and only while they
    # are empty; rmdir stops at the first one that is not.
    rmdir -p --ignore-fail-on-non-empty "$(dirname "$f")" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    DONE+=("Removed the Show Applications button icon")
  else
    SKIPPED+=("No Show Applications button icon to remove")
  fi
}

###############################################################################
step_remove_gdm_profile() {
  step "Removing the login screen theme..."
  local f="/etc/dconf/db/gdm.d/10-ubuntu-look"
  local created="${BACKUP_ORIGINAL}/gdm-profile-created"
  local removed=0
  if [ -f "$f" ]; then
    sudo rm -f "$f"
    rmdir /etc/dconf/db/gdm.d 2>/dev/null || true
    removed=1
    DONE+=("Removed ${f}")
  fi
  # Only a profile this script created: one the distribution ships is not ours
  # to take away, and removing it would leave the greeter unconfigurable.
  if [ -f "$created" ]; then
    sudo rm -f /etc/dconf/profile/gdm
    rm -f "$created"
    removed=1
    DONE+=("Removed /etc/dconf/profile/gdm, which this script created")
  fi
  if [ $removed -eq 1 ]; then
    sudo dconf update 2>/dev/null || true
  else
    SKIPPED+=("No login screen theme to remove")
  fi
}

###############################################################################
step_remove_theme_followers() {
  step "Removing the shell theme follower..."
  # The second name is what an earlier version installed; both go.
  # Both file names: .js is what the current version writes, .sh what earlier
  # ones did, and a machine can be carrying either.
  local removed=0 name unit script js
  for name in yaru-shell-theme yaru-color-scheme-sync; do
    unit="$HOME/.config/systemd/user/${name}.service"
    script="$HOME/.local/bin/${name}.sh"
    js="$HOME/.local/bin/${name}.js"
    [ -f "$unit" ] || [ -f "$script" ] || [ -f "$js" ] || continue
    systemctl --user disable --now "${name}.service" 2>/dev/null || true
    rm -f "$unit" "$script" "$js"
    removed=1
  done
  if [ $removed -eq 1 ]; then
    systemctl --user daemon-reload 2>/dev/null || true
    DONE+=("Removed the shell theme follower")
  else
    SKIPPED+=("No shell theme follower to remove")
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
    # A file that is there and carries none of this script's marks is the
    # user's own -- whether it always was, or they have written it since the
    # install. Copying the snapshot over it would discard that work, so it is
    # left exactly as it is.
    if [ -f "$target" ] && ! grep -qE "ubuntu-look\.sh|E95420" "$target" 2>/dev/null; then
      continue
    fi
    if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/${backup_name}" ]; then
      cp "${BACKUP_ORIGINAL}/${backup_name}" "$target"
      DONE+=("Restored $(basename "$target") from snapshot")
    elif [ -f "$target" ]; then
      rm -f "$target"
      GUESSED+=("Removed $(basename "$(dirname "$target")")/$(basename "$target") (written by this script, no snapshot to restore)")
    fi
  done
}

###############################################################################
step_restore_removed_packages() {
  step "Putting back what an earlier version removed..."
  local record="${BACKUP_DIR}/removed-by-script.txt" pkg
  if [ ! -f "$record" ]; then
    SKIPPED+=("No package was removed to make room for anything")
    return
  fi
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    is_installed "$pkg" && continue
    sudo apt-get install -y "$pkg" >/dev/null 2>&1 \
      && DONE+=("Reinstalled ${pkg}") \
      || GUESSED+=("could not reinstall ${pkg}")
  done < "$record"
}

###############################################################################
step_terminal_profile() {
  step "Removing the Ubuntu terminal profile..."
  local record="${BACKUP_DIR}/terminal-profile.txt"
  local base="/org/gnome/terminal/legacy/profiles:"
  local uuid keep="" one

  uuid="$(sed -n 's/^uuid=//p' "$record" 2>/dev/null)"
  if [ -z "$uuid" ] || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
     || ! command -v dconf >/dev/null 2>&1; then
    SKIPPED+=("No terminal profile was installed by this script")
    return
  fi

  # Only this script's own profile leaves the list; everything the user made,
  # before the install or after it, keeps its place and its order.
  for one in $(dconf read "${base}/list" 2>/dev/null \
               | sed 's/^@[a-z]* //' | tr -d "[]' " | tr ',' ' '); do
    [ "$one" = "$uuid" ] || keep="${keep}${keep:+, }'${one}'"
  done
  if [ -n "$keep" ]; then
    dconf write "${base}/list" "[${keep}]" 2>/dev/null
  else
    dconf reset "${base}/list" 2>/dev/null
  fi
  dconf reset -f "${base}/:${uuid}/" 2>/dev/null

  # Back to the profile gnome-terminal picks for itself, unless the user has
  # since chosen one of their own -- that choice is theirs and stays.
  if [ "$(dconf read "${base}/default" 2>/dev/null | tr -d "'")" = "$uuid" ]; then
    dconf reset "${base}/default" 2>/dev/null
  fi

  rm -f "$record"
  DONE+=("Removed the Ubuntu terminal profile; your own profiles and default are back")
}

###############################################################################
step_restore_software_icon() {
  step "Restoring the software store icon..."
  local target="$HOME/.local/share/applications/org.gnome.Software.desktop"
  # An override that is there and is not the one this script wrote belongs to
  # the user, whether it always did or they have written it since. Copying the
  # snapshot over it would discard that.
  if [ -f "$target" ] && ! grep -q '^Icon=app-center$' "$target" 2>/dev/null; then
    SKIPPED+=("Your own org.gnome.Software.desktop override left as it is")
    return
  fi
  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/org.gnome.Software.desktop" ]; then
    cp "${BACKUP_ORIGINAL}/org.gnome.Software.desktop" "$target"
    DONE+=("Restored your own org.gnome.Software.desktop override")
  elif [ -f "$target" ]; then
    rm -f "$target"
    DONE+=("Removed the App Center icon override (GNOME Software icon restored)")
  else
    return
  fi
  # An entry that has come or gone leaves a stale cache behind.
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
}

###############################################################################
step_restore_environment() {
  step "Restoring /etc/environment..."
  # Only the one line ubuntu-look.sh appends is removed. Copying the whole
  # snapshot back would discard anything added to this file afterwards.
  if grep -q "^XCURSOR_SIZE=24$" /etc/environment 2>/dev/null; then
    sudo sed -i '/^XCURSOR_SIZE=24$/d' /etc/environment
    DONE+=("Removed XCURSOR_SIZE=24 from /etc/environment (other lines untouched)")
  else
    SKIPPED+=("/etc/environment has no XCURSOR_SIZE=24 line to remove")
  fi
}

###############################################################################
step_restore_grub() {
  step "Restoring GRUB..."

  if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; then
    SKIPPED+=("No GRUB on this system — nothing to restore")
    return
  fi

  # The installer records the words it put on the kernel command line, so they
  # can be taken off one by one. That is better than copying the whole file
  # back from the snapshot, which would discard unrelated changes such as a
  # GRUB_TIMEOUT edited after the install.
  local added_file="${BACKUP_ORIGINAL}/grub-cmdline-added.txt"
  if [ -f "$added_file" ]; then
    local added line val word kept="" dropped=0
    added="$(tr '\n' ' ' < "$added_file")"
    line="$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null)"
    val="${line#*=}"; val="${val%\"}"; val="${val#\"}"
    for word in $val; do
      case " $added " in
        *" $word "*) dropped=1 ;;
        *) kept="${kept:+${kept} }${word}" ;;
      esac
    done
    # On what was actually dropped, not on the two strings differing: a
    # difference of spacing alone would rewrite the file and report a removal
    # that never happened.
    if [ -n "$line" ] && [ $dropped -eq 1 ]; then
      local tmp
      tmp="$(mktemp)"
      awk -v val="$kept" '
        !swapped && /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
          print "GRUB_CMDLINE_LINUX_DEFAULT=\"" val "\""; swapped = 1; next
        }
        { print }
      ' /etc/default/grub > "$tmp"
      if [ -s "$tmp" ]; then
        sudo cp "$tmp" /etc/default/grub
        sudo update-grub
        DONE+=("Removed '${added% }' from the kernel command line, left the rest of /etc/default/grub alone")
      fi
      rm -f "$tmp"
    else
      SKIPPED+=("/etc/default/grub no longer carries what ubuntu-look.sh added")
    fi
    return
  fi

  # No record: an install that predates it. Fall back to the snapshot, and only
  # when the file has not been touched in some other way since.
  if [ $HAVE_SNAPSHOT -eq 1 ] && [ -f "${BACKUP_ORIGINAL}/grub" ] \
     && ! sudo cmp -s "${BACKUP_ORIGINAL}/grub" /etc/default/grub; then
    sudo cp "${BACKUP_ORIGINAL}/grub" /etc/default/grub
    sudo update-grub
    GUESSED+=("GRUB restored wholesale from the snapshot — no record of what was added")
  else
    SKIPPED+=("/etc/default/grub unchanged since the snapshot — left alone")
  fi
}

###############################################################################
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

step_restore_plymouth() {
  step "Restoring Plymouth theme..."
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    SKIPPED+=("No Plymouth on this system -- nothing to put back")
    return
  fi

  # The theme is Debian's to choose and current versions do not change it. A
  # recorded theme means an earlier version did, and that is what is put back.
  local current was
  current="$(plymouth_current_theme)"
  was="$(cat "${BACKUP_ORIGINAL}/plymouth-theme-before.txt" 2>/dev/null)"

  if [ -n "$was" ] && [ "$was" != "$current" ]; then
    sudo plymouth-set-default-theme "$was"
      if sudo update-initramfs -u -k all 2>/dev/null || sudo update-initramfs -u; then
        DONE+=("Plymouth theme restored to '${was}'")
      else
        GUESSED+=("Plymouth theme set back, but the initramfs rebuild failed -- run: sudo update-initramfs -u")
      fi
  else
    SKIPPED+=("Plymouth theme left as you have it -- this script does not change it")
  fi
}

###############################################################################
step_remove_ubuntu_repo() {
  step "Removing Ubuntu apt repo/pin/keyring..."
  local changed=0
  [ -f "$UBUNTU_LIST" ] && { sudo rm -f "$UBUNTU_LIST"; changed=1; }
  [ -f "$UBUNTU_PIN" ] && { sudo rm -f "$UBUNTU_PIN"; changed=1; }
  [ -f "$UBUNTU_KEYRING" ] && { sudo rm -f "$UBUNTU_KEYRING"; changed=1; }
  # Temporary source ubuntu-look-offline.sh registers; only present if that
  # script was interrupted before its own cleanup ran.
  [ -f "$OFFLINE_LOCAL_LIST" ] && { sudo rm -f "$OFFLINE_LOCAL_LIST"; changed=1; }
  [ $changed -eq 1 ] && DONE+=("Removed Ubuntu apt sources/pin/keyring")
}

###############################################################################
step_remove_packages() {
  step "Removing packages..."

  local list="" pkg

  # An existing manifest is authoritative even when it is empty: empty means
  # ubuntu-look.sh installed nothing because everything was already there,
  # and the right thing to remove is then nothing at all. Only a manifest
  # that is missing entirely falls through to the guess list below.
  if [ -f "$INSTALLED_MANIFEST" ]; then
    for pkg in $(cat "$INSTALLED_MANIFEST"); do
      predates_us "$pkg" && continue
      is_installed "$pkg" && list="$list $pkg"
    done
    # By construction only what the manifest recorded. Shown before removal anyway.
    if purge_list "$list"; then
      if [ $PURGE_FAILED -eq 1 ]; then
        GUESSED+=("apt could not purge every tracked package — some of these are still installed:${list}")
      else
        DONE+=("Purged tracked packages:${list}")
      fi
    else
      SKIPPED+=("No package to remove -- everything ubuntu-look.sh needed was already installed before it ran")
    fi
  elif [ ! -d "$BACKUP_DIR" ]; then
    # No manifest and no backup directory either. Either this script never ran
    # on this system, or an earlier uninstall finished and took its records
    # with it. The guess list below checks its candidates against the
    # pre-install package list, which went with them, so running it here would
    # remove a package the user has had all along.
    SKIPPED+=("No record of an install on this system -- no package removed")
    return
  else
    message warn "No package manifest found (ubuntu-look.sh predates it)."
    message warn "Falling back to a conservative guess list — packages generic enough to"
    message warn "plausibly predate ubuntu-look.sh (curl, gnupg, fonts, gnome-shell-extensions,"
    message warn "gnome-shell-extension-manager, dconf-cli and plymouth) are deliberately"
    message warn "EXCLUDED to avoid removing something you wanted independent of this script."
    local fallback="yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound
      gnome-shell-extension-ubuntu-dock gnome-shell-extension-ubuntu-tiling-assistant
      gnome-shell-extension-appindicator gnome-shell-extension-desktop-icons-ng
      humanity-icon-theme ubuntu-wallpapers"
    for pkg in $fallback; do
      predates_us "$pkg" && continue
      # With no package list from before the install, apt is the next best
      # witness: if purging this would take gnome or gnome-core with it, the
      # distro put it there and it stays.
      if part_of_the_desktop "$pkg"; then
        SKIPPED+=("${pkg} left alone — apt says it is part of the GNOME desktop this Debian installed")
        continue
      fi
      is_installed "$pkg" && list="$list $pkg"
    done

    if purge_list "$list"; then
      GUESSED+=("Purged guessed packages:${list}")
      [ $PURGE_FAILED -eq 1 ] && GUESSED+=("...but apt could not purge all of them — some are still installed")
    else
      SKIPPED+=("Nothing on the guess list is installed — no package removed")
    fi
  fi


  # Orphans left by the purges above. A candidate must pass three tests:
  #   1. apt proposes it, so it is auto-installed and now unreferenced,
  #   2. it is a dependency of something ubuntu-look.sh removed,
  #   3. it was not installed before ubuntu-look.sh first ran.
  local before_list="${BACKUP_ORIGINAL}/packages-before.txt" orphans="" cand ours=""
  if [ -f "$before_list" ] && [ -n "$list" ]; then
    # shellcheck disable=SC2086
    # No --important here: it limits the walk to Depends/Pre-Depends, and apt
    # installs Recommends by default, so a recommended package would never be
    # matched and would be left behind as an orphan this script created.
    ours="$(apt-cache depends --recurse --no-suggests               --no-conflicts --no-breaks --no-replaces --no-enhances $list 2>/dev/null             | grep -E '^[a-z0-9]' | sort -u)"
    for cand in $(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}'); do
      echo "$ours" | grep -qx "$cand" || continue
      grep -qx "$cand" "$before_list" && continue
      orphans="$orphans $cand"
    done
    if [ -n "$orphans" ]; then
      # shellcheck disable=SC2086
      if sudo apt-get purge -y $orphans; then
        DONE+=("Purged orphaned dependencies:${orphans}")
      else
        SNAPSHOT_STILL_NEEDED=1
        GUESSED+=("apt could not purge these orphaned dependencies — still installed:${orphans}")
      fi
    fi
  else
    SKIPPED+=("No pre-install package list — skipped the orphan sweep rather than risk removing something older than this script")
  fi
}

###############################################################################
step_disable_extensions
step_restore_gnome_settings
step_remove_dconf_profile
step_remove_extension_autostart
step_remove_ubuntu_ding
step_remove_app_grid_icon
step_remove_gdm_profile
step_remove_theme_followers
step_restore_gtk
step_restore_removed_packages
step_terminal_profile
step_restore_software_icon
step_restore_environment
step_restore_grub
step_restore_plymouth
step_remove_ubuntu_repo
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
  if [ $SNAPSHOT_STILL_NEEDED -eq 1 ]; then
    message warn "Keeping ${BACKUP_DIR}: some of this run could not finish, and that"
    message warn "snapshot is the only way to retry it. Remove it once you have:"
    message warn "  rm -rf ${BACKUP_DIR}"
  elif [ "$BACKUP_DIR" != "${BACKUP_DIR%/.ubuntu-look-backup}" ]; then
    # The only irreversible delete in this script, so it refuses to run on a
    # path that is not the backup directory this script's own name defines.
    rm -rf "$BACKUP_DIR"
    message "Removed ${BACKUP_DIR} — nothing of ubuntu-look.sh is left on this system"
  else
    message warn "Refusing to remove ${BACKUP_DIR}: that is not where the backup belongs"
  fi
fi
echo -e "${YELLOW}Log out and back in for all changes to take effect.${ENDCOLOR}"
echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
