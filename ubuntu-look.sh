#!/bin/bash
# =============================================================================
# Title       : ubuntu-look.sh
# Version     : 1.0
# Description : Makes Debian GNOME look and behave like the newest Ubuntu
#               release that fits the installed GNOME Shell, without
#               breaking Debian: Yaru themes, Ubuntu fonts and wallpapers,
#               Ubuntu Dock, tiling assistant, tray icons, desktop icons,
#               terminal colours, login screen, boot splash and Ubuntu's
#               GNOME defaults, as an "Ubuntu" session on the login screen.
#
# Original    : DeltaLima
#               https://github.com/DeltaLima/make-debian-look-like-ubuntu
#
# Usage       : bash ubuntu-look.sh                   install or update
#               bash ubuntu-look.sh --refresh         list available updates, then ask
#                                                     to apply them
#               bash ubuntu-look.sh --uninstall       undo it, from your desktop session
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
#               UBUNTU_LOOK_LOG=0             no run log
#               UBUNTU_LOOK_REBOOT=0          no automatic reboot at the end
#               UBUNTU_LOOK_ANIMATIONS=0|1    animation effects off or on for
#                                             this user (default: unchanged)
#               An install run saves the first five; later runs reuse them
#               unless given again, e.g. UBUNTU_CODENAME=auto.
#
# Upgrading   : Before a Debian release upgrade, run --uninstall; upgrade and
#               reboot; then run this script again for the new GNOME Shell.
#
# Reboot      : A run that changed the system and left nothing undone reboots
#               after a 60 second countdown: Enter reboots at once, Ctrl-C
#               cancels. A run that changed nothing does not reboot.
#               Without a terminal, or with UBUNTU_LOOK_REBOOT=0, it names
#               the command instead.
#
# Refresh     : --refresh lists what an update would change: a newer Ubuntu
#               release, a Debian or GNOME Shell change, newer builds of the
#               look's packages. It asks before applying anything.
#
# Undo        : bash ubuntu-look.sh --uninstall removes the session and the
#               system changes, and resets the settings of the user running it.
#
# Requires    : Debian with GNOME; a normal user (not root) with sudo rights;
#               internet access.
# =============================================================================

# Contents
#   1. Constants    paths, package lists, Ubuntu's settings, run state
#   2. Helpers      messages, records, options, dconf values
#   3. Packages     apt, the Ubuntu release, sources and pin
#   4. Desktop      Ubuntu's settings, extensions, terminal, login screen
#   5. Boot         GRUB command line and boot splash
#   6. Report       --refresh, the saved release state, summary, reboot
#   7. Setup        arguments, help, run log, options
#   8. Uninstall    --uninstall
#   9. Install      the install itself
#  10. Main         one run, start to end
#
# Everything above Main only defines; nothing runs until main is called, so
# the file can be sourced (tests/run-tests.sh does).

###############################################################################
# 1. Constants: paths, package lists, Ubuntu's settings, run state
###############################################################################
# Values a run works out (options, architecture, mirror) are set by init_run.

# This script's version; the run log's first line shows it.
UBUNTU_LOOK_VERSION="1.0"

# This script's file; empty when it is read from a pipe (curl ... | bash).
SCRIPT_FILE="${BASH_SOURCE[0]:-}"

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

# The statuses of the functions that change something or look something up,
# by name; each means the same wherever it is returned. Tests and plain
# commands keep the shell's own: 0 for yes or done, non-zero otherwise.
RC_CHANGED=0     # done in this run
RC_UNCHANGED=1   # already so: nothing to do
RC_FAILED=2      # tried and not done, or could not be found out
RC_REFUSED=3     # not tried: apt would not, or the file is not in a shape to edit
RC_NO_RECORD=4   # not tried: the records it needs could not be written
RC_BUSY=5        # not tried: another program holds apt's lock

# The look's apt source and pin.
UBUNTU_SOURCES=/etc/apt/sources.list.d/ubuntu-themes.sources
UBUNTU_PIN=/etc/apt/preferences.d/ubuntu-themes

# Records. System records are shared by all users and root-owned in SYS_DIR;
# per-user records stay in the user's home.
SYS_DIR=/var/lib/ubuntu-look
SYS_RECORDS="${SYS_DIR}/records"
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
# Where AccountsService keeps each user's chosen session, one file per user.
ACCOUNTS_USERS_DIR=/var/lib/AccountsService/users
# Users who logged in to the Ubuntu session when the apt hook took it off the
# login screen; the next run chooses it for them again.
SESSION_USERS_RECORD="${SYS_RECORDS}/session-users.txt"
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
BACKUP_DIR="${HOME:-}/.ubuntu-look-backup"
# Copies of system records an unfinished uninstall keeps for a later run.
DCONF_PROFILE_COPY="${BACKUP_DIR}/dconf-system-profile.ini"
MANIFEST_COPY="${BACKUP_DIR}/look-packages.txt"
# This user's pre-install settings snapshot.
BACKUP_ORIGINAL="${BACKUP_DIR}/original"
# Present once the install chose the Ubuntu session for this user.
SESSION_CHOSEN="${BACKUP_DIR}/session-chosen"
# GNOME's list of custom shortcuts, and the look's terminal shortcut in it.
CUSTOM_KEYBINDINGS_KEY="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
TERMINAL_SHORTCUT_PATH="${CUSTOM_KEYBINDINGS_KEY}/ubuntu-look-terminal/"
TERMINAL_SHORTCUT_RECORD="${BACKUP_DIR}/terminal-shortcut-added"
# The options an install run saves: those that pick the Ubuntu release, then
# the boot options.
RELEASE_OPTION_NAMES="UBUNTU_CODENAME UBUNTU_INCLUDE_DEVEL UBUNTU_MIRROR"
BOOT_OPTION_NAMES="UBUNTU_BOOT_SPLASH PLYMOUTH_THEME"
SAVED_OPTION_NAMES="${RELEASE_OPTION_NAMES} ${BOOT_OPTION_NAMES}"

# Set by record_planned_installs: packages the combined package replaces.
PLANNED_REPLACED=""

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
UBUNTU_PINNED_PACKAGES="${LOOK_PACKAGES} ${UBUNTU_SHELL_EXT_PKGS} session-migration"

declare -A packages

# dconf-cli compiles the look's database; init_run adds Plymouth.
packages[0-base]="dconf-cli"
packages[1-desktop-base]="fonts-ubuntu ubuntu-wallpapers"
# gnome-session-canberra plays Yaru's sound on the login screen, as
# ubuntu-desktop-minimal pulls it in; its login sound is off, as on Ubuntu.
packages[2-desktop-gnome]="gnome-session-canberra ${SEPARATE_EXT_PKGS} ${YARU_PKGS}"

# Where Ubuntu keeps the releases it has retired.
UBUNTU_OLD_MIRROR="http://old-releases.ubuntu.com/ubuntu"

# Regex for Ubuntu archive URLs in apt-cache madison: any ubuntu.com host,
# plus the mirrors init_run and the uninstall add.
UBUNTU_COM_RE="://([a-z0-9.-]+[.])?ubuntu[.]com/"
UBUNTU_HOSTS_RE="$UBUNTU_COM_RE"

# Candidates come from main; the pinned release also gets universe.
UBUNTU_COMPONENTS="main"
UBUNTU_PINNED_COMPONENTS="main universe"
APT_UPDATE_OUTPUT=""

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
# Ubuntu's session and session mode, both named "ubuntu" as on Ubuntu: GNOME
# Shell starts with Yaru and the look's extensions.
SHELL_MODE_NAME="ubuntu"
# The theme extension checks for the same file (MODE_FILE).
SHELL_MODE_FILE="/usr/local/share/gnome-shell/modes/${SHELL_MODE_NAME}.json"
# Yaru's shell theme, which the session mode needs to start.
YARU_SHELL_THEME="/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
# Run by apt after each package change: keeps the session safe and reports a
# new GNOME Shell.
APT_HOOK="/usr/local/lib/ubuntu-look/after-apt.sh"
APT_HOOK_CONF="/etc/apt/apt.conf.d/99ubuntu-look"
THEME_EXT_UUID="ubuntu-look-theme@ubuntu-look"
# The session mode's extensions, where installed: the theme extension, then
# Ubuntu's in the order of its mode; only some releases ship the last.
SHELL_EXTENSIONS="${THEME_EXT_UUID} ubuntu-dock@ubuntu.com ubuntu-appindicators@ubuntu.com ding@rastersoft.com tiling-assistant@ubuntu.com web-search-provider@ubuntu.com"

# Ubuntu's defaults live in their own dconf database, read only in the Ubuntu
# session: its DCONF_PROFILE adds it after the system's databases.
# The database name has no hyphen: dconf's change signal uses it in a D-Bus path.
LOOK_PROFILE_NAME=ubuntu-look
LOOK_DB_NAME=ubuntu_look
LOOK_DB_FILE="/etc/dconf/db/${LOOK_DB_NAME}.d/10-ubuntu-look"
LOOK_PROFILE="/etc/dconf/profile/${LOOK_PROFILE_NAME}"
# The login screen's "Ubuntu" session: one entry for each of Debian's GNOME
# entries (GNOME, on Wayland, on Xorg), named as on Ubuntu.
GNOME_SESSION_ENTRIES="/usr/share/wayland-sessions/gnome.desktop /usr/share/wayland-sessions/gnome-wayland.desktop
/usr/share/xsessions/gnome.desktop /usr/share/xsessions/gnome-xorg.desktop"
# gnome-session's description of the session, and its systemd target's.
GNOME_SESSION_FILE="/usr/local/share/gnome-session/sessions/${SHELL_MODE_NAME}.session"
SESSION_TARGET_DROPIN="/usr/local/lib/systemd/user/gnome-session@${SHELL_MODE_NAME}.target.d/session.conf"
# Run when the session ends, as GNOME Shell's unit cleans up after itself.
SESSION_MANAGER_DROPIN="/usr/local/lib/systemd/user/gnome-session-manager@${SHELL_MODE_NAME}.service.d/ubuntu-look.conf"
SESSION_END_SCRIPT="/usr/local/lib/ubuntu-look/session-end.js"
# Ubuntu turns gnome-session-canberra's login sound off; gnome-session reads
# this entry before Debian's.
LOGIN_SOUND_ENTRY="/usr/share/gnome/autostart/libcanberra-login-sound.desktop"
LOGIN_SOUND_OFF="/usr/local/share/gnome/autostart/${LOGIN_SOUND_ENTRY##*/}"
# The session's font configuration: Debian's, with Ubuntu's sub-pixel rule.
SESSION_FONTS_CONF="/usr/local/share/ubuntu-look/fonts.conf"
# What the session starts with: Ubuntu's session mode, the look's settings and fonts.
SESSION_ENV="GNOME_SHELL_SESSION_MODE=${SHELL_MODE_NAME} DCONF_PROFILE=${LOOK_PROFILE_NAME} FONTCONFIG_FILE=${SESSION_FONTS_CONF}"
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

declare -a STATUS_INSTALLED=()
declare -a STATUS_UPGRADED=()
declare -a STATUS_ALREADY=()
# Packages with a newer Ubuntu build this Debian cannot take (not a failure).
declare -a STATUS_HELD=()
declare -a STATUS_CHANGES=()
declare -a STATUS_NOCHANGE=()
declare -a STATUS_FAILED=()
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
# Set by plymouth_put_back: the theme before the install, the current one,
# and the outcome in a word.
PLY_WAS=""; PLY_CURRENT=""; PLY_OUTCOME=""
# Set once fit_fonts_to_release has run.
FONTS_FITTED=0
# Set by refresh_check: 1 when the Ubuntu release needs no new check.
REFRESH_UNCHANGED=0
APT_LISTS_FRESH=0
# Set by ensure_package: the version it settled on.
ENSURE_VERSION=""
# The user's own values that the Ubuntu session shows instead of Ubuntu's.
declare -a SETTINGS_KEPT=()
# Set by need_reboot, and by init_run for a reboot an earlier run still owes.
REBOOT_NEEDED=0
# Seconds the automatic reboot waits; REBOOT_CANCELLED is set by its Ctrl-C.
REBOOT_COUNTDOWN=60
REBOOT_CANCELLED=0
RELOGIN_NEEDED=0
STEP=0
# Set when the install or the uninstall has run to its end; see print_summary
# and _on_uninstall_exit.
RUN_FINISHED=0
# GNOME Shell's major version; filled once by init_run.
SHELL_MAJOR_CACHE=""

# What this run does, set by parse_args: install, refresh or uninstall; and 1
# for --refresh.
ACTION=install
REFRESH=0

# The published Ubuntu releases, and the newest of them that the run tries.
# Set by discover_releases; narrowed by resolve_release.
UBUNTU_ALL_CODENAMES=""
UBUNTU_CANDIDATE_CODENAMES=""

# State the install's steps hand on to later steps.
# install_widen_source: the releases it writes to the apt source, 1 when the
# source stays as it is, the source and pin as it found them, 1 when the
# provisional pin is new, and write_ubuntu_sources' status.
UBUNTU_SOURCE_LIST=""
KEEP_SOURCES=0
INITIAL_UBUNTU_SOURCES=""
PINNED_BEFORE=""
PROVISIONAL_PIN_NEW=0
SOURCE_WRITE_RC="$RC_UNCHANGED"
# install_pin_release: 0 when the pin on disk is already the right one.
NEED_PIN_REWRITE=1
# install_system_upgrade: 1 when the upgrade moved GNOME Shell to a new major.
SHELL_MOVED=0
# boot_splash: 1 once this run has rebuilt the initramfs.
INITRAMFS_REBUILT=0
# strip_grub_words: the kernel command line without the look's words.
GRUB_CMDLINE_NEW=""
# refresh_check: the updates its steps counted.
REFRESH_FINDINGS=0

# The uninstall's state; uninstall_begin resets it.
# The summary's three lists.
declare -a DONE=()
declare -a SKIPPED=()
declare -a GUESSED=()
# Unfinished work keeps its records, so a later run can finish it.
USER_PENDING=0
SYSTEM_PENDING=0
# 1 when the user's animation switch could not be put back.
ANIMATIONS_FAILED=0
PURGE_FAILED=0
PURGE_KEPT_CONFIG=""
# Taken before the uninstall changes any package; "none" = not taken.
UNUSED_BEFORE_PURGE=none
INSTALLED_BEFORE_PURGE=""
RESTORED_BEFORE_PURGE=""
# Packages left on Ubuntu's build because Debian's would not install.
RESTORE_FAILED=""
# Set by apt_install_debian_build: the version it installed.
DEBIAN_BUILD=""

# The copy of /etc/default/grub a failed update left behind; the caller
# reports it.
GRUB_BACKUP_KEPT=""
# GRUB_CMDLINE_LINUX_DEFAULT's line in /etc/default/grub.
GRUB_KEY_RE='^[[:space:]]*(export[[:space:]]+)?GRUB_CMDLINE_LINUX_DEFAULT='
# Set by strip_grub_words: the words this script added.
GRUB_ADDED_WORDS=""

# gnome-terminal's own default profile, the one Ubuntu's terminal uses.
TERMINAL_DEFAULT_PROFILE="org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9"

# Keys every supported Debian already sets to Ubuntu's values are not listed;
# tap-to-click stays for older GNOME, whose default is off.
GNOME_SETTINGS=(
  "org/gnome/shell|always-show-log-out|true"
  "org/gnome/desktop/session|session-name|'ubuntu'"
  "org/gnome/desktop/background|show-desktop-icons|true"

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

  # gnome-terminal follows Yaru dark. Yaru colours Ubuntu's terminal through a
  # style class only Ubuntu's gnome-terminal sets; here its default profile
  # takes Yaru's colours.
  "org/gnome/terminal/legacy|theme-variant|'dark'"
  "${TERMINAL_DEFAULT_PROFILE}|use-theme-colors|false"
  "${TERMINAL_DEFAULT_PROFILE}|background-color|'#300A24'"
  "${TERMINAL_DEFAULT_PROFILE}|foreground-color|'#FFFFFF'"

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

# Ubuntu's default wallpaper, light and dark; the file names are the same in
# every release.
WP_LIGHT=/usr/share/backgrounds/warty-final-ubuntu.png
WP_DARK=/usr/share/backgrounds/ubuntu-wallpaper-d.png

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

# The Debian logo on the Show Applications button, under Yaru only. The dock
# asks for view-app-grid-<mode>-symbolic; this copy under /usr/local comes
# before Yaru's Ubuntu logo for the "ubuntu" mode.
APP_GRID_ICON="/usr/local/share/icons/Yaru/scalable/actions/view-app-grid-${SHELL_MODE_NAME}-symbolic.svg"

# How much of the canvas the artwork covers; fuller than Ubuntu's 0.742 so
# the button matches the icons beside it.
APP_GRID_INK_FRACTION=0.98

# One run at a time. The lock lives in /run, which only root can write, so
# no other user can replace it.
UBUNTU_LOOK_LOCK=/run/ubuntu-look.lock

###############################################################################
# 2. Helpers: messages, records, options, dconf values
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

# Append line $2 to record $1.
# Non-zero when the record could not be written.
sys_record_append() {
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

# Add text $2 to the summary of the running action: the install's lists or
# the uninstall's. $1 is the kind of outcome:
#   changed    done in this run
#   unchanged  nothing to do
#   manual     left for the user to do by hand: no failure for the install,
#              unfinished system work for the uninstall
#   failed     not done; the uninstall keeps its system records for a later run
report() {
  if [ "$ACTION" = uninstall ]; then
    case "$1" in
      changed)   DONE+=("$2") ;;
      unchanged) SKIPPED+=("$2") ;;
      manual)    SKIPPED+=("$2"); SYSTEM_PENDING=1 ;;
      *)         GUESSED+=("$2"); SYSTEM_PENDING=1 ;;
    esac
  else
    case "$1" in
      changed)          STATUS_CHANGES+=("$2") ;;
      unchanged|manual) STATUS_NOCHANGE+=("$2") ;;
      *)                STATUS_FAILED+=("$2") ;;
    esac
  fi
}

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

