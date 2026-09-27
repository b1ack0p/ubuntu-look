# ubuntu-look

Gives Debian GNOME the look of Ubuntu: Yaru themes, Ubuntu fonts and wallpapers,
Ubuntu Dock, the tiling assistant, app indicators, desktop icons, Ubuntu's terminal
colours, a Yaru login screen and Ubuntu's boot splash. No applications are installed.

The Ubuntu packages come from one release: the newest official Ubuntu release whose
Yaru and Ubuntu Dock work with your GNOME Shell. For example, Debian 13 (GNOME 48) gets
Ubuntu 25.04. The release is found each time the script runs.

> **Debian's advice.** Debian's [DontBreakDebian](https://wiki.debian.org/DontBreakDebian)
> page advises against Ubuntu repositories on Debian. This script is a deliberate, limited
> exception, with these safeguards:
>
> - An apt pin blocks every Ubuntu package except the look's own (listed under
>   [Packages](#packages)). No library or core package comes from Ubuntu.
> - apt simulates each Ubuntu package first. One that would remove another package, or
>   does not fit Debian's GNOME Shell, is not installed.
> - apt changes happen only when you run the script. Nothing runs in the background.
> - The uninstall purges everything the script installed and puts back Debian's builds.
>   Kept: `curl` and `ca-certificates`, which the script needs, packages you hold,
>   `ubuntu-keyring` while another apt source uses it, `dconf-cli` while your
>   settings still need resetting, and any package whose removal would also remove
>   another package.
>
> What remains: the Ubuntu packages get no support from Debian's security team, and Ubuntu
> may no longer support the chosen release either. `session-migration` contains a
> compiled program; the script keeps it switched off.

| Light | Dark |
| :---: | :---: |
| ![Debian GNOME with the Ubuntu look, light](screenshot/scr1.png) | ![Debian GNOME with the Ubuntu look, dark](screenshot/scr3.png) |
| ![Files and the terminal, light](screenshot/scr2.png) | ![Files and the terminal, dark](screenshot/scr4.png) |

## Requirements

- Debian with GNOME, on an architecture Ubuntu builds for (amd64, arm64, …)
- a user with sudo rights (not root)
- internet access, except for an offline install
- GNOME Shell 45 or later for the shell theme and the login screen extension

## Usage

```bash
bash ubuntu-look.sh                    # install or update
bash ubuntu-look.sh --refresh          # list updates, then ask
bash ubuntu-look.sh --uninstall        # undo everything
bash ubuntu-look.sh --prepare-upgrade  # before a Debian upgrade
bash ubuntu-look.sh --download         # build packages/
bash ubuntu-look.sh --offline          # install from packages/
bash ubuntu-look.sh 2-desktop-gnome    # only the named stages
bash ubuntu-look.sh --help             # all commands and options
```

Run it from your desktop session. Confirm with `y` and enter your sudo password. At the
end, the script says whether to reboot or to log out and back in; a reboot covers both.
Running it again is safe.

The look applies to the user who runs the script. Other users keep Debian's look until
they run it themselves. The login screen and boot splash are shared by all users.

## Options

Options are environment variables. Put them in front of the command:

```bash
UBUNTU_BOOT_SPLASH=0 bash ubuntu-look.sh
```

Several at once:

```bash
UBUNTU_CODENAME=noble UBUNTU_BOOT_SPLASH=0 \
  bash ubuntu-look.sh
```

**Saved options.** These five are remembered by each full run (one without stage
names) and reused by later runs, until you give them again. `--offline` saves
only the two boot splash options.

- `UBUNTU_CODENAME=<name>`
  - Use this Ubuntu release, for example `noble`.
  - Default: `auto`, the newest release that fits your GNOME Shell.
  - Back to automatic: `UBUNTU_CODENAME=auto`.
- `UBUNTU_INCLUDE_DEVEL=1`
  - Also consider the Ubuntu release still in development.
  - Default: `0`, released versions only.
- `UBUNTU_MIRROR=<url>`
  - Get the Ubuntu packages from this mirror.
  - Default: `http://archive.ubuntu.com/ubuntu`, or
    `http://ports.ubuntu.com/ubuntu-ports` on architectures other than amd64
    and i386.
- `UBUNTU_BOOT_SPLASH=0`
  - Leave the boot splash out, and remove one added earlier.
  - Default: `1`, boot splash on.
- `PLYMOUTH_THEME=<name>`
  - Boot splash theme. `/usr/sbin/plymouth-set-default-theme -l` lists the
    installed ones.
  - Default: `bgrt`, the Ubuntu-style splash with the computer maker's logo.

**One-run options.** These apply only to the run they are given to.

- `UBUNTU_LOOK_SYSTEM_UPGRADE=1`
  - Also upgrade the rest of the system, as `apt upgrade` does.
  - Default: off; the script upgrades only the look's packages.
- `UBUNTU_LOOK_FORCE_BUNDLE=1`
  - `--offline` only: accept a bundle built for another Debian release or GNOME
    Shell version.
  - Default: off; such a bundle is refused.
- `UBUNTU_LOOK_LOG=0`
  - Write no log file.
  - Default: a log in your home directory.

## What it changes

### Packages

From the chosen Ubuntu release (the only packages the pin allows):

- **Yaru:** `yaru-theme-gtk`, `yaru-theme-icon`, `yaru-theme-sound` and
  `yaru-theme-gnome-shell`, for apps, icons, sounds and the shell.
- **Fonts:** `fonts-ubuntu`.
- **Wallpapers:** `ubuntu-wallpapers` and the release's own set,
  `ubuntu-wallpapers-<release>`.
- **Ubuntu Dock:** `gnome-shell-extension-ubuntu-dock`.
- **Window tiling:** `gnome-shell-extension-ubuntu-tiling-assistant`.
- **Fallback icons:** `humanity-icon-theme`, which Yaru builds on.
- **session-migration:** needed by Yaru; kept switched off by a user-unit mask,
  `/etc/systemd/user/session-migration.service`.

From Debian (Debian's own builds, not Ubuntu's):

- **Tray icons in the top bar:** `gnome-shell-extension-appindicator`, with
  `gir1.2-dbusmenu-gtk3-0.4` for their menus.
- **Files and folders on the desktop:** `gnome-shell-extension-desktop-icons-ng`.
- **Boot splash:** `plymouth` and `plymouth-themes`.
- **Settings tool:** `dconf-cli`.
- **Ubuntu's archive keys:** `ubuntu-keyring`, used by apt to verify the Ubuntu packages.

Some Ubuntu releases ship their shell extensions as one package,
`gnome-shell-ubuntu-extensions`, which contains Ubuntu Dock, the tiling assistant, app
indicators and desktop icons together. When the chosen release has that package, the
script installs it instead of the separate extension packages. If Debian's
`gnome-shell-extension-desktop-icons-ng` or `gnome-shell-extension-appindicator` was
installed, it is replaced, and the uninstall puts it back.

Debian's own builds of Yaru, the Ubuntu fonts and wallpapers, if installed, are
replaced by Ubuntu's and put back on uninstall.

### System

- **apt:** an Ubuntu source (`/etc/apt/sources.list.d/ubuntu-themes.sources`) and a pin
  (`/etc/apt/preferences.d/ubuntu-themes`) that allows only the Ubuntu packages above.
- **Login screen:** Yaru on the GDM login screen (`/etc/dconf/db/gdm.d/10-ubuntu-look`
  and a login screen extension). The dconf profiles `/etc/dconf/profile/gdm` and
  `/etc/dconf/profile/Debian-gdm` are created where missing.
- **Ubuntu's defaults:** `/etc/dconf/db/ubuntu_look.d/`, read through the dconf profile
  `/etc/dconf/profile/ubuntu-look`, and a shell theme extension in
  `/usr/local/share/gnome-shell/extensions/`.
- **Boot:** `quiet splash`, whichever is missing, added to the kernel command line in
  `/etc/default/grub`, and the
  Plymouth boot splash theme set (default `bgrt`). The rest of your GRUB settings are
  not touched.

### Your session

- **Settings:** Ubuntu's GNOME defaults, as Ubuntu's `ubuntu-settings` sets them,
  apply to users who installed the look. The first install replaces your theme, light or
  dark style, wallpaper, fonts, dock and other look settings with Ubuntu's; your dock
  favourites stay. Settings you change afterwards are kept by later runs. The main
  Ubuntu defaults:
  - Theme, icons, cursor and sounds: Yaru, light style, orange accent.
  - Fonts: Ubuntu Sans 11, Ubuntu Sans Mono 13.
  - Window buttons: minimize, maximize and close, on the right.
  - Dock: on the left, full height, always shown, icons up to 48 pixels.
  - Desktop icons: from the bottom right, without trash or drives.
  - Hot corner: off. Touchpad: tap to click.
  - Keyboard: Alt+Tab switches windows, Super+Tab switches applications.
  - Power button: asks what to do. No automatic sleep on mains power.
- **Dock:** Dash-to-Dock, if enabled, is turned off for you; Ubuntu Dock replaces it.
- **Terminal:** a gnome-terminal profile named Ubuntu, made the default when the look
  creates it or you have none, and the dark terminal theme variant.
- **Show Applications button:** the Debian logo, in the Ubuntu Dock only
  (`~/.local/share/icons/Yaru/`).
- **Extensions at the next login:** a one-shot autostart entry,
  `~/.config/autostart/ubuntu-look-enable-extensions.desktop`, and its script in
  `~/.local/share/ubuntu-look/`, which switch the look's extensions on and then
  remove themselves. If an extension cannot be switched on, they stay for one more
  login.
- **Records:** `/var/lib/ubuntu-look/`, `~/.ubuntu-look-backup/` and
  `~/.config/environment.d/90-ubuntu-look.conf`, which switches the look on for you.

## Staying up to date

- Updates within the chosen Ubuntu release arrive with your own `apt upgrade`.
- `bash ubuntu-look.sh --refresh` checks for updates to the look and lists them:
  - a newer Ubuntu release, or a Debian or GNOME Shell change, that moves the
    look to another release;
  - newer builds of the look's packages;
  - a look package that no longer supports your GNOME Shell;
  - an option given now that differs from the last full run's.

  If it finds any, it asks before applying them, then ends with a reboot or log
  out notice when one is needed. If there are none, it says the look is up to
  date and changes nothing. It refreshes apt's package lists first.
- `bash ubuntu-look.sh` applies the same updates without listing them first.

## Upgrading Debian

1. `bash ubuntu-look.sh --prepare-upgrade` first lists what it will remove, then asks:
   - the packages tied to the current GNOME Shell: Ubuntu Dock, the tiling
     assistant and Yaru's shell theme (with Ubuntu's combined extensions package,
     also the app indicators and desktop icons it contains), plus anything apt
     would remove with them;
   - the Ubuntu apt source and pin.

   Yaru's app, icon and sound themes, the fonts, the wallpapers and `ubuntu-keyring`
   stay, so the desktop keeps most of its look during the upgrade.
2. Upgrade Debian and reboot.
3. `bash ubuntu-look.sh` installs the look for the new GNOME Shell.

## Offline install

1. On an online machine with the same Debian release, architecture and GNOME Shell
   version, run `bash ubuntu-look.sh --download`. This fills `packages/` and leaves that
   machine's apt setup as it was. On a machine without the look it keeps no records,
   and removes `ubuntu-keyring` again if it had to install it.
2. Copy `ubuntu-look.sh` and `packages/` to the offline machine.
3. There, run `bash ubuntu-look.sh --offline`.

An offline install adds no Ubuntu apt source; a later online run adds it.

## Uninstall

```bash
bash ubuntu-look.sh --uninstall
```

Run it from your desktop session. It lists the packages before removing them and asks
for confirmation. At the end, it says whether to reboot or to log out and back in.

For you:

- Every setting the look writes returns to Debian's default, including any you changed
  while it was installed: appearance, wallpaper, fonts, dock, power, keybindings and
  touchpad. The wallpaper is Debian's in both light and dark style, and a Yaru colour
  scheme in gedit returns to gedit's default.
- Dash-to-Dock is turned back on, with its default settings, if the install turned it off.
- The Ubuntu terminal profile and the look's helper files (the Show Applications icon,
  the one-shot autostart) are removed; your own terminal profiles and default stay.
