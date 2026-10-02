# Middle-Drag Gestures

Personal GNOME 50 extension. Middle mouse button + drag (>= 100 px):

| Drag  | Action                  |
|-------|-------------------------|
| Left  | Previous workspace      |
| Right | Next workspace          |
| Up    | Open Overview           |
| Down  | Close Overview          |

The middle-button press/release is consumed, so applications no longer see
a normal middle click (paste, close tab, autoscroll). Tune `THRESHOLD` in
`extension.js`.

## Install

    cp -r middle-drag-gestures@swad ~/.local/share/gnome-shell/extensions/
    # log out and back in (Wayland), then:
    gnome-extensions enable middle-drag-gestures@swad

Debug: `journalctl -f -o cat /usr/bin/gnome-shell`
