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
no "mirror: no user name or password"    option_value_ok UBUNTU_MIRROR "http://me:secret@mirror.example.org/ubuntu"
no "mirror: no spaces"                   option_value_ok UBUNTU_MIRROR "http://a.example/u b"
no "mirror: no shell characters"         option_value_ok UBUNTU_MIRROR 'http://a.example/$(id)'

### Saved options: parsed, never sourced
# UBUNTU_LOOK_REBOOT is an option of the script's that is not a saved one, and
# is unset here: only the list of saved names keeps it out.
tmpd="$(mktemp -d)"; tmp="$tmpd/options"
printf '%s\n' 'UBUNTU_CODENAME=plucky' "PLYMOUTH_THEME=\$(touch $tmpd/made)" \
  'UBUNTU_BOOT_SPLASH=5' 'PATH=/nowhere' 'UBUNTU_LOOK_REBOOT=0' \
  'UBUNTU_MIRROR=http://m.example/ubuntu' > "$tmp"
is "saved options: valid ones load, the rest are ignored" \
  "plucky|unset|unset|http://m.example/ubuntu|kept|unset|not run" \
  "$(unset UBUNTU_CODENAME PLYMOUTH_THEME UBUNTU_BOOT_SPLASH UBUNTU_MIRROR UBUNTU_LOOK_REBOOT
     old_path="$PATH"; SAVED_OPTIONS="$tmp"; load_saved_options
     [ "$PATH" = "$old_path" ] && p=kept || p=changed
     [ -e "$tmpd/made" ] && m=run || m="not run"
     echo "${UBUNTU_CODENAME-unset}|${PLYMOUTH_THEME-unset}|${UBUNTU_BOOT_SPLASH-unset}|${UBUNTU_MIRROR-unset}|$p|${UBUNTU_LOOK_REBOOT-unset}|$m")"
is "saved options: a value given this run wins" "noble" \
  "$(UBUNTU_CODENAME=noble; SAVED_OPTIONS="$tmp"; load_saved_options; echo "$UBUNTU_CODENAME")"
rm -rf "$tmpd"

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

# read_grub_cmdline against a stand-in /etc/default/grub.
grub_read() { ( GRUB_FILE="$(mktemp)"; printf '%b' "$1" > "$GRUB_FILE"; read_grub_cmdline; rm -f "$GRUB_FILE" ); }
is "grub: a quoted line is read"         "active ro quiet" "$(grub_read 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="ro quiet"\n')"
is "grub: no line"                       "absent "         "$(grub_read 'GRUB_DEFAULT=0\n')"
is "grub: a commented line"              "commented "      "$(grub_read '#GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n')"
is "grub: two lines are not rewritten"   "unparsable "     "$(grub_read 'GRUB_CMDLINE_LINUX_DEFAULT="a"\nGRUB_CMDLINE_LINUX_DEFAULT="b"\n')"
is "grub: an assignment later on a line is not rewritten" \
  "unparsable " "$(grub_read 'if true; then GRUB_CMDLINE_LINUX_DEFAULT="a"; fi\n')"
is "grub: one behind && is not rewritten" \
  "unparsable " "$(grub_read 'GRUB_CMDLINE_LINUX_DEFAULT="a"\n[ -d /x ] && GRUB_CMDLINE_LINUX_DEFAULT="b"\n')"
is "grub: the name in a comment does not count" \
  "active a" "$(grub_read 'GRUB_CMDLINE_LINUX_DEFAULT="a"\nGRUB_TIMEOUT=5 # not GRUB_CMDLINE_LINUX_DEFAULT=\n')"

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
is "an empty argument is refused" \
  "rc=1 [ERROR] An empty argument was given. See: bash ubuntu-look.sh --help" "$(parsed "")"
is "an empty argument beside a command is refused" \
  "rc=1 [ERROR] An empty argument was given. See: bash ubuntu-look.sh --help" "$(parsed "" --reset)"
