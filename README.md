# make-debian-look-like-ubuntu

Origin: https://git.la10cy.net/DeltaLima/make-debian-look-like-ubuntu

This script performs all necessary steps to make a Debian 13 (trixie) Gnome desktop look like an Ubuntu desktop.
For older debian releases, please check out the [tags](https://git.la10cy.net/DeltaLima/make-debian-look-like-ubuntu/tags).

It also installs flatpak with flathub.org repository enabled and Firefox from there.

The settings are only applied to the user which is executing this script. The user has to be in the `sudo` group. If not, the script will advise you how to do so.

**Important!** After the first run of setup.sh, you have to **reboot and re-run** the script. 
When the script runs the first time, it is normal that the terminal font looks ugly after it. It's normal after a reboot.

## Installation

Just execute setup.sh and show will start:

```bash
$ bash make-debian-look-like-ubuntu_rev.sh
```

![Ubuntuish Debian 13 Gnome Desktop](screenshot/screenshot1.png "Ubuntuish Debian 13 Gnome Desktop")

## ubuntu-look.sh (reworked, single-run variant)

`ubuntu-look.sh` is a reworked version of the script above. It transforms a Debian GNOME
desktop into an authentic Ubuntu look — installing the genuine Yaru theme, Ubuntu fonts,
official wallpapers and ubuntu-dock, and applying all Ubuntu GNOME defaults (including
enabling the extensions) via a dconf system profile.

The main difference: settings take effect on the **first run** — there is no need to reboot
and re-run the script.

### Usage

```bash
$ chmod +x ubuntu-look.sh
$ ./ubuntu-look.sh
# or:
$ bash ubuntu-look.sh
```

Run as a normal user (not root) who is in the `sudo` group. Confirm with `y` when prompted,
enter your sudo password when asked, and follow the SUMMARY instructions shown at the end.
Re-runs are safe — already-installed packages and settings are skipped automatically.

Run a single stage only:

```bash
$ bash ubuntu-look.sh 2-desktop-gnome
# valid stages: 0-base  1-desktop-base  2-desktop-gnome
```

Force a specific Ubuntu codename for the theme repo:

```bash
$ UBUNTU_CODENAME=plucky bash ubuntu-look.sh
```

**Requires:** Debian 12+ with GNOME, user in the `sudo` group, and a working internet connection.
