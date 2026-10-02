# Middle-Drag Gestures

System-wide **middle-mouse-button drag gestures on Wayland** for GNOME.

Hold the middle mouse button and drag to control the desktop — even while the
pointer is over application windows:

| Gesture             | Action           |
| ------------------- | ---------------- |
| Middle + drag LEFT  | Next workspace   |
| Middle + drag RIGHT | Previous workspace |
| Middle + drag UP    | Close Overview   |
| Middle + drag DOWN  | Open Overview    |

## Why two components

A GNOME Shell extension cannot observe pointer events that belong to Wayland
application surfaces. The project therefore splits the work:

```text
physical mouse ──► input daemon ──► virtual mouse ──► Wayland applications
   (evdev)            │ (Python)
                      │ D-Bus
                      ▼
             GNOME Shell extension ──► workspaces / Overview
```

* **GNOME Shell extension** (`extension/middle-drag-gestures@swad`) owns
  everything GNOME-specific: workspace switching, Overview, GSettings and the
  preferences UI. It exports a small D-Bus interface.
* **Input daemon** (`daemon/middle-drag-daemon.py`) owns everything
  Linux-specific: reading `/dev/input`, grabbing the physical mouse,
  detecting gestures, forwarding normal events through a `uinput` virtual
  mouse, and consuming middle-button events.

Neither side needs to know how the other works; **D-Bus is the boundary**.

The daemon runs as the logged-in user via a `systemd --user` unit — never as
root.

## Repository layout

```text
middle-drag-gestures/
├── extension/middle-drag-gestures@swad/   GNOME Shell extension
├── daemon/                                Python daemon + systemd user unit
├── udev/                                  udev rule for /dev/uinput
├── scripts/                               install / uninstall / enable / disable
├── docs/                                  architecture, installation, troubleshooting
├── packaging/fedora/                      RPM spec
├── tests/                                 unit tests
└── plan.md                                original design document
```

## Quick start

```bash
./scripts/install.sh
```

Then log out and back in (Wayland reloads extensions only at login) and check:

```bash
gnome-extensions info middle-drag-gestures@swad
systemctl --user status middle-drag-daemon.service
```

See [docs/installation.md](docs/installation.md) for manual installation and
[docs/troubleshooting.md](docs/troubleshooting.md) if something misbehaves.

## Documentation

* [docs/architecture.md](docs/architecture.md) — why the design looks like this
* [docs/installation.md](docs/installation.md) — dependencies, permissions, installer
* [docs/troubleshooting.md](docs/troubleshooting.md) — failure modes and fixes
* [plan.md](plan.md) — the original design document

## Development

```bash
python3 -m unittest discover -s tests -v   # unit tests
python3 tests/integration_test.py          # end-to-end test with a synthetic mouse
./scripts/verify-extension.sh              # load the extension in a throwaway Shell
./scripts/install.sh                       # redeploy everything
```

`verify-extension.sh` exists because GNOME Shell caches extension code for the
lifetime of the session: editing `extension.js` does nothing until you log
out. The script starts a second, headless GNOME Shell on a private session
bus, asserts the full D-Bus contract and opens the preferences window, then
shuts it down - your desktop is untouched.

## Requirements

* Fedora 44 (or similar) with GNOME Shell 50 on Wayland
* `python3`, `python3-evdev`, `python3-dbus`, `python3-gobject`
* User member of the `input` group
* `uinput` kernel module loaded

## License

MIT — see [LICENSE](LICENSE).
