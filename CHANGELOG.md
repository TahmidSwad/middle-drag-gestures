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
- udev rule `udev/99-middle-drag-uinput.rules`.
- Documentation: architecture, installation, troubleshooting.
- Unit tests for gesture detection and device discovery.

### Changed

- D-Bus methods `OverviewUp`/`OverviewDown` renamed to `ShowOverview`/
  `HideOverview`.
- Daemon now talks to D-Bus through `dbus-python` instead of spawning `gdbus`
  for every call.
- udev rule renamed from `99-uinput.rules` to `99-middle-drag-uinput.rules`.

### Fixed

- Daemon now handles `SIGTERM`, so `systemctl --user stop` always releases the
  physical device grab instead of leaving the mouse unusable.
