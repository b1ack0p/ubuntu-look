#!/bin/bash
# Runs inside the VM as root: upgrade Debian to release $1, unattended.
# With "autoremove" as $2 the packages the upgrade left unused go too.
to="$1"
# shellcheck disable=SC1091
. /etc/os-release
[ -n "$to" ] && [ -n "$VERSION_CODENAME" ] || exit 2
# A release's codename, and nothing sed or apt would read as more than that.
case "$to" in *[!a-z]*) echo "not a Debian codename: $to" >&2; exit 2 ;; esac
[ "$VERSION_CODENAME" = "$to" ] || sed -i "s/\b${VERSION_CODENAME}\b/${to}/g" /etc/apt/sources.list
export DEBIAN_FRONTEND=noninteractive
done=0
for _ in 1 2 3; do
  if apt-get update -q \
     && apt-get -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef full-upgrade; then
    done=1
    break
  fi
  sleep 15
done
[ "$done" -eq 1 ] || exit 1
[ "$2" != autoremove ] || apt-get -y -q autoremove
# The downloaded packages and the blocks the upgrade freed go back to the host.
apt-get clean
fstrim -a > /dev/null 2>&1
exit 0
