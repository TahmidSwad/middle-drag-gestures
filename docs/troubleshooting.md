# Troubleshooting

Work top to bottom: each layer depends on the one above it.

```text
1. extension active  ──► 2. D-Bus name owned  ──► 3. daemon running
        ──► 4. device grabbed  ──► 5. gestures dispatch
```

---

## Quick diagnostic run

```bash
gnome-extensions info middle-drag-gestures@swad
systemctl --user status middle-drag-daemon.service
journalctl --user -u middle-drag-daemon.service -n 50 --no-pager
gdbus call --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.GetStatus
python3 ~/.local/bin/middle-drag-daemon.py --list-devices
```

---

## Extension problems

### The extension is not active

```bash
gnome-extensions enable middle-drag-gestures@swad
gnome-extensions info middle-drag-gestures@swad   # Enabled: Yes / State: ACTIVE
```

### You edited extension.js but nothing changed

GNOME Shell caches extension code and metadata **for the whole session**.
`gnome-extensions disable && enable` does *not* reload it. Log out and back
in (Wayland has no `Alt+F2 r` restart).

While developing, use the throwaway Shell instead:

```bash
./scripts/verify-extension.sh
```

It starts a headless GNOME Shell on a private session bus, checks the whole
D-Bus contract and the preferences window, then shuts it down.

### The D-Bus name is not owned

```text
extension is not owning org.gnome.Shell.Extensions.MiddleDrag
(is 'gnome-extensions enable middle-drag-gestures@swad' run?)
```

The extension is disabled or failed to start. Check the Shell journal:

```bash
journalctl -b /usr/bin/gnome-shell --no-pager | grep -i middledrag
```

### `gnome-extensions prefs` says the extension has no preferences

The Shell's cached metadata predates `prefs.js`. Log out and back in, then:

```bash
gnome-extensions prefs middle-drag-gestures@swad
```

### Introspection shows `OverviewUp()` / `OverviewDown()`

The running Shell still has the pre-rename code (see above). The daemon now
calls `ShowOverview()` / `HideOverview()`, so the vertical gestures log
`UnknownMethod` until you re-login.

---

## Daemon problems

### The daemon is not running

```bash
systemctl --user status middle-drag-daemon.service
journalctl --user -u middle-drag-daemon.service -n 100 --no-pager
systemctl --user restart middle-drag-daemon.service
```

### `GSettings schema org.gnome.shell.extensions.middle-drag not found`

The schema is not installed for the user:

```bash
mkdir -p ~/.local/share/glib-2.0/schemas
cp extension/middle-drag-gestures@swad/schemas/*.xml ~/.local/share/glib-2.0/schemas/
glib-compile-schemas ~/.local/share/glib-2.0/schemas/
```

The daemon keeps working with built-in defaults until then.

### `permission denied on /dev/input/…`

```bash
groups | tr ' ' '\n' | grep -x input || sudo usermod -aG input "$USER"
```

Log out and back in afterwards.

### `… is already grabbed by another process (a second daemon?)`

Two daemons are running at once - usually a leftover manual run plus the
service:

```bash
pgrep -af middle-drag-daemon
pkill -f 'middle-drag-daemon.py'     # then:
systemctl --user start middle-drag-daemon.service
```

The daemon retries every two seconds; it will take over as soon as the other
process exits.

### `permission denied` on `/dev/uinput`

```bash
ls -l /dev/uinput        # expect: crw-rw---- root input
lsmod | grep uinput || sudo modprobe uinput
```

Reinstall the udev rule (needs a terminal for sudo):

```bash
sudo install -m 0644 udev/99-middle-drag-uinput.rules \
    /etc/udev/rules.d/99-middle-drag-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
```

### The mouse disappears when the daemon starts

The daemon grabs the physical device, so the virtual mouse must exist. Check
the log for `virtual mouse created`. If `uinput` is broken, stop the daemon:

```bash
systemctl --user stop middle-drag-daemon.service
```

The grab is released immediately; reconnect the mouse if it still misbehaves.

### The mouse became unresponsive

```bash
systemctl --user stop middle-drag-daemon.service
```

Cleanup runs on SIGTERM (`ungrab` + virtual device removal) and the kernel
releases an `EVIOCGRAB` as soon as the process's file descriptors close, so
even a hard kill does not leave the device grabbed.

### Gestures do not fire / fire too easily

```bash
gsettings get org.gnome.shell.extensions.middle-drag threshold
gsettings set org.gnome.shell.extensions.middle-drag threshold 150
```

The threshold is in pixels of accumulated movement during one middle-button
hold. Watch the daemon's debug output:

```bash
systemctl --user stop middle-drag-daemon.service
python3 ~/.local/bin/middle-drag-daemon.py --verbose
# hold middle, drag, and look for: gesture LEFT (dx=…, dy=…)
```

### Gestures do nothing but the log shows the gesture

The daemon detected it, the D-Bus call failed - see "Extension problems".

---

## Middle click still pastes in terminals

The daemon is not running (it is what consumes `BTN_MIDDLE`):

```bash
systemctl --user status middle-drag-daemon.service
```

GNOME's own middle-click emulation should stay off:

```bash
gsettings get org.gnome.desktop.peripherals.mouse middle-click-emulation
# expect: false
```

---

## Wrong mouse selected

```bash
python3 ~/.local/bin/middle-drag-daemon.py --list-devices
```

```text
/dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse    SIGMACHIP Usb Mouse
```

Pin it:

```bash
gsettings set org.gnome.shell.extensions.middle-drag device \
  /dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse
```

`auto` picks the first device that advertises `BTN_LEFT`, `BTN_RIGHT`,
`BTN_MIDDLE`, `REL_X` and `REL_Y`. Touchpads, keyboards and the daemon's own
virtual mouse are excluded.

---

## Reset everything

```bash
gsettings reset org.gnome.shell.extensions.middle-drag enabled
gsettings reset org.gnome.shell.extensions.middle-drag threshold
gsettings reset org.gnome.shell.extensions.middle-drag device
gsettings reset org.gnome.shell.extensions.middle-drag left-action
gsettings reset org.gnome.shell.extensions.middle-drag right-action
gsettings reset org.gnome.shell.extensions.middle-drag up-action
gsettings reset org.gnome.shell.extensions.middle-drag down-action
```

## Testing the layers by hand

```bash
# extension, without restarting your session
./scripts/verify-extension.sh

# daemon, unit + integration
python3 -m unittest discover -s tests -v
python3 tests/integration_test.py

# raw input, to prove the hardware is fine
sudo libinput debug-events
```