- Your dock favourites and your other settings stay.

When the last user of the look uninstalls:

- The packages the script installed are purged, and their downloaded files are removed
  from apt's cache.
- Dependencies that only those packages used are purged too, after a second
  confirmation, so no `apt autoremove` is needed afterwards.
- Debian's builds of replaced packages are put back.
- Packages you had before or installed later, and apt sources you added, are never
  removed.
- The Ubuntu source and the pin are removed.
- The login screen returns to Debian's. The words the script added (`quiet`, `splash`)
  leave the kernel command line, and the
  boot splash theme returns to the one used before the install.

If a step cannot finish, run `--uninstall` again later to complete it.

## Settings: Ubuntu's defaults and Debian's

The look applies Ubuntu's defaults, for how the desktop looks and how it
behaves. The tables compare them with Debian's. Your own value always overrides
the look's, later runs keep it, and the uninstall returns every one of these to
Debian's default.

### Keyboard and windows

| Setting | Ubuntu (the look) | Debian |
|---|---|---|
| Alt+Tab | switches windows | switches apps |
| Super+Tab | switches apps | switches apps |
| Super+D | shows the desktop | nothing |
| Window buttons | minimize, maximize, close (right) | close only |
| Middle-click on title bar | lowers the window | nothing |
| Hot corner (top left) | off | on |

