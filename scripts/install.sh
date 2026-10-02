#!/usr/bin/env bash
#
# install.sh - install the Middle-Drag Gestures extension and daemon.
#
# Layout after installation:
#
#   ~/.local/share/gnome-shell/extensions/middle-drag-gestures@swad/
#   ~/.local/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml
#   ~/.local/bin/middle-drag-daemon.py
#   ~/.config/systemd/user/middle-drag-daemon.service
#   /etc/udev/rules.d/99-middle-drag-uinput.rules      (root, via sudo)
#
# Idempotent: safe to re-run after every code change.
#
# Usage:
#   ./scripts/install.sh
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UUID="middle-drag-gestures@swad"
SCHEMA_ID="org.gnome.shell.extensions.middle-drag"

EXT_SRC="$PROJECT_DIR/extension/$UUID"
EXT_DST="${HOME}/.local/share/gnome-shell/extensions/$UUID"
DAEMON_SRC="$PROJECT_DIR/daemon/middle-drag-daemon.py"
DAEMON_DST="${HOME}/.local/bin/middle-drag-daemon.py"
UNIT_SRC="$PROJECT_DIR/daemon/middle-drag-daemon.service"
UNIT_DST="${HOME}/.config/systemd/user/middle-drag-daemon.service"
SCHEMA_SRC="$EXT_SRC/schemas/${SCHEMA_ID}.gschema.xml"
SCHEMA_DST_DIR="${HOME}/.local/share/glib-2.0/schemas"
UDEV_SRC="$PROJECT_DIR/udev/99-middle-drag-uinput.rules"
UDEV_DST="/etc/udev/rules.d/99-middle-drag-uinput.rules"
UDEV_LEGACY="/etc/udev/rules.d/99-uinput.rules"

info()  { printf '  %s\n' "$*"; }
step()  { printf '\n%s\n' "$*"; }
die()   { printf '\nError: %s\n' "$*" >&2; exit 1; }

# Root helper: only udev rules need privileges.
as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}
printf 'Installing Middle-Drag Gestures\n'
printf '===============================\n'

# ---------------------------------------------------------------------------
# Privileges: the udev rule is the only step that needs root.
#   * interactive  -> ask for the password once, cache it
#   * passwordless -> use it directly
#   * non-interactive without cached credentials -> skip the udev step with
#     a clear warning instead of hanging on a prompt
# ---------------------------------------------------------------------------
if [ "$(id -u)" = 0 ]; then
    HAVE_ROOT=1
elif [ -t 0 ] && sudo -v 2>/dev/null; then
    HAVE_ROOT=1
elif sudo -n true 2>/dev/null; then
    HAVE_ROOT=1
else
    HAVE_ROOT=0
fi

# ---------------------------------------------------------------------------
# 1. Dependency checks
# ---------------------------------------------------------------------------
step "Checking dependencies"

command -v gnome-shell >/dev/null 2>&1 || die "gnome-shell not found - this project only targets GNOME"
info "gnome-shell: $(gnome-shell --version 2>/dev/null | head -1)"

case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*|*gnome*) info "desktop session: ${XDG_CURRENT_DESKTOP}" ;;
    *) info "warning: XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-}' does not look like GNOME" ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v gdbus >/dev/null 2>&1 || die "gdbus not found (package glib2)"
command -v glib-compile-schemas >/dev/null 2>&1 || die "glib-compile-schemas not found (package glib2)"
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

for module in evdev dbus gi; do
    if ! python3 -c "import $module" >/dev/null 2>&1; then
        case "$module" in
            evdev) hint="sudo dnf install python3-evdev" ;;
            dbus)  hint="sudo dnf install python3-dbus" ;;
            gi)    hint="sudo dnf install python3-gobject" ;;
        esac
        die "python3 cannot import '$module' - install it with: $hint"
    fi
done
info "python3 modules: evdev, dbus, gi"

if [ ! -e /dev/uinput ]; then
    if command -v modprobe >/dev/null 2>&1; then
        info "loading the uinput kernel module"
        as_root modprobe uinput || die "could not load the uinput module"
    else
        die "/dev/uinput is missing and modprobe is unavailable"
    fi
fi
info "/dev/uinput present"

# ---------------------------------------------------------------------------
# 2. input group membership
# ---------------------------------------------------------------------------
step "Checking input group membership"

if id -nG "$USER" | grep -qw input; then
    info "user '$USER' is in the input group"
else
    if [ "$HAVE_ROOT" = 0 ]; then
        die "'$USER' is not in the 'input' group and this shell cannot run sudo.
Run this installer from a terminal so it can ask for your password:
  sudo usermod -aG input \$USER
then log out and back in, and run the installer again."
    fi
    info "adding '$USER' to the input group"
    as_root usermod -aG input "$USER"
    cat <<EOF

  '$USER' was added to the 'input' group.

  Log out and log back in, then run this script again.
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. udev rule
# ---------------------------------------------------------------------------
step "Installing udev rule"

if [ "$HAVE_ROOT" = 0 ]; then
    info "skipped: cannot elevate privileges from this shell (no sudo tty)."
    if [ -f "$UDEV_DST" ] || [ -f "$UDEV_LEGACY" ]; then
        info "an existing udev rule for /dev/uinput was left in place"
    else
        info "WARNING: without this rule the daemon cannot open /dev/uinput."
        info "Run this installer from a terminal, or install it manually:"
        info "  sudo install -m 0644 $UDEV_SRC $UDEV_DST"
        info "  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc"
    fi