# The on and off switches: only 0 and 1.
switched() {  # switched <name> <value>: "ok", or the error
  ( unset UBUNTU_LOOK_REBOOT UBUNTU_LOOK_LOG UBUNTU_LOOK_SYSTEM_UPGRADE
    export "$1=$2"
    (check_switches && echo ok) 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' )
}
is "a switch takes 0"                    "ok" "$(switched UBUNTU_LOOK_REBOOT 0)"
is "a switch takes 1"                    "ok" "$(switched UBUNTU_LOOK_LOG 1)"
is "a switch may be empty"               "ok" "$(switched UBUNTU_LOOK_SYSTEM_UPGRADE "")"
is "a switch takes no word" \
  "[ERROR] UBUNTU_LOOK_REBOOT takes 0 or 1 (got 'no')." "$(switched UBUNTU_LOOK_REBOOT no)"
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
    ensure_package pkg > "$T/ensure.out" 2>&1; rc=$?
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
# These two stop the run: the subshell ends before it prints, with the
# error's status and its reason.
stopped() {  # stopped <text of the error> <ensured's arguments...>
  local said="$1" out rc; shift
  out="$(ensured "$@")"; rc=$?
  echo "rc=${rc} out=${out} said=$(grep -c -- "$said" "$T/ensure.out")"
}
is "ensure_package: a busy apt stops the run" \
  "rc=1 out= said=1" "$(stopped "apt is busy or the network failed" "" "3 2" "3=busy")"
is "ensure_package: unwritable records stop the run" \
  "rc=1 out= said=1" "$(stopped "could not write the look's records" "" "3 2" "3=no-record")"

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

# auto_reboot: the real reboot command is never reached here, and the wait
# for Enter is a stand-in that ends at once with the status of an Enter (0),
# of the time running out (142) or of a terminal that went away (1).
rebooted() {  # rebooted <UBUNTU_LOOK_REBOOT> <terminal: 0|1> [reboot status] [wait status]
  (
    reboot_now() { echo "REBOOT"; return "$R_RC"; }
    reboot_can_be_answered() { [ "$TTY" = 1 ]; }
    countdown_read() { return "$READ_RC"; }
    UBUNTU_LOOK_REBOOT="$1" TTY="$2" R_RC="${3:-0}" READ_RC="${4:-142}" REBOOT_COUNTDOWN=3
    auto_reboot 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | tr '\n' '|'
  )
}
is "auto_reboot: counts down, then reboots" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| Rebooting now.|REBOOT|" "$(rebooted 1 1)"
is "auto_reboot: Enter reboots" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| Rebooting now.|REBOOT|" "$(rebooted 1 1 0 0)"
is "auto_reboot: Ctrl-C cancels" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| Reboot cancelled. When you are ready, run: sudo reboot|" "$(rebooted 1 1 0 130)"
is "auto_reboot: a terminal that went away does not reboot" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| The terminal is gone — not rebooting. Run: sudo reboot|" "$(rebooted 1 1 0 1)"
is "auto_reboot: UBUNTU_LOOK_REBOOT=0 only names the command" \
  " Run: sudo reboot|" "$(rebooted 0 1)"
is "auto_reboot: no terminal, no reboot" \
  " Run: sudo reboot|" "$(rebooted 1 0)"
is "auto_reboot: a reboot that does not start is reported" \
  " Rebooting in 3 seconds. Press Enter to reboot now, Ctrl-C to cancel.| Rebooting now.|REBOOT|[WARN] could not start the reboot — run: sudo reboot|" "$(rebooted 1 1 1)"

### The summary's reboot: one an earlier run owes starts no countdown
summarised() {  # summarised <carried: 0|1> <relogin: 0|1> <failed items> <finished: 0|1>
  (
    log_final_state() { :; }
    auto_reboot() { echo "COUNTDOWN"; }
    RUN_STARTED=1 RUN_FINISHED="$4" INITRAMFS_PARTIAL=0 REBOOT_NEEDED=1 REBOOT_CARRIED="$1" RELOGIN_NEEDED="$2"
    STATUS_INSTALLED=() STATUS_UPGRADED=() STATUS_ALREADY=() STATUS_HELD=() STATUS_CHANGES=() STATUS_NOCHANGE=()
    STATUS_FAILED=(); [ "$3" -eq 0 ] || STATUS_FAILED=("one thing")
    SETTINGS_KEPT=()
    true; print_summary 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' \
      | grep -oE 'REBOOT (STILL )?REQUIRED|COUNTDOWN|Run: sudo reboot|Everything else was applied' | tr '\n' '|'
  )
}
is "summary: a reboot this run needs counts down" \
  "REBOOT REQUIRED|COUNTDOWN|" "$(summarised 0 0 0 1)"
is "summary: a reboot only an earlier run owes names the command" \
  "REBOOT STILL REQUIRED|Run: sudo reboot|" "$(summarised 1 0 0 1)"
is "summary: an owed reboot with new changes counts down" \
  "REBOOT REQUIRED|COUNTDOWN|" "$(summarised 1 1 0 1)"
is "summary: with a step not done there is no countdown" \
  "Everything else was applied|REBOOT REQUIRED|Run: sudo reboot|" "$(summarised 0 0 1 1)"

### The provisional pin: a file that blocks nothing is no pin
provisional() {  # provisional <content of the pin file, or "absent">
  (
    d="$T/pin"; rm -rf "$d"; mkdir -p "$d"
    UBUNTU_PIN="$d/pin"
    [ "$1" = absent ] || printf '%b' "$1" > "$UBUNTU_PIN"
    sudo_write_atomic() { cp "$1" "$2"; }
    sudo() { "$@"; }
    write_provisional_pin; rc=$?
    echo "rc=${rc} blocks=$(grep -cx 'Pin-Priority: -1' "$UBUNTU_PIN")"
  )
}
is "provisional pin: written where there is none"   "rc=${RC_CHANGED} blocks=1"   "$(provisional absent)"
is "provisional pin: an empty file is written anew" "rc=${RC_CHANGED} blocks=1"   "$(provisional "")"
is "provisional pin: a pin that blocks is kept" \
  "rc=${RC_UNCHANGED} blocks=1" "$(provisional 'Package: *\nPin: release o=Ubuntu\nPin-Priority: -1\n')"

### The session choice: any of the Ubuntu session's entries counts as chosen
chosen() {  # chosen <the user's session>
  (
    busctl() { [ "$1" = get-property ] && echo "s \"$SESSION\""; }
    sudo() { echo "SET"; }
    SESSION="$1"
    choose_ubuntu_session > /dev/null; echo "$?"
  )
}
is "session: ubuntu is already chosen"            "$RC_UNCHANGED" "$(chosen ubuntu)"
is "session: Ubuntu on Xorg stays as picked"      "$RC_UNCHANGED" "$(chosen ubuntu-xorg)"
is "session: Ubuntu on Wayland stays as picked"   "$RC_UNCHANGED" "$(chosen ubuntu-wayland)"
is "session: GNOME is changed to Ubuntu"          "$RC_CHANGED"   "$(chosen gnome)"

### --reset needs a finished install, not only its records
reset_start() {  # reset_start <records: 0|1> <pin: full|provisional|none>
  (
    d="$T/resetstart"; rm -rf "$d"; mkdir -p "$d"
    PACKAGES_BEFORE="$d/before"; UBUNTU_PIN="$d/pin"
    [ "$1" -eq 0 ] || : > "$PACKAGES_BEFORE"
    case "$2" in
      full)        printf '# pin-version: 1\nPackage: *\n' > "$UBUNTU_PIN" ;;
      provisional) printf '# provisional\nPackage: *\n' > "$UBUNTU_PIN" ;;
    esac
    have_session() { echo "REACHED"; exit 0; }
    ACTION=reset REFRESH=0
    install_start 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | head -n 1
  )
}
is "--reset: an installed look goes on" "REACHED" "$(reset_start 1 full)"
is "--reset: records of an install that stopped early are not an install" \
  "[ERROR] The Ubuntu look is not installed, or its install did not finish. Install it with: bash ubuntu-look.sh" \
  "$(reset_start 1 provisional)"
is "--reset: records an uninstall kept are not an install" \
  "[ERROR] The Ubuntu look is not installed, or its install did not finish. Install it with: bash ubuntu-look.sh" \
  "$(reset_start 1 none)"
is "--reset: no records, no install" \
  "[ERROR] The Ubuntu look is not installed, or its install did not finish. Install it with: bash ubuntu-look.sh" \
  "$(reset_start 0 none)"

### Variable scope: a lowercase variable a function sets is local, and run
### state is declared in section 1 (tests/lint-scope.py).
if command -v python3 > /dev/null 2>&1; then
  # The linter's status as well as its findings: one that stops with an
  # error prints no finding either.
  scope_out="$(python3 tests/lint-scope.py ubuntu-look.sh 2>&1)"; scope_rc=$?
  is "scope: the linter ran to its end" "0" "$scope_rc"
  is "scope: every variable is local or declared" "" \
    "$(printf '%s\n' "$scope_out" | grep -v '^0 scope problem(s) in [1-9][0-9]* functions$')"
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

