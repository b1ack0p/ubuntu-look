#!/bin/bash
# Build the test VM for tests/vm-test.sh: an unattended Debian 13 (trixie)
# GNOME install from Debian's network installer, with a user that logs in
# automatically and an SSH key for the tests. Takes about 25 minutes and 7 GB.
#
#   bash tests/vm/make-vm.sh
#
# The VM lands in $UBUNTU_LOOK_VM (default ~/ubuntu-look-vm); its disk keeps a
# snapshot "fresh-install" that every test run starts from. Delete the folder
# to remove the VM.
#
# $UBUNTU_LOOK_VM_RELEASE names another Debian release, such as forky: the VM
# is then upgraded to it before the snapshot is taken (about 20 minutes more).
# Debian 13's installer is used either way, since the installer of the
# testing release is often out of step with its archive.

cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck disable=SC1091
. tests/vm/lib.sh
need_tools curl cpio gzip ssh-keygen sha256sum
RELEASE="${UBUNTU_LOOK_VM_RELEASE:-trixie}"
mkdir -p "$VM"
if [ "$RELEASE" = trixie ]; then need_free_space 10240; else need_free_space 16384; fi
REPO="$PWD"
[ -f "$OVMF_VARS" ] || { echo "missing: $OVMF_VARS (package ovmf)" >&2; exit 2; }
[ ! -e "$VM/disk.qcow2" ] || { echo "$VM already holds a VM; delete the folder to build a new one." >&2; exit 2; }
case "$RELEASE" in *[!a-z]*|"") echo "UBUNTU_LOOK_VM_RELEASE is not a Debian codename: $RELEASE" >&2; exit 2 ;; esac
# However the build ends, the VM does not stay running and holding its port.
trap 'stop_vm' EXIT

IMAGES=https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images
INSTALLER_PATH=netboot/debian-installer/amd64
INSTALLER="$IMAGES/$INSTALLER_PATH"
mkdir -p "$VM" && cd "$VM" || exit 1

echo "Downloading Debian's network installer..."
curl -fsSLO "$INSTALLER/linux" && curl -fsSLO "$INSTALLER/initrd.gz" \
  && curl -fsSL -o installer-SHA256SUMS "$IMAGES/SHA256SUMS" || exit 1
# Both files as the installer's own list of checksums names them.
for f in linux initrd.gz; do
  sum="$(awk -v f="./$INSTALLER_PATH/$f" '$2 == f { print $1 }' installer-SHA256SUMS)"
  if [ -z "$sum" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$sum" ]; then
    echo "The downloaded installer file '$f' does not match Debian's SHA256SUMS." >&2
    rm -f linux initrd.gz installer-SHA256SUMS
    exit 1
  fi
done
rm -f installer-SHA256SUMS
[ -f id_vm ] || ssh-keygen -q -t ed25519 -N '' -C ubuntu-look-test-vm -f id_vm

# The installer's answers. The late command adds the SSH key and switches the
# login screen to automatic login, so a desktop session runs after each boot.
cat > preseed.cfg << EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/variant select English (US)
keyboard-configuration keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string looktest
d-i netcfg/get_domain string local
d-i netcfg/hostname string looktest
d-i hw-detect/load_firmware boolean false
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-login boolean false
d-i passwd/user-fullname string Tester
d-i passwd/username string ${VM_USER}
d-i passwd/user-password password ${VM_PASSWORD}
d-i passwd/user-password-again password ${VM_PASSWORD}
d-i user-setup/allow-password-weak boolean true
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i clock-setup/ntp boolean true
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-efi/non_efi_system boolean true
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/non-free-firmware boolean true
d-i apt-setup/services-select multiselect security, updates
tasksel tasksel/first multiselect standard, gnome-desktop, ssh-server
d-i pkgsel/include string openssh-server sudo curl
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
d-i preseed/late_command string \\
  in-target mkdir -p /home/${VM_USER}/.ssh; \\
  echo '$(cat id_vm.pub)' > /target/home/${VM_USER}/.ssh/authorized_keys; \\
  in-target chown -R ${VM_USER}:${VM_USER} /home/${VM_USER}/.ssh; \\
  in-target chmod 700 /home/${VM_USER}/.ssh; \\
  in-target sed -i 's/^# *AutomaticLoginEnable.*/AutomaticLoginEnable = true/; s/^# *AutomaticLogin *=.*/AutomaticLogin = ${VM_USER}/' /etc/gdm3/daemon.conf
EOF
cp initrd.gz initrd-preseed.gz
echo preseed.cfg | cpio -o -H newc 2> /dev/null | gzip >> initrd-preseed.gz

qemu-img create -q -f qcow2 disk.qcow2 25G
cp "$OVMF_VARS" vars.fd

echo "Installing Debian 13 with GNOME; the VM powers off when it is done..."
start_vm -kernel linux -initrd initrd-preseed.gz -append "auto=true priority=critical --- quiet" -no-reboot
SECONDS=0
while vm_running; do
  sleep 30
  # A question the answers above do not cover would wait for ever.
  if [ "$SECONDS" -gt 5400 ]; then
    kill "$VM_PID"
    echo "The install did not finish in 90 minutes; see the VM's screen with:" >&2
    echo "  echo 'screendump $VM/screen.ppm' | socat - unix:$VM/mon.sock" >&2
    exit 1
  fi
done
wait "$VM_PID"

# The installed system must boot to a desktop before it becomes the snapshot.
start_vm
if ! wait_desktop 400; then
  stop_vm
  echo "The installed VM did not reach its desktop; $VM is left for inspection." >&2
  exit 1
fi
if [ "$RELEASE" != trixie ]; then
  echo "Upgrading the VM to ${RELEASE}..."
  if ! to_vm "$REPO/tests/vm/upgrade.sh" \
     || ! vm_sudo "bash upgrade.sh $RELEASE autoremove" > upgrade.log 2>&1 || ! reboot_vm; then
    stop_vm
    echo "The upgrade to ${RELEASE} failed; see $VM/upgrade.log. $VM is left for inspection." >&2
    exit 1
  fi
  in_vm 'rm -f upgrade.sh'
fi
# The snapshot must hold the release it is named for.
if ! in_vm ". /etc/os-release; [ \"\$VERSION_CODENAME\" = $RELEASE ]"; then
  stop_vm
  echo "The VM does not run ${RELEASE}; $VM is left for inspection." >&2
  exit 1
fi
# The tests' rerun must not meet the screen lock.
if ! in_vm 'gsettings set org.gnome.desktop.session idle-delay 0 && gsettings set org.gnome.desktop.screensaver lock-enabled false'; then
  stop_vm
  echo "Could not switch the VM's screen lock off; $VM is left for inspection." >&2
  exit 1
fi
# Give the blocks the install and an upgrade freed back to this machine's disk.
vm_sudo fstrim -a > /dev/null 2>&1
stop_vm
if vm_running; then echo "The VM did not stop; no snapshot was taken." >&2; exit 1; fi
qemu-img snapshot -c fresh-install disk.qcow2 && cp vars.fd vars-fresh.fd || exit 1
rm -f linux initrd.gz initrd-preseed.gz
echo "The ${RELEASE} test VM is ready in $VM ($(du -sh disk.qcow2 | cut -f1)). Run: bash tests/vm-test.sh"
