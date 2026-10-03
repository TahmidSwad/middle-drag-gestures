# Middle-Drag Gestures

System-wide **middle-mouse-button drag gestures on Wayland** for GNOME.

Hold the middle mouse button and drag to control the desktop — even while the
pointer is over application windows:

| Gesture             | Action             |
| ------------------- | ------------------ |
| Middle + drag LEFT  | Next workspace     |
| Middle + drag RIGHT | Previous workspace |
| Middle + drag UP    | Open Overview      |
| Middle + drag DOWN  | Close Overview     |

Every direction is configurable: `none`, `next-workspace`,
`previous-workspace`, `show-overview` or `hide-overview`.

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
  everything GNOME-specific: workspace switching, the Overview, GSettings and
  the preferences UI. It exports a small D-Bus interface.
* **Input daemon** (`daemon/middle-drag-daemon.py`) owns everything
  Linux-specific: reading `/dev/input`, grabbing the physical mouse,
  detecting gestures, forwarding normal events through a `uinput` virtual
  mouse, and consuming middle-button events.

Neither side needs to know how the other works; **D-Bus is the boundary**.
The daemon runs as the logged-in user via a `systemd --user` unit — never as
root.

## Requirements

* GNOME Shell **50** on **Wayland** — the extension declares
  `"shell-version": ["50"]`; an X11 session is untested.
* systemd + udev + logind, and the `uinput` kernel module:
  `lsmod | grep uinput || sudo modprobe uinput`
* Python 3 with `python3-evdev`, `python3-dbus`, `python3-gobject`, plus
  `glib2` (for `glib-compile-schemas`). Debian/Ubuntu: `python3-evdev
  python3-dbus python3-gi libglib2.0-bin`.
* **No `input` group membership** — the shipped udev rule grants the session
  access through a per-login `uaccess` ACL, and no account is ever modified.

**Tested on Fedora 44 (GNOME Shell 50.5, Wayland) only.** Any other
distribution with systemd, udev, logind and GNOME 50 should work: supported
by design, not yet by test.

## Install

### Fedora — release RPM (recommended)

```bash
sudo dnf install https://github.com/TahmidSwad/middle-drag-gestures/releases/download/v0.1.3/middle-drag-gestures-0.1.3-1.fc44.noarch.rpm
gnome-extensions enable middle-drag-gestures@swad
# systemctl --user start middle-drag-daemon.service   # only to run it before the relogin
```

### Any other GNOME 50 distro — installer from source

```bash
curl -fsSL -o /tmp/middle-drag-gestures.tar.gz https://github.com/TahmidSwad/middle-drag-gestures/archive/refs/tags/v0.1.3.tar.gz
tar -xzf /tmp/middle-drag-gestures.tar.gz -C /tmp
bash /tmp/middle-drag-gestures-0.1.3/scripts/install.sh
```

`install.sh` checks every dependency before writing a byte, prints the exact
package name for your distribution (`dnf`, `apt`, …), then lays down the udev
rule, daemon, systemd unit, extension and GSettings schema, enables all of it
and reports what is left to do. It runs `sudo` once, for the udev rule (plus
`modprobe uinput` if the module is missing).

### Build the RPM yourself

```bash
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

### After any install: one relogin, then verify

Wayland loads extension code only at login, and that login is also when
systemd-logind grants the device ACL — so **log out and log back in once**.
Then:

```bash
gnome-extensions info middle-drag-gestures@swad      # Enabled: Yes / State: ACTIVE
systemctl --user status middle-drag-daemon.service   # Active: active (running)
```

Hold the middle button and drag left: you land on the next workspace. The
preferences page (`gnome-extensions prefs middle-drag-gestures@swad`) shows
the daemon status live and, when the daemon is missing, the exact commands to
install it.

### Remove

```bash
# from the RPM — disable first, so no dangling uuid is left behind
gnome-extensions disable middle-drag-gestures@swad
systemctl --user disable --now middle-drag-daemon.service
sudo dnf remove middle-drag-gestures

