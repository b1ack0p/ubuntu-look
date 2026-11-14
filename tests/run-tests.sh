#!/bin/bash
# Tests for ubuntu-look.sh's pure helpers and its argument parser.
# Nothing here touches the system: the script is sourced, which defines its
# functions without running main.
#
#   bash tests/run-tests.sh

# shellcheck disable=SC2016,SC2034  # literal $(...) test data; variables the sourced script reads
# shellcheck disable=SC2030,SC2031,SC2086,SC2317  # stand-ins and their settings live in subshells
cd "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
. ./ubuntu-look.sh
# As a real run: main switches it on first.
set -u

PASS=0
FAIL=0

# is <name> <expected> <actual>
is() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"
  fi
}

# ok <name> <command...>: the command succeeds.  no: it fails.
ok() { local n="$1"; shift; "$@" > /dev/null 2>&1; is "$n" 0 "$?"; }
no() { local n="$1" rc=0; shift; "$@" > /dev/null 2>&1 || rc=1; is "$n" 1 "$rc"; }

# What parse_args makes of a command line: "ACTION REFRESH", or its error
# text with the exit status.
parsed() {
  local out rc
  out="$( (parse_args "$@" && echo "$ACTION $REFRESH") 2>&1 )"; rc=$?
  out="$(printf '%s' "$out" | sed -r 's/\x1b\[[0-9;]*m//g')"
  if [ "$rc" -eq 0 ]; then printf '%s' "$out"; else printf 'rc=%s %s' "$rc" "$out"; fi
}

### Word lists
ok "in_word_list finds a word"           in_word_list b "a b c"
no "in_word_list wants the whole word"   in_word_list b "ab bc"
no "in_word_list on an empty list"       in_word_list b ""
is "word_list_without drops the word"    "a c" "$(word_list_without "a b c" b | xargs)"
is "word_list_without keeps the rest"    "a b c" "$(word_list_without "a b c" z | xargs)"

### Option values
ok "codename: lower case letters"        option_value_ok UBUNTU_CODENAME plucky
no "codename: devel is no codename"      option_value_ok UBUNTU_CODENAME devel
no "codename: no digits or capitals"     option_value_ok UBUNTU_CODENAME Plucky1
ok "boot splash: 0"                      option_value_ok UBUNTU_BOOT_SPLASH 0
no "boot splash: 2"                      option_value_ok UBUNTU_BOOT_SPLASH 2
ok "plymouth theme: a name"              option_value_ok PLYMOUTH_THEME ubuntu-logo_2.0
no "plymouth theme: no path"             option_value_ok PLYMOUTH_THEME ../x
ok "mirror: empty means the default"     option_value_ok UBUNTU_MIRROR ""
ok "mirror: an http URL"                 option_value_ok UBUNTU_MIRROR "http://mirror.example.org/ubuntu"
ok "mirror: an IPv6 host"                option_value_ok UBUNTU_MIRROR "https://[2001:db8::1]:8080/ubuntu"
no "mirror: not ftp"                     option_value_ok UBUNTU_MIRROR "ftp://mirror.example.org/ubuntu"
no "mirror: no spaces"                   option_value_ok UBUNTU_MIRROR "http://a.example/u b"
no "mirror: no shell characters"         option_value_ok UBUNTU_MIRROR 'http://a.example/$(id)'

### Saved options: parsed, never sourced
tmp="$(mktemp)"
printf '%s\n' 'UBUNTU_CODENAME=plucky' 'PLYMOUTH_THEME=$(touch /tmp/x)' \
  'UBUNTU_BOOT_SPLASH=5' 'PATH=/nowhere' 'UBUNTU_MIRROR=http://m.example/ubuntu' > "$tmp"
is "saved options: valid ones load, the rest are ignored" \
  "plucky|unset|unset|http://m.example/ubuntu|kept" \
  "$(unset UBUNTU_CODENAME PLYMOUTH_THEME UBUNTU_BOOT_SPLASH UBUNTU_MIRROR
     old_path="$PATH"; SAVED_OPTIONS="$tmp"; load_saved_options
     [ "$PATH" = "$old_path" ] && p=kept || p=changed
     echo "${UBUNTU_CODENAME-unset}|${PLYMOUTH_THEME-unset}|${UBUNTU_BOOT_SPLASH-unset}|${UBUNTU_MIRROR-unset}|$p")"
is "saved options: a value given this run wins" "noble" \
  "$(UBUNTU_CODENAME=noble; SAVED_OPTIONS="$tmp"; load_saved_options; echo "$UBUNTU_CODENAME")"
rm -f "$tmp"

### dconf values
is "gvariant_string_array"               "['a', 'b']" "$(gvariant_string_array "a b")"
is "gvariant_string_array, empty"        "@as []" "$(gvariant_string_array "")"
is "array_items"                         "a b" "$(array_items "['a', 'b']")"
is "array_items, typed empty array"      "" "$(array_items "@as []")"
is "normalise_binding: Ctrl is Primary"  "<alt><primary>t" "$(normalise_binding "'<Ctrl><Alt>T'")"
is "normalise_binding: order is ignored" \
  "$(normalise_binding "<Alt><Control>t")" "$(normalise_binding "<Primary><Alt>t")"