# Copy $1 over system file $2 (mode 0644) only when the content differs, through
# sudo and atomically. Returns RC_CHANGED, RC_UNCHANGED (already identical)
# or RC_FAILED.
sudo_install_if_changed() {
  [ -f "$2" ] && cmp -s "$1" "$2" && return "$RC_UNCHANGED"
  sudo_write_atomic "$1" "$2" || return "$RC_FAILED"
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

# The major version of package version $1: the digits after any epoch, up to
# the first dot or pre-release mark ("1:49.1-2" and "49~rc-1" both give 49).
version_major() {
  local v="${1#*:}"
  printf '%s' "${v%%[!0-9]*}"
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
  {
    echo "$head"
    # shellcheck disable=SC2086
    option_lines $SAVED_OPTION_NAMES
  } > "$tmp"
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
# lock is an fcntl lock, listed in /proc/locks by device and inode. Non-zero
# on timeout.
wait_dpkg_lock() {
  local lock=/var/lib/dpkg/lock-frontend ino dev id n=0
  ino="$(stat -c %i "$lock" 2>/dev/null)" || return 0
  # /proc/locks names a file as <major>:<minor>:<inode>, the device in hex and
  # as the mount table has it; stat's differs on btrfs (the subvolume's).
  # Where the mount table gives no device, the inode alone is compared.
  id=":${ino}"
  dev="$(findmnt -no MAJ:MIN -T "$lock" 2>/dev/null | head -n 1)"
  [[ "$dev" =~ ^[[:space:]]*([0-9]+):([0-9]+)[[:space:]]*$ ]] \
    && id="$(printf '%02x:%02x:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$ino")"
  while awk -v id="$id" '
          { for (k = 1; k <= NF; k++) if (substr($k, length($k) - length(id) + 1) == id) f = 1 }
          END { exit !f }' /proc/locks 2>/dev/null; do
    [ "$n" = 0 ] && message "waiting for another package manager to finish"
    [ "$n" -ge 300 ] && return 1
    n=$((n + 1))
    command sleep 1
  done
  return 0
}

debian_codename() { (. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}"); }

###############################################################################
# 3. Packages: apt, the Ubuntu release, sources and pin
###############################################################################

# apt-get through sudo, waiting for an apt lock instead of failing.
apt_get() {
  # From a pipe (curl ... | bash) stdin is the script itself: a dpkg prompt
  # would read its lines. Without a terminal, apt reads nothing.
  if [ -t 0 ]; then
    sudo apt-get -o DPkg::Lock::Timeout=300 "$@"
  else
    sudo apt-get -o DPkg::Lock::Timeout=300 "$@" < /dev/null
  fi
}

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
# carries the dock, not an older metapackage.
combined_carries_dock() {
  [ -n "$1" ] && LC_ALL=C apt-cache show "${COMBINED_EXT_PKG}=$1" 2>/dev/null \
    | grep -q '^Provides:.*gnome-shell-extension-ubuntu-dock'
}

# Use the combined extensions package where the pinned release offers it.
use_combined_extensions_if_offered() {
  local stage="2-desktop-gnome" p list=""
  if combined_carries_dock "$(pkg_candidate_version "$COMBINED_EXT_PKG")"; then
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
    # record_upgraded_pkg keeps only builds that predate the look or are Debian's.
    case "$origin" in Ubuntu:*) ;; *) continue ;; esac
    record_upgraded_pkg "$p" "$was" || rc=1
  done < <(printf '%s\n' "$1" \
    | awk '/^Inst / && $3 ~ /^\[/ { gsub(/[][()]/, ""); print $2, $3, $4, $5 }')
  return "$rc"
}

# apt-get install $@ after one simulation, with the new packages recorded
# first. Returns RC_REFUSED, without installing, when apt cannot resolve it
# or it would remove packages other than ALLOWED_REMOVALS (then in REMOVES);
# RC_FAILED when apt fails; RC_NO_RECORD, without installing, when the
# records could not be written. Call directly, not in $(...).
apt_install_checked() {
  local sim
  local -a no_remove=()
  REMOVES=""
  sim="$(LC_ALL=C apt-get -s install "$@" 2>&1)" || return "$RC_REFUSED"
  REMOVES="$(unexpected_removals "$sim")"
  [ -z "$REMOVES" ] || return "$RC_REFUSED"
  if ! record_planned_installs "$sim" || ! record_planned_upgrades "$sim"; then
    message warn "could not write the install records in ${SYS_RECORDS} — apt not run"
    return "$RC_NO_RECORD"
  fi
  # With no removal allowed, the real run cannot remove what the simulation kept.
  [ -n "$ALLOWED_REMOVALS" ] || no_remove=(--no-remove)
  apt_get install -y "${no_remove[@]}" "$@" || return "$RC_FAILED"
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
    apt-cache show "$pkg" >/dev/null 2>&1 && avail="$avail $pkg"
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
  LC_ALL=C apt-cache policy "$1" 2>/dev/null \
    | awk '/^  Candidate:/ { if ($2 != "(none)") print $2; exit }'
}

# Every version of $1 the pin allows (priority 0 or more), from apt's
# candidate down, newest first; nothing when there is no candidate.
pkg_allowed_versions_desc() {
  LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '
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
  sim="$(LC_ALL=C apt-get install -s "$@" 2>&1)" || return 1
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
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      echo "apt has no candidate for it — every build it can see is blocked by ${UBUNTU_PIN}"
    else
      echo "no configured repository offers a package by that name"
    fi
    return
  fi
  have="$(pkg_installed_version "$pkg")"
  [ "$have" = "$ver" ] && { echo "${ver} is already the newest build apt offers"; return; }

  sim="$(LC_ALL=C apt-get install -s "${pkg}=${ver}" 2>&1)"
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
       && apt-cache show "$dep" >/dev/null 2>&1; then
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
#   RC_CHANGED    installed or upgraded
#   RC_UNCHANGED  already at the newest version that fits
#   RC_FAILED     nothing on offer can be installed here
ensure_package() {
  local pkg="$1" have ver log rc busy
  ENSURE_VERSION=""
  have="$(pkg_installed_version "$pkg")"

  # Newest allowed build first; none when the pin leaves no candidate.
  for ver in $(pkg_allowed_versions_desc "$pkg"); do
    if [ -n "$have" ] && dpkg --compare-versions "$ver" le "$have"; then
      ENSURE_VERSION="$have"
      return "$RC_UNCHANGED"
    fi
    # Turned down earlier this run (by the alignment, say); not tried twice.
    in_word_list "${pkg}=${ver}" "$REJECTED_BUILDS" && continue
    message "  installing ${pkg} ${ver}..."
    log="$(mktemp)" || error "Could not create a temporary file — nothing more is changed; run this again."
    # Run here, not in a pipeline subshell, so its records reach the summary;
    # C locale so the messages below can be read.
    LC_ALL=C apt_install_checked "${pkg}=${ver}" > >(tee "$log") 2>&1; rc=$?
    wait $! 2>/dev/null
    # A busy apt, a lost network or an interrupted dpkg says nothing about
    # the build: stop here.
    busy=0
    [ "$rc" -eq "$RC_FAILED" ] && grep -qE 'Could not get lock|(Failed|Unable) to fetch (https?|ftp)://|Temporary failure resolving|dpkg was interrupted' "$log" && busy=1
    rm -f "$log"
    if [ "$rc" -eq "$RC_CHANGED" ]; then
      ENSURE_VERSION="$ver"
      return "$RC_CHANGED"
    fi
    [ "$busy" -eq 0 ] \
      || error "apt is busy or the network failed while installing ${pkg} — nothing more is changed; run this again later."
    [ "$rc" -ne "$RC_NO_RECORD" ] \
      || error "could not write the look's records in ${SYS_RECORDS} while installing ${pkg} — nothing more is changed; run this again."
    REJECTED_BUILDS="${REJECTED_BUILDS} ${pkg}=${ver}"
    [ "$rc" -eq "$RC_REFUSED" ] || message warn "${pkg}=${ver} would not install after all — trying an older build"
  done

  [ -n "$have" ] && { ENSURE_VERSION="$have"; return "$RC_UNCHANGED"; }
  return "$RC_FAILED"
}

# The codename of the Ubuntu series in development, empty when there is none;
# answered once per run. The archive's "devel" link names it, unless Ubuntu's
# development list shows that release as published (the link moves on only
# when the next series opens). Without the link, the list's last entry is
# the series while the list marks it unpublished. Returns RC_FAILED when
# neither the link nor the list could be read.
ubuntu_devel_codename() {
  local memo="${UBUNTU_RELEASE_CACHE:+${UBUNTU_RELEASE_CACHE}.devel}"
  local m out code link="" known=0 list last cn="" tried=""
  if [ -n "$memo" ] && [ -f "$memo" ]; then cat "$memo"; return 0; fi
  for m in "${UBUNTU_MIRROR:-}" "${UBUNTU_DEFAULT_MIRROR:-}"; do
    if [ -z "$m" ] || [ "$m" = "$tried" ]; then continue; fi
    tried="$m"
    out="$(curl -sSL --connect-timeout 5 -m 15 --retry 2 --retry-delay 2 -r 0-2047 \
             -w '\n%{http_code}' "${m}/dists/devel/Release" 2>/dev/null)"
    code="${out##*$'\n'}"
    case "$code" in
      2*) link="$(printf '%s\n' "${out%$'\n'*}" | awk '/^Codename:/ { print $2; exit }')"
          [[ "$link" =~ ^[a-z]+$ ]] || link=""
          known=1; break ;;
      # Only Ubuntu's own archive is known to carry the link: its "no" counts.
      4*) [ "$m" = "${UBUNTU_DEFAULT_MIRROR:-}" ] && known=1 ;;
    esac
  done
  # "<codename> <Supported>" for each release, oldest first.
  list="$(curl -fsSL -m 15 "${UBUNTU_META_RELEASE}-development" 2>/dev/null \
    | awk '/^Dist:/ { d = $2 } /^Supported:/ { if (d != "") print d, $2; d = "" }')"
  [ -z "$list" ] || known=1
  [ "$known" -eq 1 ] || return "$RC_FAILED"
  if [ -n "$link" ] && ! grep -qx "${link} 1" <<< "$list"; then
    cn="$link"
  elif [ -n "$list" ]; then
    last="$(tail -n 1 <<< "$list")"
    [ "${last#* }" = 0 ] && cn="${last% *}"
  fi
  [ -z "$memo" ] || printf '%s\n' "$cn" > "$memo"
  printf '%s\n' "$cn"
}

# One Ubuntu release as "<version> <state> <mirror>", from the run's release
# cache, whichever mirror it came from, else probed and added to it: on
# mirror $2 only, if given. The state is "devel" for the series in
# development (ubuntu_devel_codename), else "stable". Returns 1 when no
# mirror publishes it, RC_FAILED when a mirror could not be read (no
# connection, a server error).
ubuntu_release_info() {
  local cn="$1" mirror out code unread=0 state devel
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
    out="$(printf '%s\n' "${out%$'\n'*}" | awk '/^Version:/ { print $2; exit }')"
    if [ -n "$out" ]; then
      state=stable
      # Every retired release was published.
      if [ "$mirror" != "${UBUNTU_OLD_MIRROR:-}" ]; then
        devel="$(ubuntu_devel_codename)" || { unread=1; continue; }
        [ "$devel" = "$cn" ] && state=devel
      fi
      out="${out} ${state} ${mirror}"
      [ -n "${UBUNTU_RELEASE_CACHE:-}" ] && printf '%s %s\n' "$cn" "$out" >> "$UBUNTU_RELEASE_CACHE"
      printf '%s\n' "$out"
      return 0
    fi
  done
  [ "$unread" -eq 0 ] || return "$RC_FAILED"
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

# Mirror serving $1. Returns 1 when none publishes it, RC_FAILED when a
# mirror could not be read, as ubuntu_release_info.
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
    [ "$rc" -eq "$RC_FAILED" ] && { release_unread "$cn"; return "$RC_FAILED"; }
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
# cannot be read is skipped with a warning; returns RC_FAILED only when none
# could be.
discover_retired_codenames() {
  local cn info versioned="" rc unread="" listed order found=0 ordered="" rest=""
  listed="$(list_dists "$UBUNTU_OLD_MIRROR" | xargs)"
  # An unreadable listing is not "none retired": the caller must not claim
  # that no release fits.
  if [ -z "$listed" ]; then
    message error "Could not list the retired Ubuntu releases on ${UBUNTU_OLD_MIRROR} — check the connection, then run this again." >&2
    return "$RC_FAILED"
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
    [ "$rc" -eq "$RC_FAILED" ] && { unread="${unread} ${cn}"; continue; }
    [ "$rc" -eq 0 ] || continue
    versioned="${versioned}${info%% *} ${cn}
"
    found=$((found + 1))
    [ -n "$order" ] && [ "$found" -ge "$MAX_UBUNTU_LOOKBACK" ] && break
  done
  if [ -n "$unread" ]; then
    [ -n "$versioned" ] || { release_unread "${unread# }"; return "$RC_FAILED"; }
    message warn "could not read these retired Ubuntu releases, skipped:${unread}" >&2
  fi
  printf '%s' "$versioned" | oldest_first | tail -n "$MAX_UBUNTU_LOOKBACK" | xargs
}

# Install the missing tools in $1 (curl, ca-certificates). Generic tools, not
# recorded: the uninstall keeps them.
ensure_prereqs() {
  local prereq
  [ -n "$1" ] || return 0
  message "installing ${1}, needed to read Ubuntu's archive..."
  if apt_get update -qq; then APT_LISTS_FRESH=1; else message warn "apt update reported an error"; fi
  for prereq in $1; do
    installs_cleanly "$prereq" \
      || error "Installing prerequisite ${prereq} would remove packages or cannot be done — install it by hand"
    apt_get install -y "$prereq" < /dev/null \
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
    ubuntu_release_info "$1" >/dev/null; local st=$?
    case $st in
      0) ;;
      "$RC_FAILED") release_unread "$1"; exit 1 ;;
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
    message "installing Debian's ubuntu-keyring (Ubuntu's archive keys)..."
    # The prerequisites' update, if any, is recent enough.
    [ "${APT_LISTS_FRESH:-0}" = 1 ] || apt_get update -qq || message warn "apt update reported an error"
    wait_dpkg_lock || error "Another package manager is still running after 5 minutes — let it finish, then run this again."
    apt_install_checked ubuntu-keyring \
      || error "Could not install Debian's ubuntu-keyring package (Ubuntu's archive keys)."
    STATUS_CHANGES+=("Installed ubuntu-keyring (Ubuntu's archive keys, from Debian)")
  fi
  [ -s "$UBUNTU_KEYRING" ] || error "${UBUNTU_KEYRING} is missing — reinstall ubuntu-keyring."
}

# Write the Ubuntu apt source (deb822), one stanza per release. Returns
# RC_CHANGED, RC_UNCHANGED, or RC_FAILED when no archive answered or the file
# could not be written; the summary says which. With no argument, every
# candidate is written.
write_ubuntu_sources() {
  local tmp _c _m _rc_m _suites _comp _missing="" _list="${*:-$UBUNTU_CANDIDATE_CODENAMES}"
  tmp="$(mktemp)" || { STATUS_FAILED+=("Could not write ${UBUNTU_SOURCES} — no temporary file could be made"); return "$RC_FAILED"; }
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
      message "  checking the archive for ${_c}..." >&2
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
    return "$RC_FAILED"
  fi

  # 0644: apt reads sources as any user.
  local rc
  sudo_install_if_changed "$tmp" "$UBUNTU_SOURCES"; rc=$?
  rm -f "$tmp"
  [ "$rc" -ne "$RC_FAILED" ] || STATUS_FAILED+=("Could not write ${UBUNTU_SOURCES}")
  return "$rc"
}

