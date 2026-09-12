#!/bin/bash
# Real apt archive in the genuine dists/ layout, GPG-signed, plus a dpkg root.
# Unprivileged throughout. Nothing here is a stub.
set -eu
T="${RIG:-${TMPDIR:-/tmp}/ubuntu-look-rig}"; R="$T/root"; A="$T/archive"
rm -rf "$T"
mkdir -p "$A/pool" "$T/build" \
         "$R"/var/lib/dpkg/{info,updates,alternatives,triggers} \
         "$R"/var/lib/apt/lists/partial "$R"/var/cache/apt/archives/partial \
         "$R"/etc/apt/{preferences.d,sources.list.d,keyrings,apt.conf.d} \
         "$R"/var/log/apt "$R"/usr/share/doc
: > "$R/var/lib/dpkg/status"; : > "$R/var/lib/dpkg/available"

export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

# --- throwaway signing key ----------------------------------------------------
export GNUPGHOME="$T/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
    --quick-generate-key 'ubuntu-look rig <rig@example.invalid>' rsa2048 sign never 2>/dev/null
KEYID="$(gpg --batch --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
gpg --batch --quiet --export "$KEYID" > "$R/etc/apt/keyrings/rig.gpg"

# --- package builder ----------------------------------------------------------
# mkdeb <codename> <component> <name> <version> [control-extra]
mkdeb() {
  local cn="$1" comp="$2" name="$3" ver="$4" extra="${5:-}"
  local d="$T/build/${cn}_${name}_${ver}"
  rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name"
  echo "$name $ver from $cn" > "$d/usr/share/doc/$name/marker"
  { echo "Package: $name"; echo "Version: $ver"; echo "Architecture: all"
    echo "Maintainer: rig <rig@example.invalid>"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    echo "Section: $comp"; echo "Priority: optional"
    echo "Description: rig package $name"; } > "$d/DEBIAN/control"
  mkdir -p "$A/pool/$cn/$comp"
  dpkg-deb --build -Znone "$d" "$A/pool/$cn/$comp/${name}_${ver}_all.deb" >/dev/null 2>&1
}

# --- publish a suite ----------------------------------------------------------
# publish <codename> <origin> <version>
publish() {
  local cn="$1" origin="$2" version="$3" comp
  for comp in main universe; do
    mkdir -p "$A/dists/$cn/$comp/binary-all"
    ( cd "$A"
      if [ -d "pool/$cn/$comp" ]; then
        apt-ftparchive packages "pool/$cn/$comp" > "dists/$cn/$comp/binary-all/Packages"
      else
        : > "dists/$cn/$comp/binary-all/Packages"
      fi )
  done
  # Real Ubuntu publishes <codename>-updates with Suite: <codename>-updates but
  # Codename: <codename>, which is why a pin on "n=<codename>" covers it.
  ( cd "$A/dists/$cn"
    rm -f Release InRelease Release.gpg
    apt-ftparchive -o APT::FTPArchive::Release::Origin="$origin" \
                   -o APT::FTPArchive::Release::Label="$origin" \
                   -o APT::FTPArchive::Release::Suite="$cn" \
                   -o APT::FTPArchive::Release::Codename="${cn%-updates}" \
                   -o APT::FTPArchive::Release::Version="$version" \
                   -o APT::FTPArchive::Release::Architectures=all \
                   -o APT::FTPArchive::Release::Components="main universe" \
                   release . > Release
    gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback \
        --clearsign -o InRelease Release
    gpg --batch --quiet --yes --passphrase '' --pinentry-mode loopback \
        -abs -o Release.gpg Release )
  # The script configures <cn>-updates too; publish it empty so apt is happy.
  if [ "${4:-}" != "noupdates" ]; then
    publish "${cn}-updates" "$origin" "$version" noupdates
  fi
}

