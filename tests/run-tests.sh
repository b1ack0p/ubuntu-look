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
is "a flag may repeat"                   "uninstall 0"  "$(parsed --uninstall --uninstall)"
is "two actions" \
  "rc=1 [ERROR] Give only one of --refresh and --uninstall." "$(parsed --refresh --uninstall)"
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
  "1 removes= apt=" "$(checked "E: broken" 100 0 0)"
is "apt_install_checked: refuses a removal, and names it" \
  "1 removes=other apt=" "$(checked "Remv other [1]"$'\n'"Inst pkg (1)" 0 0 0)"
is "apt_install_checked: an allowed removal goes through" \
  "0 removes= apt=[install -y pkg]" "$(checked "Remv other [1]"$'\n'"Inst pkg (1)" 0 0 0 other)"
is "apt_install_checked: no records, no install" \
  "3 removes= apt=" "$(checked "Inst pkg (1)" 0 1 0)"
is "apt_install_checked: apt fails" \
  "2 removes= apt=[install -y --no-remove pkg]" "$(checked "Inst pkg (1)" 0 0 100)"

# ensure_package: the newest build that installs; hands back ENSURE_VERSION.
ensured() {  # ensured <installed version> <versions on offer> <"version=status" of failing builds> [rejected before]
  (
    pkg_installed_version() { echo "$HAVE"; }
    pkg_allowed_versions_desc() { printf '%s\n' $OFFER; }
    apt_install_checked() {
      local f
      TRIED="${TRIED:+${TRIED} }${1#*=}"
      for f in $FAILS; do
        [ "${f%%=*}" = "${1#*=}" ] || continue
        [ "${f#*=}" = busy ] && { echo "E: Could not get lock /var/lib/dpkg/lock"; return 2; }
        return "${f#*=}"
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
  "0 version=2 tried=3 2 rejected=pkg=3" "$(ensured "" "3 2 1" "3=1")"
is "ensure_package: a failed install tries the next build too" \
  "0 version=2 tried=3 2 rejected=pkg=3" "$(ensured "" "3 2 1" "3=2")"
is "ensure_package: never below the installed build" \
  "2 version=2 tried=3 rejected=pkg=3" "$(ensured 2 "3 2 1" "3=1")"
is "ensure_package: already at the newest" \
  "2 version=3 tried= rejected=" "$(ensured 3 "3 2 1" "")"
is "ensure_package: nothing on offer" \
  "1 version= tried= rejected=" "$(ensured "" "" "")"
is "ensure_package: nothing on offer installs" \
  "1 version= tried=2 1 rejected=pkg=2 pkg=1" "$(ensured "" "2 1" "2=1 1=1")"
is "ensure_package: a build turned down earlier is not tried twice" \
  "0 version=2 tried=2 rejected=pkg=3" "$(ensured "" "3 2" "" "pkg=3")"
# These two stop the run: the subshell ends before it prints.
is "ensure_package: a busy apt stops the run"      "" "$(ensured "" "3 2" "3=busy")"
is "ensure_package: unwritable records stop the run" "" "$(ensured "" "3 2" "3=3")"

# plymouth_put_back: hands back PLY_WAS and PLY_CURRENT.
put_back() {  # put_back <current theme> <theme before> <theme set> <owed: 0|1> <put status> <rebuild status> [owe status]
  (
    plymouth_current_theme() { echo "$CUR"; }
    put_back_plymouth_theme() { PUT="$1"; return "$PUT_RC"; }
    rebuild_initramfs_recorded() { REBUILT=1; return "$REBUILD_RC"; }
    owe_initramfs() { [ "$OWE_RC" -eq 0 ] && : > "$INITRAMFS_PENDING"; return "$OWE_RC"; }
    drop_plymouth_records() { DROPPED=1; }
    PLYMOUTH_BEFORE_FILE="$T/ply-before" PLYMOUTH_SET_FILE="$T/ply-set" INITRAMFS_PENDING="$T/ply-pending"
    rm -f "$PLYMOUTH_BEFORE_FILE" "$PLYMOUTH_SET_FILE" "$INITRAMFS_PENDING"
    CUR="$1" PUT_RC="$5" REBUILD_RC="$6" OWE_RC="${7:-0}" PUT="" REBUILT=0 DROPPED=0 PLYMOUTH_THEME=bgrt
    [ -z "$2" ] || echo "$2" > "$PLYMOUTH_BEFORE_FILE"
    [ -z "$3" ] || echo "$3" > "$PLYMOUTH_SET_FILE"
    [ "$4" = 0 ] || : > "$INITRAMFS_PENDING"
    plymouth_put_back > /dev/null 2>&1; rc=$?
    [ -f "$INITRAMFS_PENDING" ] && owed=1 || owed=0
    echo "${rc} was=${PLY_WAS} current=${PLY_CURRENT} put=${PUT} rebuilt=${REBUILT} dropped=${DROPPED} owed=${owed}"
  )
}
is "plymouth_put_back: restores the earlier theme" \
  "0 was=spinner current=bgrt put=spinner rebuilt=1 dropped=1 owed=1" "$(put_back bgrt spinner bgrt 0 0 0)"
is "plymouth_put_back: nothing recorded" \
  "1 was= current=bgrt put= rebuilt=0 dropped=1 owed=0" "$(put_back bgrt "" "" 0 0 0)"
is "plymouth_put_back: already on the earlier theme" \
  "1 was=bgrt current=bgrt put= rebuilt=0 dropped=1 owed=0" "$(put_back bgrt bgrt bgrt 0 0 0)"
is "plymouth_put_back: the user's own theme stays" \
  "2 was=spinner current=solar put= rebuilt=0 dropped=1 owed=0" "$(put_back solar spinner bgrt 0 0 0)"
is "plymouth_put_back: the set theme defaults to PLYMOUTH_THEME" \
  "0 was=spinner current=bgrt put=spinner rebuilt=1 dropped=1 owed=1" "$(put_back bgrt spinner "" 0 0 0)"
is "plymouth_put_back: theme unreadable, records kept" \
  "3 was=spinner current= put= rebuilt=0 dropped=0 owed=0" "$(put_back "" spinner bgrt 0 0 0)"
is "plymouth_put_back: put-back fails, records kept, nothing owed" \
  "4 was=spinner current=bgrt put=spinner rebuilt=0 dropped=0 owed=0" "$(put_back bgrt spinner bgrt 0 1 0)"
is "plymouth_put_back: put-back fails, an older debt stays" \
  "4 was=spinner current=bgrt put=spinner rebuilt=0 dropped=0 owed=1" "$(put_back bgrt spinner bgrt 1 1 0)"
is "plymouth_put_back: rebuild fails after the put-back" \
  "5 was=spinner current=bgrt put=spinner rebuilt=1 dropped=0 owed=1" "$(put_back bgrt spinner bgrt 0 0 1)"
is "plymouth_put_back: an owed rebuild is finished" \
  "6 was= current=bgrt put= rebuilt=1 dropped=1 owed=1" "$(put_back bgrt "" "" 1 0 0)"
is "plymouth_put_back: an owed rebuild fails" \
  "7 was= current=bgrt put= rebuilt=1 dropped=0 owed=1" "$(put_back bgrt "" "" 1 0 1)"
is "plymouth_put_back: the debt cannot be recorded" \
  "8 was=spinner current=bgrt put= rebuilt=0 dropped=0 owed=0" "$(put_back bgrt spinner bgrt 0 0 0 1)"

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
  "1 words=quiet splash did= forgot=1 pending=0" "$(stripped "active ro" 0 0 0)"
is "strip_grub_words: the file is not in a shape to edit" \
  "2 words=quiet splash did= forgot=0 pending=0" "$(stripped "unparsable " 0 0 0)"
is "strip_grub_words: the write fails, the note goes" \
  "3 words=quiet splash did=write:ro forgot=0 pending=0" "$(stripped "active ro quiet splash" 0 0 1)"
is "strip_grub_words: finishes an interrupted update-grub" \
  "0 words=quiet splash did=update-grub forgot=1 pending=0" "$(stripped "active ro" 1 0 0)"
is "strip_grub_words: the interrupted update-grub fails again" \
  "3 words=quiet splash did=update-grub forgot=0 pending=1" "$(stripped "active ro" 1 0 0 1)"

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

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
