#!/bin/bash
# Integration suite: real .debs, real signed archive, real apt resolver, real
# dpkg database. Only privilege escalation is dropped.
set -u
cd "$(dirname "$0")"
. ./lib.sh

# A fresh archive + dpkg root for every run, so results never depend on leftovers.
if [ "${KEEP_RIG:-0}" != "1" ]; then
  echo "building rig in $T ..."
  env -u APT_CONFIG bash ./build-rig.sh >/dev/null 2>&1 || { echo "rig build failed"; exit 1; }
fi
load_fns is_installed predates_install available_packages pkg_installed_version \
         pkg_candidate_version pkg_versions_desc installs_cleanly explain_blocked \
         ensure_package resolve_ubuntu_pkg_codename resolve_ubuntu_codename \
         write_ubuntu_sources add_ubuntu_key apt_update \
         ubuntu_release_info ubuntu_suite_published ubuntu_mirror_for
declare -a STATUS_CHANGES=()
STAGE="dconf-cli yaru-theme-gnome-shell yaru-theme-gtk ubuntu-wallpapers"
quiet() { "$@" >/dev/null 2>&1; }

run_stage() {   # runs the script's real stage-loop body over $STAGE
  declare -ga STATUS_INSTALLED=() STATUS_UPGRADED=() STATUS_ALREADY=() STATUS_HELD=() STATUS_FAILED=()
  RELOGIN_NEEDED=0; category=rig
  available="$(available_packages "$STAGE")"
  BEFORE="$T/before.$$"; snapshot_installed > "$BEFORE"
  eval "$(load_stage_loop)" >/dev/null 2>&1
  record_manifest "$BEFORE"
}

################################################################################
echo "════ T1  fresh install ════"
mkdir -p "$BACKUP_ORIGINAL"; snapshot_installed > "$BACKUP_ORIGINAL/packages-before.txt"; : > "$INSTALLED_MANIFEST"
UBUNTU_CANDIDATE_CODENAMES="alpha bravo charlie delta"
quiet write_ubuntu_sources; write_real_pin PLACEHOLDER; quiet apt_update
CN="$(resolve_ubuntu_codename)"
assert_eq "$CN" "bravo" "codename resolves to the newest gnome-shell-compatible release"
write_real_pin "$CN"; quiet apt_update
run_stage
assert_version yaru-theme-gnome-shell 25.04.1-0ubuntu1 "shell theme from the pinned release"
assert_version yaru-theme-gtk         25.04.1-0ubuntu1 "gtk theme walked back to the last build whose deps resolve"
assert_version ubuntu-wallpapers      26.04.2          "wallpapers floated to the newest release"
assert_version ubuntu-wallpapers-delta 26.04.2         "its per-release pack came along"
assert_version user-session-migration absent           "pin-blocked Ubuntu-only dep never installed"
echo "  installed: ${STATUS_INSTALLED[*]:-none}"

################################################################################
echo
echo "════ T2  a new Ubuntu is published ════"
publish_suite echo 26.10 <<PKGS
yaru-theme-gnome-shell|26.10.1-0ubuntu1|Breaks: gnome-shell (<< 50~)
yaru-theme-gtk|26.10.1-0ubuntu1|
ubuntu-wallpapers|26.10.1|Depends: ubuntu-wallpapers-echo
ubuntu-wallpapers-echo|26.10.1|
PKGS
UBUNTU_CANDIDATE_CODENAMES="bravo charlie delta echo"
quiet write_ubuntu_sources; quiet apt_update
echo "  control — what plain 'apt-get upgrade' does with this:"
apt-get -s upgrade 2>/dev/null | sed -n '/kept back/,/^[A-Z0-9]/p' | sed 's/^/    /' | head -4
CN="$(resolve_ubuntu_codename)"; write_real_pin "$CN"; quiet apt_update
assert_eq "$CN" "bravo" "shell theme still pinned to the only release that fits"
run_stage
assert_version ubuntu-wallpapers      26.10.1 "wallpapers carried across the release boundary"
assert_version ubuntu-wallpapers-echo 26.10.1 "the new per-release pack was pulled in"
assert_version yaru-theme-gtk         26.10.1-0ubuntu1 "gtk theme upgraded once its blocker was gone"
assert_version yaru-theme-gnome-shell 25.04.1-0ubuntu1 "shell theme held where gnome-shell requires"
grep -qx ubuntu-wallpapers-echo "$INSTALLED_MANIFEST" && ok "new pack recorded for uninstall" || bad "new pack missing from manifest"
echo "  upgraded : ${STATUS_UPGRADED[*]:-none}"

