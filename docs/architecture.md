# Architecture

Middle-Drag Gestures has two components that talk over D-Bus:

```text
                     MIDDLE-DRAG GESTURES
                              │
             ┌────────────────┴────────────────┐
             │                                 │
             ▼                                 ▼
      GNOME Shell Extension             Input Daemon
             │                                 │
       GNOME-specific                    Linux-specific
          logic                              logic
             │                                 │
       GSettings / UI                      evdev / uinput
             │                                 │
             └──────────────┬──────────────────┘
                            │
                          D-Bus
```

* the **extension** knows about GNOME: workspaces, the Overview, GSettings,
  the preferences window
* the **daemon** knows about Linux input: `/dev/input`, grabbing devices,
  `uinput` virtual devices, gesture detection

Neither side needs to know how the other works. **D-Bus is the boundary.**

---

## 1. Why two components are needed

A GNOME Shell extension observes events on the Shell's own Clutter stage.
Application windows are Wayland surfaces: *they* receive their pointer
events, and there is no public Shell API to intercept events belonging to
every application.

```text
GNOME Shell UI
     │  └── a Shell extension can observe Shell-side events

Application window
     │  └── the Wayland application owns its pointer events
```

Middle-Drag Gestures must see the middle button even while the pointer is
over Firefox, a terminal or a game. That requires reading the device below
the desktop stack, which is what `evdev` does:

```text
physical mouse
     │
     ▼
/dev/input/event*        ← the daemon reads here (below Wayland)
     │
     ▼
  daemon ──── D-Bus ────► GNOME Shell extension ────► workspaces / Overview
     │
     ▼
uinput virtual mouse ────► Wayland compositor ────► applications
```

The original prototype was a pure GNOME extension using
`global.stage.connect('captured-event', …)`. It only worked when the pointer
was over Shell UI, which is why the daemon exists.

---

## 2. Data flow

### Normal input

Everything the mouse reports - movement, wheel, left/right/extra buttons - is
re-emitted on a virtual mouse created with `uinput`. Applications cannot tell
the difference, except that the device is now called
`Middle Drag Virtual Mouse`.

### The middle button

`BTN_MIDDLE` is **consumed**: it is read from the physical device and never
written to the virtual one. Reserving the button is what makes it usable as a
gesture modifier - applications no longer see a middle click (paste in
terminals, close tab, autoscroll).

```text
physical BTN_MIDDLE ──► daemon ──┬──► gesture detection
                                 └──► (not forwarded)
```

### Gestures

While the middle button is held, `REL_X`/`REL_Y` movement is accumulated:

| condition | meaning |
| --------- | ------- |
| `max(abs(dx), abs(dy)) >= threshold` | the drag is big enough to be a gesture |
| `abs(dx) > abs(dy)` | horizontal gesture (otherwise vertical) |
| `dx < 0` | left, `dx > 0` right |
| `dy < 0` | up, `dy > 0` down (Linux Y grows downwards) |

A `fired` flag guarantees **one action per middle-button press**: extra
movement after the first trigger is ignored until the button is released.

Default mapping:

```text
          MIDDLE + UP
                │
                ▼
         Show Overview

MIDDLE + LEFT              MIDDLE + RIGHT
      │                          │
      ▼                          ▼
 Next Workspace           Previous Workspace

          MIDDLE + DOWN
                │
                ▼
         Hide Overview
```

Each direction maps to a configurable action
(`org.gnome.shell.extensions.middle-drag`), which the daemon translates into
a D-Bus method call.

---

## 3. The D-Bus contract

```text
bus name      org.gnome.Shell.Extensions.MiddleDrag
object path   /org/gnome/Shell/Extensions/MiddleDrag
interface     org.gnome.Shell.Extensions.MiddleDrag
```

| method | effect |
| ------ | ------ |
| `PreviousWorkspace()` | activate the previous workspace |
| `NextWorkspace()` | activate the next workspace |
| `ShowOverview()` | open the Overview |
| `HideOverview()` | close the Overview |
| `GetStatus()` | JSON blob: uuid, version, enabled, threshold, device |

Method names describe the **operation**, not the gesture direction, so the
configured action decides which method is called. The daemon never touches
GNOME's internal APIs.

Because GNOME Shell only reloads extension code at login, the daemon also
tolerates a session that still exports the pre-rename names `OverviewUp()` /
`OverviewDown()`: it calls the current name first and retries once under the
old name when the answer is `UnknownMethod` (`LEGACY_METHODS` in the daemon).
New sessions never hit that path.

Check it yourself:

```bash
gdbus introspect \
  --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag

gdbus call --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.GetStatus
```

---

## 4. The daemon step by step

1. **Read configuration** - GSettings (live, via a small GLib main loop) with
   command-line overrides for `--device` and `--threshold`.
2. **Find the mouse** - enumerate `/dev/input/event*`, keep devices that
   advertise `BTN_LEFT`, `BTN_RIGHT`, `BTN_MIDDLE`, `REL_X` and `REL_Y`.
   The daemon's own virtual mouse is excluded so it can never grab itself.
   Stable `/dev/input/by-id/…` paths are preferred over `eventN` numbers.
3. **Create the virtual mouse** (`uinput`) - without it, grabbing the
   physical device would leave the desktop with no mouse at all.
4. **Grab** the physical device (`EVIOCGRAB`) - this is what reserves the
   middle button and routes every event through the daemon.
5. **Forward and filter** in a `select()` loop with a 1s tick so shutdown and
   settings changes are noticed promptly.
6. **Release** in a `finally` block: `ungrab()` then `close()` the virtual
   device - on SIGTERM, SIGINT and on any error.

### Reconnect handling

USB mice disappear. When `read()` or `select()` reports the device is gone,
the daemon ungrabs, closes, and goes back to step 2, polling every two
seconds until the mouse returns.

### Failure isolation

* a failed grab (for example a second daemon already holding the device)
  logs `already grabbed by another process` and backs off
* a session that ends immediately is always followed by a pause, so no error
  path can become a hot loop
* an unexpected exception is logged with a traceback and the loop restarts

---

## 5. Process model

The daemon runs as a **`systemd --user` unit**, never as root:

```ini
[Service]
ExecStart=%h/.local/bin/middle-drag-daemon.py
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
```

Root privileges are used only during installation, for the udev rule.

The runtime footprint is:

```text
~/.local/share/gnome-shell/extensions/middle-drag-gestures@swad/
~/.local/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml
~/.local/bin/middle-drag-daemon.py
~/.config/systemd/user/middle-drag-daemon.service
/etc/udev/rules.d/70-middle-drag-uaccess.rules
```

That is a script install. The RPM ships the same five things under the
distribution's own directories instead: `/usr/libexec/middle-drag-daemon`,
`/usr/lib/systemd/user/middle-drag-daemon.service`,
`/usr/share/gnome-shell/extensions/middle-drag-gestures@swad/`,
`/usr/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml`
and `/usr/lib/udev/rules.d/70-middle-drag-uaccess.rules`.

---

## 6. Design principles

1. GNOME-specific logic stays in JavaScript; Linux input logic stays in
   Python.
2. D-Bus is the only interface between them.
3. The runtime daemon is unprivileged.
4. Never hardcode one particular mouse - discover devices.
5. Any code that grabs an input device must always restore it.
6. No X11 utilities: this is a Wayland design.