# Bring the look packages back to the pinned release. apt never downgrades by
# itself; only these packages move, and nothing is removed but what
# ALLOWED_REMOVALS names: the separate extension packages the combined one
# replaces, or the combined one where the release no longer offers it.
align_look_packages() {
  [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != "auto" ] || return 0

  local pkg want have plan="" any_down=0
  local -A is_down=()
  message "checking the installed look packages against ${UBUNTU_CODENAME}..."
  # shellcheck disable=SC2086
  for pkg in $LOOK_PACKAGES $UBUNTU_SHELL_EXT_PKGS; do
    have="$(pkg_installed_version "$pkg")"
    [ -n "$have" ] || continue
    is_held "$pkg" && continue
    # The pinned release's newest build, up or down.
    pkg_version_in_codename "$pkg" "$have" "$UBUNTU_CODENAME" && continue
    want="$(release_build "$pkg" "$UBUNTU_CODENAME")"
    [ -n "$want" ] && [ "$want" != "$have" ] || continue
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
  if [ "$rc" -eq "$RC_CHANGED" ]; then
    done_list="$plan"
  elif [ "$rc" -eq "$RC_REFUSED" ]; then
    [ -n "$REMOVES" ] && message warn "aligning ${plan# } would remove: ${REMOVES} — skipped"
    # One package that cannot move must not hold back the others.
    for pkg in $plan; do
      down=""
      [ "${is_down[${pkg%%=*}]:-0}" = 1 ] && down=--allow-downgrades
      # shellcheck disable=SC2086
      apt_install_checked $down "$pkg"; rc=$?
      if [ "$rc" -eq "$RC_CHANGED" ]; then
        done_list="${done_list} ${pkg}"
        continue
      fi
      [ -n "$REMOVES" ] && message warn "aligning ${pkg} would remove: ${REMOVES} — skipped"
      if [ "$rc" -eq "$RC_REFUSED" ]; then
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

# A per-release wallpaper pack a release change left unused is reported: any
# user of the session may still show one of its pictures.
report_unused_wallpaper_packs() {
  local pkg orphan=""
  for pkg in $(LC_ALL=C apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' \
               | grep -E '^ubuntu-wallpapers-'); do
    predates_install "$pkg" || orphan="${orphan} ${pkg}"
  done
  [ -z "$orphan" ] \
    || STATUS_NOCHANGE+=("Now unused, kept for anyone showing its pictures:${orphan} — 'sudo apt autoremove' removes it")
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
  [ "$rc" -eq "$RC_CHANGED" ] || return 1
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
  STATUS_FAILED+=("${msg} $(echo $dropped) — its source stays on main; packages Ubuntu keeps in universe are left out")
  return 0
}

# Narrow the apt source to the pinned release before anything installs.
# Only a newly added suite needs an apt update.
narrow_ubuntu_sources() {
  [ -n "${UBUNTU_CODENAME:-}" ] && [ "$UBUNTU_CODENAME" != "auto" ] || return 0
  local before rc="$RC_CHANGED"
  before="$(ubuntu_source_entries)"
  # Each run tries universe again; the record stays if no archive answers.
  local no_universe=""
  if [ -f "$NO_UNIVERSE_RECORD" ]; then
    no_universe="$(cat "$NO_UNIVERSE_RECORD")"
    sudo rm -f "$NO_UNIVERSE_RECORD"
  fi
  write_ubuntu_sources "$UBUNTU_CODENAME" || rc=$?
  if [ "$rc" -eq "$RC_FAILED" ]; then
    [ -n "$no_universe" ] && sys_record_write "$NO_UNIVERSE_RECORD" "$no_universe"
    return 0
  fi
  if [ "$rc" -eq "$RC_CHANGED" ] \
     && ubuntu_source_entries | grep -qvxF -f <(printf '%s\n' "$before"); then
    message "refreshing the package list for ${UBUNTU_CODENAME}..."
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
    -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0; rc=$?
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
      LC_ALL=C apt_get update "$@" > "$log" 2>&1; rc=$?
    else
      LC_ALL=C apt_get update "$@" 2>&1 | tee "$log"
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
# Returns RC_BUSY when apt stayed locked, RC_FAILED when the Ubuntu sources
# could not be updated.
apt_update() {
  local log rc
  log="$(mktemp)" || return "$RC_FAILED"
  apt_update_waiting "$log" show; rc=$?
  [ "$rc" -eq 0 ] && { rm -f "$log"; return 0; }
  # Still locked after five tries.
  grep -q 'Could not get lock' "$log" && { rm -f "$log"; return "$RC_BUSY"; }
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
  return "$RC_FAILED"
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

# apt-cache madison $@ as trimmed "<version>|<source>" lines.
madison_rows() {
  LC_ALL=C apt-cache madison "$@" 2>/dev/null | awk -F'|' '
    { gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); print $2 "|" $3 }'
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
      want="$(release_build "$themepkg" "$UBUNTU_CODENAME")"
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
  cand_major="$(version_major "$(pkg_candidate_version gnome-shell)")"
  if [ -n "$cand_major" ] && [ "$cand_major" -gt "$running" ]; then
    for pkg in $UBUNTU_SHELL_EXT_PKGS; do
      bound="$(pkg_shell_upper_bound "$pkg")"
      if [ -n "$bound" ] && [ "$cand_major" -ge "$bound" ]; then
        STATUS_FAILED+=("GNOME Shell ${cand_major} is available but ${pkg} holds it back — before a Debian release upgrade run 'bash ubuntu-look.sh --uninstall', and this script again after it")
        break
      fi
    done
  fi

  # Only the extensions wait on a GNOME Shell change; each release line above
  # says what to do.
  [ "$drift" -eq 1 ] && message warn "see the summary; re-run this script after a GNOME Shell change"
  return 0
}

# The release the Ubuntu pin names; empty without one.
pinned_codename() { sed -n 's/^Pin: release o=Ubuntu, n=//p' "$UBUNTU_PIN" 2>/dev/null | head -1; }

# Without a pin, write one that blocks every Ubuntu package. Returns
# RC_CHANGED, RC_UNCHANGED (a pin exists) or RC_FAILED.
write_provisional_pin() {
  [ ! -f "$UBUNTU_PIN" ] || return "$RC_UNCHANGED"
  printf '%s\n' \
    "# provisional — written before the Ubuntu sources, replaced once the codename resolves" \
    "Package: *" \
    "Pin: release o=Ubuntu" \
    "Pin-Priority: -1" | sudo_tee "$UBUNTU_PIN" \
    || { sudo rm -f "$UBUNTU_PIN"; return "$RC_FAILED"; }
}

# The per-release wallpaper packs that the pinned release's ubuntu-wallpapers
# depends on. Early in a release's cycle the pack still carries the previous
# release's name, so the names are read from the package; UBUNTU_CODENAME
# gives the name only while apt knows no build of it.
wallpaper_packs() {
  local ver packs=""
  ver="$(release_build ubuntu-wallpapers "$UBUNTU_CODENAME")"
  [ -n "$ver" ] && packs="$(LC_ALL=C apt-cache show "ubuntu-wallpapers=${ver}" 2>/dev/null \
    | sed -n 's/^Depends: //p' | head -n 1 | tr ',|' '\n\n' | awk '{ print $1 }' \
    | grep -E '^ubuntu-wallpapers-[a-z]+$' | sort -u | xargs)"
  echo "${packs:-ubuntu-wallpapers-${UBUNTU_CODENAME}}"
}

# The wallpaper packs the pin on disk names.
pinned_wallpaper_packs() {
  sed -n 's/^Package: //p' "$UBUNTU_PIN" 2>/dev/null | tr ' ' '\n' \
    | grep -E '^ubuntu-wallpapers-' | sort -u | xargs
}

# Write the Ubuntu pin for UBUNTU_CODENAME.
# Returns RC_CHANGED, RC_UNCHANGED or RC_FAILED.
write_ubuntu_pin() {
  local tmp
  tmp="$(mktemp)" || { STATUS_FAILED+=("Could not write the Ubuntu pin ${UBUNTU_PIN}"); return "$RC_FAILED"; }
  cat << EOF > "$tmp"
# pin-version: ${PIN_VERSION}
# Written by ubuntu-look.sh. Every Ubuntu package is blocked (-1) except the
# look, which comes from one release. Debian's builds it replaces are put back
# by 'ubuntu-look.sh --uninstall'.
Package: *
Pin: release o=Ubuntu
Pin-Priority: -1

Package: ${UBUNTU_PINNED_PACKAGES} $(wallpaper_packs)
Pin: release o=Ubuntu, n=${UBUNTU_CODENAME}
Pin-Priority: 990
EOF
  local rc
  sudo_install_if_changed "$tmp" "$UBUNTU_PIN"; rc=$?
  rm -f "$tmp"
  [ "$rc" -ne "$RC_FAILED" ] || STATUS_FAILED+=("Could not write the Ubuntu pin ${UBUNTU_PIN}")
  return "$rc"
}

# The package list, manual marks and config-files list before this script
# installs anything, taken once. Any failed query or write stops the run
# before PACKAGES_BEFORE, whose presence marks the snapshot complete.
record_packages_before() {
  [ ! -f "$PACKAGES_BEFORE" ] || return 0
  local tmp ok=0
  tmp="$(mktemp -d)" || error "Could not take the pre-install package snapshot."
  # pipefail: a failed query must not pass as an empty list.
  if ( set -o pipefail
       apt-mark showmanual 2>/dev/null | sort > "${tmp}/manual" \
       && dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
            | awk '$4 == "config-files" { print $1 }' | sort > "${tmp}/config" \
       && installed_package_list > "${tmp}/installed" && [ -s "${tmp}/installed" ] ) \
     && sys_records_dir \
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
      [ "$info_rc" -eq "$RC_FAILED" ] && { release_unread "$hint"; exit 1; }
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
ubuntu_shell_major() { version_major "$(release_build gnome-shell "$1")"; }

# Put back the Ubuntu apt source saved in PREV_UBUNTU_SOURCES, and drop a
# provisional pin this run wrote.
restore_prev_ubuntu_sources() {
  # Without the saved copy there is nothing to go by: the source stays.
  if [ ! -f "${PREV_UBUNTU_SOURCES:-}" ]; then
    :
  elif [ -s "$PREV_UBUNTU_SOURCES" ]; then
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
# 4. Desktop: Ubuntu's settings, extensions, terminal, login screen
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
# without their user database. Returns RC_CHANGED, RC_UNCHANGED or RC_FAILED.
write_look_profile() {
  local tmp rc
  # A pending boot-time removal would delete the new profile. The directory it
  # was to remove too was the install's: that stays on record.
  if [ -f "$LOOK_CLEANUP_CONF" ]; then
    grep -qxF 'r /etc/dconf/profile' "$LOOK_CLEANUP_CONF" 2>/dev/null \
      && sys_records_dir && sudo touch "$DCONF_PROFILE_DIR_MADE"
    sudo rm -f "$LOOK_CLEANUP_CONF"
  fi
  tmp="$(mktemp)" || return "$RC_FAILED"
  look_profile_content > "$tmp" || { rm -f "$tmp"; return "$RC_FAILED"; }
  if [ ! -d /etc/dconf/profile ]; then
    sys_records_dir; sudo touch "$DCONF_PROFILE_DIR_MADE"
    sudo install -d -m 0755 /etc/dconf/profile || { rm -f "$tmp"; return "$RC_FAILED"; }
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

# Mask session-migration. Returns RC_CHANGED, RC_UNCHANGED (already masked),
# or RC_FAILED: it failed, or an admin's own unit file is there.
mask_session_migration() {
  [ "$(readlink "$SESSION_MIGRATION_MASK" 2>/dev/null)" = /dev/null ] && return "$RC_UNCHANGED"
  [ -e "$SESSION_MIGRATION_MASK" ] || [ -L "$SESSION_MIGRATION_MASK" ] && return "$RC_FAILED"
  sys_records_dir && sudo touch "$SESSION_MIGRATION_MASKED" || return "$RC_FAILED"
  sudo mkdir -p "${SESSION_MIGRATION_MASK%/*}" \
    && sudo ln -s /dev/null "$SESSION_MIGRATION_MASK" && return "$RC_CHANGED"
  sudo rm -f "$SESSION_MIGRATION_MASKED"
  return "$RC_FAILED"
}

# Choose the Ubuntu session for this user's next logins, as picking it on the
# login screen does. Returns RC_CHANGED, RC_UNCHANGED (already chosen) or
# RC_FAILED.
choose_ubuntu_session() {
  local user
  user="/org/freedesktop/Accounts/User$(id -u)"
  [ "$(busctl get-property org.freedesktop.Accounts "$user" org.freedesktop.Accounts.User \
        Session 2>/dev/null)" = "s \"${SHELL_MODE_NAME}\"" ] && return "$RC_UNCHANGED"
  sudo busctl call org.freedesktop.Accounts "$user" org.freedesktop.Accounts.User \
    SetSession s "$SHELL_MODE_NAME" >/dev/null 2>&1 || return "$RC_FAILED"
}

# Take this user off the record of those the apt hook's removal of the
# session left without it.
forget_session_user() {
  local rest
  [ -f "$SESSION_USERS_RECORD" ] || return 0
  rest="$(grep -vxF -- "$RUN_USER" "$SESSION_USERS_RECORD" 2>/dev/null | sort -u)"
  if [ -z "$rest" ]; then
    sudo rm -f "$SESSION_USERS_RECORD"
  else
    sys_record_write "$SESSION_USERS_RECORD" "$rest"
  fi
}

# True when gnome-shell reports extension $1 as running; older GNOME Shell
# versions call that state ENABLED, newer ones ACTIVE.
EXT_RUNNING_RE='State: (ACTIVE|ENABLED)$'
extension_active() { LC_ALL=C gnome-extensions info "$1" 2>/dev/null | grep -qE "$EXT_RUNNING_RE"; }

# The session mode file: the values of Ubuntu's ubuntu.json, less its debug
# flags and its icons resource, which only Ubuntu's GNOME Shell reads (the
# theme extension loads those icons), with the look's extensions that are
# installed for everyone.
session_mode_content() {
  local e list=""
  for e in $SHELL_EXTENSIONS; do
    [ -d "/usr/share/gnome-shell/extensions/$e" ] || [ -d "${LOCAL_EXT_DIR}/$e" ] \
      && list="${list:+${list},}"$'\n'"        \"${e}\""
  done
  cat << MODE
{
    "parentMode": "user",
    "stylesheetName": "Yaru/gnome-shell.css",
    "themeResourceName": "theme/Yaru/gnome-shell-theme.gresource",
    "colorScheme": "prefer-light",
    "enabledExtensions": [${list}
    ]
}
MODE
}

# The session's font configuration. Ubuntu turns on RGB sub-pixel rendering
# for every program through fontconfig; Debian's fontconfig sets "none".
# Inside the session only, "none" becomes "rgb"; a value an app sets itself
# stays.
session_fonts_content() {
  cat << 'FONTS'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Written by ubuntu-look.sh; its uninstall removes this file. -->
<fontconfig>
  <include>/etc/fonts/fonts.conf</include>
  <match target="pattern">
    <test name="rgba" compare="eq"><const>none</const></test>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
FONTS
}

# The script run when the session ends: Debian's GNOME session gets back what
# the Ubuntu session took over. GNOME Shell disables no extension at log out,
# so the tiling assistant's shortcuts are given back as its own disable()
# would.
session_end_content() {
  cat << 'END'
// Written by ubuntu-look.sh; removed by its uninstall.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const source = Gio.SettingsSchemaSource.get_default();
const schema = source.lookup('org.gnome.shell.extensions.tiling-assistant', true);
const tiling = schema ? new Gio.Settings({settings_schema: schema}) : null;
const saved = tiling?.get_user_value('overridden-settings');
if (saved) {
    const nothing = GLib.Variant.new_maybe(new GLib.VariantType('b'), null);
    for (const [path, value] of Object.entries(saved.unpack())) {
        const key = path.split('.').at(-1);
        const id = path.split('.').slice(0, -1).join('.');
        const keySchema = source.lookup(id, true);
        if (!keySchema?.has_key(key))
            continue;
        const settings = new Gio.Settings({settings_schema: keySchema});
        const original = value.get_variant();
        if (original.equal(nothing))
            settings.reset(key);
        else
            settings.set_value(key, original);
    }
    tiling.reset('overridden-settings');
    Gio.Settings.sync();
}
END
}

# The session manager's drop-in: it runs the script above, then clears the
# session's variables. The user's service manager outlives a quick log out; a
# GNOME session started next must not inherit them.
session_manager_dropin_content() {
  cat << UNSET
# Written by ubuntu-look.sh; removed by its uninstall.
[Service]
ExecStopPost=-/usr/bin/gjs -m ${SESSION_END_SCRIPT}
ExecStopPost=-/usr/bin/systemctl --user unset-environment $(printf '%s\n' $SESSION_ENV | cut -d= -f1 | xargs)
UNSET
}

# The apt hook, run after each package change. It takes the Ubuntu session
# off the login screen when Yaru's shell theme is gone or GNOME Shell is on
# another major version than the look was set up for, and notes who logged in
# to it, so the next run chooses it for them again.
apt_hook_content() {
  cat << HOOK
#!/bin/sh
# Written by ubuntu-look.sh; removed by its uninstall. Run by apt after each
# package change; it never fails, so it cannot stop apt.
mode=${SHELL_MODE_FILE}
[ -e "\$mode" ] || exit 0
# The Ubuntu session goes and the login screen offers Debian's GNOME. Who
# logs in to it is noted first: the next run of ubuntu-look.sh chooses it for
# them again.
drop_session() {
  if [ -d ${SYS_RECORDS} ]; then
    for f in ${ACCOUNTS_USERS_DIR}/*; do
      [ -f "\$f" ] && grep -qE '^X?Session=${SHELL_MODE_NAME}' "\$f" && echo "\${f##*/}"
    done >> ${SESSION_USERS_RECORD} 2>/dev/null
  fi
  rm -f "\$mode" ${SESSION_ENTRIES}
}
# The look's packages match one GNOME Shell: its major version, the digits
# before the first dot or pre-release mark (49.1, 49~rc).
shell=\$(dpkg-query -W -f='\${Version}' gnome-shell 2>/dev/null)
shell=\${shell#*:}; shell=\${shell%%[!0-9]*}
built=\$(sed -n 's/.*"shell-version": \["\([0-9]*\)"\].*/\1/p' ${THEME_EXT_DIR}/metadata.json 2>/dev/null)
if [ ! -e ${YARU_SHELL_THEME} ]; then
  drop_session
elif [ -n "\$shell" ] && [ -n "\$built" ] && [ "\$shell" != "\$built" ]; then
  drop_session
  echo "ubuntu-look: GNOME Shell is now \${shell}; run 'bash ubuntu-look.sh --refresh' to update the look." >&2
fi
exit 0
HOOK
}

# apt's configuration entry that runs the hook.
apt_hook_conf_content() {
  cat << CONF
// Written by ubuntu-look.sh; removed by its uninstall.
DPkg::Post-Invoke { "if [ -x ${APT_HOOK} ]; then ${APT_HOOK}; fi"; };
CONF
}

# Install the login screen's "Ubuntu" session, as Ubuntu has it: entries made
# from Debian's GNOME ones, Debian's gnome-session files for it, Ubuntu's
# session mode, the session's font rule, and the apt hook that guards them.
# GNOME Shell loads Yaru and the look's extensions when it starts, so nothing
# restyles after login. Returns RC_CHANGED, RC_UNCHANGED or RC_FAILED.
write_session() {
  local tmp rc="$RC_UNCHANGED" r f src dest pairs=""
  tmp="$(mktemp -d)" || return "$RC_FAILED"
  session_mode_content > "${tmp}/mode"
  session_fonts_content > "${tmp}/fonts"
  session_end_content > "${tmp}/end"
  session_manager_dropin_content > "${tmp}/unset"
  apt_hook_content > "${tmp}/hook"
  apt_hook_conf_content > "${tmp}/conf"
  # One entry per Debian GNOME entry: GNOME, on Wayland, on Xorg.
  for src in $GNOME_SESSION_ENTRIES; do
    [ -f "$src" ] || continue
    f="${src##*/}"; f="ubuntu${f#gnome}"
    dest="/usr/local/share/${src#/usr/share/}"; dest="${dest%/*}/${f}"
    mkdir -p "${tmp}${dest%/*}"
    { echo "# Written by ubuntu-look.sh; removed by its uninstall."
      sed -e '/^\(Name\|Comment\)\[/d' -e 's/^Name=GNOME/Name=Ubuntu/' \
          -e 's/^Comment=.*/Comment=This session logs you into Ubuntu/' \
          -e "s#^Exec=.*#Exec=env ${SESSION_ENV} /usr/bin/gnome-session --session=${SHELL_MODE_NAME}#" \
          -e "s/^DesktopNames=.*/DesktopNames=${SHELL_MODE_NAME};GNOME/" "$src"
    } > "${tmp}${dest}"
    pairs="${pairs} ${tmp}${dest}:${dest}"
  done
  # Debian's login sound entry, off and hidden as Ubuntu's. Only where the
  # look brought gnome-session-canberra: Debian's GNOME session stays silent
  # as before, and a login sound the user had keeps playing.
  local sound_dir=""
  if [ -f "$LOGIN_SOUND_ENTRY" ] && ! predates_install gnome-session-canberra; then
    sound_dir="${LOGIN_SOUND_OFF%/*}"
    mkdir -p "${tmp}${sound_dir}"
    { echo "# Written by ubuntu-look.sh; removed by its uninstall."
      grep -v '^\(X-GNOME-Autostart-enabled\|NoDisplay\)=' "$LOGIN_SOUND_ENTRY"
      printf 'X-GNOME-Autostart-enabled=false\nNoDisplay=true\n'
    } > "${tmp}${LOGIN_SOUND_OFF}"
    pairs="${pairs} ${tmp}${LOGIN_SOUND_OFF}:${LOGIN_SOUND_OFF}"
  fi
  local dirs="${SHELL_MODE_FILE%/*} ${APT_HOOK%/*} ${SESSION_FONTS_CONF%/*} ${GNOME_SESSION_FILE%/*} ${SESSION_TARGET_DROPIN%/*} ${SESSION_MANAGER_DROPIN%/*} ${sound_dir}"
  for f in $SESSION_ENTRIES; do dirs="${dirs} ${f%/*}"; done
  # shellcheck disable=SC2086
  if ! sudo install -d -m 0755 $dirs; then
    rm -rf "$tmp"
    return "$RC_FAILED"
  fi
  # The hook before what it guards, and its apt entry last.
  if [ -f "$APT_HOOK" ] && cmp -s "${tmp}/hook" "$APT_HOOK"; then r="$RC_UNCHANGED"
  elif sudo_write_atomic "${tmp}/hook" "$APT_HOOK" 0755; then r="$RC_CHANGED"
  else r="$RC_FAILED"; fi
  rc=$r
  for f in "${tmp}/mode:${SHELL_MODE_FILE}" "${tmp}/fonts:${SESSION_FONTS_CONF}" \
           "${tmp}/end:${SESSION_END_SCRIPT}" "${tmp}/unset:${SESSION_MANAGER_DROPIN}" \
           $pairs "${tmp}/conf:${APT_HOOK_CONF}"; do
    [ "$rc" = "$RC_FAILED" ] && break
    sudo_install_if_changed "${f%%:*}" "${f#*:}"; r=$?
    [ "$r" = "$RC_CHANGED" ] && rc="$RC_CHANGED"
    [ "$r" = "$RC_FAILED" ] && rc="$RC_FAILED"
  done
  # Debian's own GNOME session files serve it, linked so they stay in step.
  # From GNOME 49 the target's file names the shell's mode, as the unit
  # org.gnome.Shell@user.service; there the session gets a copy that names its
  # own mode, since the shell no longer takes it from the environment.
  for f in /usr/share/gnome-session/sessions/gnome.session:"$GNOME_SESSION_FILE" \
           /usr/lib/systemd/user/gnome-session@gnome.target.d/gnome.session.conf:"$SESSION_TARGET_DROPIN"; do
    [ "$rc" = "$RC_FAILED" ] && break
    src="${f%%:*}"; dest="${f#*:}"
    [ -f "$src" ] || { rc="$RC_FAILED"; break; }
    if grep -q 'org\.gnome\.Shell@user\.service' "$src"; then
      { echo "# Written by ubuntu-look.sh from ${src}; removed by its uninstall."
        sed "s/org\.gnome\.Shell@user\.service/org.gnome.Shell@${SHELL_MODE_NAME}.service/" "$src"
      } > "${tmp}/target"
      # A link from an older GNOME must not be written through.
      [ ! -L "$dest" ] || sudo rm -f "$dest" || { rc="$RC_FAILED"; break; }
      sudo_install_if_changed "${tmp}/target" "$dest"; r=$?
      [ "$r" = "$RC_CHANGED" ] && rc="$RC_CHANGED"
      [ "$r" = "$RC_FAILED" ] && rc="$RC_FAILED"
      continue
    fi
    [ "$(readlink "$dest" 2>/dev/null)" = "$src" ] && continue
    if sudo ln -sfn "$src" "$dest"; then rc="$RC_CHANGED"; else rc="$RC_FAILED"; fi
  done
  rm -rf "$tmp"
  return "$rc"
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

# Render GNOME_SETTINGS and SESSION_ONLY_SETTINGS as dconf keyfile groups.
render_dconf_groups() {
  local line last_path="" path key value
  fit_fonts_to_release
  for line in "${GNOME_SETTINGS[@]}" "${SESSION_ONLY_SETTINGS[@]}"; do
    IFS='|' read -r path key value <<< "$line"
    if [ "$path" != "$last_path" ]; then
      [ -n "$last_path" ] && echo ""
      echo "[${path}]"
      last_path="$path"
    fi
    echo "${key}=${value}"
  done
}

# True when this user's running gnome-shell has $1 ("NAME=value") in its
# environment.
shell_started_with() {
  local pid
  pid="$(pgrep -u "$(id -u)" -x gnome-shell 2>/dev/null | head -1)"
  [ -n "$pid" ] && tr '\0' '\n' 2>/dev/null < "/proc/${pid}/environ" | grep -qxF -- "$1"
}

# True when this user's running gnome-shell reads the look profile.
session_on_look_profile() { shell_started_with "DCONF_PROFILE=${LOOK_PROFILE_NAME}"; }

# True when this user's running gnome-shell started in Ubuntu's session mode.
session_in_look_mode() { shell_started_with "GNOME_SHELL_SESSION_MODE=${SHELL_MODE_NAME}"; }

# The value the look set for the key, from its defaults database.
our_dconf_value() {
  local f
  for f in "$LOOK_DB_FILE" "$DCONF_PROFILE_COPY"; do
    [ -f "$f" ] && { ini_value "$f" "$1" "$2"; return; }
  done
}

# The look's keys where this user's own value differs from Ubuntu's default:
# the Ubuntu session shows theirs. Listed in the summary, never changed.
report_own_settings() {
  local path key own ours
  while read -r path key; do
    ours="$(our_dconf_value "$path" "$key")"
    [ -n "$ours" ] || continue
    own="$(user_dconf_read "/${path}/${key}")"
    [ -n "$own" ] && [ "${own// /}" != "${ours// /}" ] \
      && SETTINGS_KEPT+=("/${path}/${key} — yours: ${own}, Ubuntu's: ${ours}")
  done < <(look_keys)
}

# Every key the look sets or clears, as "<path> <key>", the colour scheme
# first, so a running theme extension picks the theme from it before the
# other keys go. The dock has its own step.
look_keys() {
  local line path key
  for line in "$COLOR_SCHEME_KEY" "${GNOME_SETTINGS[@]}" "${WALLPAPER_KEYS[@]}"; do
    IFS='|' read -r path key _ <<< "$line"
    echo "$path $key"
  done
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

  write_look_profile; profile_rc=$?
  case $profile_rc in
    "$RC_CHANGED") STATUS_CHANGES+=("dconf profile for the Ubuntu session → ${LOOK_PROFILE}"); RELOGIN_NEEDED=1 ;;
    "$RC_FAILED") STATUS_FAILED+=("${LOOK_PROFILE} could not be written — the look cannot apply") ;;
  esac
  if [ "$profile_rc" -ne "$RC_FAILED" ] && ! look_profile_usable; then
    STATUS_FAILED+=("${LOOK_PROFILE} has no user database — the look is not enabled")
    profile_rc="$RC_FAILED"
  fi
  mask_session_migration; local st=$?
  case $st in
    "$RC_CHANGED") STATUS_CHANGES+=("session-migration masked → ${SESSION_MIGRATION_MASK}") ;;
    "$RC_FAILED") STATUS_FAILED+=("session-migration could not be masked (${SESSION_MIGRATION_MASK}) — it may change color-scheme at login") ;;
  esac

  local tmp
  if ! tmp="$(mktemp)"; then
    STATUS_FAILED+=("${LOOK_DB_FILE} could not be written — Ubuntu's defaults are not updated")
    [ "$profile_rc" -ne "$RC_FAILED" ]
    return
  fi
  {
    echo "# Written by ubuntu-look.sh — Ubuntu's GNOME defaults, read only in the"
    echo "# Ubuntu session (see ${LOOK_PROFILE}). Users' own values win."
    echo ""
    render_dconf_groups
    echo "$bg_block"
  } > "$tmp"

  local db_rc="$RC_FAILED"
  { [ -d "${LOOK_DB_FILE%/*}" ] || sudo install -d -m 0755 "${LOOK_DB_FILE%/*}"; } \
    && { sudo_install_if_changed "$tmp" "$LOOK_DB_FILE"; db_rc=$?; }
  case $db_rc in
    "$RC_CHANGED") compile_dconf && { STATUS_CHANGES+=("Ubuntu's defaults written → ${LOOK_DB_FILE}"); RELOGIN_NEEDED=1; } ;;
    "$RC_FAILED") STATUS_FAILED+=("${LOOK_DB_FILE} could not be written — Ubuntu's defaults are not updated") ;;
    *) if dconf_db_stale "$LOOK_DB_NAME"; then
         # A run stopped before dconf update.
         compile_dconf && { STATUS_CHANGES+=("Ubuntu's defaults compiled → /etc/dconf/db/${LOOK_DB_NAME}"); RELOGIN_NEEDED=1; }
       else
         STATUS_NOCHANGE+=("Ubuntu's defaults already current")
       fi ;;
  esac
  rm -f "$tmp"
  [ "$profile_rc" -ne "$RC_FAILED" ]
}