# from a checkout — and prove nothing is left
./scripts/uninstall.sh --purge      # files, settings, install state
./scripts/verify-clean.sh --purge   # exit 0 only if the machine is clean
```

## Repository layout

```text
middle-drag-gestures/
├── extension/middle-drag-gestures@swad/   GNOME Shell extension (UI + D-Bus)
├── daemon/                                Python daemon + systemd user unit
├── udev/                                  uaccess rule for /dev/uinput + mice
├── scripts/                               install, uninstall, enable, disable,
│                                          verify-clean, verify-extension,
│                                          package-extension, lib
├── docs/                                  architecture, installation, troubleshooting
├── packaging/fedora/                      RPM spec + preset (ships everything)
├── tests/                                 unit, integration, install-matrix
├── Makefile   VERSION   CHANGELOG.md   LICENSE
```

## Documentation

* [docs/architecture.md](docs/architecture.md) — why the design looks like this
* [docs/installation.md](docs/installation.md) — dependencies, permissions, every install route, flags, verification
* [docs/troubleshooting.md](docs/troubleshooting.md) — failure modes and fixes, layer by layer

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

# day to day
./scripts/install.sh | uninstall.sh | enable.sh | disable.sh
./scripts/verify-clean.sh                  # exit 0 only if nothing is left
```

### Scripts

Every script accepts `--help`, re-runs safely and exits non-zero on a
broken machine. Only `install.sh` and `uninstall.sh` ever ask for root,
and only to place or remove the udev rule (plus `modprobe uinput` if the
module is not loaded).

| script | does | notes |
| --- | --- | --- |
| `install.sh` | preflight → files → permissions → enable, rolling back on failure | missing-dependency hints name the `dnf` and `apt` packages; translate them for other distros |
| `uninstall.sh` | remove the installation (`--purge` also dconf and install state) | never calls `rpm`, `dnf` or `apt` — removes the same way on any systemd distro |
| `enable.sh` / `disable.sh` | start or stop the daemon and extension without installing or removing anything | refuses to run when nothing is installed; portable |
| `verify-clean.sh` | exit 0 only if nothing is left (`--purge`, `--scope=script`) | its `rpm -q` check runs only where `rpm` exists (Fedora and other rpm distros) and is skipped elsewhere |
| `verify-extension.sh` | load the extension in a nested GNOME Shell, then exercise prefs and the D-Bus interface | needs a running GNOME Wayland session and `dbus-run-session` (package `dbus-daemon`) |
| `package-extension.sh` | build `dist/*.shell-extension.zip` — a shareable bundle of the GNOME half only (the daemon comes from `install.sh` or the RPM) | needs `gnome-extensions`, `zip` and `glib-compile-schemas` |
| `lib.sh` | shared paths, state helpers and the `mdg_*` functions | sourced by the other scripts, never run directly |

Everything else they call — `systemctl --user`, `gnome-extensions`,
`udevadm`, `dconf` — ships with systemd, GLib and GNOME everywhere, so
the scripts themselves are distribution-neutral. **The only
Fedora-specific files in the repository are `packaging/fedora/`** (the
RPM spec and its preset), plus the `dnf` package-name hints above.

### Makefile

```bash
make test | verify | matrix | release | zip | install | uninstall | clean
```

`make release` is the gate: unit + integration + extension + install matrix.

The integration test creates a synthetic mouse and has to read it back, so it
needs read/write access to the `event*` node udev creates — the very access
the shipped udev rule (or `input` group membership) provides. On a machine
where the product is not installed it prints `SKIP` with both ways to get that
access instead of timing out.

`verify-extension.sh` exists because GNOME Shell caches extension code for the
lifetime of the session: editing `extension.js` does nothing until you log
out. The script starts a second, headless GNOME Shell on a private session
bus, asserts the full D-Bus contract and opens the preferences window, then
shuts it down — your desktop is untouched. It runs before anything is
installed too: when the extension is not in `$HOME` it stages a copy of the
working tree in a throwaway HOME (your real dconf is never written).

### Cutting a release

```bash
# 1. bump VERSION, packaging/fedora/middle-drag-gestures.spec (Version +
#    %changelog), extension/metadata.json "version", and every version-pinned
#    URL (README, docs, prefs.js INSTALL_COMMAND); then commit.
git tag v$(cat VERSION) && git push origin main "v$(cat VERSION)"

# 2. build the RPM from the tag archive — that is what Source0 points at:
curl -fsSL -o ~/rpmbuild/SOURCES/v$(cat VERSION).tar.gz \
  https://github.com/TahmidSwad/middle-drag-gestures/archive/refs/tags/v$(cat VERSION).tar.gz
rpmbuild -ba packaging/fedora/middle-drag-gestures.spec

# 3. publish, with the prebuilt RPM as the release asset
gh release create "v$(cat VERSION)" \
  ~/rpmbuild/RPMS/noarch/middle-drag-gestures-$(cat VERSION)-*.noarch.rpm
```

## License

MIT — see [LICENSE](LICENSE).