tmp="$(mktemp)"
printf '%s\n' '[org/gnome/a]' "theme='One'" '' '[org/gnome/b]' "theme='Two'" > "$tmp"
is "ini_value reads the key of its group" "'Two'" "$(ini_value "$tmp" org/gnome/b theme)"
is "ini_value: absent key"               "" "$(ini_value "$tmp" org/gnome/a font)"
is "ini_value: absent file"              "" "$(ini_value "$tmp.none" org/gnome/a theme)"
rm -f "$tmp"

### The kernel command line
is "grub_without_words drops the words"  "ro loglevel=3" "$(grub_without_words "ro quiet splash loglevel=3" "quiet splash")"
ok "grub_without_words: a word was dropped"  grub_without_words "quiet splash" splash
no "grub_without_words: none matched"    grub_without_words "quiet nosplash" splash
is "grub_without_words leaves * alone"   "a=* b" "$(grub_without_words "a=* splash b" splash)"

### Arguments
is "no arguments: an install"            "install 0"    "$(parsed)"
is "--refresh"                           "refresh 1"    "$(parsed --refresh)"
is "--uninstall"                         "uninstall 0"  "$(parsed --uninstall)"
is "--reset"                             "reset 0"      "$(parsed --reset)"
is "a flag may repeat"                   "uninstall 0"  "$(parsed --uninstall --uninstall)"
is "two actions" \
  "rc=1 [ERROR] Give only one of --refresh, --reset and --uninstall." "$(parsed --refresh --uninstall)"
is "--reset beside another action" \
  "rc=1 [ERROR] Give only one of --refresh, --reset and --uninstall." "$(parsed --reset --uninstall)"
is "unknown argument" \
  "rc=1 [ERROR] Unknown argument '--bogus'. See: bash ubuntu-look.sh --help" "$(parsed --bogus)"
is "unknown arguments beside an action" \
  "rc=1 [ERROR] Unknown argument 'x y'. See: bash ubuntu-look.sh --help" "$(parsed x --uninstall y)"
for gone in --download --offline --prepare-upgrade; do
  is "${gone} is gone" \
    "rc=1 [ERROR] ${gone} is no longer part of this script. See: bash ubuntu-look.sh --help" "$(parsed "$gone")"
done
help="$(parsed --bogus --help)"
is "--help wins over a bad command line" "Usage" "${help%% *}"

### Functions that change the system, run against stand-ins
# Each case runs in a subshell: the commands that would touch the system
# (apt, sudo, the boot tools) are replaced there, and the records live in a
# temporary directory. A case prints the exit status and what the function
# handed back.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
sudo() { "$@"; }   # never the real one: every path below is under $T

# apt_install_checked: one simulation, then the install; hands back REMOVES.
checked() {  # checked <simulation> <simulation status> <records status> <apt status> [allowed removals]
  (
    apt-get() { printf '%s\n' "$SIM"; return "$SIM_RC"; }
    apt_get() { CALLS="${CALLS}[$*]"; return "$APT_RC"; }
    record_planned_installs() { return "$REC_RC"; }
    record_planned_upgrades() { return 0; }
    SIM="$1" SIM_RC="$2" REC_RC="$3" APT_RC="$4" ALLOWED_REMOVALS="${5:-}" CALLS=""
    apt_install_checked pkg > /dev/null 2>&1; rc=$?
    echo "${rc} removes=${REMOVES} apt=${CALLS}"
  )
}
is "apt_install_checked: installs, with no removal allowed" \
  "0 removes= apt=[install -y --no-remove pkg]" "$(checked "Inst pkg (1)" 0 0 0)"
is "apt_install_checked: apt cannot resolve it" \
  "${RC_REFUSED} removes= apt=" "$(checked "E: broken" 100 0 0)"
is "apt_install_checked: refuses a removal, and names it" \
  "${RC_REFUSED} removes=other apt=" "$(checked "Remv other [1]"$'\n'"Inst pkg (1)" 0 0 0)"
is "apt_install_checked: an allowed removal goes through" \
  "0 removes= apt=[install -y pkg]" "$(checked "Remv other [1]"$'\n'"Inst pkg (1)" 0 0 0 other)"
is "apt_install_checked: no records, no install" \
  "${RC_NO_RECORD} removes= apt=" "$(checked "Inst pkg (1)" 0 1 0)"
is "apt_install_checked: apt fails" \
  "${RC_FAILED} removes= apt=[install -y --no-remove pkg]" "$(checked "Inst pkg (1)" 0 0 100)"

# ensure_package: the newest build that installs; hands back ENSURE_VERSION.
ensured() {  # ensured <installed version> <versions on offer> <"version=refused|failed|busy|no-record" of failing builds> [rejected before]
  (
    pkg_installed_version() { echo "$HAVE"; }
    pkg_allowed_versions_desc() { printf '%s\n' $OFFER; }
    apt_install_checked() {
      local f
      TRIED="${TRIED:+${TRIED} }${1#*=}"
      for f in $FAILS; do
        [ "${f%%=*}" = "${1#*=}" ] || continue
        case "${f#*=}" in
          busy)      echo "E: Could not get lock /var/lib/dpkg/lock"; return "$RC_FAILED" ;;
          refused)   return "$RC_REFUSED" ;;
          no-record) return "$RC_NO_RECORD" ;;
          *)         return "$RC_FAILED" ;;
        esac
      done
      return 0
    }
    HAVE="$1" OFFER="$2" FAILS="$3" REJECTED_BUILDS="${4:-}" TRIED=""
    ensure_package pkg > /dev/null 2>&1; rc=$?
    echo "${rc} version=${ENSURE_VERSION} tried=${TRIED} rejected=${REJECTED_BUILDS# }"
  )
}
is "ensure_package: installs the newest build" \
  "0 version=3 tried=3 rejected=" "$(ensured "" "3 2 1" "")"
