#!/bin/bash
# Real-run test of ubuntu-look.sh in a Debian VM: install, repeat run,
# --refresh, --reset, a plain run's reset, --uninstall and a second install, each for real, with
# the VM rebooting where the script reboots. Takes 10 to 20 minutes.
#
#   bash tests/vm/make-vm.sh     once: builds the VM (about 25 minutes, 7 GB)
#   bash tests/vm-test.sh        every run starts from the VM's clean snapshot
#
# The VM lives in $UBUNTU_LOOK_VM (default ~/ubuntu-look-vm). Transcripts and
# recorded states of the last run are kept in its "last-run" folder.
# Nothing outside the VM is changed.
#
# For another Debian release, build a second VM and name it for both:
#   UBUNTU_LOOK_VM=~/ubuntu-look-vm-forky UBUNTU_LOOK_VM_RELEASE=forky bash tests/vm/make-vm.sh
#   UBUNTU_LOOK_VM=~/ubuntu-look-vm-forky bash tests/vm-test.sh

# shellcheck disable=SC2016  # commands quoted for the VM's shell
cd "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
. tests/vm/lib.sh
need_tools
need_vm
need_free_space 4096
if (exec 3<> "/dev/tcp/127.0.0.1/${VM_PORT}") 2> /dev/null; then
  echo "Port ${VM_PORT} is in use: is the test VM already running?" >&2
  exit 2
fi

start_run last-run

trap 'stop_vm' EXIT
# A stopped test leaves through its exit trap, so the VM does not stay up.
trap 'exit 143' INT TERM HUP
echo "Starting the VM from its clean snapshot..."
reset_vm || exit 2
start_vm
wait_desktop 400 || { echo "The VM's desktop did not come up." >&2; exit 2; }
to_vm ubuntu-look.sh tests/vm/state.sh || { echo "Could not copy the script to the VM." >&2; exit 2; }
state fresh

# rejected <arguments> <text>: the script fails on them and says <text>.
rejected() {
  local out
  out="$(in_vm "bash ubuntu-look.sh $1 < /dev/null 2>&1")" && return 1
  grep -qF -- "$2" <<< "$out"
}
# The names in the VM user's home, the script's run logs apart.
home_names() { in_vm 'ls -A | grep -v "^ubuntu-look-.*\.log$"'; }

echo "Rejected command lines"
for bad in --download --offline --prepare-upgrade; do
  check "'$bad' is rejected"           rejected "$bad" "is no longer part of this script"
done
check "two commands are rejected"      rejected "--refresh --uninstall" "Give only one of"
check "'bogus' is rejected"            rejected bogus "Unknown argument"
check "an empty argument is rejected"  rejected "''" "An empty argument was given"
check "a switch takes only 0 or 1"     eval 'in_vm "UBUNTU_LOOK_REBOOT=no bash ubuntu-look.sh < /dev/null 2>&1" | grep -qF "takes 0 or 1"'
check "--refresh needs an install"     rejected --refresh "not installed"
check "--reset needs an install"       rejected --reset "not installed"
run decline n "" bash ubuntu-look.sh
check "answering no changes nothing"   said decline "Aborted."
check "answering no leaves no records" in_vm '[ ! -e /var/lib/ubuntu-look ]'
check "a declined run keeps no log"    in_vm '! ls ubuntu-look-*.log'

echo "First install, Enter at the countdown"
boot="$(boot_id)"
run install1 y enter bash ubuntu-look.sh
check "the install finished"           said install1 "All steps finished"
check "nothing was left undone"        unsaid install1 "Not done"
check "Ubuntu's style is read from its packages" said install1 "(read from its packages)"
check "Enter reboots at once"          said install1 "Rebooting now."
check "the countdown stopped early"    unsaid install1 "   30 "
check "the VM rebooted"                wait_reboot "$boot"
state installed
check "the style is on record"         in_vm 'grep -qE "^[a-z]+ prefer-(light|dark) " /var/lib/ubuntu-look/records/ubuntu-style.txt'
check_look_installed installed
check "the boot splash theme changed"  differ fresh installed plymouth-theme
check "font smoothing uses the file Ubuntu enables" in_vm 'grep -q "conf.avail/10-sub-pixel-rgb.conf" /usr/local/share/ubuntu-look/fonts.conf'
check "the session's fonts are sub-pixel rgb" in_vm 'FONTCONFIG_FILE=/usr/local/share/ubuntu-look/fonts.conf fc-match -v sans | grep -q "rgba: 1"'
check "Ubuntu's session details are on record" in_vm 'grep -q "^terminal: <Primary><Alt>t$" /var/lib/ubuntu-look/records/ubuntu-session-extras.txt'