### The reset: the user's own values of the look's settings, and nothing else;
### nothing is written to the user's home
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
    # The look's own values: Yaru as the GTK theme, and with WALLPAPER=1 its
    # wallpaper; nothing else.
    our_dconf_value() {
      case "$1/$2" in
        org/gnome/desktop/interface/gtk-theme) echo "'Yaru'" ;;
        org/gnome/desktop/background/picture-uri) [ "${WALLPAPER:-0}" = 0 ] || echo "'file:///look.png'" ;;
      esac
    }
    message() { :; }
    HOME="$d/home"
    DCONF_RC="${2:-0}" STATUS_CHANGES=() STATUS_NOCHANGE=() STATUS_FAILED=()
    reset_user_settings > /dev/null 2>&1
    # Nothing may appear in the user's home beside what was there.
    echo "left=$(tr '\n' ' ' < "$d/db" | sed 's/ *$//') changes=${#STATUS_CHANGES[@]} failed=${#STATUS_FAILED[@]} home=$(cd "$d/home" && find . -mindepth 1 | sort | xargs)"
  )
}
is "reset: the look's keys go, every other setting stays" \
  "left=/org/gnome/shell/favorite-apps=['a'] /org/gnome/desktop/input-sources/sources=x changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/desktop/interface/gtk-theme='Adwaita' /org/gnome/desktop/wm/preferences/button-layout='close:' /org/gnome/shell/favorite-apps=['a'] /org/gnome/desktop/input-sources/sources=x")"
is "reset: the settings of the look's extensions go" \
  "left= changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/shell/extensions/dash-to-dock/dock-position='LEFT' /org/gnome/shell/extensions/tiling-assistant/x=1")"
is "reset: the tiling assistant keeps its note of the shortcuts it took over" \
  "left=/org/gnome/shell/extensions/tiling-assistant/overridden-settings={} changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/shell/extensions/tiling-assistant/overridden-settings={} /org/gnome/shell/extensions/tiling-assistant/gaps/window=8 /org/gnome/shell/extensions/tiling-assistant/x=1")"
is "reset: what the extensions store by themselves stays" \
  "left=/org/gnome/shell/extensions/tiling-assistant/last-version-installed=51 /org/gnome/shell/extensions/tiling-assistant/focus-hint-color='rgb(237,91,0)' /org/gnome/shell/extensions/ding/check-x11wayland=true changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/shell/extensions/tiling-assistant/last-version-installed=51 /org/gnome/shell/extensions/tiling-assistant/focus-hint-color='rgb(237,91,0)' /org/gnome/shell/extensions/ding/check-x11wayland=true")"
is "reset: a value that is the look's own is left" \
  "left=/org/gnome/desktop/interface/gtk-theme='Yaru' changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/desktop/interface/gtk-theme='Yaru'")"
is "reset: an extension the user had before keeps its settings" \
  "left=/org/gnome/shell/extensions/appindicator/icon-size=5 changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/shell/extensions/appindicator/icon-size=5")"
is "reset: the look's extensions leave the disabled list" \
  "left=/org/gnome/shell/favorite-apps=['a'] changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/shell/disabled-extensions=['ubuntu-dock@ubuntu.com'] /org/gnome/shell/favorite-apps=['a']")"
is "reset: the user's wallpaper goes for the look's" \
  "left= changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(WALLPAPER=1 reset_run "/org/gnome/desktop/background/picture-uri='file:///mine.png'")"
is "reset: without a wallpaper of the look's the user's stays" \
  "left=/org/gnome/desktop/background/picture-uri='file:///mine.png' changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/desktop/background/picture-uri='file:///mine.png'")"
is "reset: the dark style goes, though the look sets no value for it" \
  "left= changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/desktop/interface/color-scheme='prefer-dark'")"
is "reset: the light style written out is the look's default and stays" \
  "left=/org/gnome/desktop/interface/color-scheme='prefer-light' changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/desktop/interface/color-scheme='prefer-light'")"
is "reset: were Ubuntu's style dark, a light one would go" \
  "left= changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(UBUNTU_COLOR_SCHEME=prefer-dark; reset_run "/org/gnome/desktop/interface/color-scheme='prefer-light'")"
is "reset: were Ubuntu's style dark, a dark one would stay" \
  "left=/org/gnome/desktop/interface/color-scheme='prefer-dark' changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(UBUNTU_COLOR_SCHEME=prefer-dark; reset_run "/org/gnome/desktop/interface/color-scheme='prefer-dark'")"
is "reset: a style Ubuntu's settings set is the one that stays" \
  "left=/org/gnome/desktop/interface/color-scheme='prefer-dark' changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(UBUNTU_COLOR_SCHEME_SETTING=prefer-dark; reset_run "/org/gnome/desktop/interface/color-scheme='prefer-dark'")"
is "reset: with a style set by Ubuntu's settings, GNOME's default goes" \
  "left= changes=1 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(UBUNTU_COLOR_SCHEME_SETTING=prefer-dark; reset_run "/org/gnome/desktop/interface/color-scheme='default'")"
is "defaults: no style set by Ubuntu's settings, no key" "0" \
  "$(render_dconf_groups | grep -c '^color-scheme=')"
is "defaults: a style Ubuntu's settings set is written, in the interface group" "[org/gnome/desktop/interface]|color-scheme='prefer-dark'" \
  "$(UBUNTU_COLOR_SCHEME_SETTING=prefer-dark; render_dconf_groups | grep -B1 '^color-scheme=' | tr '\n' '|' | sed 's/|$//')"
is "session mode: it names the release's style" "1" \
  "$(UBUNTU_COLOR_SCHEME=prefer-dark; session_mode_content 2>/dev/null | grep -c '"colorScheme": "prefer-dark"')"
# Ubuntu's own files, as its packages carry them.
is "style: Ubuntu's session mode names it" "prefer-light" \
  "$(printf '{\n    "parentMode": "user",\n    "colorScheme": "prefer-light",\n    "enabledExtensions": []\n}\n' | mode_color_scheme)"