write_greeter_extension() {
  write_local_extension "$GREETER_EXT_UUID" "Login screen extension" \
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
write_local_extension() {
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
  if ! tmp="$(mktemp -d)"; then
    cat > /dev/null
    STATUS_FAILED+=("${label} not installed — no temporary directory could be made")
    return 1
  fi
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
      sudo_install_if_changed "${tmp}/${f}" "${dir}/${f}"; local st=$?
      case $st in "$RC_CHANGED") changed=1 ;; "$RC_FAILED") failed=1; break ;; esac
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

# The rest of Ubuntu's shell theme: the shell theme itself comes from the
# Ubuntu session mode (write_session). As on Ubuntu, a Yaru GTK and icon
# theme follow the colour scheme and accent colour, and the Dark Style toggle
# also moves the icons to Yaru.
write_theme_extension() {
  write_local_extension "$THEME_EXT_UUID" "Shell theme extension" \
    "Ubuntu look" "Yaru's shell icons and Ubuntu's Dark Style, as on Ubuntu." \
    '"user"' << 'EOF'
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// The icons resource of Ubuntu's session mode: Yaru's shell icons over GNOME's.
const ICONS_RESOURCE = 'theme/Yaru/gnome-shell-icons.gresource';
// The session mode; the uninstall removes it first.
const MODE_FILE = '/usr/local/share/gnome-shell/modes/ubuntu.json';

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
        // Still running from before the screen was locked.
        if (this._interface)
            return;
        this._skipStartupOverview();
        this._loadIcons();
        this._interface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        // GNOME before 47 has no accent colour; the current Yaru variant is kept.
        this._hasAccent = this._interface.settings_schema.has_key('accent-color');
        this._schemeId = this._interface.connect('changed::color-scheme',
            () => this._followAppearance());
        this._accentId = this._hasAccent
            ? this._interface.connect('changed::accent-color', () => this._followAppearance())
            : 0;
        // Only a change made in this session moves the themes, as on Ubuntu;
        // nothing is written at login, so Debian's GNOME session, which shares
        // the user's settings, stays as it was.
        this._hookDarkToggle();
    }

    disable() {
        // The lock screen's mode lists no extensions; Ubuntu's own shell keeps
        // its icons and Dark Style there, so this keeps running.
        if (Main.sessionMode.isLocked)
            return;
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
    }

    // Ubuntu Dock's "disable-overview-on-startup": login goes straight to the
    // desktop. The dock applies it only when it starts before the startup
    // animation; this extension, loaded first, applies it in time.
    _skipStartupOverview() {
        if (!Main.layoutManager._startingUp || !Main.sessionMode.hasOverview)
            return;
        const schema = Gio.SettingsSchemaSource.get_default()
            .lookup('org.gnome.shell.extensions.dash-to-dock', true);
        if (!schema?.has_key('disable-overview-on-startup') ||
            !new Gio.Settings({settings_schema: schema}).get_boolean('disable-overview-on-startup'))
            return;
        Main.sessionMode.hasOverview = false;
        const id = Main.layoutManager.connect('startup-complete', () => {
            Main.layoutManager.disconnect(id);
            // After the dock's own startup handler, which restores the value
            // it found.
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                Main.sessionMode.hasOverview = true;
                return GLib.SOURCE_REMOVE;
            });
        });
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

            if (this._interface.get_string('gtk-theme').split('-')[0] === 'Yaru' &&
                !this._lookRemoved())
                this._setYaruSettings(preferDark);
        };
    }

    // True once the uninstall has begun: the themes it resets stay reset.
    _lookRemoved() {
        return !GLib.file_test(MODE_FILE, GLib.FileTest.EXISTS);
    }

    _setYaruSettings(preferDark) {
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
        if (this._toggling || this._lookRemoved())
            return;
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

  write_greeter_extension
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
  if ! tmp="$(mktemp)"; then
    STATUS_FAILED+=("${GDM_PROFILE_FILE} could not be written — login screen unchanged")
    return 0
  fi
  cat << EOF > "$tmp"
# Written by ubuntu-look.sh — the login screen's Ubuntu theme; removed by 'ubuntu-look.sh --uninstall'.
[org/gnome/desktop/interface]
${iface%$'\n'}
${sound}
${ext_block}
${bg_block}
EOF

  local gdm_rc="$RC_FAILED"
  if [ ! -d "$GDM_PROFILE_DIR" ]; then
    sys_records_dir; sudo touch "${SYS_RECORDS}/dconf-gdm-dir-created"
    sudo install -d -m 0755 "$GDM_PROFILE_DIR"
  fi
  [ -d "$GDM_PROFILE_DIR" ] && { sudo_install_if_changed "$tmp" "$GDM_PROFILE_FILE"; gdm_rc=$?; }
  case $gdm_rc in
    "$RC_CHANGED") compile_dconf && if [ "$_reader" -eq 1 ]; then
         STATUS_CHANGES+=("Login screen themed → ${GDM_PROFILE_FILE}")
         RELOGIN_NEEDED=1
       else
         STATUS_NOCHANGE+=("${GDM_PROFILE_FILE} written, but no greeter profile reads it — login screen unchanged")
       fi ;;
    "$RC_UNCHANGED") if dconf_db_stale gdm; then
         compile_dconf && { STATUS_CHANGES+=("Login screen defaults compiled → /etc/dconf/db/gdm"); RELOGIN_NEEDED=1; }
       elif [ "$_reader" -eq 1 ]; then
         STATUS_NOCHANGE+=("Login screen theme already current")
       else
         STATUS_NOCHANGE+=("${GDM_PROFILE_FILE} is current, but no greeter profile reads it — login screen unchanged")
       fi ;;
    "$RC_FAILED") STATUS_FAILED+=("${GDM_PROFILE_FILE} could not be written — login screen unchanged") ;;
  esac
  rm -f "$tmp"
  return 0
}

# UBUNTU_LOOK_ANIMATIONS: sets the user's own animation switch, the one in
# Settings > Accessibility; neither the look nor the uninstall resets it.
# Called only when the option is given. Prints the result; returns
# RC_CHANGED, RC_UNCHANGED or RC_FAILED.
apply_animation_option() {
  local want=true state=on
  [ "$UBUNTU_LOOK_ANIMATIONS" = 0 ] && { want=false; state=off; }
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "Animation effects not set — run this again from your desktop session"
    return "$RC_FAILED"
  fi
  if [ "$(gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null)" = "$want" ]; then
    echo "Animation effects already ${state}"; return "$RC_UNCHANGED"
  fi
  gsettings set org.gnome.desktop.interface enable-animations "$want" 2>/dev/null \
    && { echo "Animation effects turned ${state}"; return "$RC_CHANGED"; }
  echo "Animation effects could not be turned ${state}"
  return "$RC_FAILED"
}

# A key binding in one spelling: lower case, <Control> and <Ctrl> as
# <Primary>, the modifiers in sorted order.
normalise_binding() {
  local b key
  b="$(printf '%s' "$1" | tr -d "'" | tr '[:upper:]' '[:lower:]' | sed 's/<control>/<primary>/g; s/<ctrl>/<primary>/g')"
  key="${b##*>}"
  printf '%s%s' "$(printf '%s' "${b%"$key"}" | grep -o '<[^>]*>' | sort -u | tr -d '\n')" "$key"
}

# Ubuntu binds Ctrl+Alt+T to the terminal; Debian binds nothing there. The
# look's settings bind it with a custom shortcut, but a user's own list of
# custom shortcuts replaces the look's: for this user it is added to theirs,
# once, so one they remove stays removed. Their own Ctrl+Alt+T wins.
add_terminal_shortcut() {
  local list p want
  if [ -f "$TERMINAL_SHORTCUT_RECORD" ]; then
    STATUS_NOCHANGE+=("Ctrl+Alt+T terminal shortcut already added")
    return 0
  fi
  list="$(user_dconf_read "$CUSTOM_KEYBINDINGS_KEY")"
  [ -n "$list" ] || return 0
  list="$(array_items "$list" | xargs)"
  if ! in_word_list "$TERMINAL_SHORTCUT_PATH" "$list"; then
    want="$(normalise_binding '<Primary><Alt>t')"
    for p in $list; do
      if [ "$(normalise_binding "$(dconf read "${p}binding" 2>/dev/null)")" = "$want" ]; then
        STATUS_NOCHANGE+=("Ctrl+Alt+T already runs your own shortcut — left as it is")
        return 0
      fi
    done
    if ! dconf write "$CUSTOM_KEYBINDINGS_KEY" "$(gvariant_string_array "${list} ${TERMINAL_SHORTCUT_PATH}")" 2>/dev/null; then
      STATUS_FAILED+=("Ctrl+Alt+T terminal shortcut not added to your shortcuts — re-run to retry")
      return 0
    fi
    STATUS_CHANGES+=("Ctrl+Alt+T opens the terminal, as on Ubuntu — added to your own shortcuts")
  fi
  mkdir -p "$BACKUP_DIR" && : > "$TERMINAL_SHORTCUT_RECORD"
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

write_app_grid_icon() {
  local src="" c tmp _icon_rc _changed_note="" _current_note=""
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

  tmp="$(mktemp)" || { STATUS_FAILED+=("Show Applications icon not written — no temporary file could be made"); return 0; }
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

  # A directory that cannot be made is a failed write, not "already current".
  _icon_rc="$RC_FAILED"
  sudo install -d -m 0755 "${APP_GRID_ICON%/*}" \
    && { sudo_install_if_changed "$tmp" "$APP_GRID_ICON"; _icon_rc=$?; }
  if [ "$_icon_rc" -eq "$RC_FAILED" ]; then
    rm -f "$tmp"
    STATUS_FAILED+=("Show Applications icon could not be written to ${APP_GRID_ICON}")
    return 0
  fi
  # No icon cache is needed: GTK finds uncached icons. An unscaled copy is
  # reported on every run.
  if [ "$_icon_rc" -eq "$RC_CHANGED" ]; then
    STATUS_CHANGES+=("Show Applications button now uses ${src##*/}${_changed_note}")
    RELOGIN_NEEDED=1
  else
    STATUS_NOCHANGE+=("Show Applications button icon already current${_current_note}")
  fi
  rm -f "$tmp"
}

###############################################################################
# 5. Boot: GRUB command line and boot splash
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
  ' /etc/default/grub > "$tmp"; local st=$?

  # A failed awk (a full /tmp) leaves a partial copy that may still parse.
  if [ "$st" -ne 0 ] || [ ! -s "$tmp" ] || ! grep -qE "$GRUB_KEY_RE" "$tmp"; then
    rm -f "$tmp"
    message warn "the /etc/default/grub rewrite did not come out right — leaving it alone"
    return 1
  fi
  replace_grub_file "$tmp"
}

