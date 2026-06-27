# ubuntu-look

Transform a fresh Debian GNOME desktop into an authentic Ubuntu look.

`ubuntu-look.sh` installs the genuine **Yaru** theme, **Ubuntu fonts**, official
**wallpapers** and **ubuntu-dock**, and applies all Ubuntu GNOME defaults — including
enabling the extensions — via a dconf system profile. It also sets up **flatpak** with the
flathub.org repository enabled.

Unlike the original, everything takes effect on the **first run** — there is no need to
reboot and re-run the script.

![Ubuntuish Debian 13 Gnome Desktop](screenshot/screenshot1.png "Ubuntuish Debian 13 Gnome Desktop")

## Usage

Run as a normal user (**not** root) who is in the `sudo` group:

```bash
$ chmod +x ubuntu-look.sh
$ ./ubuntu-look.sh
# or:
$ bash ubuntu-look.sh
```

Confirm with `y` when prompted, enter your sudo password when asked, and follow the SUMMARY
instructions shown at the end (log out / reboot as needed). Re-runs are safe — already
installed packages and settings already in place are skipped automatically.

### Run a single stage

```bash
$ bash ubuntu-look.sh 2-desktop-gnome
# valid stages: 0-base  1-desktop-base  2-desktop-gnome
```

### Force a specific Ubuntu codename for the theme repo

```bash
$ UBUNTU_CODENAME=plucky bash ubuntu-look.sh
```

## Requirements

- Debian 12+ with the GNOME desktop
- The executing user must be in the `sudo` group (the script advises you how if not)
- A working internet connection

## Credits

This is a reworked version of **make-debian-look-like-ubuntu** by **DeltaLima**.

- Original: https://github.com/DeltaLima/make-debian-look-like-ubuntu
- Upstream source: https://git.la10cy.net/DeltaLima/make-debian-look-like-ubuntu

The original `make-debian-look-like-ubuntu_rev.sh` is kept in this repository for reference.
For older Debian releases, check out the upstream
[tags](https://git.la10cy.net/DeltaLima/make-debian-look-like-ubuntu/tags).
