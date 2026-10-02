# Middle-Drag Gestures

A GNOME Shell extension with a companion `evdev`/`uinput` daemon that provides **system-wide middle-mouse-button drag gestures on Wayland**.

The project allows the middle mouse button to act as a gesture modifier:

| Gesture             | Action               |
| ------------------- | -------------------- |
| Middle + drag LEFT  | Next workspace       |
| Middle + drag RIGHT | Previous workspace   |
| Middle + drag UP    | Close GNOME Overview |
| Middle + drag DOWN  | Open GNOME Overview  |

The gesture is detected globally, including while the pointer is over application windows.

The implementation uses:

* GNOME Shell Extension
* D-Bus
* Linux `evdev`
* Linux `uinput`
* `systemd --user`
* `udev`
* Python
* Wayland-compatible input handling

---

# 1. Why This Project Needs Two Components

A normal GNOME Shell extension cannot reliably intercept arbitrary mouse-button events occurring inside application windows on Wayland.

The GNOME Shell extension can receive events from the Shell's own Clutter stage, but application surfaces receive their own pointer events.

Therefore the project uses two layers:

```text
                         Wayland Session
                              │
                              │
                       ┌──────▼──────┐
                       │ GNOME Shell │
                       └──────┬──────┘
                              │
                    GNOME Shell Extension
                              │
                            D-Bus
                              │
                              ▼
                    ┌──────────────────┐
                    │  Input Daemon    │
                    │                  │
                    │ Python + evdev   │
                    │ Python + uinput  │
                    └────────┬─────────┘
                             │
                          /dev/input
                             │
                             ▼
                       Physical Mouse
```

The responsibilities are deliberately separated.

## GNOME Shell Extension

Responsible for:

* GNOME-specific actions
* Workspace switching
* Opening/closing Overview
* D-Bus service
* Preferences
* Future configuration UI

## Input Daemon

Responsible for:

* Reading physical mouse events
* Grabbing the physical mouse
* Detecting middle-button gestures
* Forwarding normal mouse events
* Consuming middle-button events
* Creating the virtual mouse
* Communicating with GNOME through D-Bus

This separation keeps the Linux input layer independent from GNOME's JavaScript internals.

---

# 2. Current Hardware / Software Environment

The current implementation was developed and tested on:

```text
OS:             Fedora 44
Desktop:        GNOME
GNOME Shell:    50.5
Display server: Wayland

Mouse:
    SIGMACHIP Usb Mouse

Input device:
    /dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse

Python:
    Python 3

Python package:
    python-evdev
```

The stable `/dev/input/by-id/` path is used instead of `/dev/input/event3`.

This is important because `/dev/input/event3` is not guaranteed to remain the same after rebooting or reconnecting devices.

---

# 3. Project Layout

The project should eventually be organized as:

```text
middle-drag-gestures/
│
├── README.md
├── LICENSE
├── CHANGELOG.md
├── VERSION
│
├── extension/
│   └── middle-drag-gestures@swad/
│       ├── extension.js
│       ├── metadata.json
│       ├── prefs.js
│       ├── schemas/
│       │   └── org.gnome.shell.extensions.middle-drag.gschema.xml
│       ├── stylesheet.css
│       └── icons/
│
├── daemon/
│   ├── middle-drag-daemon.py
│   ├── requirements.txt
│   └── middle-drag-daemon.service
│
├── dbus/
│   └── org.gnome.Shell.Extensions.MiddleDrag.service
│
├── udev/
│   └── 99-middle-drag-uinput.rules
│
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   ├── enable.sh
│   └── disable.sh
│
├── packaging/
│   └── fedora/
│       └── middle-drag-gestures.spec
│
└── docs/
    ├── architecture.md
    ├── installation.md
    └── troubleshooting.md
```

The current working prototype does not yet contain every file above.

The files below represent the **current working implementation**.

---

# 4. GNOME Extension

## Extension UUID

```text
middle-drag-gestures@swad
```

Installation directory:

```text
~/.local/share/gnome-shell/extensions/middle-drag-gestures@swad/
```

Current files:

```text
extension.js
metadata.json
LICENSE
README.md
```

---

# 5. Current `metadata.json`

```json
{
  "uuid": "middle-drag-gestures@swad",
  "name": "Middle-Drag Gestures",
  "description": "Middle mouse button + drag switches workspaces and toggles the Overview, like three-finger touchpad gestures.",
  "shell-version": ["50"],
  "version": 1
}
```

The extension currently targets GNOME Shell 50.

---

# 6. Current `extension.js`

```javascript
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';


const BUS_NAME = 'org.gnome.Shell.Extensions.MiddleDrag';
const OBJECT_PATH = '/org/gnome/Shell/Extensions/MiddleDrag';

const IFACE_XML = `
<node>
  <interface name="org.gnome.Shell.Extensions.MiddleDrag">
    <method name="PreviousWorkspace"/>
    <method name="NextWorkspace"/>
    <method name="OverviewUp"/>
    <method name="OverviewDown"/>
  </interface>
