# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

Initial structured release of the two-component design (GNOME Shell extension +
companion `evdev`/`uinput` daemon).

### Added

- GNOME Shell extension `middle-drag-gestures@swad` exporting the
  `org.gnome.Shell.Extensions.MiddleDrag` D-Bus interface.
- Python input daemon using `evdev` to grab the physical mouse and `uinput` to
  forward normal events through a virtual mouse.
- Automatic mouse discovery, unplug/reconnect handling and signal-safe cleanup
  in the daemon.
- Shared GSettings schema (`org.gnome.shell.extensions.middle-drag`) with a
  GNOME preferences UI.
- `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/enable.sh`,
  `scripts/disable.sh`.
- `scripts/lib.sh`, shared by installer and uninstaller (paths, logging,
  extension enable/disable, install state helpers).
- `scripts/verify-clean.sh`: asserts every path the installer writes, the
  systemd enabled symlink, the running daemon and the gsettings entries, and
  exits non-zero naming anything left behind. `--purge` variant additionally
  covers dconf and the install state.
- Install state file `~/.local/state/middle-drag-gestures/state`
  (`version`, `installed_at`, `group_added`, `uinput_orig_perms`), written only
  after a successful install.
- Installer flags `--user-only`, `--no-start`, `--no-systemd`, `--help`, and
  `uninstall.sh --purge`.
- `tests/install_matrix.sh`: nine scripted scenarios (fail-fast without root,
  fail-fast on a missing dependency, clean install, idempotent re-run,
  verify-while-installed, rollback, uninstall, purge, and an opt-in `--real`
  round trip through the actual home directory), plus `make matrix` and
  `make release`.
- Fedora RPM now packages the whole product: extension, preferences UI, user
  and system GSettings schema, daemon, udev rule and systemd user unit (it
  previously shipped the daemon half only, so an installed system had a daemon
  calling a D-Bus name nobody owned). Built and verified on Fedora 44 /
  GNOME Shell 50.5: `rpmbuild` clean with no unpackaged files, `rpm -V` clean
  after install, the udev rule applied (`/dev/uinput` → `0660 root:input`),
  the extension reached `State: ACTIVE`, and the daemon grabbed the mouse and
  answered `GetStatus` over D-Bus.
- systemd user preset `50-middle-drag-gestures.preset`. Fedora's default
  policy for user units is `disable *`, and `%post` applies that policy with
  `systemctl --global preset`, so without a preset the package installed with
  the daemon disabled in every account: installed, `rpm -V` clean, and doing
  nothing until each user ran `systemctl --user enable` by hand. Checked with
  `systemctl --root … --global preset` in a throwaway root - `disabled`
  before the preset file, `enabled` and linked from
  `/etc/systemd/user/graphical-session.target.wants/` after it.
- udev rule `udev/70-middle-drag-uaccess.rules`.
- Documentation: architecture, installation, troubleshooting.
- Unit tests for gesture detection and device discovery.
- `verify-clean.sh --scope=script|system|all` (default `all`). The two
  install methods leave different traces, so one verdict cannot serve both:
  the matrix's "the uninstall left nothing" assertion was failing over a live
  RPM install. A narrow run names what it did not judge instead of hiding it,
  and ownership is decided by location - a symlink into `$HOME` is the
  script's, one into `/usr` is the package's.

### Changed

- Device access no longer goes through the `input` group: the udev rule
  (renamed `99-middle-drag-uinput.rules` → `70-middle-drag-uaccess.rules`)
  now tags `/dev/uinput` and every input device with `uaccess`, so systemd-logind
  grants the active local session an ACL - no `/etc/group` edit for a package
  to make, and nothing that only applies at the next login. Two details are
  required and are documented in the rule itself: the `70-` prefix, so the tag
  exists before `71-seat.rules`/`73-seat-late.rules` evaluate it (a `99-` name
  added it too late and missed a device's first event, i.e. every fresh boot),
  and `OPTIONS+="static_node=uinput"`, which puts the node in
  `/run/udev/static_node-tags/uaccess/` for logind's login-time pass - the
  mechanism Fedora already uses for `/dev/snd/seq` and `/dev/snd/timer`.
  Verified after a fresh boot: `/dev/uinput` and all 20 input nodes carried
  `user:swad:rw-` one second after session start, and uinput, keyboard and
  mouse opened with zero supplementary groups (`setpriv --clear-groups`).
  Installer, uninstaller, `verify-clean.sh` and the docs follow suit; a
  membership added by an older install is left alone, and
  `uninstall.sh --purge` still drops it when the state file says we added it.
- D-Bus methods `OverviewUp`/`OverviewDown` renamed to `ShowOverview`/
  `HideOverview`. The daemon retries under the old name when the running
  Shell still exports the pre-rename code, so vertical gestures keep working
  across an upgrade without waiting for the next login.
- Daemon now talks to D-Bus through `dbus-python` instead of spawning `gdbus`
  for every call.
- udev rule renamed from `99-uinput.rules` to `70-middle-drag-uaccess.rules`
  (it first passed through an intermediate `99-middle-drag-uinput.rules`
  name, which the installers still clean up as a legacy path).
- `install.sh` preflights **all** checks before writing anything: a missing
  dependency, or root needed where `sudo` cannot ask for a password, now fails
  with instructions and an untouched home directory instead of skipping a step
  halfway through.
- `install.sh` is transactional: every write is recorded and rolled back if a
  later step fails, and the extension is built in a cache staging directory
  and swapped into place, so a failed install never leaves half an
  installation behind.
- Installing no longer stops after adding you to the `input` group: the
  group, the udev rule, the extension and the unit all take effect at the
  same single logout instead of requiring a second pass.
- `uninstall.sh` restores the `/dev/uinput` permissions measured at install
  time, and removes the legacy `99-uinput.rules` name as well. Uninstalling
  keeps `input` membership and dconf values by default and says so; `--purge`
  removes them, dropping the group only when the install state says this
  project added it.
- `verify-extension.sh` runs on a clean checkout: when the extension is not in
  `$HOME` it stages a copy of the working tree in a throwaway HOME, seeding
  `enabled-extensions` inside a private session so the real dconf is never
  written.
- The integration test reports its three dispatch assertions as `SKIP` when
  the extension is not loaded in the current session, so the suite passes on a
  machine that has been cleanly uninstalled.

### Fixed

- `install.sh`, `uninstall.sh` and `verify-clean.sh` no longer touch the live
  session when `$HOME` is not the invoking user's own. None of the three
  services involved respects `HOME`: `gsettings set` writes through the
  running dconf service into the real `~/.config/dconf/user`, `gnome-extensions`
  talks to the running Shell, and `systemctl --user` talks to the manager of
  this login. Running the test matrix on a machine with the product installed
  therefore stopped a working daemon with `SIGTERM` and stripped the uuid out
  of the real `enabled-extensions` - the suite was switching off the user's
  product. Each skip is printed as `skipped ...`, never silently.
- Daemon now handles `SIGTERM`, so `systemctl --user stop` always releases the
  physical device grab instead of leaving the mouse unusable.
- `gsettings get` prints an unset array as `@as []`, which the extension
  enable fallback passed straight to `ast.literal_eval` and crashed on. Since
  the key is unset by definition on a fresh machine, enabling would have
  failed on every first install.
- The `/dev/uinput` permission restore ran `chmod "660 0 104 <file>"`, which
  is not a valid mode, so the restore silently did nothing; it now uses
  `chown` for the ids and `chmod` for the mode.
- The Fedora spec's `%files` listed only the daemon half, so an RPM built from
  it shipped no extension, no preferences and no GSettings schema.
