#!/bin/bash
# Real-run test of a Debian release upgrade with the Ubuntu look, in the test
# VM. Two scenarios, each from the VM's clean snapshot:
#
#   uninstall-first  the README's way: uninstall, upgrade Debian, install again
#   keep             the look stays installed through the upgrade, then the
#                    script runs again
#
#   bash tests/vm-upgrade-test.sh [uninstall-first|keep]     default: both
#
# The VM is the one tests/vm/make-vm.sh builds; it is upgraded to
# $UBUNTU_LOOK_VM_UPGRADE_TO (default forky). Each scenario takes about 40
# minutes and downloads a full release upgrade; the VM's disk grows by about
# 8 GB until the next run resets it. Transcripts and states are kept in the
# VM folder's "upgrade-<scenario>" folders. Nothing outside the VM is changed.

# shellcheck disable=SC2016  # commands quoted for the VM's shell
cd "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
. tests/vm/lib.sh
need_tools
need_free_space 12288
TO="${UBUNTU_LOOK_VM_UPGRADE_TO:-forky}"
[ -f "$VM/disk.qcow2" ] && [ -f "$VM/vars-fresh.fd" ] && [ -f "$VM/id_vm" ] \
  || { echo "No test VM in $VM. Build it with: bash tests/vm/make-vm.sh" >&2; exit 2; }
if (exec 3<> "/dev/tcp/127.0.0.1/${VM_PORT}") 2> /dev/null; then
  echo "Port ${VM_PORT} is in use: is the test VM already running?" >&2
  exit 2
fi
case "${1:-both}" in
  both) scenarios="uninstall-first keep" ;;
  uninstall-first|keep) scenarios="$1" ;;
  *) echo "usage: bash tests/vm-upgrade-test.sh [uninstall-first|keep]" >&2; exit 2 ;;
esac

trap 'stop_vm' EXIT

# One scenario, $1, start to end.
scenario() {
  local how="$1" from boot shell_before shell_after
  start_run "upgrade-${how}"
  echo "== ${how}: starting the VM from its clean snapshot..."
  reset_vm || exit 2
  start_vm
  wait_desktop 400 || { echo "The VM's desktop did not come up." >&2; exit 2; }
  to_vm ubuntu-look.sh tests/vm/state.sh tests/vm/upgrade.sh
  from="$(in_vm '. /etc/os-release; echo "$VERSION_CODENAME"')"
  shell_before="$(in_vm 'gnome-shell --version')"

  echo "Install on ${from}"
  boot="$(boot_id)"
  run install y enter bash ubuntu-look.sh
  check "the install finished"           said install "All steps finished"
  check "the VM rebooted"                wait_reboot "$boot"
  state installed
  check_look_installed installed

  if [ "$how" = uninstall-first ]; then
    echo "Uninstall before the upgrade"
    boot="$(boot_id)"
    run uninstall y enter bash ubuntu-look.sh --uninstall
    check "nothing was left unfinished"  unsaid uninstall "Could not"
    check "Enter reboots at once"        said uninstall "Rebooting now."
    check "the VM rebooted"              wait_reboot "$boot"
    state uninstalled
    check_look_gone uninstalled
  fi

  echo "Upgrade Debian from ${from} to ${TO}"
  vm_sudo "bash upgrade.sh $TO" > "$RUN/upgrade.txt" 2>&1
  check "apt finishes the upgrade"       [ "$?" -eq 0 ]
  check "the desktop comes back"         reboot_vm
  check "the VM runs ${TO}"              in_vm ". /etc/os-release; [ \"\$VERSION_CODENAME\" = $TO ]"
  shell_after="$(in_vm 'gnome-shell --version')"
  echo "  note  ${shell_before} -> ${shell_after}"
  check "GNOME Shell was upgraded"       [ "$shell_before" != "$shell_after" ]
  state upgraded
  if [ "$how" = keep ]; then
    # The apt hook takes the Ubuntu session away once GNOME Shell changes, so
    # the login lands in Debian's GNOME until the script has run again.
    echo "  note  session after the upgrade: $(tr '\n' ' ' < "$RUN/upgraded/session")"
    check "a desktop session runs"       in_vm 'pgrep -u "$USER" -x gnome-shell'
  fi

  echo "Run the script on ${TO}"
  boot="$(boot_id)"
  run reinstall y enter bash ubuntu-look.sh
  check "the install finished"           said reinstall "All steps finished"
  check "nothing was left undone"        unsaid reinstall "Not done"
  if said reinstall "Rebooting now."; then
    check "the VM rebooted"              wait_reboot "$boot"
  else
    check "the VM reboots by hand"       reboot_vm
  fi
  state final
  check_look_installed final
  run rerun y "" bash ubuntu-look.sh
  check "a repeat run changes nothing"   said rerun "Nothing changed"

  echo "Uninstall on ${TO}"
  run uninstall-final y "" UBUNTU_LOOK_REBOOT=0 bash ubuntu-look.sh --uninstall
  check "the uninstall exits with 0"     said uninstall-final "SCRIPT EXIT 0"
  check "the VM reboots by hand"         reboot_vm
  state gone
  check_look_gone gone
  stop_vm
}

for s in $scenarios; do scenario "$s"; done
finish_run