################################################################################
echo
echo "════ T3  Ubuntu outruns this Debian (lookback) ════"
publish_suite foxtrot 27.04 <<PKGS
yaru-theme-gnome-shell|27.04.1-0ubuntu1|Breaks: gnome-shell (<< 50~)
yaru-theme-gtk|27.04.1-0ubuntu1|
PKGS
UBUNTU_ALL_CODENAMES="alpha bravo charlie delta echo foxtrot"
UBUNTU_CANDIDATE_CODENAMES="$(echo "$UBUNTU_ALL_CODENAMES" | tr ' ' '\n' | tail -n "$MAX_UBUNTU_CANDIDATES" | xargs)"
echo "  window is now: $UBUNTU_CANDIDATE_CODENAMES  (bravo has aged out)"
quiet write_ubuntu_sources; quiet apt_update
UBUNTU_CODENAME="$(resolve_ubuntu_codename)"
assert_eq "$UBUNTU_CODENAME" "" "nothing in the window fits, so the lookback must run"
eval "$(load_lookback)" >/dev/null 2>&1
assert_eq "$UBUNTU_CODENAME" "bravo" "lookback reached back and found the newest release that fits"
assert_eq "$UBUNTU_CANDIDATE_CODENAMES" "bravo charlie delta echo foxtrot" "exactly one extra suite kept"
assert_eq "$(grep -c '^deb ' "$UBUNTU_LIST")" "10" "sources rewritten: 5 suites x (release + updates)"
write_real_pin "$UBUNTU_CODENAME"; quiet apt_update
run_stage
assert_version yaru-theme-gnome-shell 25.04.1-0ubuntu1 "shell theme still installable after the lookback"

################################################################################
echo
echo "════ T5  a second run changes nothing ════"
run_stage
assert_eq "${STATUS_INSTALLED[*]:-}" "" "nothing installed on a repeat run"
assert_eq "${STATUS_UPGRADED[*]:-}"  "" "nothing upgraded on a repeat run"
assert_eq "$RELOGIN_NEEDED" "0" "no re-login demanded when nothing changed"
assert_eq "$(echo "${STATUS_ALREADY[*]}" | wc -w)" "8" "all four packages reported as already current"

################################################################################
echo
echo "════ T6  a newer build that cannot be installed is refused, not forced ════"
publish_suite golf 27.10 <<PKGS
ubuntu-wallpapers|27.10.1|Depends: ubuntu-wallpapers-golf
yaru-theme-gtk|27.10.1-0ubuntu1|Depends: a-package-that-does-not-exist
PKGS
UBUNTU_CANDIDATE_CODENAMES="bravo delta echo foxtrot golf"
quiet write_ubuntu_sources; quiet apt_update
was_wp="$(pkg_installed_version ubuntu-wallpapers)"
was_gtk="$(pkg_installed_version yaru-theme-gtk)"
run_stage
assert_version ubuntu-wallpapers "$was_wp"  "unsatisfiable wallpaper metapackage left where it was"
assert_version yaru-theme-gtk    "$was_gtk" "unsatisfiable gtk build left where it was"
assert_version a-package-that-does-not-exist absent "nothing invented to satisfy it"
case "${STATUS_HELD[*]:-}" in
  *"needs: ubuntu-wallpapers-golf"*) ok "held, and the reason names the missing dependency";;
  *) bad "held reason does not name the dependency: ${STATUS_HELD[*]:-none}";;
esac
printf '  held: %s\n' "${STATUS_HELD[@]:-none}"

################################################################################
echo
echo "════ T7  a Debian release upgrade moves gnome-shell forward ════"
A="$T/archive"; export GNUPGHOME="$T/gnupg"
d="$T/build/gs49"; rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/doc/gnome-shell"
echo x > "$d/usr/share/doc/gnome-shell/marker"
printf 'Package: gnome-shell\nVersion: 49.0-1\nArchitecture: all\nMaintainer: rig <rig@example.invalid>\nDescription: rig gnome-shell\n' > "$d/DEBIAN/control"
dpkg-deb --build -Znone "$d" "$A/pool/debian-stable/main/gnome-shell_49.0-1_all.deb" >/dev/null 2>&1
( cd "$A"; apt-ftparchive packages pool/debian-stable/main > dists/debian-stable/main/binary-all/Packages )
( cd "$A/dists/debian-stable"; rm -f Release InRelease Release.gpg
  apt-ftparchive -o APT::FTPArchive::Release::Origin=Debian -o APT::FTPArchive::Release::Label=Debian \
    -o APT::FTPArchive::Release::Suite=debian-stable -o APT::FTPArchive::Release::Codename=debian-stable \
    -o APT::FTPArchive::Release::Version=14 -o APT::FTPArchive::Release::Architectures=all \
    -o APT::FTPArchive::Release::Components="main universe" release . > Release
  gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback --clearsign -o InRelease Release
  gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback -abs -o Release.gpg Release )
