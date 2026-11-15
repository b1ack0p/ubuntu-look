# Resume notes — ubuntu-look

Updated 2026-11-14. This file is untracked; delete it or keep it out of commits.

## Where things stand

- `main` and `origin/main` are at `0a4da28`. Nothing since is committed.
- **Uncommitted work** in `ubuntu-look.sh` (now version 1.1), `README.md` and
  everything under `tests/`. It is two things:
  1. The earlier rounds: backup folder removed, `--refresh` always repairs,
     `--uninstall` resets every setting the look sets.
  2. The fixes for the full audit of 2026-11-14 (script, README, tests, VM
     harness).
- All of it is verified:
  - `bash tests/run-tests.sh`: 283 passed, 0 failed
  - `shellcheck -S warning ubuntu-look.sh tests/*.sh tests/vm/*.sh`: clean
  - `python3 tests/lint-scope.py ubuntu-look.sh`: 0 scope problems
  - `bash tests/vm-test.sh` (real run in the Debian 13 VM): 106 passed, 0 failed
  - `bash tests/vm-upgrade-test.sh` (trixie to forky, both variants):
    92 passed, 0 failed
  - `bash tests/vm/make-vm.sh` into a separate folder: built a working VM
    in about 12 minutes; that folder was deleted afterwards

## The four commands

| Command | What it does | The look's settings | Your files |
|---|---|---|---|
| `bash ubuntu-look.sh` | install, or repair and update | reset to the look's defaults | not touched |
| `--reset` | repair and update an installed look | reset to the look's defaults | not touched |
| `--refresh` | list updates, ask, then update and repair | not touched | not touched |
| `--uninstall` | remove the Ubuntu session and everything installed; Debian's GNOME remains | reset to Debian's defaults | not touched |

## Behaviour changed by the audit fixes

- Closing the terminal during the reboot countdown no longer reboots.
- `--reset` refuses after an install that did not finish (it needs the pin's
  version line, as `--refresh` does).
- A plain run without a desktop session lists the settings reset under
  "Not done", exits 1 and does not reboot by itself.
- A declined `--refresh` exits 1.
- A run declined or refused before it changed anything keeps no log file.
- `UBUNTU_LOOK_REBOOT`, `UBUNTU_LOOK_LOG` and `UBUNTU_LOOK_SYSTEM_UPGRADE`
  take 0 or 1 only; an empty argument is refused; `UBUNTU_MIRROR` takes no
  user name or password.
- A reset and the uninstall leave an extension's settings alone when the
  user has a build of their own of it (Debian's Dash to Dock, or one from
  extensions.gnome.org).
- The uninstall puts back the user's own tiling shortcuts from the tiling
  assistant's saved values; Debian's default only where they had none.
- A pick of "Ubuntu on Xorg" on the login screen is kept by every run.
- The login screen's Ubuntu entries are written last, once the session's
  files are in place.

## Fixed after the audit round

- A complete uninstall removes the look's run logs from the home folder,
  its own included; an uninstall with work left over keeps them.
- The Ctrl+Alt+T entry added to the user's own shortcuts carries its name,
  command and keys, so it shows and works in Debian's GNOME session too.
- A reset leaves the user's wallpaper alone when the look has none to show.
- Found by the first upgrade-test run: on forky (GNOME Shell 51) the user's
  colour scheme holds 'prefer-light' after login in the Ubuntu session, and
  every plain run reset it. What writes the value was not established.
- The style is now read from the Ubuntu release itself on every run
  (`read_ubuntu_style`): the shell's style from Ubuntu's session mode in
  `gnome-shell-common`, the apps' `color-scheme` from `ubuntu-settings`,
  both downloaded and read, never installed. The session mode, the look's
  defaults and the reset follow it; the uninstall goes to Debian's default.
  Today plucky and stonking both give shell prefer-light, apps GNOME's
  default. The rest of the look's defaults are still the script's table.
- The values of the look's settings are now read from the release too
  (`apply_release_settings`): Ubuntu's defaults file in `ubuntu-settings`,
  the ":ubuntu" sections winning. `GNOME_SETTINGS` says which settings are
  the look and holds the fallback values. `UBUNTU_DEFAULTS_LEFT_OUT` lists
  what is left out on purpose; `UBUNTU_DEFAULTS_LATER` lists defaults only
  later releases set, applied only when the chosen release sets them. A
  default the script does not know is reported in the summary, not applied.
  On forky this followed 26.10's monospace size 11 and found its new
  start-in-overview default, which was then added to the look.
- Owner's rules, stated 2026-11-14: real exact Ubuntu look and behaviour
  from the newest released Ubuntu that the latest Debian's GNOME takes,
  without breaking Debian; power and touchpad defaults count as Ubuntu
  behaviour and stay in the look; uninstall restores Debian's GNOME.
- Confirmed from both archives on 2026-11-14: Debian 13 (GNOME Shell 48.7)
  takes Ubuntu 25.04 plucky; forky (51.0) takes 26.10 stonking. The README
  has the tables ("Which Ubuntu release you get").
- Further release-following, all read from the pinned release's own
  packages (downloaded and read, never installed): login-screen values and
  wallpaper names (`ubuntu-settings`); session mode stylesheet, theme and
  extension list (`gnome-shell-common`), less extensions named
  `@canonical.com`; session name and comment (`ubuntu-session`); terminal
  shortcut keys (`gnome-settings-daemon-common`); font smoothing through
  the standard fontconfig files Ubuntu enables (`fontconfig-config`);
  terminal colours from the installed Yaru theme (`yaru_terminal_colours`);
  every default Ubuntu sets for its session where this Debian has the
  schema; look packages Ubuntu's desktop depends on, adopted when their
  simulated install is clean (`adopt_release_look_packages`).
- Decided by the owner: Debian's GNOME Shell stays (Ubuntu's is not
  installed); Ubuntu's settings package is read, not installed; logo, boot
  splash stay Debian's; Canonical's services stay out.
- The README has "Where each feature comes from": one table of every
  feature, whether it is from real Ubuntu, its source and the reason.
- The last VM runs were on the script before one log-only change (the
  terminal colours are now always logged); unit tests cover that change.
- Do not edit a test script while it is running: bash reads it as it goes.
  Do not stop a test with `pkill -f`: it matches the calling shell too.

## What to do next

1. Commit and push to `main` (not done; waiting for the go-ahead).
2. Test timings measured today: vm-test about 12 minutes, the upgrade test
   about 40 minutes for both variants, make-vm about 12 minutes.