echo "Repeat run and --refresh"
# What the session's extensions stored by themselves: a repeat run must not
# count it as the user's own settings.
in_vm 'dconf dump /org/gnome/shell/extensions/' > "$RUN/extension-settings.txt" 2> /dev/null
run rerun y "" bash ubuntu-look.sh
check "a repeat run changes nothing"   said rerun "Nothing changed"
check "a repeat run does not reboot"   unsaid rerun "Rebooting in"
run refresh y "" bash ubuntu-look.sh --refresh
check "--refresh finds nothing to do"  said refresh "up to date"
# The summary's heading: a declined refresh ends before it, with its own
# "Nothing changed".
check "the refresh ran to its summary" said refresh "SUMMARY"
check "its repair changes nothing"     said refresh "Nothing changed"
run refresh-no n "" bash ubuntu-look.sh --refresh
check "a declined --refresh says so"   said refresh-no "Nothing changed."
check "it ends before the summary"     unsaid refresh-no "SUMMARY"
check "it exits with 1"                said refresh-no "SCRIPT EXIT 1"
# A setting of the user's own and a missing file of the look's: --refresh
# puts the file back and leaves the setting.
in_vm "dconf write /org/gnome/desktop/wm/preferences/button-layout \"'close:'\""
vm_sudo rm -f /usr/local/share/gnome-shell/modes/ubuntu.json
run repair y "" UBUNTU_LOOK_REBOOT=0 bash ubuntu-look.sh --refresh
check "--refresh repairs a missing file" in_vm '[ -f /usr/local/share/gnome-shell/modes/ubuntu.json ]'
check "--refresh keeps the user's setting" in_vm 'dconf read /org/gnome/desktop/wm/preferences/button-layout | grep -q close:'
in_vm 'dconf reset /org/gnome/desktop/wm/preferences/button-layout'
state rerun
check "packages unchanged by both"     same installed rerun packages grub apt-files

echo "--reset, after settings changed by hand"
in_vm "mkdir -p Documents && echo mine > Documents/notes.txt
       dconf write /org/gnome/desktop/interface/gtk-theme \"'Adwaita'\"
       dconf write /org/gnome/desktop/wm/preferences/button-layout \"'close:'\"
       dconf write /org/gnome/shell/extensions/dash-to-dock/dock-position \"'BOTTOM'\"
       dconf write /org/gnome/shell/favorite-apps \"['org.gnome.Nautilus.desktop']\""
check "the settings were changed"      in_vm 'dconf read /org/gnome/desktop/interface/gtk-theme | grep -q Adwaita'
# shellcheck disable=SC2034  # read in the check below
home_before="$(home_names)"
run reset y "" UBUNTU_LOOK_REBOOT=0 bash ubuntu-look.sh --reset
check "the reset finished"             said reset "All steps finished"
check "nothing was left undone"        unsaid reset "Not done"
check "it reset the user's settings"   said reset "of your own settings reset to the look's defaults"
check "the theme is the look's again"  in_vm '[ -z "$(dconf read /org/gnome/desktop/interface/gtk-theme)" ]'
check "the window buttons too"         in_vm '[ -z "$(dconf read /org/gnome/desktop/wm/preferences/button-layout)" ]'
check "the dock's settings too"        in_vm '[ -z "$(dconf list /org/gnome/shell/extensions/dash-to-dock/)" ]'
check "Yaru is the GTK theme"          in_vm "DCONF_PROFILE=ubuntu-look dconf read /org/gnome/desktop/interface/gtk-theme | grep -q Yaru"
check "another setting is kept"        in_vm 'dconf read /org/gnome/shell/favorite-apps | grep -q Nautilus'
check "the user's file is kept"        in_vm '[ "$(cat Documents/notes.txt)" = mine ]'
check "no backup folder in the home"   in_vm '[ ! -e .ubuntu-look-backup ]'
check "nothing new in the home folder" eval '[ -n "$home_before" ] && [ "$(home_names)" = "$home_before" ]'
state reset
check "packages unchanged by the reset" same installed reset packages grub apt-files
run reset2 y "" UBUNTU_LOOK_REBOOT=0 bash ubuntu-look.sh --reset
check "a second reset changes nothing" said reset2 "Nothing changed"