is "style: a mode that names none" "" "$(printf '{\n    "parentMode": "user"\n}\n' | mode_color_scheme)"
is "style: a word that is no style is not taken" "" "$(printf '"colorScheme": "$(id)",\n' | mode_color_scheme)"
is "style: settings that set none" "" \
  "$(printf '[org.gnome.desktop.interface]\ngtk-theme="Yaru"\n[org.gnome.desktop.interface:ubuntu]\nicon-theme="Yaru"\n' | override_color_scheme)"
is "style: the Ubuntu session's own section wins" "prefer-dark" \
  "$(printf '[org.gnome.desktop.interface:ubuntu]\ncolor-scheme = "prefer-dark"\n[org.gnome.desktop.interface]\ncolor-scheme="prefer-light"\n' | override_color_scheme)"
is "style: another session's section does not count" "" \
  "$(printf "[org.gnome.desktop.interface:Unity]\ncolor-scheme='prefer-dark'\n" | override_color_scheme)"
is "style: GNOME's default reads as none" "" \
  "$(printf "[org.gnome.desktop.interface]\ncolor-scheme='default'\n" | override_color_scheme)"
# read_ubuntu_style against stand-ins for apt and the package files.
styled() {  # styled <packages readable: 0|1> <record, or ""> <mode's style> <settings' style, or "">
  (
    d="$T/style"; rm -rf "$d"; mkdir -p "$d"
    UBUNTU_STYLE_RECORD="$d/record"; [ -z "$2" ] || echo "$2" > "$UBUNTU_STYLE_RECORD"
    UBUNTU_DEFAULTS_RECORD="$d/defaults"
    [ -z "${5:-}" ] || printf '# release: %s\n[org.gnome.desktop.interface:ubuntu]\ngtk-theme="Yaru"\n' "$5" > "$UBUNTU_DEFAULTS_RECORD"
    UBUNTU_CODENAME=stonking STATUS_NOCHANGE=() RELEASE_SETTINGS_APPLIED=0
    release_build() { echo 1; }
    UBUNTU_EXTRAS_RECORD="$d/extras"
    apt-get() { [ "$READABLE" = 1 ] && touch "${2%%=*}_1_all.deb"; }
    deb_file() {
      case "$2" in
        */ubuntu.json) echo "{ \"colorScheme\": \"${MODE}\", \"enabledExtensions\": [ ${EXTS:-} ] }" ;;
        *) printf '[org.gnome.desktop.interface:ubuntu]\ngtk-theme="Yaru"\n'; [ -z "$SETTING" ] || echo "color-scheme='${SETTING}'" ;;
      esac
    }
    sys_record_write() { echo "$2" > "$1"; }
    message() { :; }
    READABLE="$1" MODE="$3" SETTING="${4:-}"
    read_ubuntu_style
    [ -z "${EXTS:-}" ] || { echo "mode=${MODE_EXTENSIONS#* } record=$(cut -d' ' -f4 "$UBUNTU_STYLE_RECORD")"; exit; }
    echo "shell=${UBUNTU_COLOR_SCHEME} apps=${UBUNTU_COLOR_SCHEME_SETTING:-none} record=$(cat "$UBUNTU_STYLE_RECORD" 2>/dev/null) notes=${#STATUS_NOCHANGE[@]} defaults=$([ -n "$UBUNTU_DEFAULTS" ] && head -n 1 "$UBUNTU_DEFAULTS")"
  )
}
is "style: read from the release's packages and recorded" \
  "shell=prefer-light apps=none record=stonking prefer-light - - - - notes=0 defaults=# release: stonking" "$(styled 1 "" prefer-light)"
is "style: a release that starts dark is followed" \
  "shell=prefer-dark apps=prefer-dark record=stonking prefer-dark prefer-dark - - - notes=0 defaults=# release: stonking" "$(styled 1 "plucky prefer-light -" prefer-dark prefer-dark "" plucky)"
is "style: unreadable packages, the record of this release is used" \
  "shell=prefer-dark apps=prefer-dark record=stonking prefer-dark prefer-dark notes=1 defaults=# release: stonking" "$(styled 0 "stonking prefer-dark prefer-dark" x "" stonking)"
is "style: unreadable packages and another release's record, light is assumed" \
  "shell=prefer-light apps=none record=plucky prefer-dark prefer-dark notes=2 defaults=" "$(styled 0 "plucky prefer-dark prefer-dark" x "" plucky)"

is "style: the session mode's extensions are the release's, Canonical's services apart" \
  "mode=ubuntu-dock@ubuntu.com new-thing@ubuntu.com record=ubuntu-dock@ubuntu.com,snapd-prompting@canonical.com,new-thing@ubuntu.com" \
  "$(EXTS='"ubuntu-dock@ubuntu.com", "snapd-prompting@canonical.com", "new-thing@ubuntu.com"' styled 1 "" prefer-light)"

### The look's values come from the release's own defaults file
DEFAULTS_SAMPLE="$T/defaults-sample"
cat > "$DEFAULTS_SAMPLE" << 'SAMPLE'
# release: stonking
[org.gnome.desktop.interface]
monospace-font-name="Ubuntu Sans Mono 13"
accent-color = 'orange'
[org.gnome.Epiphany]
default-search-engine = 'Google'
[org.gnome.desktop.interface:GNOME-Greeter]
gtk-theme = "Greeter"
[org.gnome.desktop.interface:ubuntu]
gtk-theme = "Yaru-next"
monospace-font-name = "Ubuntu Sans Mono 11"
enable-hot-corners = "yes"
[org.gnome.desktop.wm.keybindings:ubuntu]
switch-windows = ['<Alt>Tab','<Super>w']
[org.gnome.desktop.wm.preferences:ubuntu]
button-layout = 'close,minimize,maximize:'
[org.gnome.desktop.wm.preferences:Unity]
button-layout = 'unity'
[org.gnome.mutter:ubuntu]
edge-tiling = true
[org.gnome.shell.extensions.new-thing:ubuntu]
shiny = true
[org.gtk.Settings.FileChooser:ubuntu]
startup-mode = 'recent'
SAMPLE
is "defaults: the Ubuntu session's section wins over the one for every session" \
  "org.gnome.desktop.interface monospace-font-name \"Ubuntu Sans Mono 11\"" \
  "$(ubuntu_defaults "$DEFAULTS_SAMPLE" | grep ' monospace-font-name ')"
