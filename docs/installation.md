# Installation

Tested on **Fedora 44, GNOME Shell 50.5, Wayland** with a USB mouse.

---

## 1. Requirements

| component | package |
| --------- | ------- |
| GNOME Shell on Wayland | `gnome-shell` |
| Python 3 | `python3` |
| evdev bindings | `python3-evdev` |
| D-Bus bindings | `python3-dbus` |
| GObject introspection (GSettings) | `python3-gobject` |
| schema compiler | `glib2` (provides `glib-compile-schemas`) |
| session bus client | `glib2` (provides `gdbus`) |

Install them all:

```bash
sudo dnf install python3-evdev python3-dbus python3-gobject glib2
```

Kernel side:

```bash
lsmod | grep uinput || sudo modprobe uinput
```

---

## 2. Permissions

### `input` group

`/dev/input/event*` is `root:input` with mode `0660`, so your user must be in
the `input` group:

```bash
sudo usermod -aG input "$USER"
```

**Log out and log back in** (group membership is applied at login), then
verify:

```bash
groups
# expect: … wheel input
```

### `/dev/uinput`

`/dev/uinput` starts out as `crw------- root root`. A udev rule shipped with
this project widens it to `crw-rw---- root input`:

```text
/etc/udev/rules.d/99-middle-drag-uinput.rules
```

```udev
KERNEL=="uinput", GROUP="input", MODE="0660"
```

The installer lays it down and reloads the rules; to do it by hand:

```bash
sudo install -m 0644 udev/99-middle-drag-uinput.rules \
    /etc/udev/rules.d/99-middle-drag-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
ls -l /dev/uinput
# expect: crw-rw----. 1 root input 10, 223 …
```

---

## 3. Install with the script

```bash
./scripts/install.sh
```

It checks **every** dependency first and refuses before writing a single file:
if something cannot work (a missing package, or root needed where `sudo` cannot
ask for a password), it says exactly what to do and exits non-zero with your
home directory untouched.

What it does:

```text
./scripts/install.sh
             │
             ├── preflight: GNOME / Python / evdev / dbus / gi / gdbus,
             │   /dev/uinput, udev rule, 'input' group   ← nothing is written
             │   until all of these pass
             ├── install udev rule            (sudo, only if not present)
             ├── add you to the 'input' group (sudo, only if not present)
             ├── install daemon        → ~/.local/bin/middle-drag-daemon.py
             ├── install systemd unit  → ~/.config/systemd/user/
             ├── install extension     → ~/.local/share/gnome-shell/extensions/
             ├── compile GSettings schema (extension dir + user dir)
             ├── enable + restart the daemon
             └── enable the extension
```

Every step records what it created, so a failure further down rolls those
files back and exits non-zero - a failed install never leaves half an
installation behind (exercised by `tests/install_matrix.sh`).

**One logout, not two.** `input` group membership only applies to new
sessions, so when the script has to add you to the group it prints

```text
ACTION REQUIRED: log out and log back in (once).
```

and leaves the daemon start to that login. Everything else (extension
enabled, unit enabled) is already in place; there is no second pass.

Root is needed only for the udev rule and the group. The script asks once,
non-interactively, and refuses up front if it cannot get it. Other flags:

| flag | purpose |
| ---- | ------- |
| `--user-only` | skip the root steps (udev rule, `input` group) - the daemon then cannot open the mouse, see [troubleshooting](troubleshooting.md) |
| `--no-start` | install and enable everything but do not start the daemon |
| `--no-systemd` | do not touch systemd at all (used by `tests/install_matrix.sh`) |
| `--help` | full usage |

### Important: GNOME Shell reloads extension code only at login

The daemon restarts immediately, but `extension.js` and `prefs.js` are cached
by the Shell. **Log out and back in** after updating the extension. Until you
do, the running Shell still exports the pre-rename methods and the daemon
logs one notice:

```text
the running extension predates the D-Bus method rename; gestures keep
working through the legacy OverviewUp() fallback. …
```

Vertical gestures keep working meanwhile through that fallback; nothing is
broken while you wait for your next login.

To test extension changes *without* logging out, use:

```bash
./scripts/verify-extension.sh
```