# Delete the GRUB_CMDLINE_LINUX_DEFAULT line this script appended.
remove_grub_cmdline_line() {
  local tmp
  GRUB_BACKUP_KEPT=""
  tmp="$(mktemp)" || return 1
  awk -v re="$GRUB_KEY_RE" '!done && $0 ~ re { done = 1; next } { print }' \
    /etc/default/grub > "$tmp" || { rm -f "$tmp"; return 1; }
  replace_grub_file "$tmp"
}

# Install temporary file $1 as /etc/default/grub (atomically, its mode kept)
# and run update-grub; put the original back if either fails. The backup is
# removed only once the file is known to match it or the new content took.
replace_grub_file() {
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
  grep -vxF -- "$1" "$GRUB_ADDED_FILE" > "$rec" 2>/dev/null; local st=$?
  case $st in
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
  message "rebuilding the initramfs for every kernel; this can take a minute..."
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
# Sets PLY_WAS, PLY_CURRENT and PLY_OUTCOME, which names the outcome:
#   restored   the earlier theme is back                          RC_CHANGED
#   rebuilt    nothing to set back; a rebuild still owed is made  RC_CHANGED
#   none       nothing to do                                      RC_UNCHANGED
#   kept       the user's own theme stays                         RC_UNCHANGED
#   unread     the current theme cannot be read                   RC_FAILED
#   put-back   setting the theme back failed                      RC_FAILED
#   rebuild    the theme is back, its initramfs rebuild failed    RC_FAILED
#   owed       the rebuild still owed failed again                RC_FAILED
#   no-record  the records could not be written                   RC_NO_RECORD
# The records stay unless it returns RC_CHANGED or RC_UNCHANGED.
plymouth_put_back() {
  local ours rc
  # The theme the install set: its record, else the saved option.
  ours="$(head -1 "$PLYMOUTH_SET_FILE" 2>/dev/null)"
  ours="${ours:-$PLYMOUTH_THEME}"
  PLY_CURRENT="$(plymouth_current_theme)"
  PLY_WAS="$(cat "$PLYMOUTH_BEFORE_FILE" 2>/dev/null)"
  if [ -z "$PLY_CURRENT" ]; then PLY_OUTCOME=unread; return "$RC_FAILED"; fi
  if [ -z "$PLY_WAS" ] || [ "$PLY_WAS" = "$PLY_CURRENT" ]; then
    # Nothing to set back; finish a rebuild an earlier run still owes.
    PLY_OUTCOME=none; rc="$RC_UNCHANGED"
    if [ -f "$INITRAMFS_PENDING" ]; then
      rebuild_initramfs_recorded || { PLY_OUTCOME=owed; return "$RC_FAILED"; }
      PLY_OUTCOME=rebuilt; rc="$RC_CHANGED"
    fi
  elif [ "$PLY_CURRENT" != "$ours" ]; then
    PLY_OUTCOME=kept; rc="$RC_UNCHANGED"
    # The user's theme stays; a rebuild still owed is made for it.
    if [ -f "$INITRAMFS_PENDING" ]; then
      rebuild_initramfs_recorded || { PLY_OUTCOME=owed; return "$RC_FAILED"; }
    fi
  else
    # The rebuild is owed from before any change, so a cut run still makes it;
    # a put-back that changes nothing owes none.
    local owed_before=0
    [ -f "$INITRAMFS_PENDING" ] && owed_before=1
    owe_initramfs || { PLY_OUTCOME=no-record; return "$RC_NO_RECORD"; }
    if ! put_back_plymouth_theme "$PLY_WAS"; then
      [ "$owed_before" -eq 1 ] || sudo rm -f "$INITRAMFS_PENDING"
      PLY_OUTCOME=put-back; return "$RC_FAILED"
    fi
    rebuild_initramfs_recorded || { PLY_OUTCOME=rebuild; return "$RC_FAILED"; }
    PLY_OUTCOME=restored; rc="$RC_CHANGED"
  fi
  drop_plymouth_records
  return "$rc"
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
  # Without a settled command line the theme is left alone too.
  add_grub_splash_words || return 0
  set_plymouth_theme
}

# An earlier run stopped between recording its words (note $1) and
# update-grub: finish it if the file was written (the words are among $2, the
# kernel command line's), else drop the record.
finish_interrupted_grub_add() {
  local pending="$1" val_words="$2" pend p_line
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
}

# Add "quiet splash" to GRUB_CMDLINE_LINUX_DEFAULT, except a word the user
# took off after the install. Returns 1 when /etc/default/grub is not in a
# shape to edit, or it or its records could not be written; 0 otherwise.
add_grub_splash_words() {
  local where val new opt added="" before="" kept_out=""
  where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"
  # A commented line counts as none; a new line is appended to the file.
  case "$where" in
    absent|commented) val="" ;;
    unparsable)
      message warn "/etc/default/grub is not in a shape this script will edit — leaving it alone"
      STATUS_NOCHANGE+=("/etc/default/grub left alone — the boot splash is not applied")
      return 1 ;;
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

  local pending="$GRUB_ADD_PENDING"
  finish_interrupted_grub_add "$pending" "$val_words"

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
      return 1
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
      return 1
    fi
  fi
  return 0
}

# Set the Plymouth theme; the previous one is recorded once for the uninstall.
set_plymouth_theme() {
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
# (the recorded words) and GRUB_CMDLINE_NEW. Returns RC_CHANGED, RC_UNCHANGED
# (the words are gone already), RC_REFUSED (the file is not in a shape to
# edit) or RC_FAILED (the write or update-grub failed).
strip_grub_words() {
  local where val pending="$GRUB_STRIP_PENDING"
  GRUB_ADDED_WORDS="$(tr '\n' ' ' < "$GRUB_ADDED_FILE")"
  GRUB_ADDED_WORDS="${GRUB_ADDED_WORDS% }"
  where="$(read_grub_cmdline)"; val="${where#* }"; where="${where%% *}"
  [ "$where" = unparsable ] && return "$RC_REFUSED"
  if ! GRUB_CMDLINE_NEW="$(grub_without_words "$val" "$GRUB_ADDED_WORDS")" || [ "$where" != active ]; then
    # An earlier run wrote the file but stopped before update-grub finished.
    if [ -f "$pending" ]; then
      message "finishing the update-grub an earlier run left undone"
      boot_tool update-grub || return "$RC_FAILED"
      GRUB_CMDLINE_NEW="$val"
      forget_grub_words "$pending"
      return "$RC_CHANGED"
    fi
    forget_grub_words
    return "$RC_UNCHANGED"
  fi
  message "removing '${GRUB_ADDED_WORDS}' from GRUB_CMDLINE_LINUX_DEFAULT"
  sudo touch "$pending"
  if [ -z "$GRUB_CMDLINE_NEW" ] && [ -f "$GRUB_LINE_ADDED" ]; then
    # Kept when the original could not be put back: a later run then finishes it.
    remove_grub_cmdline_line || { [ -n "$GRUB_BACKUP_KEPT" ] || sudo rm -f "$pending"; return "$RC_FAILED"; }
  else
    write_grub_cmdline "$GRUB_CMDLINE_NEW" || { [ -n "$GRUB_BACKUP_KEPT" ] || sudo rm -f "$pending"; return "$RC_FAILED"; }
  fi
  forget_grub_words "$pending"
  return "$RC_CHANGED"
}

# Take the look's words off the kernel command line (strip_grub_words) and
# report the outcome in the summary of the running action.
restore_grub_cmdline() {
  local st line_was_added=0
  if [ ! -f "$GRUB_ADDED_FILE" ]; then
    report unchanged "Nothing of this script's is on the kernel command line"
    return 0
  fi
  if [ ! -f /etc/default/grub ] || ! command -v update-grub >/dev/null 2>&1; then
    report unchanged "GRUB is gone — the words this script added cannot be removed"
    forget_grub_words
    return 0
  fi
  [ -f "$GRUB_LINE_ADDED" ] && line_was_added=1
  strip_grub_words; st=$?
  case $st in
    "$RC_CHANGED") if [ -z "$GRUB_CMDLINE_NEW" ] && [ "$line_was_added" = 1 ]; then
         report changed "/etc/default/grub: the GRUB_CMDLINE_LINUX_DEFAULT line this script added is removed"
       else
         report changed "Removed '${GRUB_ADDED_WORDS}' from the kernel command line: GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_NEW}\""
       fi
       need_reboot ;;
    "$RC_UNCHANGED") report unchanged "/etc/default/grub no longer carries what this script added" ;;
    "$RC_REFUSED") message warn "/etc/default/grub is not in a shape this script will edit — leaving it alone"
       report manual "/etc/default/grub left alone — remove '${GRUB_ADDED_WORDS}' by hand" ;;
    *) report failed "/etc/default/grub could not be updated — '${GRUB_ADDED_WORDS}' is still on the kernel command line"
       [ -z "$GRUB_BACKUP_KEPT" ] \
         || report failed "the file as it was before that attempt is at ${GRUB_BACKUP_KEPT}" ;;
  esac
  return 0
}

# Put back the boot splash theme from before the install (plymouth_put_back)
# and report the outcome in the summary of the running action.
restore_plymouth_theme() {
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    report unchanged "Plymouth is gone — no boot splash theme to put back"
    drop_plymouth_records
    return 0
  fi
  plymouth_put_back
  case "$PLY_OUTCOME" in
    restored)  report changed "Boot splash theme restored to '${PLY_WAS}'"; need_reboot ;;
    rebuilt)   report changed "Boot splash theme '${PLY_CURRENT}' rebuilt into the initramfs"; need_reboot ;;
    none)      if [ -z "$PLY_WAS" ]; then
                 report unchanged "No earlier boot splash theme was recorded — left on '${PLY_CURRENT}'"
               else
                 report unchanged "Boot splash theme is already '${PLY_CURRENT}'"
               fi ;;
    kept)      report unchanged "Boot splash theme left on '${PLY_CURRENT}', which you chose after the install" ;;
    unread)    report failed "The boot splash theme cannot be read — not restored; run this again later" ;;
    put-back)  message warn "the Plymouth theme cannot be set back to '${PLY_WAS}' — it may no longer be installed"
               report failed "Boot splash theme is still '${PLY_CURRENT}', not '${PLY_WAS}' — the record is kept at ${PLYMOUTH_BEFORE_FILE}" ;;
    rebuild)   report failed "Boot splash theme set to '${PLY_WAS}', but the initramfs rebuild failed — run: sudo update-initramfs -u" ;;
    owed)      report failed "The initramfs rebuild still owed failed — run: sudo update-initramfs -u" ;;
    no-record) report failed "Boot splash theme not put back — ${SYS_RECORDS} cannot be written; run this again" ;;
  esac
  return 0
}

# UBUNTU_BOOT_SPLASH=0: remove the recorded words from the kernel command line
# and restore the previous Plymouth theme.
unset_boot_splash() {
  restore_grub_cmdline
  # Unless the user has chosen another theme since.
  [ ! -f "$PLYMOUTH_BEFORE_FILE" ] || restore_plymouth_theme
  return 0
}

###############################################################################
# 6. Report: --refresh, the saved release state, summary, reboot
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
  tmp="$(mktemp)" || return 1
  if release_fingerprint | sort -u > "$tmp"; then echo "$tmp"; else rm -f "$tmp"; return 1; fi
}

# --refresh: list what an update would change, then ask. Exits when there is
# nothing to do or the user declines; returns to apply the update. Before
# the answer it changes nothing but apt's package lists.
refresh_check() {
  # Counted by the steps below.
  REFRESH_FINDINGS=0
  refresh_apt_lists

  message "comparing with what was checked last time and looking for newer builds..."
  echo ""
  echo "Updates for the Ubuntu look:"
  refresh_list_release
  refresh_list_packages
  refresh_list_unsupported

  echo ""
  if [ "$REFRESH_FINDINGS" -eq 0 ]; then
    message "The Ubuntu look is up to date — nothing to apply."
    exit 0
  fi
  message "${REFRESH_FINDINGS} update(s) found. Apply them now?"
  ask_yes || { message "Nothing changed."; exit 0; }
}

# --refresh: bring apt's package lists up to date, changing nothing else.
refresh_apt_lists() {
  local log rc
  echo ""
  message "refreshing apt's package lists (nothing is installed yet)"
  # Plain apt update: its fallbacks (a mirror without universe) would edit
  # the apt source before the user agrees.
  log="$(mktemp)" || error "Could not create a temporary file."
  apt_update_waiting "$log" quiet; rc=$?
  if [ "$rc" -ne 0 ]; then
    grep -q 'Could not get lock' "$log" && { rm -f "$log"; error "apt is in use by another program — try again later."; }
    message warn "apt reported errors while refreshing its lists; the list below may be incomplete"
  else
    # Only a clean refresh spares the update its second apt update.
    APT_LISTS_FRESH=1
  fi
  rm -f "$log"
}

# --refresh: list what changed for the Ubuntu release since it was chosen,
# and the options given now that differ from the saved ones. Adds to
# REFRESH_FINDINGS.
refresh_list_release() {
  local tmp line key
  # The Ubuntu release and what it depends on.
  if [ "$UBUNTU_CODENAME" != auto ]; then
    echo "  = Ubuntu release fixed by UBUNTU_CODENAME=${UBUNTU_CODENAME}"
    if ! pin_is_current; then
      echo "  + This script writes a newer apt pin"
      REFRESH_FINDINGS=$((REFRESH_FINDINGS + 1))
    fi
  elif unchanged_since_last_run; then
    REFRESH_UNCHANGED=1
    echo "  = Ubuntu ${KEPT_CODENAME}: nothing changed since it was chosen"
  elif ! readable_regular_file "$RELEASE_STATE"; then
    echo "  + No record of the releases checked last time: the Ubuntu release is checked again"
    REFRESH_FINDINGS=$((REFRESH_FINDINGS + 1))
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
      REFRESH_FINDINGS=$((REFRESH_FINDINGS + 1))
    done < <(diff "$RELEASE_STATE" "$tmp" | sed -n 's/^\([<>]\) /\1/p')
    # Only lines that went away (a retired release, a dropped option), or a
    # missing apt source or pin.
    if [ "$REFRESH_FINDINGS" -eq 0 ]; then
      echo "  + The Ubuntu releases on offer or the look's apt source changed: the Ubuntu release is checked again"
      REFRESH_FINDINGS=1
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
    REFRESH_FINDINGS=$((REFRESH_FINDINGS + 1))
  done
}

# --refresh: list newer builds of the look's packages, and packages it lacks,
# as the update would handle them. Adds to REFRESH_FINDINGS.
refresh_list_packages() {
  local p have cand combined=0
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
    REFRESH_FINDINGS=$((REFRESH_FINDINGS + 1))
  done
  if [ "$combined" -eq 1 ]; then
    have="$(pkg_installed_version "$COMBINED_EXT_PKG")"
    cand=""
    is_held "$COMBINED_EXT_PKG" || cand="$(refresh_target "$COMBINED_EXT_PKG" "$have")"
    if [ -n "$cand" ]; then
      echo "  + ${COMBINED_EXT_PKG}: ${have} → ${cand}"
      REFRESH_FINDINGS=$((REFRESH_FINDINGS + 1))
    fi
  fi
}

# --refresh: name the extensions the installed GNOME Shell has moved past. Not
# an update by itself: a release that supports it shows as a newer release or
# a GNOME Shell change; until Ubuntu has one, applying cannot help.
refresh_list_unsupported() {
  local p running bound
  running="$(shell_major)"
  for p in $UBUNTU_SHELL_EXT_PKGS; do
    is_installed "$p" || continue
    bound="$(pkg_shell_upper_bound "$p")"
    [ -n "$running" ] && [ -n "$bound" ] && [ "$running" -ge "$bound" ] || continue
    echo "  ! ${p} does not support GNOME Shell ${running}; a release that does is listed above when Ubuntu has one"
  done
}

# Save the fingerprint that later runs and --refresh compare against.
save_release_state() {
  local tmp rc="$RC_FAILED"
  tmp="$(fingerprint_file)" && { sudo_install_if_changed "$tmp" "$RELEASE_STATE"; rc=$?; }
  rm -f "$tmp"
  [ "$rc" -ne "$RC_FAILED" ] \
    || STATUS_FAILED+=("${RELEASE_STATE} could not be written — the next run checks the Ubuntu release again")
}

# Log the installed packages, the pin, the extension states, the Plymouth
# theme, kernel command line, GTK and icon themes, wallpaper, favourites,
# terminal colours and shortcut, and the session entries.
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
  echo "  session mode   : $([ -f "$SHELL_MODE_FILE" ] && echo "$SHELL_MODE_FILE" || echo 'none')"
  echo "  disabled-ext   : $(dconf_show /org/gnome/shell/disabled-extensions)"
  for e in $(grep -o '"[^"]*@[^"]*"' "$SHELL_MODE_FILE" 2>/dev/null | tr -d '"'); do
    # The running shell knows only the extensions present at login, and runs
    # the mode's only when it started in that mode.
    state="$(LC_ALL=C gnome-extensions info "$e" 2>/dev/null | awk -F': ' '/State/{print $2}')"
    if [ -z "$state" ] || ! session_in_look_mode; then
      state="active after the reboot"
    fi
    printf '  %-46s %s\n' "$e" "$state"
  done

  echo "  plymouth theme : $(plymouth_current_theme)"
  echo "  kernel cmdline : $(read_grub_cmdline)"
  echo "  gtk-theme      : $(dconf_show /org/gnome/desktop/interface/gtk-theme)"
  echo "  term colours   : $(dconf_show "/${TERMINAL_DEFAULT_PROFILE}/background-color")"
  echo "  term shortcut  : $(dconf_show "${TERMINAL_SHORTCUT_PATH}binding")"
  v=""; for p in $SESSION_ENTRIES; do [ -f "$p" ] && v="${v} ${p}"; done
  echo "  session entries:${v:- none}"
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

# True when someone at a terminal can answer the reboot countdown.
reboot_can_be_answered() { [ -t 0 ] && { : < /dev/tty; } 2>/dev/null; }

# Reboot: as the desktop user where the system allows it, else through sudo.
reboot_now() { systemctl --no-ask-password reboot 2>/dev/null || sudo systemctl reboot; }