is "defaults: other sessions' sections are not read" "0" \
  "$(ubuntu_defaults "$DEFAULTS_SAMPLE" | grep -c 'Greeter\|unity')"
is "value: a string takes single quotes"   "'Yaru'"        "$(gvariant_canon '"Yaru"')"
is "value: a list keeps its items"         "['a', 'b']"    "$(gvariant_canon "['a', 'b']")"
is "kind: a string"   "string"  "$(gvariant_kind "'Ubuntu Sans 11'")"
is "kind: a switch"   "bool"    "$(gvariant_kind true)"
is "kind: a number"   "number"  "$(gvariant_kind 0)"
is "kind: a list"     "strings" "$(gvariant_kind "['<Alt>Tab','<Super>w']")"
is "kind: an empty list" "strings" "$(gvariant_kind "[]")"
is "kind: anything else is none" "" "$(gvariant_kind "{'a': <1>}")"
is "kind: a cut string is none"  "" "$(gvariant_kind "'Yaru")"
is "schema: a path's schema"            "org.gnome.desktop.interface"  "$(schema_of_path org/gnome/desktop/interface)"
is "schema: the file chooser's"         "org.gtk.Settings.FileChooser" "$(schema_of_path org/gtk/settings/file-chooser)"
followed() {  # followed <key>: its value in GNOME_SETTINGS after the release's defaults are applied
  (
    message() { :; }
    # The schemas this stand-in system has, beside those the look sets keys of.
    gsettings() { echo "org.gnome.shell.extensions.new-thing /org/gnome/shell/extensions/new-thing/"; }
    UBUNTU_DEFAULTS="$DEFAULTS_SAMPLE" UBUNTU_CODENAME=stonking RELEASE_SETTINGS_APPLIED=0 STATUS_NOCHANGE=()
    apply_release_settings
    if [ "$1" = notes ]; then printf '%s\n' "${STATUS_NOCHANGE[@]}"; exit; fi
    printf '%s\n' "${GNOME_SETTINGS[@]}" | sed -n "s/^[^|]*|${1}|//p"
  )
}
is "follow: a default the release changed is taken"      "'Yaru-next'"                "$(followed gtk-theme)"
is "follow: the session's own section, not the general"  "'Ubuntu Sans Mono 11'"      "$(followed monospace-font-name)"
is "follow: a list is taken"                             "['<Alt>Tab','<Super>w']"    "$(followed switch-windows)"
is "follow: another session's value is not"              "'close,minimize,maximize:'" "$(followed button-layout)"
is "follow: a mapped schema is found"                    "'recent'"                   "$(followed startup-mode)"
is "follow: a value of another kind keeps the script's"  "false"                      "$(followed enable-hot-corners)"
is "follow: a setting the release does not set keeps the script's" "'Yaru'"           "$(followed icon-theme)"
is "follow: a default in a schema new to the look is applied where this system has the schema" "true" "$(followed shiny)"
is "follow: nothing is reported for it, nor for one left out on purpose" "" "$(followed notes)"
is "follow: a default for software this system does not have is not applied" "" \
  "$(printf '# release: x\n[com.example.absent:ubuntu]\nthing = true\n' > "$T/absent"; DEFAULTS_SAMPLE="$T/absent"; followed thing)"
is "follow: a later release's default the release does not set is not applied" "" "$(followed start-in-overview)"
is "follow: a later release's default the release sets is applied" "false" \
  "$(printf '# release: stonking\n[org.gnome.shell:ubuntu]\nstart-in-overview = false\n' > "$T/later"; DEFAULTS_SAMPLE="$T/later"; followed start-in-overview)"
is "follow: a new default in a schema the look sets keys of is applied" "true" \
  "$(printf '# release: x\n[org.gnome.desktop.interface:ubuntu]\nshiny-new = true\n' > "$T/new"; DEFAULTS_SAMPLE="$T/new"; followed shiny-new)"
is "follow: it joins its schema's other settings" "org/gnome/desktop/interface" \
  "$( ( message() { :; }; printf '# release: x\n[org.gnome.desktop.interface:ubuntu]\nshiny-new = true\n' > "$T/new"
        UBUNTU_DEFAULTS="$T/new" UBUNTU_CODENAME=x RELEASE_SETTINGS_APPLIED=0 STATUS_NOCHANGE=()
        apply_release_settings; printf '%s\n' "${GNOME_SETTINGS[@]}" | grep -B1 '|shiny-new|' | head -n 1 | cut -d'|' -f1 ) )"
is "follow: a new default whose value is no value is reported, not applied" \
  "Ubuntu stonking sets 1 default(s) whose value this script cannot take, not applied: org.gnome.desktop.interface.odd" \
  "$(printf "# release: x\n[org.gnome.desktop.interface:ubuntu]\nodd = {'a': <1\n" > "$T/odd"; DEFAULTS_SAMPLE="$T/odd"; followed notes)"
ok "value: one of a kind the script knows is valid"          gvariant_valid "'Yaru'"
no "value: a cut value is not valid"                         gvariant_valid "{'a': <1"
no "value: an empty value is not valid"                      gvariant_valid ""
if command -v dconf > /dev/null 2>&1; then
  ok "value: any value dconf's compiler takes is valid"      gvariant_valid "{'audio/x-vorbis': 'Ubuntu'}"
  is "follow: a new default of any kind dconf takes is applied" "{'a': <1>}" \
    "$(printf "# release: x\n[org.gnome.desktop.interface:ubuntu]\nodd = {'a': <1>}\n" > "$T/odd2"; DEFAULTS_SAMPLE="$T/odd2"; followed odd)"
fi
wallpapers() {  # wallpapers <defaults file text>
  ( message() { :; }; printf '%b' "$1" > "$T/wp"
    UBUNTU_DEFAULTS="$T/wp" UBUNTU_CODENAME=x RELEASE_SETTINGS_APPLIED=0 STATUS_NOCHANGE=()
    apply_release_settings; echo "${WP_LIGHT##*/} ${WP_DARK##*/}" )
}
is "follow: the wallpaper files are the release's" "new-light.png new-dark.png" \
  "$(wallpapers "# release: x\n[org.gnome.desktop.background:ubuntu]\npicture-uri = 'file:///usr/share/backgrounds/new-light.png'\npicture-uri-dark = 'file:///usr/share/backgrounds/new-dark.png'\n")"
