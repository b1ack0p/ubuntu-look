#!/bin/bash
# Breaks each fix on purpose and checks that the suite notices. A test that
# still passes against a broken script is not testing anything.
set -u
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
WORK="${TMPDIR:-/tmp}/ubuntu-look-mutants"; rm -rf "$WORK"; mkdir -p "$WORK"
PASS=0; FAIL=0

mutate() {   # mutate <name> <expected-test> <python-replacement>
  local name="$1" expect="$2" py="$3" m="$WORK/${1}.sh"
  cp "$REPO/ubuntu-look.sh" "$m"
  python3 - "$m" <<PY || { printf '  \033[31mSKIP\033[0m %-28s (mutation did not apply)\n' "$name"; FAIL=$((FAIL+1)); return; }
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
$py
open(p,"w",encoding="utf-8").write(s)
PY
  if SRC="$m" bash ./run.sh >"$WORK/$name.log" 2>&1; then
    printf '  \033[31mNOT CAUGHT\033[0m %-22s — %s still passes with this broken\n' "$name" "$expect"
    FAIL=$((FAIL+1))
  else
    printf '  \033[32mcaught\033[0m %-26s by: %s\n' "$name" \
      "$(grep -oE 'FAIL.*' "$WORK/$name.log" | head -1 | cut -c1-90)"
    PASS=$((PASS+1))
  fi
}

echo "Each line breaks one fix; the suite must fail."
echo

mutate upgrades-disabled "T2 (new release)" '
old="      to_upgrade=\"$to_upgrade $p\""
assert s.count(old)==1, s.count(old)
s=s.replace(old,"      :",1)'

mutate no-version-walk "T1 (fallback build)" '
old="  for ver in $(pkg_versions_desc \"$pkg\"); do"
assert s.count(old)==1, s.count(old)
s=s.replace(old,"  for ver in $cand; do",1)'

mutate no-candidate-ceiling "T8c (candidate ceiling)" '
old="    dpkg --compare-versions \"$ver\" gt \"$cand\" && continue\n"
assert s.count(old)==1, s.count(old)
s=s.replace(old,"",1)'

mutate lookback-disabled "T3 (lookback)" '
old="  resolve_ubuntu_pkg_codename yaru-theme-gnome-shell 0 \"\""
assert s.count(old)==1, s.count(old)
s=s.replace(old,"  resolve_ubuntu_pkg_codename yaru-theme-gnome-shell 0 \"$(echo \"$UBUNTU_CANDIDATE_CODENAMES\" | awk \x27{print $1}\x27)\"",1)'

mutate predates-ignored "T8a (pre-existing packages)" '
old="  [ -f \"${BACKUP_ORIGINAL}/packages-before.txt\" ] || return 1"
assert s.count(old)==1, s.count(old)
s=s.replace(old,"  return 1",1)'

mutate apt-output-leak "T8b (clean status strings)" '
old="    if sudo apt-get install -y \"${pkg}=${ver}\" >&2; then"
assert s.count(old)==1, s.count(old)
s=s.replace(old,"    if sudo apt-get install -y \"${pkg}=${ver}\"; then",1)'

mutate narrow-dep-matcher "T6 (held reason)" '
old="(installable|going to be installed)"
assert s.count(old)==1, s.count(old)
s=s.replace(old,"(going to be installed)",1)'

mutate no-with-new-pkgs "T9b (held-back updates)" '
old="  if sudo apt-get upgrade -y --with-new-pkgs; then"
assert s.count(old)==1, s.count(old)
s=s.replace(old,"  if sudo apt-get upgrade -y; then",1)'

echo
echo "$PASS of $((PASS+FAIL)) mutations were caught"
exit $((FAIL > 0))
