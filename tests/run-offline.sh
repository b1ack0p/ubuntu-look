#!/bin/bash
# The same rig, driving ubuntu-look-offline.sh's own helpers and stage loop.
# The offline installer reaches apt through LOCAL_APT_OPTS; emptying that array
# points it at the rig's apt configuration, so the code under test is the
# offline script's, unmodified.
set -u
cd "$(dirname "$0")"
SRC="$(cd .. && pwd)/ubuntu-look-offline.sh"
. ./lib.sh
if [ "${KEEP_RIG:-0}" != "1" ]; then
  echo "building rig in $T ..."
  env -u APT_CONFIG bash ./build-rig.sh >/dev/null 2>&1 || { echo "rig build failed"; exit 1; }
fi
declare -a LOCAL_APT_OPTS=()
load_fns is_installed predates_install available_packages pkg_installed_version \
         pkg_candidate_version pkg_versions_desc installs_cleanly explain_blocked \
         ensure_package
# Source configuration is the online script's job; borrow it from there.
# write_ubuntu_sources() resolves the mirror per codename, so its helpers have
# to come along or every source line is skipped and nothing is installable.
for _f in write_ubuntu_sources resolve_ubuntu_pkg_codename \
          ubuntu_release_info ubuntu_suite_published ubuntu_mirror_for; do
  eval "$(awk -v n="$_f" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' "$REPO/ubuntu-look.sh")"
  declare -F "$_f" >/dev/null || { echo "FATAL: could not borrow $_f" >&2; exit 1; }
done
eval "$(awk '/^resolve_ubuntu_codename\(\) \{/,/^}$/' "$REPO/ubuntu-look.sh")"
quiet() { "$@" >/dev/null 2>&1; }
STAGE="dconf-cli yaru-theme-gnome-shell yaru-theme-gtk ubuntu-wallpapers"

run_stage_offline() {
  declare -ga STATUS_INSTALLED=() STATUS_UPGRADED=() STATUS_ALREADY=() STATUS_HELD=() STATUS_FAILED=()
  RELOGIN_NEEDED=0; category=rig
  available="$(available_packages "$STAGE")"
  BEFORE="$T/before.off"; snapshot_installed > "$BEFORE"
  eval "$(load_stage_loop)" >/dev/null 2>&1
  record_manifest "$BEFORE"
}

echo "════ OFF-1  offline install from the bundle ════"
mkdir -p "$BACKUP_ORIGINAL"; snapshot_installed > "$BACKUP_ORIGINAL/packages-before.txt"; : > "$INSTALLED_MANIFEST"
UBUNTU_CANDIDATE_CODENAMES="alpha bravo charlie delta"
quiet write_ubuntu_sources; write_real_pin PLACEHOLDER; quiet apt-get update
CN="$(resolve_ubuntu_codename)"; write_real_pin "$CN"; quiet apt-get update
assert_eq "$CN" "bravo" "offline helpers resolve the same codename"
run_stage_offline
assert_version yaru-theme-gnome-shell 25.04.1-0ubuntu1 "shell theme installed from the bundle"
assert_version yaru-theme-gtk         25.04.1-0ubuntu1 "gtk theme walked back past the unsatisfiable builds"
assert_version ubuntu-wallpapers      26.04.2          "wallpapers took the newest bundled build"
assert_version ubuntu-wallpapers-delta 26.04.2         "its per-release pack came along"

echo
echo "════ OFF-2  the bundle is refreshed after a new Ubuntu ════"
publish_suite echo 26.10 <<PKGS
yaru-theme-gnome-shell|26.10.1-0ubuntu1|Breaks: gnome-shell (<< 50~)
yaru-theme-gtk|26.10.1-0ubuntu1|
ubuntu-wallpapers|26.10.1|Depends: ubuntu-wallpapers-echo
ubuntu-wallpapers-echo|26.10.1|
PKGS
UBUNTU_CANDIDATE_CODENAMES="bravo charlie delta echo"
quiet write_ubuntu_sources; quiet apt-get update
run_stage_offline
assert_version ubuntu-wallpapers      26.10.1 "refreshed bundle carried the wallpapers forward"
assert_version ubuntu-wallpapers-echo 26.10.1 "and pulled the new per-release pack"
assert_version yaru-theme-gnome-shell 25.04.1-0ubuntu1 "shell theme stayed where gnome-shell requires"
grep -qx ubuntu-wallpapers-echo "$INSTALLED_MANIFEST" && ok "recorded for uninstall" || bad "not in manifest"
printf '  upgraded: %s\n' "${STATUS_UPGRADED[@]:-none}"

echo
echo "════ $PASS passed, $FAIL failed ════"
exit $((FAIL > 0))