is "follow: a wallpaper outside the backgrounds folder is not taken" "warty-final-ubuntu.png ubuntu-wallpaper-d.png" \
  "$(wallpapers "# release: x\n[org.gnome.desktop.background:ubuntu]\npicture-uri = 'file:///etc/passwd'\npicture-uri-dark = 'http://x/y.png'\n")"
greeter() {  # greeter <key> <the session's value> [old font names: 0|1]
  ( message() { :; }
    printf '# release: x\n[org.gnome.desktop.interface:GNOME-Greeter]\ngtk-theme = "Yaru-greeter"\nfont-name = "Ubuntu Sans 12"\nfont-antialiasing = 7\n[org.gnome.desktop.interface:ubuntu]\ngtk-theme = "Yaru"\n' > "$T/gr"
    UBUNTU_DEFAULTS="$T/gr" UBUNTU_CODENAME=x RELEASE_SETTINGS_APPLIED=0 STATUS_NOCHANGE=()
    apply_release_settings; FONTS_OLD_NAMES="${3:-0}"; greeter_value "$1" "$2" )
}
is "greeter: the login screen's own value is used"        "'Yaru-greeter'"   "$(greeter gtk-theme "'Yaru'")"
is "greeter: one it does not set takes the session's"     "'Yaru'"           "$(greeter icon-theme "'Yaru'")"
is "greeter: a value of another kind is not taken"        "'rgba'"           "$(greeter font-antialiasing "'rgba'")"
is "greeter: older font names are fitted"                 "'Ubuntu 12'"      "$(greeter font-name "'Ubuntu 11'" 1)"
is "mode: its stylesheet"  "Yaru/gnome-shell.css" \
  "$(printf '{\n  "stylesheetName": "Yaru/gnome-shell.css",\n  "colorScheme": "prefer-light"\n}\n' | mode_string stylesheetName)"
is "mode: a name with anything but a file name's characters is not taken" "" \
  "$(printf '{ "stylesheetName": "a b$(id)" }\n' | mode_string stylesheetName)"
is "session mode: it names the release's stylesheet and theme" "2" \
  "$(MODE_STYLESHEET=Next/shell.css MODE_THEME_RESOURCE=theme/Next/x.gresource; session_mode_content 2>/dev/null | grep -c 'Next/')"
# The terminal's colours from the Yaru theme, against a stand-in for gresource.
terminal_colours() {  # terminal_colours <the theme's rule>
  (
    message() { :; }
    YARU_GTK_RESOURCE="$T/yaru.gresource"; : > "$YARU_GTK_RESOURCE"
    gresource() {
      case "$1" in
        list) echo /com/ubuntu/themes/Yaru/3.0/gtk.css; echo /com/ubuntu/themes/Yaru/3.0/gtk-dark.css ;;
        extract) printf 'window { color: red; }\n%b\nother { color: blue; }\n' "$RULE" ;;
      esac
    }
    RULE="$1"
    yaru_terminal_colours
    printf '%s\n' "${GNOME_SETTINGS[@]}" | sed -n 's/.*|\(background\|foreground\)-color|//p' | xargs
  )
}
is "terminal: the theme's colours are taken" "#2C001E #EEEEEE" \
  "$(terminal_colours 'terminal-window .terminal-screen {\n  background-color: #2C001E;\n  color: #EEEEEE; }')"
is "terminal: white is a colour" "#300A24 #FFFFFF" \
  "$(terminal_colours 'terminal-window .terminal-screen {\n  background-color: #300A24;\n  color: white; }')"
is "terminal: a theme without the rule keeps the script's colours" "#300A24 #FFFFFF" \
  "$(terminal_colours 'terminal-window .other { background-color: #111111; }')"
is "terminal: a value that is no colour is not taken" "#300A24 #FFFFFF" \
  "$(terminal_colours 'terminal-window .terminal-screen {\n  background-color: url(x);\n  color: inherit; }')"
adopted() {  # adopted <installs cleanly: 0|1>: the packages taken into the look, the pin's list, the note
  (
    message() { :; }
    release_build() { echo 1; }
    apt-cache() { echo "Depends: yaru-theme-gtk (>= 1), yaru-theme-new, network-manager, gnome-shell-ubuntu-extensions | gnome-shell-extension-ubuntu-dock, fonts-noto-core"; }
    installs_cleanly() { [ "$CLEAN" = 1 ]; }
    # shellcheck disable=SC2154  # the sourced script's package lists
    CLEAN="$1" UBUNTU_CODENAME=stonking STATUS_NOCHANGE=() ALL_STAGE_PACKAGES="${packages[*]}"
    adopt_release_look_packages
    echo "adopted=${ADOPTED_PACKAGES# } pinned=$(in_word_list yaru-theme-new "$UBUNTU_PINNED_PACKAGES" && echo yes || echo no) staged=$(in_word_list yaru-theme-new "${packages[2-desktop-gnome]}" && echo yes || echo no) note=${STATUS_NOCHANGE[*]:-}"
  )
}
is "packages: a new look package of Ubuntu's desktop that installs is taken, pinned and staged" \
  "adopted=yaru-theme-new pinned=yes staged=yes note=" "$(adopted 1)"
is "packages: one that does not install here is named, not taken" \
  "adopted= pinned=no staged=no note=Ubuntu stonking's desktop also uses look packages that do not install on this Debian: yaru-theme-new" "$(adopted 0)"
# The session's font configuration from the files Ubuntu enables.
fonts_conf() {  # fonts_conf <files Ubuntu enables>: the files the session reads first
  (
    d="$T/fontconf"; rm -rf "$d"; mkdir -p "$d/avail" "$d/enabled"
    touch "$d/avail/10-sub-pixel-rgb.conf" "$d/avail/10-sub-pixel-none.conf" "$d/avail/11-lcdfilter-default.conf"
    touch "$d/enabled/10-sub-pixel-none.conf" "$d/enabled/11-lcdfilter-default.conf"
    FONTCONFIG_AVAIL="$d/avail" FONTCONFIG_ENABLED="$d/enabled" UBUNTU_FONT_CONFS="$1"
    session_fonts_content | sed -n 's#.*<include ignore_missing="yes">.*/\([^/<]*\)</include>.*#\1#p' | xargs
    session_fonts_content | grep -c 'mode="assign"'
  ) | xargs
}
is "fonts: the file Ubuntu enables and Debian does not is read, the others are not" \
  "10-sub-pixel-rgb.conf 0" "$(fonts_conf "10-sub-pixel-rgb.conf 11-lcdfilter-default.conf 99-not-shipped.conf")"