### Power

| Setting | Ubuntu (the look) | Debian |
|---|---|---|
| Power button | asks (Power Off dialog) | suspend |
| Sleep on mains power | never | after 15 min idle |
| Log Out in the menu | always shown | with several users |

### Touchpad and sound

| Setting | Ubuntu (the look) | Debian |
|---|---|---|
| Tap to click | on | on (off in older GNOME) |
| Right click | area or two fingers (as the touchpad) | two fingers |
| Sound theme | Yaru | freedesktop |
| Input feedback sounds | on | off |

### Appearance

| Setting | Ubuntu (the look) | Debian |
|---|---|---|
| Style | light | light |
| Accent colour | orange | blue |
| Theme, icons, cursor | Yaru | Adwaita |
| Interface font | Ubuntu Sans 11 | Cantarell 11 |
| Monospace font | Ubuntu Sans Mono 13 | Monospace 11 |
| Dock | Ubuntu Dock, left | none (Dash in overview) |
| Desktop icons | shown, from bottom right | none |

As on Ubuntu, a new accent colour applies to the whole desktop: the
theme and icons move to the matching Yaru colour, for example
Yaru-purple or Yaru-purple-dark. Orange returns plain Yaru.

### Files and file dialogs

| Setting | Ubuntu (the look) | Debian |
|---|---|---|
| Icon size in Files | small | medium |
| Open folder on drag hover | off | on |
| Folders first in dialogs (GTK 3) | on | off |
| Dialogs start in | current folder | recent files |

