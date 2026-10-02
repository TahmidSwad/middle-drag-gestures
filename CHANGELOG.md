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
  calling a D-Bus name nobody owned).
- udev rule `udev/99-middle-drag-uinput.rules`.
- Documentation: architecture, installation, troubleshooting.
- Unit tests for gesture detection and device discovery.

### Changed

- D-Bus methods `OverviewUp`/`OverviewDown` renamed to `ShowOverview`/
  `HideOverview`. The daemon retries under the old name when the running
  Shell still exports the pre-rename code, so vertical gestures keep working
  across an upgrade without waiting for the next login.
- Daemon now talks to D-Bus through `dbus-python` instead of spawning `gdbus`
  for every call.
- udev rule renamed from `99-uinput.rules` to `99-middle-drag-uinput.rules`.
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