# --- the base system (Debian's side) -----------------------------------------
mkdeb debian-stable main gnome-shell   48.7-0+deb13u2
mkdeb debian-stable main dconf-cli   0.40.0-5
mkdeb debian-stable main plymouth    24.004.60-5
mkdeb debian-stable main yaru-theme-gnome-shell 24.04.3-1 'Breaks: gnome-shell (<< 46~)'
publish debian-stable Debian 13 noupdates

# --- Ubuntu-like releases -----------------------------------------------------
mkdeb alpha main yaru-theme-gnome-shell      24.04.2-0ubuntu1 'Breaks: gnome-shell (<< 46~)'
mkdeb alpha main yaru-theme-gtk        24.04.2-0ubuntu1
mkdeb alpha main ubuntu-wallpapers       24.04.2          'Depends: ubuntu-wallpapers-alpha'
mkdeb alpha main ubuntu-wallpapers-alpha 24.04.2
publish alpha Ubuntu 24.04

mkdeb bravo main yaru-theme-gnome-shell      25.04.1-0ubuntu1 'Breaks: gnome-shell (<< 48~)'
mkdeb bravo main yaru-theme-gtk        25.04.1-0ubuntu1
mkdeb bravo main ubuntu-wallpapers       25.04.2          'Depends: ubuntu-wallpapers-bravo'
mkdeb bravo main ubuntu-wallpapers-bravo 25.04.2
publish bravo Ubuntu 25.04

# charlie: shell theme needs a newer gnome-shell; gtk theme picked up an
# Ubuntu-only dependency the pin whitelist does not name.
mkdeb charlie main yaru-theme-gnome-shell        25.10.3-0ubuntu1 'Breaks: gnome-shell (<< 49~)'
mkdeb charlie main yaru-theme-gtk          25.10.3-0ubuntu1 'Depends: user-session-migration'
mkdeb charlie universe user-session-migration   0.5.0
mkdeb charlie main ubuntu-wallpapers         25.10.2          'Depends: ubuntu-wallpapers-charlie'
mkdeb charlie main ubuntu-wallpapers-charlie 25.10.2
publish charlie Ubuntu 25.10

mkdeb delta main yaru-theme-gnome-shell        26.04.5-0ubuntu1 'Breaks: gnome-shell (<< 49~)'
mkdeb delta main yaru-theme-gtk          26.04.5-0ubuntu1 'Depends: user-session-migration'
mkdeb delta universe user-session-migration   0.5.1
mkdeb delta main ubuntu-wallpapers         26.04.2          'Depends: ubuntu-wallpapers-delta'
mkdeb delta main ubuntu-wallpapers-delta   26.04.2
publish delta Ubuntu 26.04

# --- apt configuration --------------------------------------------------------
cat > "$T/apt.conf" <<EOF
Dir "$R/";
Dir::State "$R/var/lib/apt";
Dir::State::status "$R/var/lib/dpkg/status";
Dir::Cache "$R/var/cache/apt";
Dir::Etc "$R/etc/apt";
Dir::Etc::sourcelist "$R/etc/apt/sources.list";
Dir::Etc::sourceparts "$R/etc/apt/sources.list.d";
Dir::Etc::preferences "$R/etc/apt/preferences";
Dir::Etc::preferencesparts "$R/etc/apt/preferences.d";
Dir::Log "$R/var/log/apt";
DPkg::Options { "--root=$R"; "--force-not-root"; "--force-script-chrootless"; "--log=$R/var/log/dpkg.log"; };
Debug::NoLocking "true";
APT::Sandbox::User "";
EOF
echo "deb [signed-by=$R/etc/apt/keyrings/rig.gpg] file://$A debian-stable main" \
  > "$R/etc/apt/sources.list"

# --- pre-existing system state ------------------------------------------------
export APT_CONFIG="$T/apt.conf" DPKG_ADMINDIR="$R/var/lib/dpkg"
apt-get update -qq 2>/dev/null
apt-get install -y -qq gnome-shell dconf-cli plymouth >/dev/null 2>&1
echo "rig ready: $(dpkg-query -W -f='${Package}=${Version} ' gnome-shell dconf-cli plymouth)"
