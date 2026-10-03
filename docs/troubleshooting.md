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

#### `Extension middle-drag-gestures@swad does not exist`

```text
$ gnome-extensions enable middle-drag-gestures@swad
Extension middle-drag-gestures@swad does not exist
$ echo $?
2
```

This is **not** a failed install. GNOME Shell scans the extension
directories once, at login, and reports `does not exist` for anything the
running Shell has not scanned yet - so it happens after a fresh
`install.sh`, and after re-installing over a previous uninstall, until you
log in again.

`install.sh` knows this and therefore does not rely on the CLI: it writes the
uuid into `org.gnome.shell enabled-extensions` directly, which the Shell
honours on its next scan. Confirm it is in place:

```bash
gsettings get org.gnome.shell enabled-extensions
#   ['middle-drag-gestures@swad', …]
```

Then log out and log back in; afterwards `gnome-extensions info` works
normally. To test the extension *without* logging out, use
`./scripts/verify-extension.sh` (it starts a separate, headless Shell that
loads the files fresh from disk).

#### It is enabled but not `ACTIVE`

The Shell rejected it - look for the reason in the Shell journal:

```bash
journalctl -b /usr/bin/gnome-shell --no-pager | grep -i middledrag
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

The running Shell still has the pre-rename code (see above). This is harmless:
the daemon first calls `ShowOverview()` / `HideOverview()`, and when that
answers `UnknownMethod` it retries under the old name, so vertical gestures
keep working. It logs the reason once:

```text
the running extension predates the D-Bus method rename; gestures keep
working through the legacy OverviewUp() fallback. Log out and log back in …
```

Log out and log back in to load the renamed `extension.js` and silence the
notice.

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

Access comes from the uaccess ACL, not from a group membership:

```bash
getfacl /dev/input/event3 | grep user:    # expect: user:YOU:rw- …
ls /usr/lib/udev/rules.d/70-middle-drag-uaccess.rules \
   /etc/udev/rules.d/70-middle-drag-uaccess.rules 2>/dev/null
# expect: exactly one path - the RPM's is in /usr/lib, install.sh's in /etc
```

If the rule is missing, reinstall it (see
[installation](installation.md#2-permissions)). If it is present but the ACL
is not, re-evaluate the devices - the grant then happens immediately for the
running session, or at the next login:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
```

Older releases used `sudo usermod -aG input "$USER"`; that membership still
works and is left untouched.

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
getfacl /dev/uinput | grep user:   # expect: user:YOU:rw- (the uaccess ACL)
lsmod | grep uinput || sudo modprobe uinput
```

Reinstall the udev rule (needs a terminal for sudo). If you installed
the RPM, do **not** copy it into `/etc` - a same-named file there shadows
the packaged rule and would go stale on the next upgrade; reinstall the
package instead:

```bash
sudo dnf reinstall middle-drag-gestures
```

For a script or manual install:

```bash
sudo install -m 0644 udev/70-middle-drag-uaccess.rules \
    /etc/udev/rules.d/70-middle-drag-uaccess.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
sudo udevadm trigger --subsystem-match=input
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

Settings only (stay installed):

```bash
gsettings reset org.gnome.shell.extensions.middle-drag enabled
gsettings reset org.gnome.shell.extensions.middle-drag threshold
gsettings reset org.gnome.shell.extensions.middle-drag device
gsettings reset org.gnome.shell.extensions.middle-drag left-action
gsettings reset org.gnome.shell.extensions.middle-drag right-action
gsettings reset org.gnome.shell.extensions.middle-drag up-action
gsettings reset org.gnome.shell.extensions.middle-drag down-action
```

Everything (files, settings, install state):

```bash
./scripts/uninstall.sh --purge
./scripts/verify-clean.sh --purge   # exit 0 only if nothing is left
```

## Testing the layers by hand

```bash
# the whole install/uninstall matrix against a throwaway HOME
./tests/install_matrix.sh

# extension, without restarting your session
./scripts/verify-extension.sh

# daemon, unit + integration
python3 -m unittest discover -s tests -v
python3 tests/integration_test.py

# raw input, to prove the hardware is fine
sudo libinput debug-events
```

The integration test dispatches three assertions only when the extension is
actually loaded in this session; on a machine where the product has been
uninstalled they are reported as `SKIP`, not `FAIL`.