</node>
`;


export default class MiddleDragGestures extends Extension {

    enable() {

        this._dbusImpl = Gio.DBusExportedObject.wrapJSObject(
            IFACE_XML,
            this
        );

        this._dbusImpl.export(
            Gio.DBus.session,
            OBJECT_PATH
        );


        try {

            const result = Gio.DBus.session.call_sync(
                'org.freedesktop.DBus',
                '/org/freedesktop/DBus',
                'org.freedesktop.DBus',
                'RequestName',
                new GLib.Variant(
                    '(su)',
                    [BUS_NAME, 0]
                ),
                new GLib.VariantType('(u)'),
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );


            const reply = result.deepUnpack()[0];

            console.log(
                `[MiddleDrag] D-Bus RequestName result: ${reply}`
            );


            if (reply !== 1 && reply !== 4) {

                throw new Error(
                    `Failed to acquire D-Bus name: ${reply}`
                );

            }

        } catch (e) {

            console.error(
                `[MiddleDrag] D-Bus registration failed: ${e}`
            );

            this._dbusImpl.unexport();
            this._dbusImpl = null;

            return;
        }


        console.log('[MiddleDrag] D-Bus service ready');
    }


    disable() {

        if (this._dbusImpl) {

            this._dbusImpl.unexport();
            this._dbusImpl = null;

        }


        try {

            Gio.DBus.session.call_sync(
                'org.freedesktop.DBus',
                '/org/freedesktop/DBus',
                'org.freedesktop.DBus',
                'ReleaseName',
                new GLib.Variant(
                    '(s)',
                    [BUS_NAME]
                ),
                new GLib.VariantType('(u)'),
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );

        } catch (e) {

            console.error(
                `[MiddleDrag] D-Bus release failed: ${e}`
            );

        }


        console.log('[MiddleDrag] D-Bus service disabled');
    }


    PreviousWorkspace() {

        this._switchWorkspace(-1);

    }


    NextWorkspace() {

        this._switchWorkspace(1);

    }


    OverviewUp() {

        Main.overview.show();

    }


    OverviewDown() {

        Main.overview.hide();

    }


    _switchWorkspace(direction) {

        const wm = global.workspace_manager;

        const current =
            wm.get_active_workspace_index();

        const targetIndex =
            current + direction;


        if (
            targetIndex < 0 ||
            targetIndex >= wm.get_n_workspaces()
        ) {
            return;
        }


        wm.get_workspace_by_index(targetIndex)
            .activate(global.get_current_time());
    }
}
```

---

# 7. D-Bus Interface

The daemon does not directly manipulate GNOME workspaces.

Instead, it sends D-Bus commands.

Current bus name:

```text
org.gnome.Shell.Extensions.MiddleDrag
```

Object path:

```text
/org/gnome/Shell/Extensions/MiddleDrag
```

Interface:

```text
org.gnome.Shell.Extensions.MiddleDrag
```

Current methods:

```text
PreviousWorkspace()
NextWorkspace()
OverviewUp()
OverviewDown()
```

Conceptually:

```text
Python
   │
   │ gdbus call
   ▼
org.gnome.Shell.Extensions.MiddleDrag
   │
   ▼
GNOME Shell extension
   │
   ├── PreviousWorkspace()
   ├── NextWorkspace()
   ├── OverviewUp()
   └── OverviewDown()
```

For the eventual published version, the Overview methods should preferably be renamed:

```text
ShowOverview()
HideOverview()
```

because `Up` and `Down` describe the gesture direction rather than the actual operation.

---

# 8. Verifying the D-Bus Service

Check that the extension is active:

```bash
gnome-extensions info middle-drag-gestures@swad
```

Expected:

```text
Enabled: Yes
State: ACTIVE
```

Check the GNOME Shell journal:

```bash
journalctl -b /usr/bin/gnome-shell --no-pager | grep MiddleDrag
```

Expected:

```text
[MiddleDrag] D-Bus RequestName result: 1
[MiddleDrag] D-Bus service ready
```

Introspect the interface:

```bash
gdbus introspect \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag
```

The methods should appear in the introspection output.

---

# 9. Manual D-Bus Testing

The individual operations can be tested without moving the mouse.

## Next workspace

```bash
gdbus call \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.NextWorkspace
```

## Previous workspace

```bash
gdbus call \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.PreviousWorkspace
```

## Show Overview

Current implementation:

```bash
gdbus call \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.OverviewUp
```

## Hide Overview

```bash
gdbus call \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.OverviewDown
```

A successful call returns:

```text
()
```

---

# 10. Why `evdev` Is Needed

Linux input devices expose events through:

```text
/dev/input/event*
```

The mouse generates events such as:

```text
BTN_LEFT
BTN_RIGHT
BTN_MIDDLE

REL_X
REL_Y

REL_WHEEL
REL_HWHEEL
```

The daemon reads these low-level events directly.

This occurs below the application/Wayland level.

Therefore it can see the physical middle-button event even when the pointer is over:

* Firefox
* VS Code
* terminal windows
* file managers
* other Wayland applications