else
    if [ "$(id -u)" = 0 ]; then
        install -m 0644 "$UDEV_SRC" "$UDEV_DST"
    else
        printf '%s\n' "$(cat "$UDEV_SRC")" | sudo tee "$UDEV_DST" >/dev/null
        sudo chmod 0644 "$UDEV_DST"
    fi
    info "installed $UDEV_DST"

    if [ -f "$UDEV_LEGACY" ] && grep -q 'KERNEL=="uinput"' "$UDEV_LEGACY" 2>/dev/null; then
        as_root rm -f "$UDEV_LEGACY"
        info "removed legacy $UDEV_LEGACY"
    fi

    as_root udevadm control --reload-rules
    as_root udevadm trigger --subsystem-match=misc
    info "udev rules reloaded"
fi

if [ -e /dev/uinput ]; then
    perms="$(ls -l /dev/uinput | awk '{print $1, $3, $4}')"
    info "/dev/uinput: $perms"
    if [ ! -w /dev/uinput ]; then
        info "warning: /dev/uinput is not writable by '$USER' yet - it becomes"
        info "         effective after the next login (or: udevadm trigger)"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Daemon + systemd user service
# ---------------------------------------------------------------------------
step "Installing the input daemon"

install -D -m 0755 "$DAEMON_SRC" "$DAEMON_DST"
info "$DAEMON_DST"

install -D -m 0644 "$UNIT_SRC" "$UNIT_DST"
info "$UNIT_DST"

systemctl --user daemon-reload

# ---------------------------------------------------------------------------
# 5. GNOME extension + GSettings schema
# ---------------------------------------------------------------------------
step "Installing the GNOME Shell extension"

install -d -m 0755 "$EXT_DST" "$EXT_DST/schemas"
install -m 0644 "$EXT_SRC/extension.js"  "$EXT_DST/extension.js"
install -m 0644 "$EXT_SRC/prefs.js"      "$EXT_DST/prefs.js"
install -m 0644 "$EXT_SRC/metadata.json" "$EXT_DST/metadata.json"
install -m 0644 "$EXT_SRC/stylesheet.css" "$EXT_DST/stylesheet.css"
install -m 0644 "$EXT_SRC/LICENSE"       "$EXT_DST/LICENSE" 2>/dev/null || true
if [ -d "$EXT_SRC/icons" ]; then
    find "$EXT_SRC/icons" -mindepth 1 -maxdepth 1 -exec \
        cp -r {} "$EXT_DST/icons/" \; 2>/dev/null || true
fi
info "$EXT_DST"

# The extension's own Gio.Settings looks for schemas/gschemas.compiled next
# to metadata.json, and enable() reads it - without this the extension
# throws as soon as it is enabled.
install -m 0644 "$SCHEMA_SRC" "$EXT_DST/schemas/"
glib-compile-schemas --strict "$EXT_DST/schemas"
if [ ! -f "$EXT_DST/schemas/gschemas.compiled" ]; then
    die "failed to compile $EXT_DST/schemas/gschemas.compiled"
fi
info "extension schema compiled"

install -d -m 0755 "$SCHEMA_DST_DIR"
install -m 0644 "$SCHEMA_SRC" "$SCHEMA_DST_DIR/"
glib-compile-schemas --strict "$SCHEMA_DST_DIR"
if [ ! -f "$SCHEMA_DST_DIR/gschemas.compiled" ]; then
    die "failed to compile $SCHEMA_DST_DIR/gschemas.compiled"
fi
info "user schema installed ($SCHEMA_DST_DIR)"

if ! gsettings get "$SCHEMA_ID" threshold >/dev/null 2>&1; then
    die "schema $SCHEMA_ID is not usable by gsettings"
fi
info "gsettings can read $SCHEMA_ID"

# ---------------------------------------------------------------------------
# 6. Enable everything
# ---------------------------------------------------------------------------
step "Enabling extension and daemon"

if gnome-extensions enable "$UUID" 2>/dev/null; then
    info "extension enabled"
else
    info "could not enable the extension from this shell - it will be"
    info "enabled on next login, or run: gnome-extensions enable $UUID"
fi

systemctl --user enable middle-drag-daemon.service >/dev/null 2>&1 || true
if systemctl --user restart middle-drag-daemon.service; then
    info "daemon restarted (enabled at login)"
else
    info "warning: the daemon did not start - see:"
    info "  journalctl --user -u middle-drag-daemon.service -n 50"
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
sleep 1
printf '\n%s\n' "----------------------------------------------------------------"
if systemctl --user is-active --quiet middle-drag-daemon.service; then
    printf '%s\n' "Middle-Drag Gestures installed successfully."
else
    printf '%s\n' "Middle-Drag Gestures installed, but the daemon is not running."
    printf '%s\n' "Check: journalctl --user -u middle-drag-daemon.service -n 100"
fi

cat <<'EOF'

Gesture configuration:

  Middle + Left   -> Next workspace
  Middle + Right  -> Previous workspace
  Middle + Up     -> Hide Overview
  Middle + Down   -> Show Overview

Configuration:
  gnome-extensions prefs middle-drag-gestures@swad
  gsettings list-recursively org.gnome.shell.extensions.middle-drag

The daemon starts automatically at login.

NOTE: GNOME Shell loads extension code only at login. If you just updated
      extension.js, log out and log back in (or reboot) for the new code to
      take effect. The daemon restarts immediately.
EOF