which loads the extension in a throwaway headless GNOME Shell. It works on a
clean checkout too: if the extension is not installed it stages a private copy
of the working tree (and never touches your real dconf).

### Alternative: install the Fedora RPM

`packaging/fedora/middle-drag-gestures.spec` packages the whole product -
extension, prefs, GSettings schema, daemon, udev rule and user unit - into
`/usr`:

```bash
sudo dnf install -y rpm-build systemd-rpm-macros

# Source0 has no real URL in this repository, so `spectool -g` does not
# work - make the tarball from the checkout instead:
mkdir -p ~/rpmbuild/SOURCES
git archive --format=tar.gz --prefix=middle-drag-gestures-0.1.0/ \
  -o ~/rpmbuild/SOURCES/middle-drag-gestures-0.1.0.tar.gz HEAD

rpmbuild -ba packaging/fedora/middle-drag-gestures.spec
sudo dnf install ~/rpmbuild/RPMS/noarch/middle-drag-gestures-*.rpm
```

A package cannot perform per-user steps, so afterwards:

```bash
sudo usermod -aG input "$USER"                        # applies at the NEXT login
gnome-extensions enable middle-drag-gestures@swad     # immediate
systemctl --user enable --now middle-drag-daemon.service   # immediate
```

**Do not skip the `input` group.** `dnf install` does not add you to it, and
without it the daemon cannot open `/dev/input` or `/dev/uinput` (both are
`root:input`). Everything looks fine until your next login, and then the
daemon fails with `permission denied on /dev/input/…` — the current session
may still work if your shell inherited the group from an earlier login.

> **Verified** on Fedora 44 / GNOME Shell 50.5 (2026-10-03): `rpmbuild`
> completed with no unpackaged files, `rpm -V` clean after install, the udev
> rule really fired (`/dev/uinput` → `0660 root:input`), `gsettings` resolved
> the system schema (`threshold = 100`), the extension reached
> `State: ACTIVE` in a running Shell, and the daemon grabbed the mouse and
> answered `GetStatus` over D-Bus.

---

## 4. Manual installation

<details>
<summary>For people who prefer to do every step themselves</summary>

```bash
UUID=middle-drag-gestures@swad

# 1. extension
mkdir -p ~/.local/share/gnome-shell/extensions/$UUID/schemas
cp extension/$UUID/{extension.js,prefs.js,metadata.json,stylesheet.css,LICENSE} \
   ~/.local/share/gnome-shell/extensions/$UUID/
cp extension/$UUID/schemas/*.xml \
   ~/.local/share/gnome-shell/extensions/$UUID/schemas/
glib-compile-schemas ~/.local/share/gnome-shell/extensions/$UUID/schemas/

# 2. schema for the daemon
mkdir -p ~/.local/share/glib-2.0/schemas
cp extension/$UUID/schemas/*.xml ~/.local/share/glib-2.0/schemas/
glib-compile-schemas ~/.local/share/glib-2.0/schemas/

# 3. daemon
install -D -m 0755 daemon/middle-drag-daemon.py ~/.local/bin/middle-drag-daemon.py

# 4. systemd user unit
install -D -m 0644 daemon/middle-drag-daemon.service \
    ~/.config/systemd/user/middle-drag-daemon.service
systemctl --user daemon-reload

# 5. udev rule (root)
sudo install -m 0644 udev/99-middle-drag-uinput.rules \
    /etc/udev/rules.d/99-middle-drag-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc

# 6. enable
gnome-extensions enable $UUID
systemctl --user enable --now middle-drag-daemon.service
```

</details>

---

## 5. Enabling, disabling, removing

```bash
./scripts/enable.sh            # extension on + daemon started
./scripts/disable.sh           # both off, nothing removed
./scripts/uninstall.sh         # remove every file
./scripts/uninstall.sh --purge # ...plus settings, state and group note
./scripts/verify-clean.sh      # exit 0 only if nothing is left
./scripts/verify-clean.sh --purge
```

Equivalent by hand:

```bash
systemctl --user enable --now middle-drag-daemon.service
gnome-extensions enable middle-drag-gestures@swad

systemctl --user disable --now middle-drag-daemon.service
gnome-extensions disable middle-drag-gestures@swad
```

Uninstalling deliberately **keeps** two things, and says so:

