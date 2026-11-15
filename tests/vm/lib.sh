# shellcheck shell=bash disable=SC2034
# Shared by make-vm.sh, vm-test.sh and vm-upgrade-test.sh: where the test VM
# lives and how to start it and talk to it.
VM="${UBUNTU_LOOK_VM:-$HOME/ubuntu-look-vm}"
VM_PORT="${UBUNTU_LOOK_VM_PORT:-2222}"
VM_USER=tester
# The VM's throwaway account; the VM is reachable from this machine only.
VM_PASSWORD="test"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
# This machine's own ssh settings and agent keys stay out of it.
SSH_COMMON=(-F /dev/null -i "$VM/id_vm" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
SSH_OPTS=("${SSH_COMMON[@]}" -p "$VM_PORT")
SCP_OPTS=(-q "${SSH_COMMON[@]}" -P "$VM_PORT")

need_tools() {
  local t
  for t in qemu-system-x86_64 qemu-img ssh scp python3 "$@"; do
    command -v "$t" > /dev/null 2>&1 || { echo "missing: $t" >&2; exit 2; }
  done
  [ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "no access to /dev/kvm" >&2; exit 2; }
  [ -f "$OVMF_CODE" ] || { echo "missing: $OVMF_CODE (package ovmf)" >&2; exit 2; }
}

# Start the VM in the background; extra arguments go to qemu.
start_vm() {
  ( cd "$VM" && exec qemu-system-x86_64 -name ubuntu-look-test -machine q35,accel=kvm -cpu host \
      -smp 4 -m 4096 \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file=vars.fd \
      -drive if=virtio,format=qcow2,file=disk.qcow2,discard=unmap \
      -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${VM_PORT}-:22" -device virtio-net-pci,netdev=n0 \
      -device virtio-vga -display none -device qemu-xhci -device usb-tablet \
      -monitor unix:mon.sock,server,nowait "$@" ) > /dev/null 2>&1 &
  VM_PID=$!
}

vm_running() { [ -n "${VM_PID:-}" ] && kill -0 "$VM_PID" 2> /dev/null; }

# Run a command in the VM; copy files to the VM user's home.
in_vm() { ssh "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$@"; }
to_vm() { scp "${SCP_OPTS[@]}" "$@" "${VM_USER}@127.0.0.1:"; }
vm_sudo() { in_vm "echo $VM_PASSWORD | sudo -S -p '' $*"; }

# Wait until the VM user's GNOME session runs; fails after $1 seconds.
# shellcheck disable=SC2120
wait_desktop() {
  # By the clock: a connection that times out takes longer than the pause.
  local end=$((SECONDS + ${1:-300}))
  until in_vm 'pgrep -u "$USER" -x gnome-shell > /dev/null' 2> /dev/null; do
    vm_running || return 1
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 3
  done
  sleep 15
}

# Wait until the VM has booted again since boot id $1. Without that id
# nothing tells a new boot from the old one.
wait_reboot() {
  local was="$1" end=$((SECONDS + ${2:-300})) now
  [ -n "$was" ] || return 1
  while :; do
    now="$(in_vm 'cat /proc/sys/kernel/random/boot_id' 2> /dev/null)"
    [ -n "$now" ] && [ "$now" != "$was" ] && break
    vm_running || return 1
    [ "$SECONDS" -lt "$end" ] || return 1
    sleep 3
  done
  wait_desktop
}

boot_id() { in_vm 'cat /proc/sys/kernel/random/boot_id'; }

stop_vm() {
  vm_running || return 0
  vm_sudo systemctl poweroff > /dev/null 2>&1
  local left=60
  while vm_running && [ "$left" -gt 0 ]; do sleep 2; left=$((left - 2)); done
  vm_running && kill "$VM_PID" 2> /dev/null
  wait "$VM_PID" 2> /dev/null
}

# Megabytes free where the VM lives; nothing when that cannot be read.
vm_free_mb() { df -Pm "$VM" 2> /dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }'; }

# Start the VM from its clean snapshot. A disk that test runs have grown past
# 16 GB is first written out again without the unused blocks, when this
# machine has room for the copy: twice the VM's virtual disk is always enough.
reset_vm() {
  local size free
  # What an interrupted compaction left.
  rm -f "$VM/disk-new.qcow2"
  if ! qemu-img snapshot -a fresh-install "$VM/disk.qcow2"; then
    echo "$VM/disk.qcow2 has no snapshot 'fresh-install'; build the VM again with: bash tests/vm/make-vm.sh" >&2
    return 1
  fi
  size="$(du -m "$VM/disk.qcow2" | cut -f1)"
  free="$(vm_free_mb)"
  if [ "${size:-0}" -gt 16384 ]; then
    if [ "${free:-0}" -gt 51200 ] || [ "${free:-0}" -gt "$size" ]; then
      # The copy gets its snapshot before it takes the disk's place, so the
      # disk in use always has one. A copy that fails leaves the disk as it is.
      if qemu-img convert -O qcow2 "$VM/disk.qcow2" "$VM/disk-new.qcow2" \
         && qemu-img snapshot -c fresh-install "$VM/disk-new.qcow2" \
         && mv -f "$VM/disk-new.qcow2" "$VM/disk.qcow2"; then
        :
      else
        rm -f "$VM/disk-new.qcow2"
        echo "Could not compact $VM/disk.qcow2; continuing with it as it is." >&2
      fi
    else
      echo "Not enough free space to compact $VM/disk.qcow2; continuing with it as it is." >&2
    fi
  fi
  cp "$VM/vars-fresh.fd" "$VM/vars.fd"
}

# Stop before a test fills this machine's disk: a run needs room to grow.
need_free_space() {
  local free
  free="$(vm_free_mb)"
  [ -n "$free" ] || { echo "Could not read the free space where $VM lives." >&2; exit 2; }
  [ "$free" -ge "$1" ] && return 0
  echo "Less than $1 MB free where $VM lives; free some space first." >&2
  exit 2
}

# Stop unless the VM that make-vm.sh builds is there.
need_vm() {
  [ -f "$VM/disk.qcow2" ] && [ -f "$VM/vars-fresh.fd" ] && [ -f "$VM/id_vm" ] && return 0
  echo "No test VM in $VM. Build it with: bash tests/vm/make-vm.sh" >&2
  exit 2
}

# The test's bookkeeping: transcripts and states go to $RUN.
PASS=0
FAIL=0
start_run() {
  RUN="$VM/$1"
  rm -rf "$RUN"; mkdir -p "$RUN"
}

# check <name> <command...>: the command succeeds.
check() {
  local name="$1"; shift
  if "$@" > /dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  ok    $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $name"
  fi
}

# Run a command in the VM on a terminal, answering the script's prompts:
#   run <name> <y|n> <countdown key: enter, ctrlc or ""> <command...>
# The transcript, without colours, lands in $RUN/<name>.txt. A command that
# does not end in time counts as a failed check.
run() {
  local name="$1" answer="$2" key="$3" rc; shift 3
  VM_PASSWORD="$VM_PASSWORD" DRIVE_COUNTDOWN="$key" python3 tests/vm/drive.py "$RUN/$name.raw" "$answer" 2400 -- \
    ssh -tt "${SSH_OPTS[@]}" "${VM_USER}@127.0.0.1" "$* ; echo \"SCRIPT EXIT \$?\""; rc=$?
  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL  $name: the command was not driven to its end (drive.py status $rc)"
  fi
  sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$RUN/$name.raw" | tr '\r' '\n' | grep -v '^\s*$' > "$RUN/$name.txt"
}
said() { grep -qF -- "$2" "$RUN/$1.txt"; }
unsaid() { ! grep -qF -- "$2" "$RUN/$1.txt"; }

# Record the VM's state as <name>. A state that cannot be recorded counts as
# a failed check: the checks on it would have nothing to read.
state() {
  rm -rf "${RUN:?}/$1"
  if in_vm "rm -rf state/$1; bash state.sh state/$1" \
     && scp -r "${SCP_OPTS[@]}" "${VM_USER}@127.0.0.1:state/$1" "$RUN/" && [ -d "$RUN/$1" ]; then
    return 0
  fi
  FAIL=$((FAIL + 1)); echo "  FAIL  recording the VM's state '$1'"
  return 1
}
# same <a> <b> <file...>: those files match.  differ: they are there and differ.
same() {
  local a="$1" b="$2" f; shift 2
  for f in "$@"; do diff -q "$RUN/$a/$f" "$RUN/$b/$f" > /dev/null || return 1; done
}
differ() {
  local a="$1" b="$2" f; shift 2
  for f in "$@"; do
    [ -f "$RUN/$a/$f" ] && [ -f "$RUN/$b/$f" ] || return 1
    ! diff -q "$RUN/$a/$f" "$RUN/$b/$f" > /dev/null || return 1
  done
}
# state_lacks <state> <file> <grep arguments...>: the recorded file is there
# and nothing in it matches.
state_lacks() {
  local f="$RUN/$1/$2"; shift 2
  [ -f "$f" ] && ! grep -q "$@" "$f"
}

# Reboot the VM by hand and wait for its desktop.
reboot_vm() {
  local boot
  boot="$(boot_id)"
  vm_sudo systemctl reboot > /dev/null 2>&1
  wait_reboot "$boot" 400
}

# The checks every installed look must pass, on state <name>.
check_look_installed() {
  local s="$1" ext
  check "the session is Ubuntu's"        grep -qx 'XDG_CURRENT_DESKTOP=ubuntu:GNOME' "$RUN/$s/session"
  check "the session mode is ubuntu"     grep -qx 'GNOME_SHELL_SESSION_MODE=ubuntu' "$RUN/$s/session"
  for ext in ubuntu-dock@ubuntu.com ding@rastersoft.com tiling-assistant@ubuntu.com \
             ubuntu-appindicators@ubuntu.com ubuntu-look-theme@ubuntu-look; do
    check "extension $ext is on"         grep -qx "$ext" "$RUN/$s/extensions"
  done
  check "the kernel runs with splash"    grep -qw splash "$RUN/$s/cmdline"
  check "the Ubuntu pin is in place"     grep -q ubuntu-themes "$RUN/$s/apt-files"
  check "Yaru is the GTK theme"          in_vm "DCONF_PROFILE=ubuntu-look dconf read /org/gnome/desktop/interface/gtk-theme | grep -q Yaru"
  check "the wallpaper file is there"    in_vm '[ -f /usr/share/backgrounds/warty-final-ubuntu.png ]'
}

# The checks after an uninstall and a reboot, on state <name>.
check_look_gone() {
  local s="$1"
  check "the session is GNOME's"         grep -qx 'XDG_CURRENT_DESKTOP=GNOME' "$RUN/$s/session"
  check "no setting names Yaru"          state_lacks "$s" dconf -i yaru
  check "no package of the look is left" state_lacks "$s" packages -E '^(yaru-theme|ubuntu-wallpapers|fonts-ubuntu|gnome-shell-ubuntu-extensions|gnome-shell-extension-ubuntu)'
  check "no apt source or pin is left"   state_lacks "$s" apt-files ubuntu
  check "the kernel runs without splash" state_lacks "$s" cmdline -w splash
  check "no file of the look is left"    in_vm '[ -z "$(find /etc /usr/local /var/lib -iname "*ubuntu-look*" -o -iname "*ubuntu_look*" 2> /dev/null)" ]'
}

finish_run() {
  echo ""
  echo "${PASS} passed, ${FAIL} failed — transcripts and states: $RUN"
  [ "$FAIL" -eq 0 ]
}