is "ensure_package: falls back to an older build" \
  "0 version=2 tried=3 2 rejected=pkg=3" "$(ensured "" "3 2 1" "3=refused")"
is "ensure_package: a failed install tries the next build too" \
  "0 version=2 tried=3 2 rejected=pkg=3" "$(ensured "" "3 2 1" "3=failed")"
is "ensure_package: never below the installed build" \
  "${RC_UNCHANGED} version=2 tried=3 rejected=pkg=3" "$(ensured 2 "3 2 1" "3=refused")"
is "ensure_package: already at the newest" \
  "${RC_UNCHANGED} version=3 tried= rejected=" "$(ensured 3 "3 2 1" "")"
is "ensure_package: nothing on offer" \
  "${RC_FAILED} version= tried= rejected=" "$(ensured "" "" "")"
is "ensure_package: nothing on offer installs" \
  "${RC_FAILED} version= tried=2 1 rejected=pkg=2 pkg=1" "$(ensured "" "2 1" "2=refused 1=refused")"
is "ensure_package: a build turned down earlier is not tried twice" \
  "0 version=2 tried=2 rejected=pkg=3" "$(ensured "" "3 2" "" "pkg=3")"
# These two stop the run: the subshell ends before it prints.
is "ensure_package: a busy apt stops the run"      "" "$(ensured "" "3 2" "3=busy")"
is "ensure_package: unwritable records stop the run" "" "$(ensured "" "3 2" "3=no-record")"

# plymouth_put_back: hands back PLY_WAS, PLY_CURRENT and the outcome's name.
put_back() {  # put_back <current theme> <theme before> <theme set> <owed: 0|1> <put status> <rebuild status> [owe status]
  (
    plymouth_current_theme() { echo "$CUR"; }
    put_back_plymouth_theme() { PUT="$1"; return "$PUT_RC"; }
    rebuild_initramfs_recorded() { REBUILT=1; return "$REBUILD_RC"; }
    owe_initramfs() { [ "$OWE_RC" -eq 0 ] && : > "$INITRAMFS_PENDING"; return "$OWE_RC"; }
    drop_plymouth_records() { DROPPED=1; }
    PLYMOUTH_BEFORE_FILE="$T/ply-before" PLYMOUTH_SET_FILE="$T/ply-set" INITRAMFS_PENDING="$T/ply-pending"
    rm -f "$PLYMOUTH_BEFORE_FILE" "$PLYMOUTH_SET_FILE" "$INITRAMFS_PENDING"
    CUR="$1" PUT_RC="$5" REBUILD_RC="$6" OWE_RC="${7:-0}" PUT="" REBUILT=0 DROPPED=0 PLYMOUTH_THEME=bgrt PLY_OUTCOME=""
    [ -z "$2" ] || echo "$2" > "$PLYMOUTH_BEFORE_FILE"
    [ -z "$3" ] || echo "$3" > "$PLYMOUTH_SET_FILE"
    [ "$4" = 0 ] || : > "$INITRAMFS_PENDING"
    plymouth_put_back > /dev/null 2>&1; rc=$?
    [ -f "$INITRAMFS_PENDING" ] && owed=1 || owed=0
    echo "${rc} ${PLY_OUTCOME} was=${PLY_WAS} current=${PLY_CURRENT} put=${PUT} rebuilt=${REBUILT} dropped=${DROPPED} owed=${owed}"
  )
}
is "plymouth_put_back: restores the earlier theme" \
  "${RC_CHANGED} restored was=spinner current=bgrt put=spinner rebuilt=1 dropped=1 owed=1" "$(put_back bgrt spinner bgrt 0 0 0)"
is "plymouth_put_back: nothing recorded" \
  "${RC_UNCHANGED} none was= current=bgrt put= rebuilt=0 dropped=1 owed=0" "$(put_back bgrt "" "" 0 0 0)"
is "plymouth_put_back: already on the earlier theme" \
  "${RC_UNCHANGED} none was=bgrt current=bgrt put= rebuilt=0 dropped=1 owed=0" "$(put_back bgrt bgrt bgrt 0 0 0)"
is "plymouth_put_back: the user's own theme stays" \
  "${RC_UNCHANGED} kept was=spinner current=solar put= rebuilt=0 dropped=1 owed=0" "$(put_back solar spinner bgrt 0 0 0)"
is "plymouth_put_back: the set theme defaults to PLYMOUTH_THEME" \
  "${RC_CHANGED} restored was=spinner current=bgrt put=spinner rebuilt=1 dropped=1 owed=1" "$(put_back bgrt spinner "" 0 0 0)"
is "plymouth_put_back: theme unreadable, records kept" \
  "${RC_FAILED} unread was=spinner current= put= rebuilt=0 dropped=0 owed=0" "$(put_back "" spinner bgrt 0 0 0)"
is "plymouth_put_back: put-back fails, records kept, nothing owed" \
  "${RC_FAILED} put-back was=spinner current=bgrt put=spinner rebuilt=0 dropped=0 owed=0" "$(put_back bgrt spinner bgrt 0 1 0)"
is "plymouth_put_back: put-back fails, an older debt stays" \
  "${RC_FAILED} put-back was=spinner current=bgrt put=spinner rebuilt=0 dropped=0 owed=1" "$(put_back bgrt spinner bgrt 1 1 0)"
