#!/usr/bin/env bash
#
# uninstall.sh - remove the Middle-Drag Gestures extension and daemon.
#
# Reverses scripts/install.sh.  Notes:
#   * the 'input' group membership is left alone (other software may need it)
#   * GSettings values in dconf are left alone
#
# Usage:
#   ./scripts/uninstall.sh
#
set -euo pipefail

UUID="middle-drag-gestures@swad"
SCHEMA_ID="org.gnome.shell.extensions.middle-drag"

EXT_DST="${HOME}/.local/share/gnome-shell/extensions/$UUID"
DAEMON_DST="${HOME}/.local/bin/middle-drag-daemon.py"
UNIT_DST="${HOME}/.config/systemd/user/middle-drag-daemon.service"
SCHEMA_DST="${HOME}/.local/share/glib-2.0/schemas/${SCHEMA_ID}.gschema.xml"
UDEV_DST="/etc/udev/rules.d/99-middle-drag-uinput.rules"
UDEV_LEGACY="/etc/udev/rules.d/99-uinput.rules"

info() { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

printf 'Uninstalling Middle-Drag Gestures\n'
printf '=================================\n'

# ---------------------------------------------------------------------------
step "Stopping the daemon"

if systemctl --user is-enabled middle-drag-daemon.service >/dev/null 2>&1 || \
   systemctl --user is-active middle-drag-daemon.service >/dev/null 2>&1; then
    systemctl --user disable --now middle-drag-daemon.service >/dev/null 2>&1 || true
    info "daemon stopped and disabled"
else
    info "daemon unit not enabled"
fi

# ---------------------------------------------------------------------------
step "Removing the daemon and its service"

rm -f "$DAEMON_DST"
info "removed $DAEMON_DST"

rm -f "$UNIT_DST"
info "removed $UNIT_DST"
systemctl --user daemon-reload
info "systemd user units reloaded"

# ---------------------------------------------------------------------------
step "Removing the GNOME Shell extension"

if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions disable "$UUID" >/dev/null 2>&1 || true
    info "extension disabled"
fi

if [ -d "$EXT_DST" ]; then
    rm -rf "$EXT_DST"
    info "removed $EXT_DST"
else
    info "extension directory not present"
fi

# ---------------------------------------------------------------------------
step "Removing the GSettings schema"

if [ -f "$SCHEMA_DST" ]; then
    rm -f "$SCHEMA_DST"
    glib-compile-schemas "${HOME}/.local/share/glib-2.0/schemas/" 2>/dev/null || true
    info "removed $SCHEMA_DST"
    info "dconf values for $SCHEMA_ID were kept"
else
    info "user schema not present"
fi

# ---------------------------------------------------------------------------
step "Removing the udev rule"

removed=0
if [ -f "$UDEV_DST" ]; then
    as_root rm -f "$UDEV_DST"
    info "removed $UDEV_DST"
    removed=1
fi
# The pre-project file used this name; only remove it if it is ours.
if [ -f "$UDEV_LEGACY" ] && grep -q 'KERNEL=="uinput"' "$UDEV_LEGACY" 2>/dev/null; then
    as_root rm -f "$UDEV_LEGACY"
    info "removed legacy $UDEV_LEGACY"
    removed=1
fi
if [ "$removed" = 1 ]; then
    as_root udevadm control --reload-rules
    as_root udevadm trigger --subsystem-match=misc
    info "udev rules reloaded"
else
    info "no udev rule installed"
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------------------------------"
cat <<'EOF'
Middle-Drag Gestures uninstalled.

Not removed on purpose:
  * your membership of the 'input' group (other software may need it)
  * dconf settings under org.gnome.shell.extensions.middle-drag

Log out and log back in so GNOME Shell drops the extension completely.
If the mouse still feels odd, reconnect it or run:
  systemctl --user status middle-drag-daemon.service
EOF