# Reboot after a countdown of REBOOT_COUNTDOWN seconds: Enter reboots at once,
# Ctrl-C cancels. With UBUNTU_LOOK_REBOOT=0, or with no terminal to answer
# from, it only names the command.
auto_reboot() {
  local n key old_int tty_state ticker reader
  if [ "${UBUNTU_LOOK_REBOOT:-1}" = 0 ] || ! reboot_can_be_answered; then
    echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
    return 0
  fi
  echo -e "   Rebooting in ${REBOOT_COUNTDOWN} seconds. Press ${GREEN}Enter${ENDCOLOR} to reboot now, ${YELLOW}Ctrl-C${ENDCOLOR} to cancel."
  # The summary runs with Ctrl-C switched off; here it cancels the reboot.
  old_int="$(trap -p INT)"
  REBOOT_CANCELLED=0
  trap 'REBOOT_CANCELLED=1' INT
  # Keys typed earlier in the run must not count as the answer.
  while { read -r -s -t 0.05 key < /dev/tty; } 2>/dev/null; do :; done
  # One read waits for Enter through the whole countdown: a read per second
  # loses an Enter pressed just as a second ends. The read runs in the
  # background, where Ctrl-C ends it at once; a trap would wait for the read.
  tty_state="$({ stty -g < /dev/tty; } 2>/dev/null)"
  { stty -echo < /dev/tty; } 2>/dev/null
  # The seconds go to the terminal only, not to the run log. Both helpers
  # take back the signals the exit trap switched off, so they can be stopped.
  ( trap - INT TERM; for ((n = REBOOT_COUNTDOWN; n > 0; n--)); do printf '\r   %2d ' "$n"; sleep 1; done > /dev/tty ) 2>/dev/null &
  ticker=$!
  ( trap - INT TERM; read -r -t "$REBOOT_COUNTDOWN" key < /dev/tty ) 2>/dev/null &
  reader=$!
  # Ends on Enter, when the time is up, or on Ctrl-C (status 130).
  wait "$reader" 2>/dev/null; [ $? -ne 130 ] || REBOOT_CANCELLED=1
  kill "$reader" "$ticker" 2>/dev/null
  wait "$reader" "$ticker" 2>/dev/null
  [ -z "$tty_state" ] || { stty "$tty_state" < /dev/tty; } 2>/dev/null
  { printf '\r      \r' > /dev/tty; } 2>/dev/null
  eval "${old_int:-trap - INT}"
  if [ "$REBOOT_CANCELLED" = 1 ]; then
    echo -e "   Reboot cancelled. When you are ready, run: ${YELLOW}sudo reboot${ENDCOLOR}"
    return 0
  fi
  echo "   Rebooting now."
  reboot_now || message warn "could not start the reboot — run: sudo reboot"
}

# The EXIT trap's summary of the install run.
print_summary() {
  # First: any command before it would replace the exit status.
  local rc=$?
  local reboot=0
  # Nothing ran yet: a wrong argument, a declined prompt.
  [ "${RUN_STARTED:-0}" = 1 ] || return 0
  # A finished run added it before its exit status; a stopped one adds it here.
  [ "$INITRAMFS_PARTIAL" = 1 ] && [ "$RUN_FINISHED" != 1 ] && STATUS_FAILED+=("$INITRAMFS_PARTIAL_NOTE")
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
  summary_block "$RED" "Not done (${#STATUS_FAILED[@]}):" "!" \
    "Everything else was applied. Each line gives the reason." "${STATUS_FAILED[@]}"
  summary_block "$GREEN"  "Configuration changes:" + "" "${STATUS_CHANGES[@]}"
  summary_block "$YELLOW" "Already in place (no change):" = "" "${STATUS_NOCHANGE[@]}"

  echo ""
  [ ${#SETTINGS_KEPT[@]} -gt 0 ] && {
    echo -e "${YELLOW}Your own settings, which the Ubuntu session shows instead of Ubuntu's (${#SETTINGS_KEPT[@]}):${ENDCOLOR}"
    printf '   = %s\n' "${SETTINGS_KEPT[@]}"
    echo -e "   ${YELLOW}'dconf reset <key>' takes Ubuntu's value in the Ubuntu session and Debian's in GNOME.${ENDCOLOR}"
    echo ""
  }

  log_final_state

  # A run that finished exits 1 when a step was not done; that is no stop.
  if [ $rc -ne 0 ] && [ "$RUN_FINISHED" != 1 ]; then
    echo -e "${RED}✗  Script stopped (rc=$rc). See the ERROR or WARN lines above.${ENDCOLOR}"
  elif [ $REBOOT_NEEDED -eq 1 ] || [ $RELOGIN_NEEDED -eq 1 ]; then
    if [ $REBOOT_NEEDED -eq 1 ]; then
      echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for the boot splash and kernel command line."
      echo -e "   The reboot also applies the theme and extensions."
    else
      # The session reads these changes when it starts.
      echo -e "${YELLOW}⚠  Reboot${ENDCOLOR} so the changes apply to the Ubuntu session."
      echo -e "   The login screen's gear button shows which session is chosen."
    fi
    # Not with items left undone: their reasons are read first.
    if [ "$RUN_FINISHED" = 1 ] && [ ${#STATUS_FAILED[@]} -eq 0 ]; then
      reboot=1
    else
      echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
    fi
  elif [ ${#STATUS_FAILED[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠  Done, except the items listed above as not done — each gives its reason.${ENDCOLOR}"
  elif [ ${#STATUS_CHANGES[@]} -gt 0 ]; then
    echo -e "${GREEN}✓  Done — no reboot needed.${ENDCOLOR}"
  else
    echo -e "${GREEN}✓  Nothing changed — the Ubuntu look was already in place.${ENDCOLOR}"
  fi
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  [ "$reboot" = 1 ] && auto_reboot
  return 0
}

# Remove the run's release cache with its suite and development-series memos.
rm_release_cache() {
  [ -n "${UBUNTU_RELEASE_CACHE:-}" ] || return 0
  rm -f "$UBUNTU_RELEASE_CACHE" "${UBUNTU_RELEASE_CACHE}.suites" "${UBUNTU_RELEASE_CACHE}.devel"
}

# The EXIT trap's cleanup; returns the exit status for print_summary.
_on_exit() {
  local rc=$?
  # A second Ctrl-C must not cut the clean-up and the summary short.
  trap '' INT HUP TERM
  rm_release_cache
  # Stopped while the widened apt source was being tried: put it back.
  [ -f "${PREV_UBUNTU_SOURCES:-}" ] && restore_prev_ubuntu_sources
  return $rc
}

###############################################################################
# 7. Setup: arguments, help, run log, options
###############################################################################

# --help prints the header from Usage to Requires.
show_help() {
  if [ -f "$SCRIPT_FILE" ]; then
    sed -n '/^# Usage/,/^# ====/{/^# ====/d;s/^# \{0,1\}//;p}' "$SCRIPT_FILE"
  else
    echo "Usage: bash ubuntu-look.sh [--refresh | --uninstall | --help]"
    echo "Save the script to a file and run --help there for the options."
  fi
}

# Read the command line, the only place that does. Sets:
#   ACTION   what this run does: install, refresh or uninstall
#   REFRESH  1 for --refresh
# --help wins over everything after it.
parse_args() {
  local arg action="" unknown=""
  ACTION=install
  REFRESH=0
  for arg in "$@"; do
    case "$arg" in
      -h|--help) show_help; exit 0 ;;
      --refresh|--uninstall)
        [ -z "$action" ] || [ "$action" = "${arg#--}" ] \
          || error "Give only one of --refresh and --uninstall."
        action="${arg#--}" ;;
      --download|--offline|--prepare-upgrade)
        error "${arg} is no longer part of this script. See: bash ubuntu-look.sh --help" ;;
      *) unknown="${unknown:+${unknown} }${arg}" ;;
    esac
  done
  [ -z "$unknown" ] || error "Unknown argument '${unknown}'. See: bash ubuntu-look.sh --help"
  ACTION="${action:-install}"
  [ "$ACTION" = refresh ] && REFRESH=1
  return 0
}

# Record the run in a log file in $HOME: the script runs itself again with its
# output copied to the log, and this call never returns. It returns at once in
# that second run, and when there is no log to write.
# The logged run re-reads the script, so it must come from a file; the log
# must be writable, or the run would die with the pipe.
start_run_log() {
  local _log_file _log_name _o _opts _rc
  _log_name="ubuntu-look-${ACTION}"
  _log_file="${HOME:-/nonexistent}/${_log_name}-$(date +%Y%m%d-%H%M%S).log"
  if [ "${UBUNTU_LOOK_LOG:-1}" != "0" ] && [ -z "${UBUNTU_LOOK_LOGGING:-}" ] \
     && { [ -f "$SCRIPT_FILE" ] && : > "$_log_file"; } 2>/dev/null; then

    # The newest ten logs of this kind stay; older ones go.
    # shellcheck disable=SC2012
    ls -1t "${HOME}/${_log_name}"-*.log 2>/dev/null | tail -n +11 | xargs -r -d '\n' rm -f --

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
}

# The version of Ubuntu release $1, from apt's downloaded lists; empty when
# apt has none of it.
lists_release_version() {
  [ -n "$1" ] || return 0
  sed -n 's/^Version: //p' /var/lib/apt/lists/*_dists_"$1"_InRelease 2>/dev/null | head -1
}

# Facts for the log; $@ is the command line.
log_run_facts() {
  local _float _fv _pinned _pv _u1 _u2 _wm _yv
  echo "### $(basename "${SCRIPT_FILE:-ubuntu-look.sh}") ${UBUNTU_LOOK_VERSION}  $(sha256sum "${SCRIPT_FILE:-/dev/null}" 2>/dev/null | cut -c1-16)"
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
  _pinned="$(pinned_codename)"
  # The line after "***" is the installed version's source.
  _float="$(apt-cache policy yaru-theme-gtk 2>/dev/null |
    awk '/^ \*\*\*/{getline; if ($0 ~ /:\/\//) print $3; exit}')"
  _float="${_float%%/*}"
  _pv="$(lists_release_version "$_pinned")"
  _fv="$(lists_release_version "$_float")"
  _u1="${_pv:+${_pv} (${_pinned})}"; _u1="${_u1:-${_pinned}}"
  _u2="${_fv:+${_fv} (${_float})}"; _u2="${_u2:-${_float}}"
  echo "### pinned  : ${_u1:+ubuntu }${_u1:-none pinned yet}"
  # Installed but with no source left (its apt source removed, say).
  if [ -z "$_u2" ] && _yv="$(dpkg-query -W -f='${Version}' yaru-theme-gtk 2>/dev/null)" \
     && [ -n "$_yv" ] && [ "$(dpkg-query -W -f='${db:Status-Status}' yaru-theme-gtk 2>/dev/null)" = installed ]; then
    _u2="installed ${_yv}, no source"
    echo "### themes  : ${_u2}"
  else
    echo "### themes  : ${_u2:+from }${_u2:-not installed yet}"
  fi
  echo ""
}

# This run's options: given in the environment, else saved by an earlier
# install, else the default; each is checked. Also the architecture and
# mirror, and the stage packages that depend on what is installed.
init_options() {
  local _apt_proxy
  # Set when this run was given PLYMOUTH_THEME, before the saved options load.
  PLYMOUTH_THEME_GIVEN="${PLYMOUTH_THEME:+1}"
  load_saved_options

  # Ubuntu release supplying the look; see resolve_release().
  UBUNTU_CODENAME="${UBUNTU_CODENAME:-auto}"
  REQUESTED_CODENAME="$UBUNTU_CODENAME"
  # Checked before any network work; the uninstall needs no release.
  if [ "$ACTION" != uninstall ]; then
    [ "$UBUNTU_CODENAME" != devel ] \
      || error "UBUNTU_CODENAME=devel names no release: give the series' codename, or UBUNTU_INCLUDE_DEVEL=1."
    option_value_ok UBUNTU_CODENAME "$UBUNTU_CODENAME" \
      || error "UBUNTU_CODENAME must be a codename in lower case letters, or auto."
  fi

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
  # Ubuntu's Rhythmbox recommends its alternative toolbar, which the session's
  # Rhythmbox settings turn on.
  is_installed rhythmbox \
    && packages[2-desktop-gnome]="${packages[2-desktop-gnome]} rhythmbox-plugin-alternative-toolbar"

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
}

# Work out what the constants cannot hold: the user's directories, this run's
# options (init_options) and what follows from them. Ends by setting the exit
# and signal traps.
init_run() {
  local _d _e _n _session_config _session_data _session_env _shortcut
  # id -un always answers; $USER is unset under su.
  RUN_USER="$(id -un)"

  # The user's configuration directory as the desktop session reads it: the
  # systemd user manager's XDG_CONFIG_HOME, which the session inherits, not
  # this shell's.
  _session_env="$(systemctl --user show-environment 2>/dev/null)"
  _session_config="$(sed -n 's/^XDG_CONFIG_HOME=//p' <<< "$_session_env")"
  CONFIG_HOME="${_session_config:-${HOME:-}/.config}"
  # Its data directory likewise: user extensions and session-migration's records.
  _session_data="$(sed -n 's/^XDG_DATA_HOME=//p' <<< "$_session_env")"
  DATA_HOME="${_session_data:-${HOME:-}/.local/share}"

  init_options

  # The Ubuntu session's entries: one for each of Debian's that exists.
  SESSION_ENTRIES="$(for _e in $GNOME_SESSION_ENTRIES; do
    [ -f "$_e" ] && _n="${_e##*/}" && _d="${_e%/*}" && echo "/usr/local/share/${_d#/usr/share/}/ubuntu${_n#gnome}"
  done | xargs)"

  # Per-run cache of "<codename> <version> <state> <mirror>".
  UBUNTU_RELEASE_CACHE="$(mktemp)" || error "Could not create a temporary file — nothing was changed."

  # Every package the stages name, for log_final_state() and --refresh.
  ALL_STAGE_PACKAGES="$(printf '%s ' "${packages[@]}" | xargs -n1 | sort -u | xargs)"

  # A reboot an interrupted run of this boot owes is still asked for.
  [ -s "$REBOOT_OWED" ] \
    && [ "$(cat "$REBOOT_OWED" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] \
    && REBOOT_NEEDED=1
  # Filled here, outside any $(...), so every later call reuses it.
  shell_major > /dev/null

  # In the look's database too, but never reset in the user's own settings: the
  # terminal shortcut, as the user's list of custom shortcuts holds their own.
  _shortcut="${TERMINAL_SHORTCUT_PATH#/}"; _shortcut="${_shortcut%/}"
  SESSION_ONLY_SETTINGS=(
    "org/gnome/settings-daemon/plugins/media-keys|custom-keybindings|$(gvariant_string_array "$TERMINAL_SHORTCUT_PATH")"
    "${_shortcut}|name|'Terminal'"
    "${_shortcut}|command|'x-terminal-emulator'"
    "${_shortcut}|binding|'<Primary><Alt>t'"
  )
  unset _shortcut

  trap '_on_exit; print_summary' EXIT
  # Ctrl-C and a closed terminal still print the summary and run the cleanup.
  trap 'echo ""; message warn "interrupted — stopping here"; exit 130' INT
  trap 'exit 129' HUP; trap 'exit 143' TERM
}

###############################################################################
# 8. Uninstall (--uninstall)
###############################################################################
# The look's settings go back to Debian's defaults; installed packages go,
# replaced ones get Debian's build back, for everyone; this user's settings
# return to Debian's defaults. In five parts: helpers, settings helpers,
# per-user steps, system steps, and the run that calls them.

# --- Uninstall: helpers ------------------------------------------------------

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
  apt_get "$1" -y "${@:2}" && return 0
  PURGE_FAILED=1
  SYSTEM_PENDING=1
  message warn "apt could not $1 every package — see its output above"
}

# --- Uninstall: settings helpers ---------------------------------------------

# Pre-install value of key $2 in path $1; empty when it was at the default.
snapshot_dconf_value() { ini_value "${BACKUP_ORIGINAL}/dconf-dump.ini" "$1" "$2"; }

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
  # Records gone with an uninstall another user ran: this user's backup
  # shows the look was theirs.
  [ ! -f "$INSTALLED_MANIFEST" ] && [ ! -f "$MANIFEST_COPY" ] && [ -d "$BACKUP_DIR" ] && return 0
  own="$(ext_own_package "$1")"
  [ -n "$own" ] && predates_install "$own" && return 1
  pkg="$(ext_package "$1")"
  [ -n "$pkg" ] && grep -qxF "$pkg" "$INSTALLED_MANIFEST" "$MANIFEST_COPY" 2>/dev/null
}

# --- Uninstall: per-user steps -----------------------------------------------

# The look's extensions run from Ubuntu's session mode, which goes with the
# session; one a user turned off in the Extensions app leaves the disabled
# list, as on Debian. The user's other entries stay; empty goes back to
# Debian's default (unset).
step_extensions() {
  step "Tidying the extension lists..."
  need_session "extension lists not changed" || return
  local stored_dis was_dis e2 dis=""
  stored_dis="$(user_dconf_read /org/gnome/shell/disabled-extensions)"
  was_dis="$(array_items "$stored_dis")"
  for e2 in $was_dis; do
    in_word_list "$e2" "$SHELL_EXTENSIONS" || dis="${dis} ${e2}"
  done
  dis="$(echo "$dis" | xargs)"
  # A changed list, or an explicit empty one ("@as []"), which Debian leaves unset.
  if [ "$dis" != "$(echo "$was_dis" | xargs)" ] \
     || { [ -z "$dis" ] && [ -n "$stored_dis" ]; }; then
    if [ -z "$dis" ]; then
      dconf reset /org/gnome/shell/disabled-extensions
    else
      dconf write /org/gnome/shell/disabled-extensions "$(gvariant_string_array "$dis")"
    fi && DONE+=("The look's extensions left your list of disabled extensions") \
       || { USER_PENDING=1; GUESSED+=("Could not write disabled-extensions"); }
  fi
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
  local entry path key now before restored=0 failed=0
  # It runs until the session ends; the keys are reset now.
  extension_active tiling-assistant@ubuntu.com \
    && SKIPPED+=("Tiling assistant runs until the reboot — until then both it and GNOME answer Super+Arrow")
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

# dconf $@ with dconf's status; a failure leaves the user's settings pending.
dconf_or_pending() {
  dconf "$@" 2>/dev/null && return 0
  USER_PENDING=1
  return 1
}

# True when dconf value $1 names what the uninstall removes: a Yaru theme, an
# Ubuntu font or one of Ubuntu's wallpapers, from a package the look brought.
names_look_asset() {
  local pkg f
  case "$1" in
    *Yaru*) pkg=yaru-theme-gtk ;;
    *"Ubuntu Sans"*|*"Ubuntu Mono"*|*"'Ubuntu "*) pkg=fonts-ubuntu ;;
    *file:///*)
      f="${1#*file://}"; f="${f%%\'*}"
      pkg="$(dpkg -S "$f" 2>/dev/null | head -n 1 | cut -d: -f1)"
      case "$pkg" in ubuntu-wallpapers*) ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  ! predates_install "$pkg"
}

# Settings the user made stay, as in Debian's GNOME session; only those that
# name what the uninstall removes go back to Debian's default.
step_restore_gnome_settings() {
  step "Resetting settings that name the look's themes, fonts and wallpapers..."
  need_session "GNOME settings not reset" || return
  local path key ours value nudge=0 reset=0 failed=0
  # The theme extension runs until the session ends, but follows no change
  # once step_remove_session has removed the session mode.
  # Only a session whose Ubuntu defaults are gone needs telling.
  session_on_look_profile && nudge=1
  while read -r path key; do
    value="$(user_dconf_read "/${path}/${key}")"
    if [ -n "$value" ]; then
      names_look_asset "$value" || continue
      if dconf_or_pending reset "/${path}/${key}"; then reset=$((reset + 1)); else failed=1; fi
    elif [ "$nudge" -eq 1 ]; then
      # The extensions' own keys; they run until the session ends.
      case "$path" in org/gnome/shell/extensions/*) continue ;; esac
      # The running session was not told that Ubuntu's defaults went; a
      # write and a reset make it read Debian's value now.
      ours="$(our_dconf_value "$path" "$key")"
      [ -n "$ours" ] || continue
      dconf write "/${path}/${key}" "$ours" 2>/dev/null
      if dconf_or_pending reset "/${path}/${key}"; then reset=$((reset + 1)); else failed=1; fi
    fi
  done < <(look_keys)
  # gedit's scheme, which the theme extension switches between the Yaru
  # schemes; they go with the look.
  case "$(user_dconf_read /org/gnome/gedit/preferences/editor/scheme)" in
    "'Yaru'"|"'Yaru-dark'")
      if dconf_or_pending reset /org/gnome/gedit/preferences/editor/scheme; then reset=$((reset + 1)); else failed=1; fi ;;
  esac
  if [ "$failed" -eq 1 ]; then
    GUESSED+=("Some GNOME settings could not be reset")
  elif [ "$reset" -gt 0 ]; then
    DONE+=("Settings that named the look's themes, fonts or wallpapers back to Debian's defaults (${reset}); your other settings stay")
  else
    SKIPPED+=("No setting of yours names the look's themes, fonts or wallpapers")
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

# --- Uninstall: system steps -------------------------------------------------

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
      if ! plain="$(mktemp)" || ! clean="$(mktemp)"; then
        rm -f "$plain"
        SYSTEM_PENDING=1
        GUESSED+=("${LOOK_PROFILE} not changed — no temporary file could be made; run this again")
        return 0
      fi
      look_profile_content | grep -vx "system-db:${LOOK_DB_NAME}" > "$plain"
      printf 'r %s\nr %s\n' "$LOOK_PROFILE" "$LOOK_CLEANUP_CONF" > "$clean"
      # The session's font rule, kept for the running session, with its directory.
      [ -f "$SESSION_FONTS_CONF" ] \
        && printf 'r %s\nr %s\n' "$SESSION_FONTS_CONF" "${SESSION_FONTS_CONF%/*}" >> "$clean"
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

# First, so no new login starts it and the theme extension, which runs until
# the session ends, follows no more changes. Users who chose the session go
# back to the login screen's default, Debian's GNOME.
step_remove_session() {
  step "Removing the Ubuntu session..."
  local files="" f u m ok
  # The session entries the install wrote, also one whose Debian entry has gone.
  for f in "$SHELL_MODE_FILE" /usr/local/share/wayland-sessions/ubuntu*.desktop \
           /usr/local/share/xsessions/ubuntu*.desktop "$GNOME_SESSION_FILE" "$SESSION_TARGET_DROPIN" \
           "$SESSION_MANAGER_DROPIN" "$SESSION_END_SCRIPT" "$SESSION_FONTS_CONF" "$APP_GRID_ICON" \
           "$LOGIN_SOUND_OFF" "$APT_HOOK_CONF" "$APT_HOOK"; do
    case "$f" in *.desktop) grep -qs '^# Written by ubuntu-look.sh' "$f" || continue ;; esac
    # Programs of a running Ubuntu session read the font rule until it ends;
    # step_remove_dconf_profile has it removed at the next boot.
    [ "$f" = "$SESSION_FONTS_CONF" ] && sudo grep -qas "FONTCONFIG_FILE=${f}" /proc/[0-9]*/environ && continue
    { [ -e "$f" ] || [ -L "$f" ]; } && files="${files} ${f}"
  done
  # This user's service manager drops the session's settings now.
  # shellcheck disable=SC2046
  systemctl --user unset-environment $(printf '%s\n' $SESSION_ENV | cut -d= -f1) 2>/dev/null || true
  if [ -n "$files" ]; then
    # shellcheck disable=SC2086
    must_sudo rm -f $files && DONE+=("Removed the Ubuntu session and its files")
  else
    SKIPPED+=("No Ubuntu session to remove")
  fi
  # Their directories, once empty, below /usr/local/share and /usr/local/lib;
  # also those the apt hook emptied.
  for f in "$SHELL_MODE_FILE" $SESSION_ENTRIES "$GNOME_SESSION_FILE" "$SESSION_TARGET_DROPIN" \
           "$SESSION_MANAGER_DROPIN" "$SESSION_FONTS_CONF" "$APP_GRID_ICON" "$LOGIN_SOUND_OFF" "$APT_HOOK"; do
    f="${f%/*}"
    while case "$f" in /usr/local/share/*|/usr/local/lib/*) true ;; *) false ;; esac \
          && sudo rmdir "$f" 2>/dev/null; do f="${f%/*}"; done
  done
  # A later install chooses the session for this user anew.
  rm -f "$SESSION_CHOSEN"
  # The directory is root's own, so the pattern is expanded under sudo.
  for f in $(sudo sh -c "grep -lE '^X?Session=${SHELL_MODE_NAME}' ${ACCOUNTS_USERS_DIR}/*" 2>/dev/null); do
    u="$(id -u "${f##*/}" 2>/dev/null)" || continue
    ok=1
    for m in Session XSession; do
      sudo grep -q "^${m}=${SHELL_MODE_NAME}" "$f" || continue
      sudo busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User${u}" \
        org.freedesktop.Accounts.User "Set${m}" s "" >/dev/null 2>&1 || ok=0
    done
    if [ "$ok" -eq 1 ]; then
      DONE+=("${f##*/} logs in to the login screen's default session again")
    else
      # Not unfinished work: the login screen falls back to its default by
      # itself when the chosen session is gone.
      SKIPPED+=("${f##*/}: the Ubuntu session could not be taken off their account — the login screen uses its default instead")
    fi
  done
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
  restore_grub_cmdline
}