* your `input` group membership - other software may need it
* your dconf settings under `org.gnome.shell.extensions.middle-drag`

`--purge` removes both, plus the install state file, and drops the `input`
membership only when the state file says *this project* added it - a
membership you already had is never touched. The `input` group is a
deliberate choice; see
[troubleshooting.md](troubleshooting.md#gestures-do-nothing-but-the-log-shows-the-gesture)
for why the alternative (udev `uaccess` ACLs) is not used.

### Removing the RPM

```bash
gnome-extensions disable middle-drag-gestures@swad        # BEFORE removal
systemctl --user disable --now middle-drag-daemon.service
sudo dnf remove middle-drag-gestures
```

`dnf remove` takes care of the files, rebuilds the GSettings cache (a later
`gsettings get` correctly reports *No such schema*), stops the daemon
gracefully — the journal shows `SIGTERM` → `virtual mouse removed` →
`physical mouse released` — and clears the enable symlink, even though the
scriptlet runs as root.

Two things it cannot reach, because both live in your session:

* **The `enabled-extensions` entry.** A package cannot write your dconf, so
  the uuid stays behind and GNOME Shell keeps reporting the extension as
  `Enabled: Yes` against a path that no longer exists, until the next login.
  Disable *before* removing. If you already removed it, filter the uuid out
  yourself (do **not** reset the key — that would drop your other
  extensions):

  ```bash
  gsettings set org.gnome.shell enabled-extensions \
    "$(gsettings get org.gnome.shell enabled-extensions \
        | sed -e "s/'middle-drag-gestures@swad', //g" \
              -e "s/, 'middle-drag-gestures@swad'//g" \
              -e "s/'middle-drag-gestures@swad'//g")"
  ```

* **`/dev/uinput` keeps `0660 root:input`** until the next reboot: udev
  reloads the rule set but does not recompute permissions on a node it no
  longer matches.

`./scripts/verify-clean.sh` fails on the first of these, so run it after
removing.

### Proving it is gone

`verify-clean.sh` is the counterpart of `install.sh`: it asserts every path
the installer writes, the systemd enabled symlink, the running daemon, the
gsettings entries and (with `--purge`) dconf and the install state. It prints
one `ok:` line per check, `FAIL:` naming anything left behind, and exits
non-zero if the machine is not clean:

```bash
./scripts/verify-clean.sh
#   CLEAN: no trace of Middle-Drag Gestures remains.
```

After uninstalling, **log out and log back in** so GNOME Shell drops the
extension completely - it only rescans extension directories at login.

---

## 6. Verifying the installation

```bash
# extension
gnome-extensions info middle-drag-gestures@swad
#   Enabled: Yes
#   State: ACTIVE

# daemon
systemctl --user status middle-drag-daemon.service
#   Active: active (running)

journalctl --user -u middle-drag-daemon.service -n 20 --no-pager
#   … physical mouse grabbed; middle button reserved (threshold=100px …)

# D-Bus service
gdbus introspect --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag

gdbus call --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.GetStatus

# automatic discovery
python3 ~/.local/bin/middle-drag-daemon.py --list-devices
```

Then hold the middle button, drag left, and you should land on the next
workspace.

---

## 7. Configuration

```bash
gnome-extensions prefs middle-drag-gestures@swad
```

or with `gsettings` directly:

```bash
SCHEMA=org.gnome.shell.extensions.middle-drag

gsettings list-recursively $SCHEMA
gsettings set $SCHEMA threshold 150
gsettings set $SCHEMA enabled false
gsettings set $SCHEMA left-action 'previous-workspace'
gsettings set $SCHEMA device auto
```

Available actions: `none`, `next-workspace`, `previous-workspace`,
`show-overview`, `hide-overview`.

Changes are picked up by the running daemon immediately - no restart needed.

---

## 8. Logs

```bash
journalctl --user -u middle-drag-daemon.service -f     # follow the daemon
journalctl -b /usr/bin/gnome-shell --no-pager | grep MiddleDrag   # extension
```

For a verbose daemon run:

```bash
systemctl --user stop middle-drag-daemon.service
python3 ~/.local/bin/middle-drag-daemon.py --verbose
```

Something not working? See [troubleshooting.md](troubleshooting.md).