### Changing a setting

Set your own value with `gsettings set`. To go back to Ubuntu's value, use
`gsettings reset` with the same schema and key.

Keyboard and windows:

```bash
# Alt+Tab switches apps, as on Debian
gsettings set org.gnome.desktop.wm.keybindings \
  switch-windows "[]"
gsettings set org.gnome.desktop.wm.keybindings \
  switch-windows-backward "[]"
gsettings set org.gnome.desktop.wm.keybindings \
  switch-applications "['<Super>Tab', '<Alt>Tab']"
gsettings set org.gnome.desktop.wm.keybindings \
  switch-applications-backward \
  "['<Shift><Super>Tab', '<Shift><Alt>Tab']"
# window buttons on the left
gsettings set org.gnome.desktop.wm.preferences \
  button-layout 'close,minimize,maximize:'
# middle-click on title bar, e.g. none, lower, minimize
gsettings set org.gnome.desktop.wm.preferences \
  action-middle-click-titlebar none
# hot corner on
gsettings set org.gnome.desktop.interface \
  enable-hot-corners true
```

Power:

```bash
# power button: suspend, interactive, hibernate, nothing
gsettings set org.gnome.settings-daemon.plugins.power \
  power-button-action suspend
# sleep after 15 minutes idle on mains power (0 = never)
gsettings set org.gnome.settings-daemon.plugins.power \
  sleep-inactive-ac-timeout 900
```

Touchpad and sound:

```bash
# right click: default, fingers, areas
gsettings set org.gnome.desktop.peripherals.touchpad \
  click-method fingers
# no sounds on input
gsettings set org.gnome.desktop.sound \
  input-feedback-sounds false
```

Appearance:

```bash
# style: default (light) or prefer-dark
gsettings set org.gnome.desktop.interface \
  color-scheme prefer-dark
# accent: blue, teal, green, yellow, orange, red,
# pink, purple, slate (GNOME 47 and later)
gsettings set org.gnome.desktop.interface \
  accent-color purple
```

Dock (Ubuntu Dock):

```bash
# position: LEFT (Ubuntu), RIGHT, BOTTOM or TOP
gsettings set org.gnome.shell.extensions.dash-to-dock \
  dock-position BOTTOM
# full height (Ubuntu: true); false centres the dock
gsettings set org.gnome.shell.extensions.dash-to-dock \
  extend-height false
# always shown (Ubuntu: true); false hides it
gsettings set org.gnome.shell.extensions.dash-to-dock \
  dock-fixed false
# largest icon size in pixels (Ubuntu: 48)
gsettings set org.gnome.shell.extensions.dash-to-dock \
  dash-max-icon-size 32
# the dock's settings window
gnome-extensions prefs ubuntu-dock@ubuntu.com
```

Back to Ubuntu's value, for example the power button:

```bash
gsettings reset org.gnome.settings-daemon.plugins.power \
  power-button-action
```

## How the script is organised

`ubuntu-look.sh` is one file in nine numbered sections, listed at its top:

| Section | Contents |
|---|---|
| 1. Helpers | messages, records, options, dconf values |
| 2. Packages | apt, the Ubuntu release, sources and pin |
| 3. Desktop | Ubuntu's settings, extensions, terminal, login screen |
| 4. Boot | GRUB command line and boot splash |
| 5. Records | `--refresh`, summary |
| 6. Offline | `--download`, `--offline`, `--prepare-upgrade` |
| 7. Setup | help, run log, mode, options, variables |
| 8. Uninstall | `--uninstall` |
| 9. Install | the install itself |

## Logs

Each run writes a log to your home directory: `~/ubuntu-look-<date>.log`, or
`~/uninstall-<date>.log` for `--uninstall`.

## Credits

Based on **make-debian-look-like-ubuntu** by DeltaLima
(https://github.com/DeltaLima/make-debian-look-like-ubuntu).
