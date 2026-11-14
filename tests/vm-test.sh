#!/bin/bash
# Real-run test of ubuntu-look.sh in a Debian VM: install, repeat run,
# --refresh, --uninstall and a second install, each for real, with the VM
# rebooting where the script reboots. Takes about 15 minutes.
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
need_free_space 4096
[ -f "$VM/disk.qcow2" ] && [ -f "$VM/vars-fresh.fd" ] && [ -f "$VM/id_vm" ] \
  || { echo "No test VM in $VM. Build it with: bash tests/vm/make-vm.sh" >&2; exit 2; }
if (exec 3<> "/dev/tcp/127.0.0.1/${VM_PORT}") 2> /dev/null; then
  echo "Port ${VM_PORT} is in use: is the test VM already running?" >&2
  exit 2
fi

start_run last-run

trap 'stop_vm' EXIT
echo "Starting the VM from its clean snapshot..."
reset_vm || exit 2
start_vm
wait_desktop 400 || { echo "The VM's desktop did not come up." >&2; exit 2; }
to_vm ubuntu-look.sh tests/vm/state.sh
state fresh

echo "Rejected command lines"
for bad in --download --offline --prepare-upgrade "--refresh --uninstall" bogus; do
  check "'$bad' is rejected" in_vm "! bash ubuntu-look.sh $bad"
done
check "--refresh needs an install"     in_vm '! bash ubuntu-look.sh --refresh < /dev/null'
run decline n "" bash ubuntu-look.sh
check "answering no changes nothing"   said decline "Aborted."
check "answering no leaves no records" in_vm '[ ! -e /var/lib/ubuntu-look ]'

echo "First install, Enter at the countdown"
boot="$(boot_id)"
run install1 y enter bash ubuntu-look.sh
check "the install finished"           said install1 "All steps finished"
check "nothing was left undone"        unsaid install1 "Not done"
check "Enter reboots at once"          said install1 "Rebooting now."
check "the countdown stopped early"    unsaid install1 "   30 "
check "the VM rebooted"                wait_reboot "$boot"
state installed
check_look_installed installed
check "the boot splash theme changed"  eval '! same fresh installed plymouth-theme'

echo "Repeat run and --refresh"
run rerun y "" bash ubuntu-look.sh
check "a repeat run changes nothing"   said rerun "Nothing changed"
check "a repeat run does not reboot"   unsaid rerun "Rebooting in"
run refresh y "" bash ubuntu-look.sh --refresh
check "--refresh finds nothing to do"  said refresh "up to date"
state rerun
check "packages unchanged by both"     same installed rerun packages grub apt-files

echo "Uninstall, Ctrl-C at the countdown"
boot="$(boot_id)"
run uninstall y ctrlc bash ubuntu-look.sh --uninstall
check "the uninstall asks for a reboot" said uninstall "REBOOT REQUIRED"
check "Ctrl-C cancels the reboot"      said uninstall "Reboot cancelled"
check "the countdown stopped early"    unsaid uninstall "   30 "
check "the uninstall exits with 0"     said uninstall "SCRIPT EXIT 0"
check "the VM did not reboot"          [ "$(boot_id)" = "$boot" ]
check "the VM reboots by hand"         reboot_vm
state uninstalled
check "packages are as before the install"  same fresh uninstalled packages manual
check "boot settings are as before"    same fresh uninstalled grub plymouthd.conf plymouth-theme cmdline
check "apt sources are as before"      same fresh uninstalled apt-files
check "sessions are as before"         same fresh uninstalled sessions session
check "system dconf is as before"      same fresh uninstalled dconf-system records
check_look_gone uninstalled

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

finish_run