is "plymouth_put_back: rebuild fails after the put-back" \
  "${RC_FAILED} rebuild was=spinner current=bgrt put=spinner rebuilt=1 dropped=0 owed=1" "$(put_back bgrt spinner bgrt 0 0 1)"
is "plymouth_put_back: an owed rebuild is finished" \
  "${RC_CHANGED} rebuilt was= current=bgrt put= rebuilt=1 dropped=1 owed=1" "$(put_back bgrt "" "" 1 0 0)"
is "plymouth_put_back: an owed rebuild fails" \
  "${RC_FAILED} owed was= current=bgrt put= rebuilt=1 dropped=0 owed=1" "$(put_back bgrt "" "" 1 0 1)"
is "plymouth_put_back: the debt cannot be recorded" \
  "${RC_NO_RECORD} no-record was=spinner current=bgrt put= rebuilt=0 dropped=0 owed=0" "$(put_back bgrt spinner bgrt 0 0 0 1)"

# strip_grub_words: hands back GRUB_ADDED_WORDS and GRUB_CMDLINE_NEW.
stripped() {  # stripped <"state value" of the command line> <pending: 0|1> <line added: 0|1> <write status> [update-grub status]
  (
    read_grub_cmdline() { printf '%s\n' "$STATE"; }
    write_grub_cmdline() { DID="write:$1"; return "$W_RC"; }
    remove_grub_cmdline_line() { DID="remove-line"; return "$W_RC"; }
    boot_tool() { DID="$1"; return "$TOOL_RC"; }
    forget_grub_words() { FORGOT=1; rm -f "$@"; }
    GRUB_ADDED_FILE="$T/grub-added" GRUB_STRIP_PENDING="$T/grub-strip" GRUB_LINE_ADDED="$T/grub-line"
    rm -f "$GRUB_STRIP_PENDING" "$GRUB_LINE_ADDED"
    printf '%s\n' "quiet splash" > "$GRUB_ADDED_FILE"
    STATE="$1" W_RC="$4" TOOL_RC="${5:-0}" DID="" FORGOT=0 GRUB_BACKUP_KEPT="" GRUB_CMDLINE_NEW=""
    [ "$2" = 0 ] || : > "$GRUB_STRIP_PENDING"
    [ "$3" = 0 ] || : > "$GRUB_LINE_ADDED"
    strip_grub_words > /dev/null 2>&1; rc=$?
    [ -f "$GRUB_STRIP_PENDING" ] && pending=1 || pending=0
    echo "${rc} words=${GRUB_ADDED_WORDS} did=${DID} forgot=${FORGOT} pending=${pending}"
  )
}
is "strip_grub_words: takes the recorded words off" \
  "0 words=quiet splash did=write:ro forgot=1 pending=0" "$(stripped "active ro quiet splash" 0 0 0)"
is "strip_grub_words: only one of the words is left" \
  "0 words=quiet splash did=write:ro forgot=1 pending=0" "$(stripped "active ro splash" 0 0 0)"
is "strip_grub_words: a line the look added goes whole" \
  "0 words=quiet splash did=remove-line forgot=1 pending=0" "$(stripped "active quiet splash" 0 1 0)"
is "strip_grub_words: an emptied line of the user's stays" \
  "0 words=quiet splash did=write: forgot=1 pending=0" "$(stripped "active quiet splash" 0 0 0)"
is "strip_grub_words: words already gone" \
  "${RC_UNCHANGED} words=quiet splash did= forgot=1 pending=0" "$(stripped "active ro" 0 0 0)"
is "strip_grub_words: the file is not in a shape to edit" \
  "${RC_REFUSED} words=quiet splash did= forgot=0 pending=0" "$(stripped "unparsable " 0 0 0)"
is "strip_grub_words: the write fails, the note goes" \
  "${RC_FAILED} words=quiet splash did=write:ro forgot=0 pending=0" "$(stripped "active ro quiet splash" 0 0 1)"
is "strip_grub_words: finishes an interrupted update-grub" \
  "0 words=quiet splash did=update-grub forgot=1 pending=0" "$(stripped "active ro" 1 0 0)"
is "strip_grub_words: the interrupted update-grub fails again" \
  "${RC_FAILED} words=quiet splash did=update-grub forgot=0 pending=1" "$(stripped "active ro" 1 0 0 1)"

# set_boot_splash: no theme change without a settled kernel command line.
splash() {  # splash <"state value" of the command line>
  (
    read_grub_cmdline() { printf '%s\n' "$STATE"; }
    set_plymouth_theme() { THEME=1; }
    sys_record_write() { printf '%s\n' "$2" > "$1"; }
    GRUB_ADD_PENDING="$T/add-pending" GRUB_STRIP_PENDING="$T/strip-pending"
    GRUB_ADDED_FILE="$T/added" GRUB_SEEN_FILE="$T/seen"
    rm -f "$GRUB_ADD_PENDING" "$GRUB_STRIP_PENDING" "$GRUB_ADDED_FILE" "$GRUB_SEEN_FILE"
    STATE="$1" THEME=0 STATUS_NOCHANGE=() STATUS_FAILED=() STATUS_CHANGES=()
    set_boot_splash > /dev/null 2>&1; rc=$?
    echo "${rc} theme=${THEME} changes=${#STATUS_CHANGES[@]} failed=${#STATUS_FAILED[@]}"
  )
}
is "set_boot_splash: an unparsable grub file leaves the theme alone" \
  "0 theme=0 changes=0 failed=0" "$(splash "unparsable ")"
