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

It checks every dependency first and tells you exactly what is missing. It is
idempotent - re-run it after every code change to redeploy.

What it does:

```text
./scripts/install.sh
             │
             ├── check GNOME / Python / evdev / dbus / gi / gdbus
             ├── check /dev/uinput (loads the module if needed)
             ├── add you to the 'input' group (asks for logout if it did)
             ├── install udev rule               (sudo)
             ├── install daemon        → ~/.local/bin/middle-drag-daemon.py
             ├── install systemd unit  → ~/.config/systemd/user/
             ├── install extension     → ~/.local/share/gnome-shell/extensions/
             ├── compile GSettings schema (extension dir + user dir)
             ├── enable + restart the daemon
             └── enable the extension
```

If `sudo` is not available (for example a non-interactive shell) the udev
step is skipped with explicit instructions instead of blocking on a password
prompt.

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

which loads the extension in a throwaway headless GNOME Shell.

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
./scripts/enable.sh      # extension on + daemon started
./scripts/disable.sh     # both off, nothing removed
./scripts/uninstall.sh   # remove everything
```

Equivalent by hand:

```bash
systemctl --user enable --now middle-drag-daemon.service
gnome-extensions enable middle-drag-gestures@swad

systemctl --user disable --now middle-drag-daemon.service
gnome-extensions disable middle-drag-gestures@swad
```

Uninstalling deliberately **keeps** your `input` group membership (other
software may need it) and your dconf settings.

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
