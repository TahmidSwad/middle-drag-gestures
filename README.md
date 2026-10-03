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
│                                          / verify-clean / verify-extension
├── docs/                                  architecture, installation, troubleshooting
├── packaging/fedora/                      RPM spec (ships the whole product)
├── tests/                                 unit, integration and install-matrix tests
├── CHANGELOG.md
└── plan.md                                original design document
```

## Quick start

### As an end user (release RPM)

```bash
sudo dnf install https://github.com/TahmidSwad/middle-drag-gestures/releases/download/v0.1.0/middle-drag-gestures-0.1.0-1.fc44.noarch.rpm
gnome-extensions enable middle-drag-gestures@swad
```

Then **log out and log back in once** — Wayland loads extension code only at
login, and that login is also when systemd-logind grants the device ACL. No
`input` group membership is needed and none is added. Check:

```bash
gnome-extensions info middle-drag-gestures@swad
systemctl --user status middle-drag-daemon.service
```

Remove it again:

```bash
gnome-extensions disable middle-drag-gestures@swad   # first: no dangling uuid
sudo dnf remove middle-drag-gestures
```

### From source

```bash
git clone https://github.com/TahmidSwad/middle-drag-gestures.git
cd middle-drag-gestures
sudo dnf install rpm-build rpmdevtools               # rpmbuild + spectool
mkdir -p ~/rpmbuild/SOURCES
spectool -g -C ~/rpmbuild/SOURCES packaging/fedora/middle-drag-gestures.spec
rpmbuild -ba packaging/fedora/middle-drag-gestures.spec
sudo dnf install ~/rpmbuild/RPMS/noarch/middle-drag-gestures-*.rpm
```

### In this checkout (development)

```bash
./scripts/install.sh
```

Then log out and back in (once — Wayland reloads extensions only at login) and
check:

```bash
gnome-extensions info middle-drag-gestures@swad
systemctl --user status middle-drag-daemon.service
```

Remove it again, with proof that nothing is left:

```bash
./scripts/uninstall.sh --purge      # files, settings, install state
./scripts/verify-clean.sh --purge   # exit 0 only if the machine is clean
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
# tests
python3 -m unittest discover -s tests -v   # unit tests
python3 tests/integration_test.py          # end-to-end test with a synthetic mouse
./tests/install_matrix.sh                  # install → break → uninstall → purge,
                                           # in a throwaway HOME (--real to also
                                           # round-trip your actual home directory)

# extension
./scripts/verify-extension.sh              # load it in a throwaway GNOME Shell
./scripts/package-extension.sh             # build dist/*.shell-extension.zip

# deployment
./scripts/install.sh | uninstall.sh | enable.sh | disable.sh
./scripts/verify-clean.sh                  # exit 0 only if nothing is left
```

The same targets exist in the `Makefile` if you have `make`:

```bash
make test | verify | matrix | release | zip | install | uninstall | clean
```

`make release` is the gate: unit + integration + extension + install matrix.

The integration test creates a synthetic mouse and then has to read it back,
so it needs read/write access to the `event*` node udev creates for it — the
very access the shipped udev rule (or membership in the `input` group)
provides. On a machine where the product is not installed it prints `SKIP`
with both ways to get that access instead of timing out.

`verify-extension.sh` exists because GNOME Shell caches extension code for the
lifetime of the session: editing `extension.js` does nothing until you log
out. The script starts a second, headless GNOME Shell on a private session
bus, asserts the full D-Bus contract and opens the preferences window, then
shuts it down - your desktop is untouched. It runs before anything is
installed too: when the extension is not in `$HOME` it stages a copy of the
working tree in a throwaway HOME (your real dconf is never written).

## Requirements

* Fedora 44 (or similar) with GNOME Shell 50 on Wayland
* `python3`, `python3-evdev`, `python3-dbus`, `python3-gobject`
* No `input` group membership needed - the shipped udev rule grants the
  session access through a per-login `uaccess` ACL
* `uinput` kernel module loaded

## License

MIT — see [LICENSE](LICENSE).
