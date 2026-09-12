# tests

An integration suite for the package-resolution half of `ubuntu-look.sh`: the
part that decides which Ubuntu release to pin, what to install, what to carry
forward when a new Ubuntu is published, and what to leave alone when it will
not fit.

Nothing here is mocked. `build-rig.sh` produces real `.deb` packages, a real
GPG-signed archive in the genuine `dists/` layout, and a real dpkg database,
all under `$TMPDIR`. The suite then runs the script's own functions and its own
stage loop — extracted from `ubuntu-look.sh` at run time, so the test cannot
drift from the code — against a real apt resolver. The only thing replaced is
`sudo`, which becomes a pass-through: everything is owned by the user running
it, and nothing outside `$TMPDIR` is touched.

    bash tests/run-all.sh     # both suites
    bash tests/run.sh         # ubuntu-look.sh only
    bash tests/run-offline.sh # ubuntu-look-offline.sh only
    bash tests/mutate.sh      # check the suite can actually fail

Optional: `RIG=/path` puts the rig somewhere else, `KEEP_RIG=1` reuses the one
that is already there.

The rig mirrors the real dependency shapes rather than inventing new ones:

| rig package | stands for |
|---|---|
| `gnome-shell` | the Debian GNOME the machine actually runs |
| `yaru-theme-gnome-shell` | `Breaks: gnome-shell (<< N~)` — the hard constraint |
| `yaru-theme-gtk` | the floating theme, and its Ubuntu-only dependency |
| `ubuntu-wallpapers` | the metapackage that depends on a per-release pack |
| `user-session-migration` | an Ubuntu-only dependency the pin does not whitelist |

Suites `alpha` … `golf` stand in for consecutive Ubuntu releases. The pin is not
reimplemented here — it is read out of `ubuntu-look.sh` verbatim.

## What it covers

- **T1** fresh install: codename resolved by simulation; the shell theme comes
  from the pinned release; the GTK theme walks back two releases when its
  newest build needs a pin-blocked dependency.
- **T2** a new Ubuntu is published: the cross-release upgrade that
  `apt-get upgrade` refuses to do (the control case is asserted in the same
  run), and the new per-release pack recorded for uninstall.
- **T3** Ubuntu outruns Debian: the compatible release ages out of the window,
  and the lookback reaches back for it and keeps exactly one extra suite.
- **T5** a second run changes nothing.
- **T6** a newer build that cannot be installed is refused, not forced, and the
  reason names the missing dependency.
- **T7** a Debian release upgrade: `gnome-shell` moves, the pin re-resolves
  forward, and the shell theme is carried onto it.
- **T8** guards: a package that predates the install is left alone; reported
  versions are versions and not apt's output; the version walk never steps
  above the version the pin selected.
- **T9** ordinary updates: a point update published to `<codename>-updates`,
  and an update to a pre-existing package that needs a package not yet
  installed.
- **T4** uninstall: nothing the script installed is left behind, nothing that
  predates the install is removed, and a Debian package pulled in by the system
  upgrade is correctly kept.

## Checking the tests

`mutate.sh` breaks each fix on purpose and requires the suite to fail. A test
that still passes against a broken script is not testing anything. All eight
mutations are currently caught.

Blocks lifted out of the scripts are located by code, never by comment text,
and an extraction that comes back empty is a hard error — a reworded comment
must not quietly turn a test into a no-op.

`run-offline.sh` drives the same rig through `ubuntu-look-offline.sh`'s own
helpers and stage loop, with `LOCAL_APT_OPTS` emptied so they read the rig's
apt configuration: a fresh install from a bundle, and a bundle refreshed after
a new Ubuntu.