quiet apt_update
quiet apt-get install -y gnome-shell
assert_version gnome-shell 49.0-1 "the new Debian's gnome-shell is in place"
CN="$(resolve_ubuntu_codename)"
assert_eq "$CN" "delta" "codename re-resolved forward to the newest release the new shell can load"
write_real_pin "$CN"; quiet apt_update
run_stage
assert_version yaru-theme-gnome-shell 26.04.5-0ubuntu1 "shell theme carried forward onto the new Debian"
case "${STATUS_UPGRADED[*]:-}" in
  *yaru-theme-gnome-shell*) ok "reported as an upgrade, old to new";;
  *) bad "not reported as upgraded: ${STATUS_UPGRADED[*]:-none}";;
esac
printf '  upgraded: %s\n' "${STATUS_UPGRADED[@]:-none}"

################################################################################
echo
echo "════ T8  guards that protect the rest of the system ════"

# (a) A package that was on the machine before this script ran is not ours to
#     move, even when a newer one is on offer.
A="$T/archive"; export GNUPGHOME="$T/gnupg"
d="$T/build/dconf2"; rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/doc/dconf-cli"
echo x > "$d/usr/share/doc/dconf-cli/marker"
printf 'Package: dconf-cli\nVersion: 0.41.0-1\nArchitecture: all\nMaintainer: rig <rig@example.invalid>\nDescription: rig dconf-cli\n' > "$d/DEBIAN/control"
dpkg-deb --build -Znone "$d" "$A/pool/debian-stable/main/dconf-cli_0.41.0-1_all.deb" >/dev/null 2>&1
( cd "$A"; apt-ftparchive packages pool/debian-stable/main > dists/debian-stable/main/binary-all/Packages )
( cd "$A/dists/debian-stable"; rm -f Release InRelease Release.gpg
  apt-ftparchive -o APT::FTPArchive::Release::Origin=Debian -o APT::FTPArchive::Release::Label=Debian \
    -o APT::FTPArchive::Release::Suite=debian-stable -o APT::FTPArchive::Release::Codename=debian-stable \
    -o APT::FTPArchive::Release::Version=13 -o APT::FTPArchive::Release::Architectures=all \
    -o APT::FTPArchive::Release::Components="main universe" release . > Release
  gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback --clearsign -o InRelease Release
  gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback -abs -o Release.gpg Release )
quiet apt_update
assert_eq "$(pkg_candidate_version dconf-cli)" "0.41.0-1" "a newer dconf-cli is on offer"
run_stage
assert_version dconf-cli 0.40.0-5 "a package that predates the install is left alone"

# (b) The reported version must be a version, not whatever apt printed.
publish_suite hotel 28.04 <<PKGS
yaru-theme-gtk|28.04.1-0ubuntu1|
PKGS
UBUNTU_CANDIDATE_CODENAMES="bravo delta echo foxtrot hotel"
quiet write_ubuntu_sources; quiet apt_update
run_stage
bad_line=0
for e in "${STATUS_UPGRADED[@]:-}" "${STATUS_INSTALLED[@]:-}"; do
  [ -z "$e" ] && continue
  case "$e" in
    *$'\n'*) bad_line=1 ;;
    *"Reading"*|*"Setting up"*|*"Unpacking"*) bad_line=1 ;;
  esac
done
assert_eq "$bad_line" "0" "status entries carry a version, not apt's output"
printf '  reported: %s\n' "${STATUS_UPGRADED[@]:-none}"

# (c) The walk starts at apt's candidate and never steps above it, or the pin's
#     gnome-shell coupling would be silently undone.
# Both builds install against the gnome-shell now in place, so the only thing
# that can keep the walk off the higher one is the candidate ceiling itself.
publish_suite india 28.10 <<PKGS
gnome-shell-extension-ubuntu-dock|102ubuntu1|Depends: gnome-shell (>= 45~), gnome-shell (<< 51~)
PKGS
publish_suite bravo 25.04 <<PKGS
gnome-shell-extension-ubuntu-dock|100ubuntu2|Depends: gnome-shell (>= 45~), gnome-shell (<< 51~)
PKGS
UBUNTU_CANDIDATE_CODENAMES="bravo delta echo foxtrot india"
quiet write_ubuntu_sources; write_real_pin bravo; quiet apt_update
assert_eq "$(pkg_candidate_version gnome-shell-extension-ubuntu-dock)" "100ubuntu2" "pin holds the dock to the resolved release"
higher="$(pkg_versions_desc gnome-shell-extension-ubuntu-dock | head -1)"
assert_eq "$higher" "102ubuntu1" "a higher version exists and would install cleanly"
got="$(ensure_package gnome-shell-extension-ubuntu-dock 2>/dev/null)"
assert_eq "$got" "100ubuntu2" "the walk stayed at the candidate, not the higher build"
assert_version gnome-shell-extension-ubuntu-dock 100ubuntu2 "and that is what landed"
quiet apt-get purge -y gnome-shell-extension-ubuntu-dock