is "fonts: without Ubuntu's list the script's own rule stands" "1" "$(fonts_conf "")"
if command -v fc-match > /dev/null 2>&1 && [ -f /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf ]; then
  # fontconfig's own answer: 1 is rgb, and the first value counts.
  is "fonts: the session's configuration gives sub-pixel rgb first" "rgba: 1" \
    "$(UBUNTU_FONT_CONFS="10-sub-pixel-rgb.conf"; session_fonts_content > "$T/fonts.conf"
       FONTCONFIG_FILE="$T/fonts.conf" fc-match -v sans 2> /dev/null | sed -n 's/^[[:space:]]*\(rgba: [0-9]*\).*$/\1/p')"
fi
is "mode: its extensions, in order" \
  "ubuntu-dock@ubuntu.com ding@rastersoft.com snapd-prompting@canonical.com" \
  "$(printf '{\n  "colorScheme": "prefer-light",\n  "enabledExtensions": [\n    "ubuntu-dock@ubuntu.com",\n    "ding@rastersoft.com",\n    "snapd-prompting@canonical.com"\n  ]\n}\n' | mode_extensions)"
is "mode: a name that is no extension is not taken" "" \
  "$(printf '{ "enabledExtensions": [ "$(id)", "no-at-sign" ] }' | mode_extensions)"
is "follow: without the release's file the script's values stand" "'Yaru'" \
  "$(DEFAULTS_SAMPLE=/nonexistent; followed gtk-theme)"
is "reset: nothing of the user's own, nothing changed" \
  "left=/org/gnome/shell/favorite-apps=['a'] changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/shell/favorite-apps=['a']")"
is "reset: a reset that fails is reported, and nothing is changed" \
  "left=/org/gnome/desktop/interface/gtk-theme='Adwaita' changes=0 failed=1 home=./Documents ./Documents/notes.txt" \
  "$(reset_run "/org/gnome/desktop/interface/gtk-theme='Adwaita'" 1)"

### Extensions the user has a build of their own of keep their settings
own_build() {  # own_build <extension> <directory to make below the stand-in root> [owner package] [on the manifest: 0|1]
  (
    d="$T/ownext"; rm -rf "$d"; mkdir -p "$d/home" "$d/sys"
    DATA_HOME="$d/home"; SYSTEM_EXT_DIR="$d/sys"; INSTALLED_MANIFEST="$d/manifest"; PACKAGES_BEFORE="$d/before"
    : > "$PACKAGES_BEFORE"; : > "$INSTALLED_MANIFEST"
    [ "${4:-0}" -eq 0 ] || echo "${3}" > "$INSTALLED_MANIFEST"
    case "$2" in
      home:*) mkdir -p "$d/home/gnome-shell/extensions/${2#home:}" ;;
      sys:*)  mkdir -p "$d/sys/${2#sys:}" ;;
    esac
    dpkg-query() { [ -z "$OWNER" ] || echo "${OWNER}: $2"; }
    OWNER="${3:-}"
    has_own_ext_build "$1" && echo own || echo none
  )
}
is "own build: none"                        "none" "$(own_build ubuntu-dock@ubuntu.com -)"
is "own build: Dash to Dock in the home"    "own"  "$(own_build ubuntu-dock@ubuntu.com home:dash-to-dock@micxgx.gmail.com)"
is "own build: a copy of the look's in the home" "own" "$(own_build ding@rastersoft.com home:ding@rastersoft.com)"
is "own build: Debian's Dash to Dock"       "own"  "$(own_build ubuntu-dock@ubuntu.com sys:dash-to-dock@micxgx.gmail.com gnome-shell-extension-dashtodock)"
is "own build: a system copy no package owns" "own" "$(own_build tiling-assistant@ubuntu.com sys:tiling-assistant@leleat-on-github)"
is "own build: a system build the look installed is the look's" \
  "none" "$(own_build ubuntu-appindicators@ubuntu.com sys:appindicatorsupport@rgcjonas.gmail.com gnome-shell-extension-appindicator 1)"
is "own build: another extension's is not this one's" \
  "none" "$(own_build ubuntu-dock@ubuntu.com home:tiling-assistant@leleat-on-github)"
is "reset: an extension the user has a build of their own of keeps its settings" \
  "left=/org/gnome/shell/extensions/dash-to-dock/dock-position='LEFT' changes=0 failed=0 home=./Documents ./Documents/notes.txt" \
  "$(has_own_ext_build() { [ "$1" = ubuntu-dock@ubuntu.com ]; }; reset_run "/org/gnome/shell/extensions/dash-to-dock/dock-position='LEFT'")"

### The uninstall gives back the user's own tiling settings
SAVED_TILING="{'org.gnome.mutter.edge-tiling': <false>, 'org.gnome.desktop.wm.keybindings.maximize': <['<Super>k', '<Super>Up']>, 'org.gnome.desktop.wm.keybindings.unmaximize': <@as []>, 'org.gnome.mutter.keybindings.toggle-tiled-left': <@mb nothing>}"
tiling_saved() { ( dconf() { echo "$SAVED_TILING"; }; tiling_saved_value "$1" "$2"; echo "rc=$?" ) | tr '\n' ' '; }
is "tiling: a saved shortcut"          "['<Super>k', '<Super>Up'] rc=0 " "$(tiling_saved org/gnome/desktop/wm/keybindings maximize)"
is "tiling: a saved empty shortcut"    "@as [] rc=0 "      "$(tiling_saved org/gnome/desktop/wm/keybindings unmaximize)"
is "tiling: a saved switch"            "false rc=0 "       "$(tiling_saved org/gnome/mutter edge-tiling)"
is "tiling: no value of the user's"    "@mb nothing rc=0 " "$(tiling_saved org/gnome/mutter/keybindings toggle-tiled-left)"
is "tiling: a key it did not save"     "rc=1 "             "$(tiling_saved org/gnome/mutter/keybindings toggle-tiled-right)"
is "tiling: maximize is not unmaximize" "['<Super>k', '<Super>Up'] rc=0 " "$(tiling_saved org/gnome/desktop/wm/keybindings maximize)"
tiling_step() {  # tiling_step <own build: 0|1>: what the step writes and resets
  (
    step() { :; }
    look_installed_ext() { return 0; }
    has_own_ext_build() { [ "$OWN" = 1 ]; }
    need_session() { return 0; }
    extension_active() { return 1; }
    dconf() {
      case "$1" in
        read)  case "$2" in
                 */overridden-settings) echo "$SAVED_TILING" ;;
                 */edge-tiling) echo false ;;
                 *) echo "@as []" ;;
               esac ;;
        write) echo "write ${2##*/}=$3" >> "$T/tiling.log" ;;
        reset) echo "reset ${2##*/}" >> "$T/tiling.log" ;;
      esac
    }
    OWN="$1" DONE=() SKIPPED=() GUESSED=() USER_PENDING=0
    : > "$T/tiling.log"
    step_restore_tiling_keybindings > /dev/null 2>&1
    echo "$(tr '\n' '|' < "$T/tiling.log") done=${#DONE[@]} pending=${USER_PENDING}"
  )
}
is "tiling: the user's own values go back, the others to Debian's default" \
  "write maximize=['<Super>k', '<Super>Up']|write unmaximize=@as []|reset toggle-tiled-left|reset toggle-tiled-right|write edge-tiling=false| done=2 pending=0" \
  "$(tiling_step 0)"