is "set_boot_splash: with the words in place the theme is set" \
  "0 theme=1 changes=0 failed=0" "$(splash "active ro quiet splash")"

# auto_reboot: the real reboot command is never reached here. Without a
# terminal the countdown's reads fail at once, so it runs out immediately.
rebooted() {  # rebooted <UBUNTU_LOOK_REBOOT> <terminal: 0|1> [reboot status]
  (
    reboot_now() { echo "REBOOT"; return "$R_RC"; }
    reboot_can_be_answered() { [ "$TTY" = 1 ]; }
    UBUNTU_LOOK_REBOOT="$1" TTY="$2" R_RC="${3:-0}" REBOOT_COUNTDOWN=3
    auto_reboot 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | tr '\n' '|'
  )
}
is "auto_reboot: counts down, then reboots" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| Rebooting now.|REBOOT|" "$(rebooted 1 1)"
is "auto_reboot: UBUNTU_LOOK_REBOOT=0 only names the command" \
  " Run: sudo reboot|" "$(rebooted 0 1)"
is "auto_reboot: no terminal, no reboot" \
  " Run: sudo reboot|" "$(rebooted 1 0)"
is "auto_reboot: a reboot that does not start is reported" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| Rebooting now.|REBOOT|[WARN] could not start the reboot — run: sudo reboot|" "$(rebooted 1 1 1)"

### Variable scope: a lowercase variable a function sets is local, and run
### state is declared in section 1 (tests/lint-scope.py).
if command -v python3 > /dev/null 2>&1; then
  is "scope: every variable is local or declared" "" \
    "$(python3 tests/lint-scope.py ubuntu-look.sh | grep -v '^0 scope problem')"
else
  echo "SKIP scope check: python3 is missing"
fi

### wallpaper_packs: the pack names come from the package's dependencies
packs() {
  (
    UBUNTU_CODENAME=tenacious
    release_build() { echo "$BUILD"; }
    apt-cache() { [ -z "$DEPENDS" ] || printf 'Package: ubuntu-wallpapers\nDepends: %s\n' "$DEPENDS"; }
    BUILD="$1" DEPENDS="$2" wallpaper_packs
  )
}
is "wallpaper_packs: the pack of the release itself" \
  "ubuntu-wallpapers-tenacious" "$(packs 26.10.2 "ubuntu-wallpapers-tenacious")"
is "wallpaper_packs: a pack still named after the previous release" \
  "ubuntu-wallpapers-stonking" "$(packs 26.10.1 "ubuntu-wallpapers-stonking")"
is "wallpaper_packs: only wallpaper packs, each once" \
  "ubuntu-wallpapers-a ubuntu-wallpapers-b" "$(packs 1 "libc6 (>= 2.1), ubuntu-wallpapers-b | ubuntu-wallpapers-a, ubuntu-wallpapers-b, other-pkg")"
is "wallpaper_packs: no build known, the release's own name" \
  "ubuntu-wallpapers-tenacious" "$(packs "" "")"
is "wallpaper_packs: odd names are not taken" \
  "ubuntu-wallpapers-tenacious" "$(packs 1 'ubuntu-wallpapers-x;rm, ubuntu-wallpapers-Bad1')"

### dconf_or_pending
is "dconf_or_pending: success leaves nothing pending" "0 0" \
  "$( dconf() { return 0; }; USER_PENDING=0; dconf_or_pending reset /a/b; echo "$? $USER_PENDING" )"
is "dconf_or_pending: a failure marks the user's settings pending" "1 1" \
  "$( dconf() { return 1; }; USER_PENDING=0; dconf_or_pending reset /a/b; echo "$? $USER_PENDING" )"

### Versions
is "version_major: a release"            "49" "$(version_major 49.1-2)"
is "version_major: an epoch"             "49" "$(version_major 1:49.1-2)"
is "version_major: a pre-release"        "49" "$(version_major 49~rc-1)"
is "version_major: no version"           "" "$(version_major "")"