This is the key difference between the daemon and the original pure GNOME Shell implementation.

---

# 11. Mouse Device

The physical mouse currently appears as:

```text
SIGMACHIP Usb Mouse
```

Stable device path:

```text
/dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse
```

The device was verified with Python:

```python
from evdev import InputDevice

dev = InputDevice(
    '/dev/input/event3'
)

print('Device:', dev.name)
print('Path:', dev.path)
print('Capabilities:', dev.capabilities())
```

Output:

```text
Device: SIGMACHIP Usb Mouse
Path: /dev/input/event3
Capabilities: {
    0: [0, 1, 2, 4],
    1: [272, 273, 274],
    2: [0, 1, 8, 11],
    4: [4]
}
```

The important codes are:

```text
272 = BTN_LEFT
273 = BTN_RIGHT
274 = BTN_MIDDLE
```

---

# 12. Input Permissions

Linux input devices are normally owned by:

```text
root:input
```

with permissions similar to:

```text
crw-rw----. root input /dev/input/eventX
```

The user therefore needs membership in the `input` group.

Add the current user:

```bash
sudo usermod -aG input "$USER"
```

Then log out and log back in.

Verify:

```bash
groups
```

Expected to contain:

```text
input
```

For example:

```text
swad wheel input
```

---

# 13. `uinput`

The daemon creates a virtual mouse.

Linux provides this through:

```text
/dev/uinput
```

The kernel module is:

```text
uinput
```

Verify:

```bash
lsmod | grep uinput
```

If necessary:

```bash
sudo modprobe uinput
```

The device initially appeared as:

```text
crw-------. 1 root root 10, 223 /dev/uinput
```

so a udev rule was added.

---

# 14. Current udev Rule

File:

```text
/etc/udev/rules.d/99-uinput.rules
```

Current contents:

```udev
KERNEL=="uinput", GROUP="input", MODE="0660"
```

Install/reload:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
```

Verify:

```bash
ls -l /dev/uinput
```

Expected:

```text
crw-rw----. 1 root input 10, 223 /dev/uinput
```

For the published project, rename the rule to:

```text
99-middle-drag-uinput.rules
```

---

# 15. Current Python Daemon

File:

```text
~/.local/bin/middle-drag-daemon.py
```

The current working implementation is:

```python
#!/usr/bin/env python3

import subprocess
import time

from evdev import InputDevice, UInput, ecodes


DEVICE = "/dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse"

THRESHOLD = 100

DBUS_DEST = "org.gnome.Shell.Extensions.MiddleDrag"
DBUS_PATH = "/org/gnome/Shell/Extensions/MiddleDrag"
DBUS_IFACE = "org.gnome.Shell.Extensions.MiddleDrag"