step_restore_plymouth() {
  step "Restoring the boot splash theme..."
  # A rebuild still owed (INITRAMFS_PENDING) is finished even without the
  # theme's record.
  if [ ! -f "$PLYMOUTH_BEFORE_FILE" ] && [ ! -f "$INITRAMFS_PENDING" ]; then
    SKIPPED+=("Boot splash theme: nothing of this script's is left to put back")
    return
  fi
  restore_plymouth_theme
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

# Install $2 at Debian's version $3 from apt; $1 holds extra apt options, or
# is empty. Sets DEBIAN_BUILD to the version tried.
apt_install_debian_build() {
  local opt="$1" pkg="$2"
  DEBIAN_BUILD="$3"
  [ -n "$DEBIAN_BUILD" ] || return 1
  # shellcheck disable=SC2086
  installs_cleanly $opt "${pkg}=${DEBIAN_BUILD}" \
    && apt_get install -y $opt "${pkg}=${DEBIAN_BUILD}" < /dev/null
}

# The packages Ubuntu's combined extensions package replaced, from Debian.
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
  local pkg want
  while read -r pkg; do
    [ -n "$pkg" ] || continue
    is_installed "$pkg" && continue
    want="$(debian_version_of "$pkg")"
    message "  reinstalling ${pkg}..."
    if apt_install_debian_build "" "$pkg" "$want"; then
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
  local pkg ver now want restored=0 failed=0 kept=0 was_auto rc
  while read -r pkg ver; do
    [ -n "$pkg" ] && [ -n "$ver" ] || continue
    now="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
    # Removed by the user: stays removed.
    is_installed "$pkg" || continue
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
    if [ -z "$want" ]; then
      SKIPPED+=("${pkg}: neither ${ver} nor a Debian build is available — left at ${now}")
      RESTORE_FAILED="${RESTORE_FAILED} ${pkg}"
      failed=1
      continue
    fi
    # apt install marks the package manual; an automatic one stays automatic.
    was_auto=0
    apt-mark showauto "$pkg" 2>/dev/null | grep -qxF "$pkg" && was_auto=1
    message "  putting back ${pkg} ${want:-$ver}..."
    apt_install_debian_build --allow-downgrades "$pkg" "$want"; rc=$?
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
  # every Ubuntu package.
  if [ -f "$UBUNTU_SOURCES" ]; then
    must_sudo rm -f "$UBUNTU_SOURCES" || return 0
    src=1
  fi
  [ -f "$UBUNTU_PIN" ] && must_sudo rm -f "$UBUNTU_PIN" && pin=1
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
  message "refreshing apt's package lists..."
  apt_get update -qq < /dev/null 2>/dev/null || true
  return 0
}

# Purging Ubuntu Dock can delete Dash-to-Dock's schema; reinstall it.
repair_dashtodock() {
  is_installed gnome-shell-extension-dashtodock || return 0
  [ -f /usr/share/glib-2.0/schemas/org.gnome.shell.extensions.dash-to-dock.gschema.xml ] && return 0
  message "reinstalling Dash-to-Dock, whose settings file Ubuntu Dock had taken over..."
  if apt_get install -y --reinstall gnome-shell-extension-dashtodock < /dev/null; then
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

# Remove apt's downloads of the look's packages that are no longer installed.
step_remove_cached_debs() {
  [ "$SYSTEM_PENDING" -eq 0 ] || return 0
  local f pkg have m=0
  message "clearing the look's package files from apt's cache..."
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
  message "checking which of the look's packages can go without taking others..."
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
  message "looking for dependencies nothing uses any more..."
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
  for d in /usr/share/icons/Yaru*; do
    [ -d "$d" ] && [ "$(ls -A "$d" 2>/dev/null)" = icon-theme.cache ] || continue
    dpkg -S "$d" > /dev/null 2>&1 && continue
    must_sudo rm -rf "$d" && removed=1
  done
  [ "$removed" -eq 1 ] && DONE+=("Removed the icon caches the Yaru themes left behind")
  return 0
}

# --- Uninstall: the run ------------------------------------------------------

# The uninstall, start to end: the user's settings, then the system, then the
# packages. Exits with 1 while any of its work is unfinished.
run_uninstall() {
  uninstall_begin
  step_remove_session
  step_empty_look_defaults
  uninstall_user_settings
  step_remove_dconf_profile
  step_remove_gdm_profile
  step_restore_grub
  # Before the purge: once the look's theme package is gone, Plymouth reports
  # its fallback theme, not the one the install set.
  step_restore_plymouth
  # Without the Ubuntu source and pin, restores take Debian's builds.
  step_remove_ubuntu_repo
  uninstall_packages
  uninstall_summary
}

# The uninstall's own traps and state; says what it will do, asks, and takes
# the run lock.
uninstall_begin() {
  local _h _home _u
  # Ctrl-C stops the uninstall at once; its exit handler then lists what was
  # done so far.
  trap - INT TERM
  trap _on_uninstall_exit EXIT
  # A closed terminal must not stop the run between a purge and its cleanup.
  trap '' HUP

  # The records are read from $HOME, so it must be this user's home.
  _home="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  _h="${HOME:-}"
  [ -n "$_home" ] && [ "${_h%/}" = "${_home%/}" ] \
    || error "HOME is '${HOME:-}', but ${RUN_USER}'s home is '${_home}'. Run it from ${RUN_USER}'s own login."

  DONE=()
  SKIPPED=()
  GUESSED=()

  USER_PENDING=0
  SYSTEM_PENDING=0
  ANIMATIONS_FAILED=0
  PURGE_FAILED=0
  PURGE_KEPT_CONFIG=""
  UNUSED_BEFORE_PURGE=none
  INSTALLED_BEFORE_PURGE=""
  RESTORED_BEFORE_PURGE=""
  RESTORE_FAILED=""
  DEBIAN_BUILD=""

  # Each mirror in the Ubuntu apt source counts as an Ubuntu archive.
  for _u in $(ubuntu_source_entries | awk '{ print $1 }' | sort -u); do
    add_mirror_to_hosts_re "${_u%/}"
  done

  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
  echo -e "${YELLOW}       ubuntu-look UNINSTALL${ENDCOLOR}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${ENDCOLOR}"
  echo ""
  echo "This undoes only what ubuntu-look.sh did:"
  echo "  - for everyone: the Ubuntu session, packages it installed, apt source and"
  echo "    pin, login screen, boot splash and kernel command line"
  echo "  - for you: settings that name its themes, fonts or wallpapers, and the"
  echo "    terminal shortcut it added"
  echo "Your other settings, and the packages and apps you had before or installed"
  echo "later, are kept."
  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] \
    && message warn "No desktop session: your settings are checked on a later run from the desktop."
  echo ""
  confirm_continue

  sudo -v || error "sudo is required."

  # Wait for any run in progress; from here no other run can start.
  take_run_lock
  # From here on the run changes the system; a stopped run reports it.
  RUN_STARTED=1
}

# Reset this user's settings, and drop their records once that is done.
uninstall_user_settings() {
  local _anim _rc
  # A user who never ran the install, or never kept a Yaru theme from the
  # Ubuntu session, keeps their settings as they are.
  if [ -d "$BACKUP_DIR" ] || user_dconf dump /org/gnome/desktop/ 2>/dev/null | grep -q "^[a-z-]*-theme='Yaru"; then
    step_extensions
    step_restore_tiling_keybindings
    step_restore_gnome_settings
    step_clear_extension_state
    step_terminal_shortcut

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
  ANIMATIONS_FAILED=0
  if [ -n "$UBUNTU_LOOK_ANIMATIONS" ]; then
    _anim="$(apply_animation_option)"; _rc=$?
    case $_rc in
      "$RC_CHANGED")   DONE+=("$_anim") ;;
      "$RC_UNCHANGED") SKIPPED+=("$_anim") ;;
      *)               GUESSED+=("$_anim"); ANIMATIONS_FAILED=1 ;;
    esac
  fi

  # This user's records go once their settings are reset, so a run cut off in
  # the system part does not repeat these steps.
  if [ "$USER_PENDING" -eq 0 ] && [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
    message "Removed ${BACKUP_DIR}"
  fi
}

# Put Debian's builds back and remove the look's packages, working from a
# snapshot of what was in use before any package changed.
uninstall_packages() {
  local _had_plymouth _snapshot_failed _unused
  # What is unused, installed and replaced before any package changes; kept
  # on record, so a run that is declined or cut off is finished by the next.
  _snapshot_failed=0
  if [ ! -f "$UNINSTALL_SNAPSHOT" ]; then
    message "recording which packages are in use before any change..."
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
}

# The uninstall's three lists under heading $1.
uninstall_lists() {
  [ "$INITRAMFS_PARTIAL" = 1 ] && GUESSED+=("$INITRAMFS_PARTIAL_NOTE")
  echo ""
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  echo -e "${GREEN}                    ${1}${ENDCOLOR}"
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  summary_block "$GREEN" "Restored/removed:" + "" "${DONE[@]}"
  summary_block "$YELLOW" "Could not finish:" "?" "" "${GUESSED[@]}"
  summary_block "$YELLOW" "Skipped:" - "" "${SKIPPED[@]}"
  echo ""
}

# The uninstall's EXIT trap: the cleanup, and for a run stopped half-way
# (Ctrl-C, a killed run) what it did until then. Its records stay, so the
# next run finishes it; a finished run has printed its own summary.
_on_uninstall_exit() {
  trap '' INT HUP TERM
  rm_release_cache
  [ "$RUN_STARTED" = 1 ] && [ "$RUN_FINISHED" != 1 ] || return 0
  uninstall_lists "UNINSTALL STOPPED"
  echo -e "${RED}✗  The uninstall stopped before it finished.${ENDCOLOR} Its records are kept:"
  echo -e "   run ${YELLOW}bash ubuntu-look.sh --uninstall${ENDCOLOR} again to finish it."
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
}

# The uninstall's summary. The records go once the work they describe is done;
# the exit status is 1 while any is unfinished.
uninstall_summary() {
  local _reboot
  uninstall_lists "UNINSTALL SUMMARY"

  # System records go once all system work is done.
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

  [ "$USER_PENDING" -eq 1 ] && [ -d "$BACKUP_DIR" ] \
    && message warn "Keeping ${BACKUP_DIR}: run 'bash ubuntu-look.sh --uninstall' again from your desktop to reset your settings."

  _reboot=0
  if [ "$REBOOT_NEEDED" -eq 1 ] || [ "${#DONE[@]}" -gt 0 ]; then
    if [ "$REBOOT_NEEDED" -eq 1 ]; then
      echo -e "${RED}⚠  REBOOT REQUIRED${ENDCOLOR} for the system changes above."
      [ "$USER_PENDING" -eq 0 ] \
        && echo -e "   The reboot also applies your restored settings."
    elif [ "$USER_PENDING" -eq 0 ]; then
      echo -e "${YELLOW}⚠  Reboot${ENDCOLOR} for all changes to take effect."
    else
      echo -e "${YELLOW}⚠  Reboot${ENDCOLOR} for the changes so far to take effect."
    fi
    # Not with work left unfinished: what is listed above is read first.
    if [ $((USER_PENDING || SYSTEM_PENDING || ANIMATIONS_FAILED || INITRAMFS_PARTIAL)) -eq 0 ]; then
      _reboot=1
    else
      echo -e "   Run: ${YELLOW}sudo reboot${ENDCOLOR}"
    fi
  fi
  echo -e "${GREEN}═════════════════════════════════════════════════════════${ENDCOLOR}"
  # The run reached its end; the exit handler has nothing to add.
  RUN_FINISHED=1
  [ "$_reboot" = 1 ] && auto_reboot
  exit $((USER_PENDING || SYSTEM_PENDING || ANIMATIONS_FAILED || INITRAMFS_PARTIAL))
}

###############################################################################
# 9. Install
###############################################################################

# The install; --refresh joins it once its updates are accepted.
run_install() {
  local category
  install_start
  install_snapshots
  install_configure_source
  install_system_upgrade

  use_combined_extensions_if_offered

  # Installed look packages onto the pinned release first, so the stages
  # configure the builds that stay (fonts-ubuntu decides the font names).
  align_look_packages

  for category in $(printf '%s\n' "${!packages[@]}" | sort); do
    step "Install + configure: ${category}"
    install_stage_packages "$category"
    case $category in
      0-base)          stage_boot_splash ;;
      2-desktop-gnome) stage_desktop ;;
    esac
  done

  install_finish
}