echo "A plain run resets too"
in_vm "dconf write /org/gnome/desktop/wm/preferences/button-layout \"'close:'\""
run rerun2 y "" UBUNTU_LOOK_REBOOT=0 bash ubuntu-look.sh
check "the plain run finished"         said rerun2 "All steps finished"
check "it reset the user's setting"    said rerun2 "of your own settings reset to the look's defaults"
check "the window buttons are the look's" in_vm '[ -z "$(dconf read /org/gnome/desktop/wm/preferences/button-layout)" ]'
check "another setting is kept"        in_vm 'dconf read /org/gnome/shell/favorite-apps | grep -q Nautilus'
# Left for the uninstall: a setting of the look's that it resets, the
# favourites and the file that it keeps, and a folder as version 1.0 left.
in_vm "dconf write /org/gnome/desktop/wm/preferences/button-layout \"'close:'\"
       mkdir -p .ubuntu-look-backup && echo old > .ubuntu-look-backup/record"

echo "Uninstall, Ctrl-C at the countdown"
boot="$(boot_id)"
run uninstall y ctrlc bash ubuntu-look.sh --uninstall
check "the uninstall asks for a reboot" said uninstall "REBOOT REQUIRED"
check "Ctrl-C cancels the reboot"      said uninstall "Reboot cancelled"
check "the countdown stopped early"    unsaid uninstall "   30 "
check "the uninstall exits with 0"     said uninstall "SCRIPT EXIT 0"
# A reboot under way would still answer with the old boot for a moment.
check "the VM did not reboot"          eval 'sleep 10; [ -n "$boot" ] && [ "$(boot_id)" = "$boot" ]'
check "the VM reboots by hand"         reboot_vm
state uninstalled
check "packages are as before the install"  same fresh uninstalled packages manual
check "boot settings are as before"    same fresh uninstalled grub plymouthd.conf plymouth-theme cmdline
check "apt sources are as before"      same fresh uninstalled apt-files
check "sessions are as before"         same fresh uninstalled sessions session
check "system dconf is as before"      same fresh uninstalled dconf-system records
check_look_gone uninstalled
check "the look's settings are Debian's" in_vm '[ -z "$(dconf read /org/gnome/desktop/wm/preferences/button-layout)" ]'
check "another setting is kept"        in_vm 'dconf read /org/gnome/shell/favorite-apps | grep -q Nautilus'
check "the user's file is kept"        in_vm '[ "$(cat Documents/notes.txt)" = mine ]'
check "version 1.0's backup folder is gone" in_vm '[ ! -e .ubuntu-look-backup ]'
check "the run logs are gone"          in_vm '! ls ubuntu-look-*.log'
in_vm 'dconf reset /org/gnome/shell/favorite-apps; rm -rf Documents'

echo "Second install, UBUNTU_LOOK_REBOOT=0"
run install2 y "" UBUNTU_LOOK_REBOOT=0 bash ubuntu-look.sh
check "the install finished"           said install2 "All steps finished"
check "it only names the command"      said install2 "Run: sudo reboot"
check "there is no countdown"          unsaid install2 "Rebooting in"
check "the VM reboots by hand"         reboot_vm
state reinstalled
check "same packages as the first install"  same installed reinstalled packages
check "same boot and apt settings"     same installed reinstalled grub plymouth-theme apt-files cmdline
check "same session and extensions"    same installed reinstalled session extensions sessions

echo "Second uninstall, the countdown runs out"
# The tiling assistant holds the user's own shortcuts while it runs; here it
# is told the user had Super+K for maximize before it took the key over.
check "the tiling assistant holds Super+Up" in_vm 'dconf read /org/gnome/desktop/wm/keybindings/maximize | grep -qF "[]"'
in_vm 'bash -s' << 'SAVED'
dconf write /org/gnome/shell/extensions/tiling-assistant/overridden-settings "{'org.gnome.desktop.wm.keybindings.maximize': <['<Super>k']>, 'org.gnome.desktop.wm.keybindings.unmaximize': <@mb nothing>, 'org.gnome.mutter.keybindings.toggle-tiled-left': <@mb nothing>, 'org.gnome.mutter.keybindings.toggle-tiled-right': <@mb nothing>, 'org.gnome.mutter.edge-tiling': <@mb nothing>}"
SAVED
boot="$(boot_id)"
run uninstall2 y "" bash ubuntu-look.sh --uninstall
check "the user's own shortcut is put back" said uninstall2 "tiling setting(s) of your own"
check "the countdown ran to its end"   said uninstall2 "   10 "
check "it reboots by itself"           said uninstall2 "Rebooting now."
check "the VM rebooted"                wait_reboot "$boot"
check "maximize is the user's Super+K" in_vm 'dconf read /org/gnome/desktop/wm/keybindings/maximize | grep -qF "<Super>k"'
check "unmaximize is Debian's default" in_vm '[ -z "$(dconf read /org/gnome/desktop/wm/keybindings/unmaximize)" ]'
check "the run logs are gone"          in_vm '! ls ubuntu-look-*.log'
state uninstalled2
check_look_gone uninstalled2

finish_run
