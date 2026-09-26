# ubuntu-look

Gives Debian GNOME the look of Ubuntu: Yaru themes, Ubuntu fonts and wallpapers,
Ubuntu Dock, the tiling assistant, app indicators, desktop icons, Ubuntu's terminal
colours, a Yaru login screen and Ubuntu's boot splash.

The Ubuntu packages come from one release: the newest official Ubuntu release that fits
your GNOME Shell (for example, Debian 13 with GNOME 48 gets Ubuntu 25.04). No
applications are installed.

> **Debian's advice.** Debian's [DontBreakDebian](https://wiki.debian.org/DontBreakDebian)
> page advises against Ubuntu repositories on Debian. This script is a deliberate, limited
> exception, with these safeguards:
>
> - An apt pin blocks every Ubuntu package except the look's themes, fonts, wallpapers,
>   GNOME Shell extensions and `session-migration` (a Yaru dependency). No library or
>   core package comes from Ubuntu.
> - apt simulates each Ubuntu package first. One that would remove another package, or
>   does not fit Debian's GNOME Shell, is not installed.
> - apt changes happen only when you run the script, unless you opt in to the daily timer.
> - The uninstall purges everything the script installed and puts back Debian's builds.
>
> What remains: the Ubuntu packages get no support from Debian's security team, and Ubuntu
> may no longer support the chosen release either. `session-migration` contains a
> compiled program; the script keeps it switched off.

| Light | Dark |
| :---: | :---: |
| ![Debian GNOME with the Ubuntu look, light](screenshot/scr1.png) | ![Debian GNOME with the Ubuntu look, dark](screenshot/scr3.png) |
| ![Files and the terminal, light](screenshot/scr2.png) | ![Files and the terminal, dark](screenshot/scr4.png) |

## Requirements

- Debian with GNOME, on any architecture Ubuntu builds for (amd64, arm64, …)
- a user with sudo rights (not root)
- internet access, except for an offline install

## Usage

| Command | What it does |
|---|---|
| `bash ubuntu-look.sh` | Install, or update an existing install |
| `bash ubuntu-look.sh --uninstall` | Undo everything the install did |
| `bash ubuntu-look.sh --prepare-upgrade` | Run before a Debian release upgrade |
| `bash ubuntu-look.sh --download` | Build `packages/` for an offline install |
| `bash ubuntu-look.sh --offline` | Install from `packages/`, without network |
| `bash ubuntu-look.sh --help` | Show all commands and options |

Confirm with `y` and enter your sudo password. Reboot when the script says so; otherwise
log out and back in. Running it again is safe.

The look applies to the user who runs the script. Other users keep Debian's look until
they run it themselves. The login screen and boot splash are shared by all users.

## Options

Set as environment variables, e.g. `UBUNTU_BOOT_SPLASH=0 bash ubuntu-look.sh`.

| Option | Effect |
|---|---|
| `UBUNTU_CODENAME=<name>` | Use this Ubuntu release (`auto`: the newest that fits) |
| `UBUNTU_INCLUDE_DEVEL=1` | Also consider the Ubuntu release in development |
| `UBUNTU_MIRROR=<url>` | Ubuntu mirror (default: `archive.ubuntu.com`; `ports.ubuntu.com` on other architectures) |
| `UBUNTU_BOOT_SPLASH=0` | No boot splash (removes one added earlier) |
| `PLYMOUTH_THEME=<name>` | Boot splash theme (default `bgrt`) |
| `UBUNTU_LOOK_AUTO_REFRESH=1` | Daily update timer (off by default; `0` removes it) |
| `UBUNTU_LOOK_SYSTEM_UPGRADE=1` | Also upgrade the rest of the system |
| `UBUNTU_LOOK_FORCE_BUNDLE=1` | Offline: accept a bundle built for another Debian or GNOME version |
| `UBUNTU_LOOK_LOG=0` | No log file |

The first six options are saved and reused by later runs until given again; the others
apply to one run.

## What it changes

- **Packages:** Yaru, Ubuntu fonts, wallpapers, Ubuntu Dock and the tiling assistant from
  the chosen Ubuntu release. App indicators and desktop icons come from Debian, or from
  Ubuntu's combined extensions package where the release ships one. Debian's own builds
  of Yaru and the fonts are replaced, and put back on uninstall.
- **apt:** an Ubuntu source and a pin that allows only the look's packages
  (`/etc/apt/sources.list.d/ubuntu-themes.list`, `/etc/apt/preferences.d/ubuntu-themes`).
- **Settings:** Ubuntu's GNOME defaults, as the release's `ubuntu-settings` sets them, for
  users who installed the look only. The first install replaces your theme, light or dark
  style, wallpaper, dock and other settings with Ubuntu's; dock favourites stay. Settings
  you change afterwards are kept by later runs.
- **Dock:** an enabled Dash-to-Dock is turned off for you; Ubuntu Dock replaces it.
- **Terminal:** a gnome-terminal profile named Ubuntu, made the default.
- **Login screen and boot:** Yaru on the GDM login screen; `splash` on the kernel command
  line and a Plymouth theme.
- **Records:** `/var/lib/ubuntu-look/`, `~/.ubuntu-look-backup/` and
  `~/.config/environment.d/90-ubuntu-look.conf`, which switches the look on for you.

## Staying up to date

- Updates within the chosen Ubuntu release arrive with your own `apt upgrade`.
- Run `bash ubuntu-look.sh` again to move to a newer Ubuntu release once one fits your
  GNOME Shell, for example after a Debian release upgrade.
- To have this done daily, run the install with `UBUNTU_LOOK_AUTO_REFRESH=1`. The timer
  runs unattended and logs to the journal:

  ```bash
  $ systemctl list-timers ubuntu-look-refresh.timer     # next run
  $ sudo journalctl -u ubuntu-look-refresh.service      # what it did
  ```

## Upgrading Debian

1. `bash ubuntu-look.sh --prepare-upgrade` removes what would block the upgrade: Ubuntu's
   source and pin, the daily timer and the packages tied to the current GNOME Shell.
   Yaru, the fonts and the wallpapers stay.
2. Upgrade Debian and reboot.
3. `bash ubuntu-look.sh` installs the look for the new GNOME Shell.

## Offline install

1. On an online machine with the same Debian release, architecture and GNOME Shell
   version, run `bash ubuntu-look.sh --download`. This fills `packages/` and leaves the
   machine's apt setup as it was.
2. Copy `ubuntu-look.sh` and `packages/` to the offline machine.
3. There, run `bash ubuntu-look.sh --offline`.

An offline install adds no Ubuntu apt source and no timer; a later online run adds the
source.

## Uninstall

```bash
$ bash ubuntu-look.sh --uninstall
```

Run it from your desktop session. It lists every package before removing it and asks for
confirmation. Reboot afterwards when it says so; otherwise log out and back in.

For you:

- Every setting the look writes returns to Debian's default, including any you changed
  while it was installed: appearance, wallpaper, dock, power, keybindings and touchpad.
  The wallpaper is Debian's in both light and dark style.
- Dash-to-Dock is turned back on, with its default settings, where the install turned it off.
- Dock favourites and your other settings stay.

When the last user of the look uninstalls:

- The packages the look installed are purged, and their downloaded files are removed from
  apt's cache. Replaced packages get Debian's build back. Packages you had before or
  installed later, and apt sources you added, are never removed.
- The Ubuntu source, the pin and the timer are removed.
- The login screen returns to Debian's. `splash` leaves the kernel command line, and the
  boot splash theme returns to the one used before the install.

If a step cannot finish, run `--uninstall` again later to complete it.

## Tweaking

Every setting is a normal GSettings key; your own value always overrides the look's.

```bash
$ gsettings set org.gnome.shell.extensions.dash-to-dock dock-position BOTTOM   # LEFT RIGHT BOTTOM TOP
$ gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false    # centred dock
$ gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 32
$ gsettings set org.gnome.desktop.interface color-scheme prefer-dark           # dark style
$ gsettings set org.gnome.desktop.interface accent-color purple                # GNOME 47+
$ gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:'
$ gsettings reset <schema> <key>                                                # back to the look's value
```

Dock settings window: `gnome-extensions prefs ubuntu-dock@ubuntu.com`.

## How the script is organised

`ubuntu-look.sh` is one file in nine numbered sections, listed at its top:

| Section | Contents |
|---|---|
| 1. Helpers | messages, records, options, dconf values |
| 2. Packages | apt, the Ubuntu release, sources and pin |
| 3. Desktop | Ubuntu's settings, extensions, terminal, login screen |
| 4. Boot | GRUB command line and boot splash |
| 5. Records | migration, daily refresh, summary |
| 6. Offline | `--download`, `--offline`, `--prepare-upgrade` |
| 7. Setup | help, run log, mode, options, variables |
| 8. Uninstall | `--uninstall` |
| 9. Install | the install itself |

## Logs

Each run writes a log to your home directory: `~/ubuntu-look-<date>.log`, or
`~/uninstall-<date>.log` for `--uninstall`. The daily timer logs to the journal.

## Credits

Based on **make-debian-look-like-ubuntu** by DeltaLima
(https://github.com/DeltaLima/make-debian-look-like-ubuntu).
