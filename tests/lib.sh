# Shared rig environment + assertion helpers.
SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SP/.." && pwd)"
# The rig lives outside the repo; override with RIG=... to keep it around.
T="${RIG:-${TMPDIR:-/tmp}/ubuntu-look-rig}"; R="$T/root"
SRC="${SRC:-$REPO/ubuntu-look.sh}"
export APT_CONFIG="$T/apt.conf" DPKG_ADMINDIR="$R/var/lib/dpkg"
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

UBUNTU_PIN="$R/etc/apt/preferences.d/ubuntu-themes"
UBUNTU_LIST="$R/etc/apt/sources.list.d/ubuntu-themes.list"
UBUNTU_KEYRING="$R/etc/apt/keyrings/rig.gpg"
UBUNTU_MIRROR="file://$T/archive"
BACKUP_DIR="$R/backup"; BACKUP_ORIGINAL="$BACKUP_DIR/original"
INSTALLED_MANIFEST="$BACKUP_DIR/installed-by-script.txt"
MAX_UBUNTU_CANDIDATES=4
MAX_UBUNTU_LOOKBACK=6
RED=""; GREEN=""; YELLOW=""; ENDCOLOR=""
message() { case ${1:-} in warn|error|info) shift;; esac; echo "      | $*" >&2; }
error()   { message "$@"; exit 1; }
step()    { :; }
# Real execution; only the privilege change is dropped.
sudo() { "$@"; }

# Load the real functions out of the script, verbatim.
load_fns() {
  local f
  for f in "$@"; do
    eval "$(awk -v n="$f" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' "$SRC")"
    declare -F "$f" >/dev/null || { echo "FATAL: could not load $f from $SRC" >&2; exit 1; }
  done
}
# Pull a block of the script out by code, never by comment text: comments get
# reworded, and a silently empty extraction turns a test into a no-op.
# extract_block <awk program> <token the block must contain>
extract_block() {
  local out
  out="$(awk "$1" "$SRC")"
  case "$out" in
    *"$2"*) printf '%s\n' "$out" ;;
    *) echo "FATAL: extraction failed, '$2' not found in block from $SRC" >&2; exit 1 ;;
  esac
}

load_stage_loop() {
  extract_block '/^  declare -A PKG_BEFORE=\(\)/{p=1} p{print} p && /_installed_any -eq 1/{exit}' \
                'ensure_package'
  echo '  fi'
}

# The codename lookback, from the main flow.
load_lookback() {
  extract_block '/^  if \[ -z "\$UBUNTU_CODENAME" \]; then/{p=1} p{print} p && /verified via simulated install/{exit}' \
                'MAX_UBUNTU_LOOKBACK'
  echo '  fi'
}

# The system upgrade step, from the main flow. Opt-in since v16: the block
# starts at the flag, and only the outer "fi" sits in column 0.
load_upgrade_step() {
  extract_block '/^UBUNTU_LOOK_SYSTEM_UPGRADE=/{p=1} p{print} p && /^fi$/{exit}' \
                'with-new-pkgs'
}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
# assert_version <pkg> <expected-version|absent> <label>
assert_version() {
  local got; got="$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true)"
  is_installed "$1" || got="absent"
  [ "$got" = "$2" ] && ok "$3 ($1 = $2)" || bad "$3 — expected $1=$2, got $got"
}
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) bad "$3 — %s not found in: $1";; esac; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 — expected '$2', got '$1'"; }

# The pin, taken verbatim from the script so the test cannot drift from it.
write_real_pin() {
  local tmpl
  # Both scripts write the same pin; they just name the codename variable
  # differently, so set both and the template expands either way.
  UBUNTU_CODENAME="$1"; theme_codename="$1"; PIN_VERSION="rig"
  tmpl="$(awk '/^# pin-version:/{p=1} p&&/^EOF$/{exit} p{print}' "$SRC")"
  eval "cat > '$UBUNTU_PIN' <<PINEOF
$tmpl
PINEOF"
}

