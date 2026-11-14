#!/bin/bash
# Runs inside the VM: record the parts of the system ubuntu-look.sh changes.
#   state.sh <directory>
d="$1"; mkdir -p "$d"
dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' | sort > "$d/packages"
apt-mark showmanual | sort > "$d/manual"
dconf dump / > "$d/dconf"
cp /etc/default/grub "$d/grub"
cat /etc/plymouth/plymouthd.conf > "$d/plymouthd.conf" 2> /dev/null
/usr/sbin/plymouth-set-default-theme > "$d/plymouth-theme" 2>&1
ls /etc/apt/sources.list.d /etc/apt/preferences.d > "$d/apt-files" 2>&1
ls /usr/share/wayland-sessions /usr/share/xsessions /usr/local/share/wayland-sessions \
   /usr/local/share/xsessions > "$d/sessions" 2>&1
ls -A /var/lib/ubuntu-look > "$d/records" 2>&1
ls -A /etc/dconf/profile /etc/dconf/db > "$d/dconf-system" 2>&1
gnome-extensions list --enabled | sort > "$d/extensions" 2>&1
cat /proc/cmdline > "$d/cmdline"
tr '\0' '\n' < "/proc/$(pgrep -u "$USER" -x gnome-shell | head -1)/environ" \
  | grep -E '^(XDG_CURRENT_DESKTOP|DESKTOP_SESSION|GNOME_SHELL_SESSION_MODE|DCONF_PROFILE)=' | sort > "$d/session"