def call_gnome(method):
    result = subprocess.run(
        [
            "gdbus",
            "call",
            "--session",
            "--dest", DBUS_DEST,
            "--object-path", DBUS_PATH,
            "--method", f"{DBUS_IFACE}.{method}",
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"D-Bus error: {result.stderr.strip()}")
    else:
        print(f"Action: {method}")


def create_virtual_mouse():
    capabilities = {
        ecodes.EV_KEY: [
            ecodes.BTN_LEFT,
            ecodes.BTN_RIGHT,
            ecodes.BTN_MIDDLE,
        ],
        ecodes.EV_REL: [
            ecodes.REL_X,
            ecodes.REL_Y,
            ecodes.REL_WHEEL,
            ecodes.REL_HWHEEL,
        ],
    }

    ui = UInput(
        capabilities,
        name="Middle Drag Virtual Mouse",
        version=1,
    )

    time.sleep(0.2)

    print("Virtual mouse created.")

    return ui


def main():

    physical = InputDevice(DEVICE)

    print(f"Physical device: {physical.name}")
    print(f"Physical path:   {physical.path}")

    ui = None

    try:

        ui = create_virtual_mouse()

        physical.grab()

        print("Physical mouse grabbed.")
        print("Middle button is now reserved.")
        print("Press Ctrl+C to stop.")
        print()


        dragging = False
        fired = False

        dx = 0
        dy = 0


        for event in physical.read_loop():

            if event.type == ecodes.EV_KEY:

                if event.code == ecodes.BTN_MIDDLE:

                    if event.value == 1:

                        dragging = True
                        fired = False

                        dx = 0
                        dy = 0

                        print("MIDDLE DOWN")


                    elif event.value == 0:

                        if dragging:
                            print("MIDDLE UP")

                        dragging = False
                        fired = False


                    continue


                if event.code in (
                    ecodes.BTN_LEFT,
                    ecodes.BTN_RIGHT,
                ):

                    ui.write(
                        event.type,
                        event.code,
                        event.value,
                    )

                    ui.syn()


            elif event.type == ecodes.EV_REL:

                ui.write(
                    event.type,
                    event.code,
                    event.value,
                )


                if dragging and not fired:

                    if event.code == ecodes.REL_X:
                        dx += event.value

                    elif event.code == ecodes.REL_Y:
                        dy += event.value


                    if max(
                        abs(dx),
                        abs(dy)
                    ) >= THRESHOLD:

                        fired = True

                        print(
                            f"DRAG: dx={dx}, dy={dy}"
                        )


                        if abs(dx) > abs(dy):

                            if dx < 0:

                                print(
                                    "GESTURE: LEFT → NEXT WORKSPACE"
                                )

                                call_gnome(
                                    "NextWorkspace"
                                )

                            else:

                                print(
                                    "GESTURE: RIGHT → PREVIOUS WORKSPACE"
                                )

                                call_gnome(
                                    "PreviousWorkspace"
                                )


                        else:

                            if dy < 0:

                                print(
                                    "GESTURE: UP → CLOSE OVERVIEW"
                                )

                                call_gnome(
                                    "OverviewDown"
                                )

                            else:

                                print(
                                    "GESTURE: DOWN → OPEN OVERVIEW"
                                )

                                call_gnome(
                                    "OverviewUp"
                                )


                ui.syn()


            elif event.type == ecodes.EV_SYN:

                continue


    except KeyboardInterrupt:

        print()
        print("Stopping...")


    finally:

        try:

            physical.ungrab()

            print("Physical mouse released.")

        except Exception:

            pass


        if ui is not None:

            try:

                ui.close()

                print("Virtual mouse removed.")

            except Exception:

                pass


if __name__ == "__main__":
    main()
```

---

# 16. How the Daemon Works

The daemon has four important stages.

## Stage 1 — Open physical mouse

```python
physical = InputDevice(DEVICE)
```

This opens the Linux evdev device.

---

## Stage 2 — Create virtual mouse

```python
ui = UInput(
    capabilities,
    name="Middle Drag Virtual Mouse",
    version=1,
)
```

Applications do not interact directly with the physical mouse after it is grabbed.

Instead they receive events from:

```text
Middle Drag Virtual Mouse
```

---

# 17. Why a Virtual Mouse Is Necessary

If the daemon simply grabs the physical mouse:

```text
physical mouse
      │
      ▼
   daemon
```

then applications would stop receiving **all** mouse events.

That would make the system unusable.

Therefore the daemon creates:

```text
                   ┌─────────────┐
physical mouse ───►│   daemon    │
                   └──────┬──────┘
                          │
                          ▼
                  virtual mouse
                          │
                          ▼
                     applications
```

Normal events are forwarded.

Middle-button events are intentionally not forwarded.

---

# 18. Event Forwarding

Left/right mouse buttons are forwarded:

```python
if event.code in (
    ecodes.BTN_LEFT,
    ecodes.BTN_RIGHT,
):
    ui.write(
        event.type,
        event.code,
        event.value,
    )

    ui.syn()
```

Movement and wheel events are also forwarded:

```python
ui.write(
    event.type,
    event.code,
    event.value,
)
```

Therefore normal:

* left click
* right click
* pointer movement
* vertical scrolling
* horizontal scrolling

continue working normally.

---

# 19. Consuming Middle Button

Middle button events are handled specially:

```python
if event.code == ecodes.BTN_MIDDLE:
```

The daemon does **not** send the event to the virtual mouse.

Therefore:

```text
Physical BTN_MIDDLE
       │
       ▼
     daemon
       │
       ├── detect gesture
       │
       └── DO NOT forward
```

This reserves the middle button for the gesture system.

---

# 20. Gesture Detection

When middle button is pressed:

```python
dragging = True
fired = False
dx = 0
dy = 0
```

The daemon then accumulates pointer movement:

```python
if event.code == ecodes.REL_X:
    dx += event.value

elif event.code == ecodes.REL_Y:
    dy += event.value
```

The threshold is:

```python
THRESHOLD = 100
```

The gesture fires when:

```python
max(abs(dx), abs(dy)) >= THRESHOLD
```

This prevents tiny accidental movements from triggering a gesture.

---

# 21. Dominant Axis Detection

Once the threshold is reached:

```python
if abs(dx) > abs(dy):
```

the gesture is horizontal.

Otherwise it is vertical.

Horizontal:

```text
dx < 0  → LEFT
dx > 0  → RIGHT
```

Vertical:

```text
dy < 0  → UP
dy > 0  → DOWN
```

Linux pointer Y movement normally increases downward, which is why the vertical mapping appears reversed numerically.

---

# 22. Current Gesture Mapping

Current code:

```text
LEFT
    ↓
NextWorkspace()

RIGHT
    ↓
PreviousWorkspace()

UP
    ↓
OverviewDown()

DOWN
    ↓
OverviewUp()
```

In human terms:

```text
          MIDDLE + UP
                │
                ▼
        Close Overview

MIDDLE + LEFT              MIDDLE + RIGHT
      │                          │
      ▼                          ▼
Next Workspace            Previous Workspace

          MIDDLE + DOWN
                │
                ▼
         Open Overview
```

---

# 23. One Gesture Per Middle Press

The variable:

```python
fired = False
```

prevents repeated actions while the middle button remains held.

Once a gesture is detected:

```python
fired = True
```

Therefore a single middle-button drag produces one action.

The next middle-button press resets:

```python
fired = False
```

---

# 24. Physical Device Grab

The most important line for consuming the middle button is:

```python
physical.grab()
```

This uses Linux's input-device grabbing mechanism.

The physical device is effectively routed through the daemon.

When the daemon exits:

```python
physical.ungrab()
```

releases it.

This is why cleanup is extremely important.

---

# 25. Cleanup

The daemon uses:

```python
finally:
```

to ensure cleanup happens even when interrupted.

Physical mouse:

```python
physical.ungrab()
```

Virtual mouse:

```python
ui.close()
```

Therefore:

```text
Daemon starts
    ↓
physical mouse grabbed
    ↓
virtual mouse created
    ↓
normal events forwarded
    ↓
middle gestures detected
    ↓
daemon stops
    ↓
physical mouse ungrabbed
    ↓
virtual mouse removed
```

This is critical because a crashed or incorrectly terminated input-grabbing process could otherwise leave the mouse in a broken state until the device is reinitialized.

---

# 26. Systemd User Service

Current service:

```text
~/.config/systemd/user/middle-drag-daemon.service
```

Contents:

```ini
[Unit]
Description=Global Middle-Drag Mouse Gestures
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.local/bin/middle-drag-daemon.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
```

This is a **user service**, not a system service.

That is intentional.

The daemon should run as the logged-in user rather than as root.

---

# 27. Enable Automatic Startup

Reload systemd:

```bash
systemctl --user daemon-reload
```

Enable the service:

```bash
systemctl --user enable middle-drag-daemon.service
```

Start it:

```bash
systemctl --user start middle-drag-daemon.service
```

Or do both simultaneously:

```bash
systemctl --user enable --now middle-drag-daemon.service
```

After this, it starts automatically when the user logs into the graphical session.

---

# 28. Check Service Status

```bash
systemctl --user status middle-drag-daemon.service
```

Expected:

```text
Loaded: ... enabled
Active: active (running)
```

---

# 29. View Daemon Logs

```bash
journalctl \
    --user \
    -u middle-drag-daemon.service \
    -n 50 \
    --no-pager
```

Follow logs live:

```bash
journalctl \
    --user \
    -u middle-drag-daemon.service \
    -f
```

---

# 30. Stop the Daemon

```bash
systemctl --user stop middle-drag-daemon.service
```

The daemon's cleanup code should then:

```text
release physical mouse
remove virtual mouse
```

The normal mouse should immediately return to normal operation.

---

# 31. Disable Automatic Startup

```bash
systemctl --user disable middle-drag-daemon.service
```

Stop and disable:

```bash
systemctl --user disable --now middle-drag-daemon.service
```

---

# 32. Original Diagnostic Script

During development, a diagnostic script was used:

```text
~/.local/bin/middle-drag-test.py
```

It was useful for confirming that evdev could see:

```text
BTN_LEFT
BTN_RIGHT
BTN_MIDDLE
REL_X
REL_Y
```

It is no longer required by the project.

It can be removed:

```bash
rm ~/.local/bin/middle-drag-test.py
```

---

# 33. Testing the Physical Input Layer

The Linux input stack can be inspected with:

```bash
sudo libinput debug-events
```

The mouse produced events including:

```text
BTN_LEFT  (272)
BTN_RIGHT (273)
BTN_MIDDLE (274)
```

This verified that the physical mouse itself was correctly generating middle-button events.

---

# 34. GNOME Middle-Click Emulation

GNOME's middle-click emulation was checked using:

```bash
gsettings get org.gnome.desktop.peripherals.mouse middle-click-emulation
```

Current value:

```text
false
```

This is desirable for this project because the physical middle button is intentionally reserved for gestures.

---

# 35. Why `wmctrl` Is Not Part of the Project

`wmctrl` was installed during experimentation.

It is primarily an X11-oriented utility and is unnecessary for this implementation because the project runs through:

```text
GNOME Shell
      +
D-Bus
      +
Wayland
```

It can be removed:

```bash
sudo dnf remove wmctrl
```

The project does not depend on it.

---

# 36. Current Working Architecture

The actual working system is currently:

```text
                  USB Mouse
                     │
                     ▼
             /dev/input/eventX
                     │
                     ▼
            ┌─────────────────┐
            │  Python daemon  │
            │                 │
            │     evdev       │
            │     uinput      │
            └───────┬─────────┘
                    │
          ┌─────────┴─────────┐
          │                   │
     normal events       middle gesture
          │                   │
          ▼                   ▼
   virtual mouse             D-Bus
          │                   │
          ▼                   ▼
   Wayland applications  GNOME extension
                              │
                 ┌────────────┼────────────┐
                 │            │            │
             workspace     workspace    Overview
              next          previous     show/hide
```

---

# 37. Why the Pure GNOME Extension Approach Was Abandoned

The original implementation attempted to use:

```javascript
global.stage.connect('captured-event', ...)
```

to detect the middle button.

This worked when the pointer was interacting with the Shell itself.

However, when the pointer was over an application window, the application received the pointer event instead.

The important distinction is:

```text
GNOME Shell UI
     │
     └── Shell extension can observe Shell-side events


Application window
     │
     └── Wayland application owns its pointer events
```

A public GNOME Shell extension API does not provide a general-purpose:

```text
"intercept every pointer event from every Wayland application"
```

mechanism.

Therefore the low-level input daemon is required for the current design.

---

# 38. Why the Daemon Should Not Be Root

The daemon only needs access to:

```text
/dev/input/...
/dev/uinput
```

It does not need system-wide administrative privileges.

Running it as the normal user provides:

* better security
* better systemd integration
* easier per-user configuration
* no root-owned runtime process
* fewer privilege-escalation concerns

Administrator privileges should only be used during installation for things such as:

```text
udev rule
input permissions
system-level dependencies
```

---

# 39. Installation Architecture

The final installer should perform:

```text
./scripts/install.sh
             │
             ├── Check GNOME
             │
             ├── Check Python
             │
             ├── Check evdev
             │
             ├── Check /dev/uinput
             │
             ├── Check input group
             │
             ├── Install udev rule
             │
             ├── Install daemon
             │
             ├── Install systemd service
             │
             ├── Install GNOME extension
             │
             ├── Reload systemd
             │
             ├── Enable daemon
             │
             └── Enable extension
```

The desired user experience is:

```bash
./scripts/install.sh
```

followed by:

```text
Middle-Drag Gestures installed successfully.

Gesture configuration:

  Middle + Left   → Next workspace
  Middle + Right  → Previous workspace
  Middle + Up     → Close Overview
  Middle + Down   → Open Overview

The daemon will start automatically at login.
```

---

# 40. Future `install.sh`

A production installer should roughly perform:

```bash
#!/usr/bin/env bash

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXTENSION_UUID="middle-drag-gestures@swad"

echo "Installing Middle-Drag Gestures..."

#
# Dependency checks
#

command -v python3 >/dev/null || {
    echo "Error: python3 not found."
    exit 1
}

command -v gdbus >/dev/null || {
    echo "Error: gdbus not found."
    exit 1
}

#
# Check input group
#

if ! id -nG "$USER" | grep -qw input; then

    echo "Adding $USER to input group..."

    sudo usermod -aG input "$USER"

    echo
    echo "You must log out and log back in before continuing."
    exit 0

fi

#
# Install udev rule
#

sudo install \
    -m 0644 \
    "$PROJECT_DIR/udev/99-middle-drag-uinput.rules" \
    /etc/udev/rules.d/99-middle-drag-uinput.rules

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc

#
# Install daemon
#

mkdir -p "$HOME/.local/bin"

install \
    -m 0755 \
    "$PROJECT_DIR/daemon/middle-drag-daemon.py" \
    "$HOME/.local/bin/middle-drag-daemon.py"

#
# Install systemd user service
#

mkdir -p "$HOME/.config/systemd/user"

install \
    -m 0644 \
    "$PROJECT_DIR/daemon/middle-drag-daemon.service" \
    "$HOME/.config/systemd/user/middle-drag-daemon.service"

#
# Install GNOME extension
#

mkdir -p \
    "$HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID"

cp -r \
    "$PROJECT_DIR/extension/$EXTENSION_UUID/"* \
    "$HOME/.local/share/gnome-shell/extensions/$EXTENSION_UUID/"

#
# Enable services
#

systemctl --user daemon-reload

systemctl --user enable \
    middle-drag-daemon.service

systemctl --user start \
    middle-drag-daemon.service

gnome-extensions enable \
    "$EXTENSION_UUID"

echo
echo "Middle-Drag Gestures installed successfully."
```

This is a **future installer design**, not yet the production installer.

---

# 41. Uninstallation Flow

The uninstaller should reverse the installation:

```text
uninstall.sh
     │
     ├── Stop daemon
     │
     ├── Disable daemon
     │
     ├── Remove systemd service
     │
     ├── Remove daemon
     │
     ├── Disable extension
     │
     ├── Remove extension
     │
     ├── Remove udev rule
     │
     └── Reload udev
```

It should **not automatically remove the user from the `input` group**.

The `input` group may be needed by other software.

---

# 42. Future Device Discovery

The current daemon has:

```python
DEVICE = "/dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse"
```

This is suitable for the current machine but not for distribution.

A published version should use:

```text
device = "auto"
```

by default.

The daemon should enumerate:

```text
/dev/input/event*
```

and identify suitable mouse devices based on capabilities.

For example:

```text
Must provide:

BTN_LEFT
BTN_RIGHT
BTN_MIDDLE
REL_X
REL_Y
```

The user could optionally select a specific device.

---

# 43. Mouse Reconnection

The current daemon assumes the device remains available.

A production version should handle:

```text
Mouse unplugged
      │
      ▼
read_loop() ends
      │
      ▼
release device
      │
      ▼
wait
      │
      ▼
search for mouse
      │
      ▼
mouse reconnected
      │
      ▼
grab again
```

This is especially important for USB mice and laptops with docking stations.

---

# 44. Future Configuration

The extension should eventually expose GSettings.

Proposed schema:

```text
org.gnome.shell.extensions.middle-drag
```

Potential keys:

```text
enabled
threshold
left-action
right-action
up-action
down-action
device
```

Example:

```text
enabled       = true
threshold     = 100

left-action   = "next-workspace"
right-action  = "previous-workspace"

up-action     = "hide-overview"
down-action   = "show-overview"

device        = "auto"
```

---

# 45. Future Preferences UI

The GNOME preferences window could look conceptually like:

```text
Middle-Drag Gestures
────────────────────────────────────

Enable gestures                 [ ON ]

Gesture threshold               [ 100 ]

Horizontal gestures

    ← Left                     Next workspace
    → Right                    Previous workspace


Vertical gestures

    ↑ Up                       Hide Overview
    ↓ Down                     Show Overview


Input device                    Auto


Advanced

    Dominant axis required      [ ON ]
    Reverse horizontal          [ OFF ]
    Reverse vertical            [ OFF ]
```

This would make the project substantially more user-friendly.

---

# 46. Improved D-Bus API

The current API is:

```text
PreviousWorkspace()
NextWorkspace()
OverviewUp()
OverviewDown()
```

Recommended published API:

```text
interface org.gnome.Shell.Extensions.MiddleDrag

    PreviousWorkspace()
    NextWorkspace()

    ShowOverview()
    HideOverview()
```

Eventually it could also expose:

```text
GetSettings()
SetSettings(...)
GetStatus()
```

although configuration does not necessarily need to go through D-Bus if GSettings is sufficient.

The most important principle is that the daemon should not need to know GNOME's internal APIs.

---

# 47. Recommended Long-Term Architecture

The clean final design should be:

```text
                     MIDDLE-DRAG GESTURES
                              │
             ┌────────────────┴────────────────┐
             │                                 │
             ▼                                 ▼
      GNOME Shell Extension             Input Daemon
             │                                 │
             │                                 │
       GNOME-specific                     Linux-specific
          logic                              logic
             │                                 │
       GSettings/UI                      evdev/uinput
             │                                 │
             └──────────────┬──────────────────┘
                            │
                           D-Bus
```

The extension knows about:

```text
GNOME
Workspaces
Overview
Settings
```

The daemon knows about:

```text
Linux input
evdev
uinput
mouse events
gestures
```

Neither side needs to know the implementation details of the other.

---

# 48. Publishing Strategy

There are effectively two packages.

## GNOME Extension Package

Example:

```text
middle-drag-gestures@swad.zip
```

Contains only the GNOME Shell extension.

This is suitable for GNOME Extensions distribution.

## Companion Daemon

Distributed separately through:

* GitHub
* Fedora RPM
* installation script
* potentially other Linux package formats

The user experience can still be presented as one project:

```text
Middle-Drag Gestures
    │
    ├── GNOME Extension
    └── Companion Input Daemon
```

The GNOME extension alone cannot install:

```text
/etc/udev/rules.d/
```

or manage:

```text
/dev/uinput
```

so these responsibilities must remain outside the extension package.

---

# 49. Recommended Fedora Package Layout

For eventual Fedora packaging, the daemon could become an RPM.

Conceptually:

```text
/usr/libexec/middle-drag-daemon
/usr/lib/udev/rules.d/99-middle-drag-uinput.rules
/usr/lib/systemd/user/middle-drag-daemon.service
```

The GNOME extension would remain in the appropriate GNOME extension location.

This would be cleaner than relying permanently on a custom installer.

---

# 50. Security Model

The security model should be documented clearly.

The daemon needs access to:

```text
/dev/input/*
/dev/uinput
```

because it must:

* observe physical input
* grab the physical device
* create a virtual input device

It should run:

```text
as the logged-in user
```

and **not** as root.

The installer may request administrator privileges only when modifying system configuration such as:

```text
udev rules
```

---

# 51. Failure Modes

## Extension not running

Check:

```bash
gnome-extensions info middle-drag-gestures@swad
```

If inactive:

```bash
gnome-extensions enable middle-drag-gestures@swad
```

---

## D-Bus unavailable

Check:

```bash
gdbus introspect \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag
```

If this fails, inspect GNOME Shell logs.

---

## Daemon not running

```bash
systemctl --user status middle-drag-daemon.service
```

Then:

```bash
journalctl \
    --user \
    -u middle-drag-daemon.service \
    -n 100 \
    --no-pager
```

---

## Permission denied on `/dev/input`

Check:

```bash
groups
```

Make sure:

```text
input
```

is present.

If not:

```bash
sudo usermod -aG input "$USER"
```

Then log out and back in.

---

## Permission denied on `/dev/uinput`

Check:

```bash
ls -l /dev/uinput
```

Expected:

```text
root input
```

with group read/write permission.

Check:

```bash
lsmod | grep uinput
```

If necessary:

```bash
sudo modprobe uinput
```

---

## Mouse becomes unresponsive

Stop the daemon:

```bash
systemctl --user stop middle-drag-daemon.service
```

The `finally` block should execute:

```python
physical.ungrab()
ui.close()
```

If necessary, physically reconnect the mouse.

---

# 52. Current Development Status

The following pieces are already working:

```text
✓ GNOME Shell extension
✓ GNOME workspace switching
✓ GNOME Overview control
✓ D-Bus service
✓ D-Bus method calls
✓ evdev mouse input
✓ Middle-button detection
✓ uinput virtual mouse
✓ Physical mouse grabbing
✓ Normal mouse forwarding
✓ Middle-button consumption
✓ Four-direction gestures
✓ Gesture threshold
✓ systemd user service
✓ Automatic startup
✓ Wayland operation
```

The current prototype has therefore passed the important proof-of-concept stage.

---

# 53. Remaining Work Before Public Release

The major remaining work is engineering hardening rather than proving the basic concept.

## High priority

```text
[ ] Automatic mouse/device discovery
[ ] Mouse unplug/reconnect handling
[ ] Better daemon error handling
[ ] Production installer
[ ] Production uninstaller
[ ] Rename udev rule
[ ] Rename D-Bus Overview methods
[ ] Configuration through GSettings
[ ] GNOME preferences UI
[ ] Documentation
```

## Later

```text
[ ] Fedora RPM
[ ] GNOME Extensions packaging
[ ] Multiple mouse/device selection
[ ] Gesture customization
[ ] Enable/disable switch
[ ] Debug logging option
[ ] Versioned D-Bus API
[ ] Automated tests
```

---

# 54. Design Principles

The project should follow these principles.

### 1. GNOME-specific logic stays in JavaScript

The extension should deal with:

```text
GNOME workspaces
GNOME Overview
GNOME settings
GNOME UI
```

### 2. Linux input logic stays in Python

The daemon should deal with:

```text
evdev
uinput
mouse events
gesture detection
device management
```

### 3. D-Bus is the boundary

```text
Daemon ←──── D-Bus ────→ Extension
```

### 4. No root daemon

The runtime process should be unprivileged.

### 5. Don't hardcode a particular mouse

Use automatic device discovery.

### 6. Always restore the physical input device

Any input-grabbing code must have reliable cleanup.

### 7. Don't depend on X11 utilities

The project is designed for:

```text
Wayland + GNOME Shell
```

not:

```text
X11 + wmctrl
```

---

# 55. Current Minimal Runtime

At the moment, the complete working runtime consists of:

```text
~/.local/share/gnome-shell/extensions/
└── middle-drag-gestures@swad/
    ├── extension.js
    └── metadata.json


~/.local/bin/
└── middle-drag-daemon.py


~/.config/systemd/user/
└── middle-drag-daemon.service


/etc/udev/rules.d/
└── 99-uinput.rules
```

with:

```text
GNOME extension
      │
      ▼
D-Bus
      ▲
      │
Python daemon
      │
      ├── evdev
      └── uinput
```

This is the **known-good baseline**.

Future development should preserve this working architecture while incrementally improving it.

---

# 56. Quick Start — Current Implementation

Assuming the dependencies and permissions are already configured:

### Enable extension

```bash
gnome-extensions enable middle-drag-gestures@swad
```

### Enable daemon

```bash
systemctl --user daemon-reload

systemctl --user enable --now \
    middle-drag-daemon.service
```

### Check extension

```bash
gnome-extensions info \
    middle-drag-gestures@swad
```

### Check daemon

```bash
systemctl --user status \
    middle-drag-daemon.service
```

### Test D-Bus

```bash
gdbus introspect \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag
```

### Test gesture

```text
Hold middle button
        +
Drag LEFT
        ↓
Next workspace
```

---

# 57. Final Architecture

The intended final project is:

```text
┌──────────────────────────────────────────────────────────────┐
│                    MIDDLE-DRAG GESTURES                     │
│                                                              │
│  ┌──────────────────────┐       ┌────────────────────────┐  │
│  │   GNOME Extension    │       │     Input Daemon       │  │
│  │                      │       │                        │  │
│  │ extension.js         │       │ Python                 │  │
│  │ prefs.js             │       │ evdev                  │  │
│  │ GSettings            │       │ uinput                 │  │
│  │ GNOME actions        │       │ device management      │  │
│  │                      │       │ gesture detection       │  │
│  └──────────┬───────────┘       └───────────┬────────────┘  │
│             │                               │               │
│             │            D-Bus              │               │
│             └───────────────────────────────┘               │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                         │
                         ▼
                    Linux / Wayland
                         │
                 ┌───────┴────────┐
                 │                │
             Physical          Virtual
               Mouse             Mouse
                 │                │
                 ▼                ▼
               evdev          Wayland
                                  │
                                  ▼
                            Applications
```

The fundamental idea is simple:

> **The daemon owns the physical input problem. The extension owns the GNOME problem. D-Bus connects them.**

That separation is what makes the current working prototype capable of becoming a maintainable, distributable GNOME project rather than just a collection of startup scripts.