# Publish one more Ubuntu release into the rig archive.
# publish_suite <codename> <version> then feed "name|ver|extra" lines on stdin.
publish_suite() {
  local cn="$1" version="$2" A="$T/archive" line name ver extra d comp
  export GNUPGHOME="$T/gnupg"
  while IFS='|' read -r name ver extra; do
    [ -z "$name" ] && continue
    comp=main
    d="$T/build/${cn}_${name}"; rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name"
    echo "$name $ver" > "$d/usr/share/doc/$name/marker"
    { echo "Package: $name"; echo "Version: $ver"; echo "Architecture: all"
      echo "Maintainer: rig <rig@example.invalid>"
      [ -n "$extra" ] && echo "$extra"
      echo "Description: rig $name"; } > "$d/DEBIAN/control"
    mkdir -p "$A/pool/$cn/$comp"
    dpkg-deb --build -Znone "$d" "$A/pool/$cn/$comp/${name}_${ver}_all.deb" >/dev/null 2>&1
  done
  local s
  for s in "$cn" "${cn}-updates"; do
    for comp in main universe; do
      mkdir -p "$A/dists/$s/$comp/binary-all"
      ( cd "$A"; if [ -d "pool/$s/$comp" ]; then apt-ftparchive packages "pool/$s/$comp" > "dists/$s/$comp/binary-all/Packages"; else : > "dists/$s/$comp/binary-all/Packages"; fi )
    done
    ( cd "$A/dists/$s"; rm -f Release InRelease Release.gpg
      apt-ftparchive -o APT::FTPArchive::Release::Origin=Ubuntu -o APT::FTPArchive::Release::Label=Ubuntu \
        -o APT::FTPArchive::Release::Suite="$s" -o APT::FTPArchive::Release::Codename="${s%-updates}" \
        -o APT::FTPArchive::Release::Version="$version" -o APT::FTPArchive::Release::Architectures=all \
        -o APT::FTPArchive::Release::Components="main universe" release . > Release
      gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback --clearsign -o InRelease Release
      gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback -abs -o Release.gpg Release )
  done
}

snapshot_installed() { dpkg-query -W -f='${Package} ${Status}\n' | awk '$2=="install" && $4=="installed"{print $1}' | sort; }

record_manifest() {  # same two steps the script performs
  [ ${#STATUS_INSTALLED[@]} -gt 0 ] && printf '%s\n' "${STATUS_INSTALLED[@]}" | awk '{print $1}' >> "$INSTALLED_MANIFEST"
  snapshot_installed | comm -13 "$1" - >> "$INSTALLED_MANIFEST"
  sort -u -o "$INSTALLED_MANIFEST" "$INSTALLED_MANIFEST"
}

# publish_pocket <suite-dir> <codename> <origin> <version>; packages on stdin.
# Used for "<codename>-updates" and for Debian's own suite, so a point update
# can be published without creating a whole new release.
publish_pocket() {
  local suite="$1" codename="$2" origin="$3" version="$4" A="$T/archive" name ver extra d
  export GNUPGHOME="$T/gnupg"
  while IFS='|' read -r name ver extra; do
    [ -z "$name" ] && continue
    d="$T/build/${suite}_${name}_${ver}"; rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name"
    echo "$name $ver" > "$d/usr/share/doc/$name/marker"
    { echo "Package: $name"; echo "Version: $ver"; echo "Architecture: all"
      echo "Maintainer: rig <rig@example.invalid>"
      [ -n "$extra" ] && echo "$extra"
      echo "Description: rig $name"; } > "$d/DEBIAN/control"
    mkdir -p "$A/pool/$suite/main"
    dpkg-deb --build -Znone "$d" "$A/pool/$suite/main/${name}_${ver}_all.deb" >/dev/null 2>&1
  done
  mkdir -p "$A/dists/$suite/main/binary-all"
  ( cd "$A"; apt-ftparchive packages "pool/$suite/main" > "dists/$suite/main/binary-all/Packages" )
  ( cd "$A/dists/$suite"; rm -f Release InRelease Release.gpg
    apt-ftparchive -o APT::FTPArchive::Release::Origin="$origin" -o APT::FTPArchive::Release::Label="$origin" \
      -o APT::FTPArchive::Release::Suite="$suite" -o APT::FTPArchive::Release::Codename="$codename" \
      -o APT::FTPArchive::Release::Version="$version" -o APT::FTPArchive::Release::Architectures=all \
      -o APT::FTPArchive::Release::Components="main universe" release . > Release
    gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback --clearsign -o InRelease Release
    gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback -abs -o Release.gpg Release )
}