### The series in development
# A stand-in for curl: the archive's devel link, Ubuntu's development list and
# a release's own Release file. The script asks for "<body>\n<HTTP code>".
fake_curl() {
  local url="${!#}" e
  case "$url" in
    */dists/devel/Release)
      case "$LINK" in
        unread) printf '\n000'; return 7 ;;
        none)   printf 'Not Found\n404' ;;
        *)      printf 'Origin: Ubuntu\nCodename: %s\n\n200' "$LINK" ;;
      esac ;;
    *meta-release-development)
      [ "$LIST" != unread ] || return 22
      for e in $LIST; do printf 'Dist: %s\nVersion: 1\nSupported: %s\n\n' "${e%%:*}" "${e#*:}"; done ;;
    # A release is on the main archive, or with RETIRED=1 on the retired one.
    "${UBUNTU_OLD_MIRROR}"/dists/*/Release)
      if [ "$RETIRED" = 1 ]; then printf 'Origin: Ubuntu\nVersion: 27.04\n\n200'; else printf 'Not Found\n404'; fi ;;
    */dists/*/Release)
      if [ "$RETIRED" = 1 ]; then printf 'Not Found\n404'; else printf 'Origin: Ubuntu\nVersion: 27.04\n\n200'; fi ;;
  esac
}
devel() {  # devel <devel link: a codename, none or unread> <development list: "codename:supported"..., or unread>
  (
    curl() { fake_curl "$@"; }
    LINK="$1" LIST="$2" UBUNTU_MIRROR=http://m.example/ubuntu UBUNTU_DEFAULT_MIRROR=http://m.example/ubuntu
    UBUNTU_RELEASE_CACHE="" RETIRED=0
    cn="$(ubuntu_devel_codename)"; echo "$? ${cn}"
  )
}
is "devel series: the archive's link names it" \
  "0 tenacious" "$(devel tenacious "stonking:1 tenacious:0")"
is "devel series: the link alone is enough" \
  "0 tenacious" "$(devel tenacious unread)"
is "devel series: a link left on a published release names none" \
  "0 " "$(devel stonking "resolute:1 stonking:1")"
is "devel series: a stale link gives way to the list" \
  "0 tenacious" "$(devel stonking "stonking:1 tenacious:0")"
is "devel series: without a link the list's last entry" \
  "0 tenacious" "$(devel none "stonking:1 tenacious:0")"
is "devel series: without a link, every listed release published" \
  "0 " "$(devel none "resolute:1 stonking:1")"
is "devel series: nothing readable" \
  "2 " "$(devel unread unread)"
release_state() {  # release_state <codename> <devel link> [retired: 0|1]
  (
    curl() { fake_curl "$@"; }
    LINK="$2" LIST=unread UBUNTU_MIRROR=http://m.example/ubuntu UBUNTU_DEFAULT_MIRROR=http://m.example/ubuntu
    UBUNTU_RELEASE_CACHE="" RETIRED="${3:-0}"
    info="$(ubuntu_release_info "$1")"; echo "$? ${info}"
  )
}
is "release info: the series in development is marked" \
  "0 27.04 devel http://m.example/ubuntu" "$(release_state tenacious tenacious)"
is "release info: any other release is stable" \
  "0 27.04 stable http://m.example/ubuntu" "$(release_state stonking tenacious)"
is "release info: a retired release is never in development" \
  "0 27.04 stable ${UBUNTU_OLD_MIRROR}" "$(release_state tenacious tenacious 1)"
is "release info: an unknown devel series counts as unread" \
  "2 " "$(release_state tenacious unread)"

### The summaries
summary_end() {  # summary_end <exit status> <finished: 0|1> [failed item]
  (
    log_final_state() { :; }
    RUN_STARTED=1 RUN_FINISHED="$2" UBUNTU_RELEASE_CACHE="" REBOOT_NEEDED=0 RELOGIN_NEEDED=0
    STATUS_CHANGES=("a change") STATUS_FAILED=()
    [ -z "${3:-}" ] || STATUS_FAILED=("$3")
    trap '_on_exit; print_summary' EXIT
    exit "$1"
  ) 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | grep -E '^(✗|✓|⚠)'
}
is "summary: a run that stopped says so" \
  "✗  Script stopped (rc=1). See the ERROR or WARN lines above." "$(summary_end 1 0)"
is "summary: an interrupted run says so" \
  "✗  Script stopped (rc=130). See the ERROR or WARN lines above." "$(summary_end 130 0)"
is "summary: a finished run is done" \
  "✓  Done — no reboot needed." "$(summary_end 0 1)"
is "summary: a finished run with an item not done is no stop" \
  "⚠  Done, except the items listed above as not done — each gives its reason." "$(summary_end 1 1 "an item")"
reported() {  # reported <action> <kind>
  (
    ACTION="$1" STATUS_CHANGES=() STATUS_NOCHANGE=() STATUS_FAILED=() DONE=() SKIPPED=() GUESSED=() SYSTEM_PENDING=0
    report "$2" "text"
    echo "${#STATUS_CHANGES[@]}${#STATUS_NOCHANGE[@]}${#STATUS_FAILED[@]} ${#DONE[@]}${#SKIPPED[@]}${#GUESSED[@]} pending=${SYSTEM_PENDING}"
  )
}
is "report: install, changed"            "100 000 pending=0" "$(reported install changed)"
is "report: install, unchanged"          "010 000 pending=0" "$(reported install unchanged)"
is "report: install, left to the user"   "010 000 pending=0" "$(reported install manual)"
is "report: install, failed"             "001 000 pending=0" "$(reported install failed)"
is "report: uninstall, changed"          "000 100 pending=0" "$(reported uninstall changed)"
is "report: uninstall, unchanged"        "000 010 pending=0" "$(reported uninstall unchanged)"
is "report: uninstall, left to the user" "000 010 pending=1" "$(reported uninstall manual)"
is "report: uninstall, failed"           "000 001 pending=1" "$(reported uninstall failed)"
stopped_uninstall() {  # stopped_uninstall <started: 0|1> <finished: 0|1>
  (
    RUN_STARTED="$1" RUN_FINISHED="$2" UBUNTU_RELEASE_CACHE="" INITRAMFS_PARTIAL=0
    DONE=("one thing") SKIPPED=() GUESSED=()
    trap _on_uninstall_exit EXIT
    exit 130
  ) 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | grep -cE 'UNINSTALL STOPPED|one thing|stopped before it finished'
}
is "uninstall: a stopped run lists what it did"   "3" "$(stopped_uninstall 1 0)"
is "uninstall: a finished run adds nothing"       "0" "$(stopped_uninstall 1 1)"
is "uninstall: a run stopped before it began adds nothing" "0" "$(stopped_uninstall 0 0)"

### --reset: the user's own values of the look's settings, and nothing else
# A stand-in settings database: "<key>=<value>" lines in $T/reset/db.
reset_run() {  # reset_run <"key=value" lines of the user's own settings> [dconf status]
  (
    d="$T/reset"; rm -rf "$d"; mkdir -p "$d/home/Documents"
    printf '%s\n' $1 > "$d/db"; echo "mine" > "$d/home/Documents/notes.txt"
    user_dconf() {
      case "$1" in
        dump) cat "$d/db" ;;
        read) sed -n "s|^${2}=||p" "$d/db" ;;
        list) sed -n "s|^${2}\([^=/]*/\{0,1\}\).*|\1|p" "$d/db" | sort -u ;;
      esac
    }
    dconf() {
      [ "$DCONF_RC" -eq 0 ] || return 1
      case "$1 $2" in
        "reset -f") # A directory (ending in /) with all below it, or one key.
                    case "$3" in */) grep -v "^${3}" "$d/db" ;; *) grep -v "^${3}=" "$d/db" ;; esac > "$d/db.new"
                    mv "$d/db.new" "$d/db" ;;
        reset\ *)   grep -v "^${2}=" "$d/db" > "$d/db.new"; mv "$d/db.new" "$d/db" ;;
      esac
    }
    look_installed_ext() { [ "$1" != ubuntu-appindicators@ubuntu.com ]; }
    # The look's own values: Yaru as the GTK theme, nothing else.
    our_dconf_value() { [ "$1/$2" != org/gnome/desktop/interface/gtk-theme ] || echo "'Yaru'"; }
    message() { :; }
    HOME="$d/home" BACKUP_DIR="$d/home/.ubuntu-look-backup" TERMINAL_SHORTCUT_RECORD="$d/home/.ubuntu-look-backup/terminal-shortcut-added"
    DCONF_RC="${2:-0}" STATUS_CHANGES=() STATUS_NOCHANGE=() STATUS_FAILED=()
    reset_user_settings > /dev/null 2>&1
    saved="$(find "$BACKUP_DIR" -name 'settings-before-reset-*.ini' | wc -l)"
    echo "left=$(tr '\n' ' ' < "$d/db" | sed 's/ *$//') changes=${#STATUS_CHANGES[@]} failed=${#STATUS_FAILED[@]} saved=${saved} file=$(cat "$d/home/Documents/notes.txt")"
  )
}
is "reset: the look's keys go, every other setting stays" \
  "left=/org/gnome/shell/favorite-apps=['a'] /org/gnome/desktop/input-sources/sources=x changes=1 failed=0 saved=1 file=mine" \
  "$(reset_run "/org/gnome/desktop/interface/gtk-theme='Adwaita' /org/gnome/desktop/wm/preferences/button-layout='close:' /org/gnome/shell/favorite-apps=['a'] /org/gnome/desktop/input-sources/sources=x")"
