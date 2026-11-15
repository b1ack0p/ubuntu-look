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
need_vm
need_free_space 12288
TO="${UBUNTU_LOOK_VM_UPGRADE_TO:-forky}"
case "$TO" in *[!a-z]*|"") echo "UBUNTU_LOOK_VM_UPGRADE_TO is not a Debian codename: $TO" >&2; exit 2 ;; esac
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
# A stopped test leaves through its exit trap, so the VM does not stay up.
trap 'exit 143' INT TERM HUP

# The major version in "GNOME Shell 48.4".
shell_major() { local v="${1##* }"; echo "${v%%[!0-9]*}"; }

# One scenario, $1, start to end.
scenario() {
  local how="$1" from boot shell_before shell_after
  start_run "upgrade-${how}"
  echo "== ${how}: starting the VM from its clean snapshot..."
  reset_vm || exit 2
  start_vm
  wait_desktop 400 || { echo "The VM's desktop did not come up." >&2; exit 2; }
  to_vm ubuntu-look.sh tests/vm/state.sh tests/vm/upgrade.sh \
    || { echo "Could not copy the script to the VM." >&2; exit 2; }
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
    # The apt hook takes the Ubuntu session away once GNOME Shell's major
    # version changes, so the login lands in Debian's GNOME until the script
    # has run again. Within one major version the Ubuntu session stays.
    echo "  note  session after the upgrade: $(tr '\n' ' ' < "$RUN/upgraded/session" 2> /dev/null)"
    if [ "$(shell_major "$shell_before")" != "$(shell_major "$shell_after")" ]; then
      check "the login is Debian's GNOME session" grep -qx 'XDG_CURRENT_DESKTOP=GNOME' "$RUN/upgraded/session"
    else
      check "the login is still the Ubuntu session" grep -qx 'XDG_CURRENT_DESKTOP=ubuntu:GNOME' "$RUN/upgraded/session"
    fi
  fi

  echo "Run the script on ${TO}"
  boot="$(boot_id)"
  run reinstall y enter bash ubuntu-look.sh
  check "the install finished"           said reinstall "All steps finished"
  check "Ubuntu's style is read from its packages" said reinstall "(read from its packages)"
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
  run uninstall-final y ctrlc bash ubuntu-look.sh --uninstall
  check "the uninstall exits with 0"     said uninstall-final "SCRIPT EXIT 0"
  check "the VM reboots by hand"         reboot_vm
  state gone
  check_look_gone gone
  stop_vm
}

for s in $scenarios; do scenario "$s"; done
finish_run