################################################################################
echo
echo "════ T9  ordinary updates, not just new releases ════"

# (a) A point update published to <codename>-updates. The pin names a codename,
#     and the -updates pocket carries that same codename, so it is covered.
publish_pocket bravo-updates bravo Ubuntu 25.04 <<PKGS
yaru-theme-gnome-shell|25.04.1-0ubuntu1.1|Breaks: gnome-shell (<< 48~)
PKGS
UBUNTU_CANDIDATE_CODENAMES="bravo delta echo foxtrot india"
quiet write_ubuntu_sources; write_real_pin bravo; quiet apt_update
quiet apt-get install -y --allow-downgrades yaru-theme-gnome-shell=25.04.1-0ubuntu1
assert_eq "$(pkg_candidate_version yaru-theme-gnome-shell)" "25.04.1-0ubuntu1.1" "the -updates build is what the pin selects"
run_stage
assert_version yaru-theme-gnome-shell 25.04.1-0ubuntu1.1 "a point update inside the pinned release is taken"

# (b) An update to a package that predates the install, which needs a package
#     that is not here yet. This is the system upgrade step's job, not the
#     stage loop's; plain "apt-get upgrade" keeps such an update back.
publish_pocket debian-stable debian-stable Debian 13 <<PKGS
gnome-shell|49.0-1|
dconf-cli|0.41.0-1|
plymouth|24.004.61-1|Depends: plymouth-label
plymouth-label|24.004.61-1|
yaru-theme-gnome-shell|24.04.3-1|Breaks: gnome-shell (<< 46~)
PKGS
quiet apt_update
echo "  control — plain 'apt-get upgrade':"
apt-get -s upgrade 2>/dev/null | sed -n '/kept back/,+1p' | sed 's/^/    /'
before_manifest="$(wc -l < "$INSTALLED_MANIFEST")"

# Default: a theming script must not upgrade the rest of the system. Debian's
# "Don't break Debian" names a blanket upgrade as the risk of having a foreign
# archive configured, so the whole-system path is opt-in.
( unset UBUNTU_LOOK_SYSTEM_UPGRADE; eval "$(load_upgrade_step)" ) >/dev/null 2>&1
assert_version plymouth 24.004.60-5 "by default the system upgrade is left alone"

# Opt-in: the old behaviour, still available and still correct.
export UBUNTU_LOOK_SYSTEM_UPGRADE=1
eval "$(load_upgrade_step)" >/dev/null 2>&1
unset UBUNTU_LOOK_SYSTEM_UPGRADE
assert_version plymouth       24.004.61-1 "the held-back update was applied"
assert_version plymouth-label 24.004.61-1 "and the package it needed was installed"
assert_eq "$(wc -l < "$INSTALLED_MANIFEST")" "$before_manifest" "nothing the system upgrade pulled was claimed as ours"
grep -qx plymouth-label "$INSTALLED_MANIFEST" && bad "uninstall would wrongly remove a Debian package" || ok "uninstall will leave it alone"

################################################################################
echo
echo "════ T4  uninstall removes exactly what was added ════"
BEFORE_ALL="$BACKUP_ORIGINAL/packages-before.txt"
to_purge=""
while read -r p; do
  grep -qx "$p" "$BEFORE_ALL" && continue          # uninstall.sh's predates_us
  is_installed "$p" && to_purge="$to_purge $p"
done < "$INSTALLED_MANIFEST"
echo "  manifest : $(xargs < "$INSTALLED_MANIFEST")"
echo "  purging  :$to_purge"
# shellcheck disable=SC2086
quiet apt-get purge -y $to_purge
quiet apt-get autoremove -y --purge
# Two properties, stated separately. A plain "back to the old package list"
# would be wrong: the system upgrade step legitimately installs Debian packages
# that an update needs, and those are not this script's to remove.
left=""
while read -r p; do is_installed "$p" && left="$left $p"; done < "$INSTALLED_MANIFEST"
assert_eq "$left" "" "nothing the script installed is left behind"

missing=""
while read -r p; do is_installed "$p" || missing="$missing $p"; done < "$BEFORE_ALL"
assert_eq "$missing" "" "nothing that predates the install was removed"

is_installed plymouth-label \
  && ok "a Debian package pulled in by the system upgrade was correctly kept" \
  || bad "plymouth-label was removed, but it is Debian's, not ours"

echo
echo "════ $PASS passed, $FAIL failed ════"
exit $((FAIL > 0))
