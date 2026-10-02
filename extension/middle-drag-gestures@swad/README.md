# Middle-Drag Gestures (GNOME Shell extension)

GNOME half of the [Middle-Drag Gestures](../../README.md) project. It exports
the D-Bus interface that the companion input daemon calls:

```text
org.gnome.Shell.Extensions.MiddleDrag
  /org/gnome/Shell/Extensions/MiddleDrag

  PreviousWorkspace()
  NextWorkspace()
  ShowOverview()
  HideOverview()
  GetStatus() -> s
```

It owns nothing Linux-specific: no `evdev`, no device paths, no gesture
thresholds. Everything else lives in `daemon/middle-drag-daemon.py`.

Configuration lives in the GSettings schema
`org.gnome.shell.extensions.middle-drag` (see `schemas/`), edited through
`prefs.js`.

## Install / develop

```bash
../scripts/install.sh                # from the repository root
../scripts/verify-extension.sh       # test changes without logging out
```

GNOME Shell caches extension code per session, so log out and back in after
changing `extension.js` or `prefs.js`.