is "reset: the settings of the look's extensions go" \
  "left= changes=1 failed=0 saved=1 file=mine" \
  "$(reset_run "/org/gnome/shell/extensions/dash-to-dock/dock-position='LEFT' /org/gnome/shell/extensions/tiling-assistant/x=1")"
is "reset: the tiling assistant keeps its note of the shortcuts it took over" \
  "left=/org/gnome/shell/extensions/tiling-assistant/overridden-settings={} changes=1 failed=0 saved=1 file=mine" \
  "$(reset_run "/org/gnome/shell/extensions/tiling-assistant/overridden-settings={} /org/gnome/shell/extensions/tiling-assistant/gaps/window=8 /org/gnome/shell/extensions/tiling-assistant/x=1")"
is "reset: what the extensions store by themselves stays" \
  "left=/org/gnome/shell/extensions/tiling-assistant/last-version-installed=51 /org/gnome/shell/extensions/tiling-assistant/focus-hint-color='rgb(237,91,0)' /org/gnome/shell/extensions/ding/check-x11wayland=true changes=0 failed=0 saved=0 file=mine" \
  "$(reset_run "/org/gnome/shell/extensions/tiling-assistant/last-version-installed=51 /org/gnome/shell/extensions/tiling-assistant/focus-hint-color='rgb(237,91,0)' /org/gnome/shell/extensions/ding/check-x11wayland=true")"
is "reset: a value that is the look's own is left" \
  "left=/org/gnome/desktop/interface/gtk-theme='Yaru' changes=0 failed=0 saved=0 file=mine" \
  "$(reset_run "/org/gnome/desktop/interface/gtk-theme='Yaru'")"
is "reset: an extension the user had before keeps its settings" \
  "left=/org/gnome/shell/extensions/appindicator/icon-size=5 changes=0 failed=0 saved=0 file=mine" \
  "$(reset_run "/org/gnome/shell/extensions/appindicator/icon-size=5")"
is "reset: the look's extensions leave the disabled list" \
  "left=/org/gnome/shell/favorite-apps=['a'] changes=1 failed=0 saved=1 file=mine" \
  "$(reset_run "/org/gnome/shell/disabled-extensions=['ubuntu-dock@ubuntu.com'] /org/gnome/shell/favorite-apps=['a']")"
is "reset: nothing of the user's own, nothing changed" \
  "left=/org/gnome/shell/favorite-apps=['a'] changes=0 failed=0 saved=0 file=mine" \
  "$(reset_run "/org/gnome/shell/favorite-apps=['a']")"
is "reset: a reset that fails is reported, and nothing is changed" \
  "left=/org/gnome/desktop/interface/gtk-theme='Adwaita' changes=0 failed=1 saved=0 file=mine" \
  "$(reset_run "/org/gnome/desktop/interface/gtk-theme='Adwaita'" 1)"