is "tiling: a tiling assistant of the user's own keeps the keys" \
  " done=0 pending=0" "$(tiling_step 1)"

### The terminal shortcut among the user's own: complete, so Debian's GNOME
### session shows it too
shortcut() {  # shortcut <the user's list> [binding of the user's own shortcut]
  (
    d="$T/shortcut"; rm -rf "$d"; mkdir -p "$d"; : > "$d/db"
    [ -z "$1" ] || echo "${CUSTOM_KEYBINDINGS_KEY}=$1" > "$d/db"
    [ -z "${2:-}" ] || echo "/mine/binding=$2" >> "$d/db"
    user_dconf_read() { sed -n "s|^${1}=||p" "$d/db"; }
    dconf() {
      case "$1" in
        read)  sed -n "s|^${2}=||p" "$d/db" ;;
        write) grep -v "^${2}=" "$d/db" > "$d/db.new"; echo "${2}=${3}" >> "$d/db.new"; mv "$d/db.new" "$d/db" ;;
      esac
    }
    p="${TERMINAL_SHORTCUT_PATH#/}"; p="${p%/}"
    SESSION_ONLY_SETTINGS=("x|custom-keybindings|[]" "${p}|name|'Terminal'" "${p}|binding|'<Primary><Alt>t'")
    STATUS_CHANGES=() STATUS_NOCHANGE=() STATUS_FAILED=()
    add_terminal_shortcut > /dev/null 2>&1
    echo "keys=$(grep -c "^${TERMINAL_SHORTCUT_PATH}" "$d/db") listed=$(grep -c "^${CUSTOM_KEYBINDINGS_KEY}=.*ubuntu-look-terminal" "$d/db") changes=${#STATUS_CHANGES[@]} failed=${#STATUS_FAILED[@]}"
  )
}
is "shortcut: no shortcuts of the user's own, nothing written" \
  "keys=0 listed=0 changes=0 failed=0" "$(shortcut "")"
is "shortcut: added to the user's own, with its name and keys" \
  "keys=2 listed=1 changes=1 failed=0" "$(shortcut "['/mine/']" "'<Super>e'")"
is "shortcut: one already there without its name and keys is completed" \
  "keys=2 listed=1 changes=1 failed=0" "$(shortcut "['/mine/', '${TERMINAL_SHORTCUT_PATH}']")"
is "shortcut: the user's own Ctrl+Alt+T is left" \
  "keys=0 listed=0 changes=0 failed=0" "$(shortcut "['/mine/']" "'<Control><Alt>t'")"

### A finished uninstall removes the look's run logs, and only those
logs_removed() {
  (
    d="$T/logs"; rm -rf "$d"; mkdir -p "$d"
    touch "$d/ubuntu-look-install-20260101-120000.log" "$d/ubuntu-look-uninstall-20260102-120000-2.log" \
          "$d/ubuntu-look-notes.log" "$d/ubuntu-look-install-notes.log" "$d/other.log"
    message() { :; }
    HOME="$d" UBUNTU_LOOK_STARTED_MARK="$d/mark"
    remove_run_logs
    echo "$(cd "$d" && echo *) mark=$(cat "$d/mark")"
  )
}
is "uninstall: the run logs go, other files stay" \
  "mark other.log ubuntu-look-install-notes.log ubuntu-look-notes.log mark=removed" "$(logs_removed)"

### The uninstall removes the folder version 1.0 left in the home
legacy() {  # legacy <settings pending: 0|1>
  (
    d="$T/legacy"; rm -rf "$d"; mkdir -p "$d/home/.ubuntu-look-backup" "$d/home/Documents"
    echo old > "$d/home/.ubuntu-look-backup/record"; echo mine > "$d/home/Documents/notes.txt"
    for f in step_extensions step_restore_tiling_keybindings step_restore_gnome_settings \
             step_clear_extension_state step_terminal_shortcut; do eval "$f() { :; }"; done
    message() { :; }
    HOME="$d/home" LEGACY_BACKUP_DIR="$d/home/.ubuntu-look-backup" DATA_HOME="$d/home/.local/share"
    INSTALLED_MANIFEST="$d/manifest" SYS_RECORDS="$d/none" SETTINGS_RESET_USERS="$d/none/users"
    UBUNTU_LOOK_ANIMATIONS="" USER_PENDING="$1" RUN_USER=tester DONE=() SKIPPED=() GUESSED=()
    uninstall_user_settings > /dev/null 2>&1
    (cd "$d/home" && find . -mindepth 1 | LC_ALL=C sort -f | xargs)
  )
}
is "uninstall: the old backup folder goes, the user's files stay" \
  "./Documents ./Documents/notes.txt" "$(legacy 0)"
is "uninstall: with settings still to reset the old folder is kept" \
  "./.ubuntu-look-backup ./.ubuntu-look-backup/record ./Documents ./Documents/notes.txt" "$(legacy 1)"

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
    # All three or none: a hook that took only some of them is neither.
    n=0; for f in "$SHELL_MODE_FILE" "$d/ubuntu.desktop" "$d/ubuntu-xorg.desktop"; do [ ! -e "$f" ] || n=$((n + 1)); done
    case "$n" in 3) s=kept ;; 0) s=gone ;; *) s="partly($n of 3)" ;; esac
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