# Say what the run does and ask; --refresh lists its updates and asks instead.
# Takes the run lock.
install_start() {
  if [ "$REFRESH" = 1 ]; then
    if [ ! -f "$PACKAGES_BEFORE" ]; then
      error "The Ubuntu look is not installed. Install it with: bash ubuntu-look.sh"
    fi
    if ! grep -q '^# pin-version: ' "$UBUNTU_PIN" 2>/dev/null; then
      error "The look's apt pin is missing. Set it up again with: bash ubuntu-look.sh"
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
    message "Adds an ${YELLOW}Ubuntu${ENDCOLOR} session to the login screen for every user; the first"
    message "install chooses it for ${YELLOW}${RUN_USER}${ENDCOLOR}."
    message "Your own settings are not changed; where you set none, the Ubuntu session"
    message "uses Ubuntu's defaults and GNOME keeps Debian's."
    message "Safe to re-run. Undo with: bash ubuntu-look.sh --uninstall"
    message ""
    confirm_continue
    sudo -v || error "User ${RUN_USER} cannot use sudo."
    take_run_lock
  fi
  # From here on the run changes the system; the summary reports it.
  RUN_STARTED=1
}

# The snapshots the uninstall works from, each taken once: this user's
# settings and the system's packages.
install_snapshots() {
  local _snap
  # Per-user snapshot, taken once.
  if [ ! -d "$BACKUP_ORIGINAL" ]; then
    message "first run for ${RUN_USER} — saving your settings to ${BACKUP_ORIGINAL} (for the uninstall)"
    # Made in a side directory and moved into place whole, so a cut run leaves
    # either no snapshot or a complete one.
    _snap="${BACKUP_ORIGINAL}.new"
    rm -rf "$_snap"
    mkdir -p "$_snap" || error "Could not create ${_snap}"
    # Ubuntu's defaults need a desktop session, now or on a later run.
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

  # An unfinished uninstall's snapshot and hand-over copies no longer apply.
  [ -e "$UNINSTALL_SNAPSHOT" ] && sudo rm -f "$UNINSTALL_SNAPSHOT"
  rm -f "${BACKUP_DIR}/packages-before.txt" "$MANIFEST_COPY" "$DCONF_PROFILE_COPY"
}

# Online: configure the Ubuntu apt source, choose the release that fits this
# GNOME Shell and write the pin. A source that fails is put back.
install_configure_source() {
  install_widen_source
  install_refresh_lists
  install_pin_release
}

# Find the Ubuntu releases on offer and configure them as apt sources, behind
# a provisional pin that blocks every Ubuntu package. The source as it was is
# kept in PREV_UBUNTU_SOURCES.
install_widen_source() {
  local _rc
  step "Configure the Ubuntu apt source"

  # curl reads the archive; generic tools, so not recorded.
  ensure_prereqs "$(missing_packages "curl ca-certificates")"

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
  write_provisional_pin; _rc=$?
  case $_rc in
    "$RC_CHANGED") PROVISIONAL_PIN_NEW=1
       message "Ubuntu packages blocked by default until the Ubuntu pin is written" ;;
    "$RC_FAILED") error "Could not write ${UBUNTU_PIN}; the apt source was not changed." ;;
  esac

  # Saved so a failing apt source can be put back.
  # An empty copy means there was none; a source that cannot be copied stops the run.
  if ! PREV_UBUNTU_SOURCES="$(mktemp)"; then
    PREV_UBUNTU_SOURCES=""
    [ "$PROVISIONAL_PIN_NEW" = 1 ] && sudo rm -f "$UBUNTU_PIN"
    error "Could not create a temporary file; the apt source was not changed."
  fi
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

  # Unchanged: the apt source is as it was.
  SOURCE_WRITE_RC="$RC_UNCHANGED"
  if [ "$KEEP_SOURCES" = 1 ]; then
    message "Ubuntu sources not widened: $(configured_codenames | xargs)"
  else
    # shellcheck disable=SC2086
    write_ubuntu_sources $UBUNTU_SOURCE_LIST; SOURCE_WRITE_RC=$?
    case $SOURCE_WRITE_RC in
      "$RC_CHANGED")   message "configuring Ubuntu archive sources: ${UBUNTU_SOURCE_LIST}" ;;
      "$RC_UNCHANGED") message "Ubuntu candidate sources already current" ;;
      *) message warn "the apt source is left as it was — the summary says why" ;;
    esac
  fi
}

# Refresh apt's package lists; a failing Ubuntu source is put back and stops
# the run.
install_refresh_lists() {
  local _upd
  step "Refresh package lists"
  # A failing Ubuntu source would break every apt update. --refresh has just
  # refreshed them; with the sources unchanged that stands.
  if [ "$REFRESH" = 1 ] && [ "$SOURCE_WRITE_RC" -eq "$RC_UNCHANGED" ] && [ "$APT_LISTS_FRESH" = 1 ]; then
    message "package lists refreshed a moment ago"
    _upd=0
  else
    apt_update; _upd=$?
  fi
  case $_upd in
    0) ;;
    "$RC_BUSY") restore_prev_ubuntu_sources
       error "apt is in use by another program — the sources were put back as they were; try again later." ;;
    *) restore_prev_ubuntu_sources
       error "apt update failed for the Ubuntu sources — they were put back as they were." ;;
  esac
  if ! ubuntu_index_has_packages; then
    restore_prev_ubuntu_sources
    error "${UBUNTU_MIRROR} serves no Ubuntu packages for ${UBUNTU_ARCH} — the sources were put back as they were."
  fi
}

# Choose the release that fits this GNOME Shell, write its pin and leave only
# that release configured.
install_pin_release() {
  local _rc
  step "Resolve the Ubuntu release"

  [ "$UBUNTU_CODENAME" = "auto" ] && resolve_release "$PINNED_BEFORE"

  # Rewrite a missing, provisional, outdated or other-release pin, and one
  # that names another wallpaper pack than the release's package asks for.
  NEED_PIN_REWRITE=1
  if [ ! -f "$UBUNTU_PIN" ] || grep -q '^# provisional' "$UBUNTU_PIN"; then
    :
  elif ! pin_is_current; then
    message warn "Ubuntu pin is out of date — rewriting"
  elif ! grep -q "n=${UBUNTU_CODENAME}\$" "$UBUNTU_PIN"; then
    message warn "Ubuntu release changed to ${UBUNTU_CODENAME} — rewriting the Ubuntu pin"
  elif [ "$(pinned_wallpaper_packs)" != "$(wallpaper_packs)" ]; then
    message warn "${UBUNTU_CODENAME}'s wallpaper pack is now $(wallpaper_packs) — rewriting the Ubuntu pin"
  else
    NEED_PIN_REWRITE=0
  fi
  if [ "$NEED_PIN_REWRITE" = 1 ]; then
    # On failure the exit puts the apt source back, and the pin is left whole.
    write_ubuntu_pin; _rc=$?
    [ "$_rc" -eq "$RC_FAILED" ] && error "Could not write ${UBUNTU_PIN}; the apt source and pin are left as they were. Run this again."
    STATUS_CHANGES+=("Ubuntu pin applied (${UBUNTU_CODENAME})")
  else
    message "Ubuntu pin already current (${UBUNTU_CODENAME})"
    STATUS_NOCHANGE+=("Ubuntu pin already current")
  fi
  # The source and pin now agree; the saved source is no longer needed.
  rm -f "$PREV_UBUNTU_SOURCES"

  # Only the pinned release stays configured.
  narrow_ubuntu_sources
}

# The system-wide apt upgrade, only with UBUNTU_LOOK_SYSTEM_UPGRADE=1; then
# check that it left GNOME Shell on the major version the release was
# resolved for.
install_system_upgrade() {
  local _p _rec_ok _shell_before _sim _was upgradable_before
  step "System upgrade (only with UBUNTU_LOOK_SYSTEM_UPGRADE=1)"
  if [ "${UBUNTU_LOOK_SYSTEM_UPGRADE:-0}" = "1" ]; then
    _sim="$(LC_ALL=C apt-get -s upgrade --with-new-pkgs 2>/dev/null)"
    upgradable_before="$(printf '%s\n' "$_sim" | grep -c '^Inst ')"
    if [ "$upgradable_before" -gt 0 ]; then
      message warn "UBUNTU_LOOK_SYSTEM_UPGRADE=1 — upgrading ${upgradable_before} package(s) system-wide"
      # The pinned packages it moves to Ubuntu's builds are recorded first, as in
      # the stages, so the uninstall puts back what they replace.
      _sim="$(printf '%s\n' "$_sim" \
        | awk -v l=" ${UBUNTU_PINNED_PACKAGES} $(wallpaper_packs) " '/^Inst / && index(l, " " $2 " ")')"
      _rec_ok=1
      record_planned_installs "$_sim" || _rec_ok=0
      while read -r _p _was; do
        record_upgraded_pkg "$_p" "$_was" || _rec_ok=0
      done < <(printf '%s\n' "$_sim" | awk '$3 ~ /^\[/ { gsub(/[][]/, "", $3); print $2, $3 }')
      # Not fatal: a held package or third-party repository must not stop the look.
      if [ "$_rec_ok" = 0 ]; then
        message warn "could not write the install records — system upgrade skipped"
        STATUS_FAILED+=("system upgrade (the install records could not be written)")
      elif apt_get upgrade -y --with-new-pkgs; then
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
  SHELL_MOVED=0
  if [ "$_shell_before" != "$SHELL_MAJOR_CACHE" ]; then
    SHELL_MOVED=1
    STATUS_FAILED+=("GNOME Shell moved from ${_shell_before:-?} to ${SHELL_MAJOR_CACHE:-?} during the system upgrade — reboot, then run this script again")
  fi
}

# Install or upgrade the packages of stage $1: as one batch when apt removes
# nothing for it, else package by package.
install_stage_packages() {
  local _before _cand _have _installed_any _now _rc _rec_ok available p to_change to_install to_upgrade
  local category="$1"
  message "checking $(wc -w <<< "${packages[$category]}") package(s)..."
  available="$(available_packages "${packages[$category]}")"
  for p in ${packages[$category]}; do
    in_word_list "$p" "$available" && continue
    STATUS_FAILED+=("$p (not offered by any configured repository)")
    message warn "${p} is not available from any configured repository — skipped"
  done

  # Split into installs and upgrades.
  local -A pkg_before=()
  to_install=""
  to_upgrade=""
  for p in $available; do
    _have="$(pkg_installed_version "$p")"
    _cand="$(pkg_candidate_version "$p")"
    pkg_before[$p]="$_have"
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
    for p in $to_upgrade; do record_upgraded_pkg "$p" "${pkg_before[$p]:-}" || _rec_ok=0; done
    [ "$_rec_ok" = 1 ] \
      || error "could not write the look's records in ${SYS_RECORDS} — nothing more is changed; run this again."

    # Simulated first; a batch that would remove something is never run.
    # shellcheck disable=SC2086
    apt_install_checked $to_change; _rc=$?
    case $_rc in
      "$RC_REFUSED") if [ -n "$REMOVES" ]; then
           message warn "installing this stage as one batch would REMOVE: ${REMOVES}"
           message warn "not doing that — falling back to one package at a time"
         else
           message warn "apt cannot resolve this stage as one batch — going package by package"
         fi ;;
      "$RC_FAILED") message warn "batch install failed — retrying one package at a time" ;;
      "$RC_NO_RECORD") error "could not write the look's records in ${SYS_RECORDS} — nothing more is changed; run this again." ;;
    esac

    # Whatever the batch did not change gets the newest version that installs
    # without removals.
    _installed_any=0
    for p in $to_change; do
      _before="${pkg_before[$p]:-}"
      _now="$(pkg_installed_version "$p")"
      if [ -z "$_now" ] || [ "$_now" = "$_before" ]; then
        ensure_package "$p"; _rc=$?
        _now="$ENSURE_VERSION"
        if [ "$_rc" -eq "$RC_UNCHANGED" ]; then
          STATUS_HELD+=("$p at ${_now} — $(explain_blocked "$p")")
          message warn "${p} stays at ${_now}: no newer build fits this system"
          continue
        elif [ "$_rc" -ne "$RC_CHANGED" ]; then
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
  return 0
}

# Stage 0-base: the boot splash.
stage_boot_splash() {
  # Taking the splash off works from the records, with or without GRUB.
  if [ "$UBUNTU_BOOT_SPLASH" = "0" ]; then
    boot_splash unset
  elif ! has_boot_splash_tools; then
    STATUS_NOCHANGE+=("No GRUB or update-initramfs on this system — boot splash left alone")
  else
    boot_splash set
  fi
}

# Stage 2-desktop-gnome: Ubuntu's settings, the session, the extensions and
# the login screen. Nothing is written without Yaru's themes.
stage_desktop() {
  local _anim _chosen_rc _dropped _env_ok _missing _profile_ok _rc _session_rc p
  # The user's own animation switch, whatever else this stage does.
  if [ -n "$UBUNTU_LOOK_ANIMATIONS" ]; then
    _anim="$(apply_animation_option)"; _rc=$?
    case $_rc in
      "$RC_CHANGED")   STATUS_CHANGES+=("$_anim") ;;
      "$RC_UNCHANGED") STATUS_NOCHANGE+=("$_anim") ;;
      *)               STATUS_FAILED+=("$_anim") ;;
    esac
  fi

  # Settings naming Yaru without its themes would leave apps without icons.
  _missing=""
  for p in $YARU_PKGS; do is_installed "$p" || _missing="${_missing} ${p}"; done
  if [ -n "$_missing" ]; then
    message warn "Yaru is not installed (${_missing# }) — Ubuntu's settings are not written"
    STATUS_FAILED+=("Ubuntu's settings, extensions and login screen not applied — missing:${_missing}")
    return 0
  fi

  # System defaults, read at the next login.
  message "writing Ubuntu's GNOME defaults"
  write_dconf_profile "$WP_LIGHT" "$WP_DARK"; _profile_ok=$?
  write_theme_extension
  # The apt hook took the session off the login screen while this user
  # logged in to it: it is chosen for them again. Whoever had picked GNOME
  # keeps GNOME.
  _dropped=0
  grep -qxF -- "$RUN_USER" "$SESSION_USERS_RECORD" 2>/dev/null && _dropped=1
  write_session; _session_rc=$?
  case $_session_rc in
    "$RC_CHANGED") STATUS_CHANGES+=("Ubuntu session on the login screen → ${SESSION_ENTRIES%% *}; GNOME Shell starts with Yaru and Ubuntu's extensions")
       RELOGIN_NEEDED=1 ;;
    "$RC_UNCHANGED") STATUS_NOCHANGE+=("Ubuntu session already current") ;;
    "$RC_FAILED") STATUS_FAILED+=("Could not install the Ubuntu session (${SHELL_MODE_FILE}) — the login screen offers Debian's GNOME only") ;;
  esac
  message "installing the Show Applications button icon"
  write_app_grid_icon

  # The install chooses the Ubuntu session for this user once; later runs
  # keep what they pick on the login screen. Only with a usable profile,
  # else dconf has no database.
  _env_ok=0
  if [ "$_profile_ok" -eq 0 ] && [ "$_session_rc" -ne "$RC_FAILED" ]; then
    _env_ok=1
    if [ ! -f "$SESSION_CHOSEN" ] || [ "$_dropped" -eq 1 ]; then
      choose_ubuntu_session; _chosen_rc=$?
      case $_chosen_rc in
        "$RC_CHANGED") STATUS_CHANGES+=("Your logins use the Ubuntu session; the login screen's session menu offers GNOME too")
           RELOGIN_NEEDED=1 ;;
        "$RC_FAILED") STATUS_FAILED+=("Could not choose the Ubuntu session for you — pick Ubuntu in the login screen's session menu") ;;
      esac
      if [ "$_chosen_rc" -ne "$RC_FAILED" ]; then
        mkdir -p "$BACKUP_DIR" && : > "$SESSION_CHOSEN"
        [ "$_dropped" -eq 0 ] || forget_session_user
      fi
    fi
    export DCONF_PROFILE="$LOOK_PROFILE_NAME"
  fi

  # The settings before the install, for the uninstall's tiling step; a
  # first run without dconf-cli takes them now that the stages brought it.
  if [ ! -f "${BACKUP_ORIGINAL}/dconf-dump.ini" ] && command -v dconf >/dev/null 2>&1; then
    user_dconf dump / > "${BACKUP_ORIGINAL}/.dconf-dump.ini" \
      && mv "${BACKUP_ORIGINAL}/.dconf-dump.ini" "${BACKUP_ORIGINAL}/dconf-dump.ini"
    rm -f "${BACKUP_ORIGINAL}/.dconf-dump.ini"
  fi
  [ "$_env_ok" -eq 1 ] && report_own_settings
  # A user with custom shortcuts of their own gets Ctrl+Alt+T among them.
  if [ "$_env_ok" -eq 1 ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    add_terminal_shortcut
  elif [ "$_env_ok" -eq 1 ]; then
    message warn "No D-Bus session detected — run this again from the desktop to add Ctrl+Alt+T to your own shortcuts."
  fi

  message "theming the login screen"
  write_gdm_profile "$WP_LIGHT" "$WP_DARK"
}

# Tidy the records, save the run's options and state, and set the exit status.
install_finish() {
  report_unused_wallpaper_packs
  # Failed installs leave the manifest; replaced packages installed again leave
  # their record.
  # A package apt removed but did not purge (its configuration files left)
  # stays on record, so the uninstall purges it.
  prune_record "$INSTALLED_MANIFEST" is_present_or_configured
  prune_record "$REPLACED_BY_COMBINED" not_installed

  # Report anything that no longer matches the installed gnome-shell.
  check_shell_coupling_drift

  # The run records its options and what it was resolved against.
  save_options
  [ "$SHELL_MOVED" = 0 ] && save_release_state

  [ "$INITRAMFS_PARTIAL" = 1 ] && STATUS_FAILED+=("$INITRAMFS_PARTIAL_NOTE")
  message "${GREEN}All steps finished. See SUMMARY below.${ENDCOLOR}"
  RUN_FINISHED=1
  # A step not done makes the exit status 1, as in the uninstall.
  [ ${#STATUS_FAILED[@]} -eq 0 ] || exit 1
}

###############################################################################
# 10. Main
###############################################################################

main() {
  # An unset variable stops the run instead of reading as empty.
  set -u
  parse_args "$@"

  # Before the run log, so root leaves no log file behind.
  [ "$(id -u)" -eq 0 ] \
    && error "Do not run as root. Run as a normal user with sudo rights."

  start_run_log "$@"

  # Debian leaves sbin (update-grub, plymouth tools) off a user's PATH.
  case ":$PATH:" in
    *:/usr/sbin:*) ;;
    *) PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" ;;
  esac

  # The user's own session bus, before the log reports it.
  adopt_session_bus
  log_run_facts "$@"

  init_run

  case "$ACTION" in
    uninstall)       run_uninstall ;;
    install|refresh) run_install ;;
  esac
}

# Run, unless the file is being sourced.
(return 0 2>/dev/null) || main "$@"