### The session's record of users
forgot() {  # forgot <users on record> <user>
  (
    sys_record_write() { printf '%s\n' "$2" > "$1"; }
    SESSION_USERS_RECORD="$T/session-users" RUN_USER="$2"
    printf '%s\n' $1 > "$SESSION_USERS_RECORD"
    forget_session_user
    [ -f "$SESSION_USERS_RECORD" ] && xargs < "$SESSION_USERS_RECORD" || echo "no record"
  )
}
is "forget_session_user: the others stay on record" "bob" "$(forgot "alice bob alice" alice)"
is "forget_session_user: the last one takes the record" "no record" "$(forgot "alice" alice)"

### The apt hook, run for real against a stand-in system
hook() {  # hook <gnome-shell package version> <major the look was set up for> <Yaru's shell theme: 0|1>
  (
    d="$T/hook"; rm -rf "$d"; mkdir -p "$d/bin" "$d/records" "$d/ext" "$d/accounts"
    SHELL_MODE_FILE="$d/ubuntu.json" SESSION_ENTRIES="$d/ubuntu.desktop $d/ubuntu-xorg.desktop"
    SYS_RECORDS="$d/records" SESSION_USERS_RECORD="$d/records/session-users.txt"
    THEME_EXT_DIR="$d/ext" YARU_SHELL_THEME="$d/yaru" ACCOUNTS_USERS_DIR="$d/accounts"
    : > "$SHELL_MODE_FILE"; : > "$d/ubuntu.desktop"; : > "$d/ubuntu-xorg.desktop"
    printf '{\n  "shell-version": ["%s"],\n}\n' "$2" > "$d/ext/metadata.json"
    [ "$3" = 0 ] || : > "$YARU_SHELL_THEME"
    printf 'Session=ubuntu\n' > "$d/accounts/alice"
    printf 'XSession=ubuntu-xorg\n' > "$d/accounts/bob"
    printf 'Session=gnome\n' > "$d/accounts/carol"
    printf '#!/bin/sh\nprintf %%s "%s"\n' "$1" > "$d/bin/dpkg-query"; chmod +x "$d/bin/dpkg-query"
    apt_hook_content > "$d/hook.sh"
    PATH="$d/bin:$PATH" sh "$d/hook.sh" 2> /dev/null; rc=$?
    [ -e "$SHELL_MODE_FILE" ] || [ -e "$d/ubuntu.desktop" ] || [ -e "$d/ubuntu-xorg.desktop" ] && s=kept || s=gone
    echo "${rc} session=${s} users=$({ xargs < "$SESSION_USERS_RECORD"; } 2> /dev/null)"
  )
}
is "apt hook: the same GNOME Shell keeps the session" \
  "0 session=kept users=" "$(hook 48.4-1~deb13u1 48 1)"
is "apt hook: a pre-release of the same major keeps it" \
  "0 session=kept users=" "$(hook 49~rc-1 49 1)"
is "apt hook: an epoch is not the major" \
  "0 session=kept users=" "$(hook 1:48.4-1 48 1)"
is "apt hook: a new major drops the session and notes its users" \
  "0 session=gone users=alice bob" "$(hook 49.1-1 48 1)"
is "apt hook: without Yaru's shell theme the session goes" \
  "0 session=gone users=alice bob" "$(hook 48.4-1 48 0)"

### The files the script writes in other languages: each one parses
embedded="$T/embedded"; mkdir -p "$embedded"
(
  SESSION_ENTRIES="/usr/local/share/xsessions/ubuntu.desktop"
  write_local_extension() { cat > "${embedded}/$1.js"; }
  write_greeter_extension; write_theme_extension
  session_end_content > "${embedded}/session-end.js"
  apt_hook_content > "${embedded}/hook.sh"
  session_fonts_content > "${embedded}/fonts.conf"
  session_mode_content > "${embedded}/mode.json"
  session_manager_dropin_content > "${embedded}/dropin.conf"
  python3() { cat; }
  normalise_app_grid_icon a b > "${embedded}/icon.py"
)
is "embedded: the three scripts were written" "3" "$(find "$embedded" -name '*.js' -size +0 | wc -l)"
is "embedded: the apt hook parses as sh"      "" "$(sh -n "${embedded}/hook.sh" 2>&1)"
is "embedded: the drop-in clears the session's variables" \
  "ExecStopPost=-/usr/bin/systemctl --user unset-environment GNOME_SHELL_SESSION_MODE DCONF_PROFILE FONTCONFIG_FILE" \
  "$(grep unset-environment "${embedded}/dropin.conf")"
if command -v python3 > /dev/null 2>&1; then
  is "embedded: the icon script parses as Python" "" \
    "$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "${embedded}/icon.py" 2>&1)"
  is "embedded: the font rule parses as XML" "" \
    "$(python3 -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "${embedded}/fonts.conf" 2>&1)"
  is "embedded: the session mode parses as JSON" "" \
    "$(python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "${embedded}/mode.json" 2>&1)"
else
  echo "SKIP Python, XML and JSON checks: python3 is missing"
fi
if command -v gjs > /dev/null 2>&1; then
  is "embedded: the extensions and the session-end script parse as JavaScript" "" \
    "$(gjs tests/parse-js.js "${embedded}"/*.js 2>&1)"
else
  echo "SKIP JavaScript check: gjs is missing"
fi

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
