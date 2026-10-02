#!/usr/bin/env bash
#
# verify-clean.sh - prove that no trace of Middle-Drag Gestures remains.
#
# The machine-readable counterpart of uninstall.sh: uninstall.sh removes
# things and reports what it could not; this script asserts the end state
# and exits non-zero if anything is left.  It checks every destination that
# install.sh writes to (see its header) **and** every path the Fedora RPM
# owns under /usr, /usr/lib and /usr/lib/udev - so a CLEAN verdict holds
# whichever of the two ways was used.
#
# Usage:
#   ./scripts/verify-clean.sh [--purge] [--help]
#
#   --purge  additionally assert that everything only --purge removes is
#            gone: dconf values, the enabled-extensions entry, the
#            disabled-extensions entry and the install state file.
#
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$PROJECT_DIR/scripts/lib.sh"
UUID="$MDG_UUID"
SCHEMA_ID="$MDG_SCHEMA"
CURRENT_USER="${USER:-$(id -un)}"

EXT_DST="${HOME}/.local/share/gnome-shell/extensions/$UUID"
DAEMON_DST="${HOME}/.local/bin/middle-drag-daemon.py"
UNIT_DST="${HOME}/.config/systemd/user/middle-drag-daemon.service"
SCHEMA_XML="${HOME}/.local/share/glib-2.0/schemas/${SCHEMA_ID}.gschema.xml"
UDEV_DST="/etc/udev/rules.d/99-middle-drag-uinput.rules"
UDEV_LEGACY="/etc/udev/rules.d/99-uinput.rules"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/middle-drag-gestures"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge)   PURGE=1 ;;
        -h|--help) sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         printf 'Error: unknown option: %s (see --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

FAILURES=0
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf 'note: %s\n' "$*"; }

printf 'Verifying that Middle-Drag Gestures is fully removed%s\n' \
    "$([ "$PURGE" = 1 ] && echo ' (--purge)' || echo '')"
printf '=========================================================\n\n'

# --- files -----------------------------------------------------------------
if [ -e "$EXT_DST" ]; then
    fail "extension directory still exists: $EXT_DST"
else
    ok "extension directory"
fi

if [ -e "$DAEMON_DST" ]; then
    fail "daemon still present: $DAEMON_DST"
else
    ok "daemon"
fi

if [ -e "$UNIT_DST" ]; then
    fail "systemd user unit still present: $UNIT_DST"
else
    ok "systemd user unit"
fi

if [ -f "$SCHEMA_XML" ]; then
    fail "GSettings schema still present: $SCHEMA_XML"
else
    ok "GSettings schema"
fi

if [ -e "$CACHE_DIR" ]; then
    fail "staging cache still present: $CACHE_DIR"
else
    ok "staging cache"
fi

# --- system files (Fedora RPM install) -------------------------------------
# `dnf install` puts everything under /usr instead of ~/.local.  Without the
# checks below, verify-clean would print CLEAN over a live RPM install.
for sys in \
    "/usr/libexec/middle-drag-daemon" \
    "/usr/lib/udev/rules.d/99-middle-drag-uinput.rules" \
    "/usr/share/gnome-shell/extensions/middle-drag-gestures@swad" \
    "/usr/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml"; do
    if [ -e "$sys" ]; then
        fail "RPM file still installed: $sys"
    else
        ok "RPM file $(basename "$sys") absent"
    fi
done

if command -v rpm >/dev/null 2>&1; then
    if rpm -q middle-drag-gestures >/dev/null 2>&1; then
        fail "rpm package still installed: $(rpm -q middle-drag-gestures)"
    else
        ok "rpm package not installed"
    fi
fi

# --- udev ------------------------------------------------------------------
for rule in "$UDEV_DST" "$UDEV_LEGACY"; do
    if [ -f "$rule" ]; then
        if grep -q 'KERNEL=="uinput"' "$rule" 2>/dev/null; then
            fail "udev rule still installed: $rule"
        else
            note "$rule exists but is not ours (KERNEL==\"uinput\" absent) - kept"
        fi
    else
        ok "udev rule $(basename "$rule")"
    fi
done

# --- systemd ---------------------------------------------------------------
# Three distinct things must be gone: the unit files (user, /etc, /usr), the
# symlink systemd creates when the unit is enabled, and the running daemon.
for unit in "$UNIT_DST" \
            "/etc/systemd/user/middle-drag-daemon.service" \
            "/usr/lib/systemd/user/middle-drag-daemon.service"; do
    if [ -e "$unit" ]; then
        fail "unit file still present: $unit"
    else
        ok "unit file $(basename "$unit") absent"
    fi
done

enabled_links="$(find "${HOME}/.config/systemd/user" -name 'middle-drag-daemon.service' \
    -type l 2>/dev/null)"
if [ -n "$enabled_links" ]; then
    fail "unit is still enabled: $enabled_links"
else
    ok "no enabled symlink"
fi

if systemctl --user is-active --quiet middle-drag-daemon.service 2>/dev/null; then
    fail "daemon service is still running"
else
    ok "daemon service not running"
fi

# The manager can hold a unit in memory after its file has been deleted; that
# clears at the next daemon-reload or login, so it is only a note unless a
# unit file actually exists somewhere.
load_state="$(systemctl --user show -p LoadState --value \
    middle-drag-daemon.service 2>/dev/null || echo unknown)"
if [ "$load_state" = "not-found" ] || [ "$load_state" = "unknown" ]; then
    ok "systemd manager has no record of the unit"
else
    # No unit file exists anywhere (checked above), so this is only the
    # manager's in-memory copy, which drops at the next daemon-reload.
    note "systemd manager still holds '$load_state' in memory - clears at\n        next daemon-reload or login"
fi

# --- extension state in org.gnome.shell ------------------------------------
enabled_list="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")"
disabled_list="$(gsettings get org.gnome.shell disabled-extensions 2>/dev/null || echo "[]")"

case "$enabled_list" in
    *"$UUID"*) fail "uuid is still in org.gnome.shell enabled-extensions" ;;
    *)         ok "not enabled in org.gnome.shell" ;;
esac

# --- dconf -----------------------------------------------------------------
dconf_out="$(dconf list "/org/gnome/shell/extensions/middle-drag/" 2>/dev/null || true)"
if [ -n "$dconf_out" ]; then
    if [ "$PURGE" = 1 ]; then
        fail "dconf values remain under /org/gnome/shell/extensions/middle-drag/"
        printf '%s' "$dconf_out" | sed 's/^/        /'
    else
        note "dconf values kept (use --purge): /org/gnome/shell/extensions/middle-drag/"
    fi
else
    ok "no dconf values"
fi

# --- install state ---------------------------------------------------------
if [ -f "$MDG_STATE_FILE" ]; then
    if [ "$PURGE" = 1 ]; then
        fail "install state file remains: $MDG_STATE_FILE"
    else
        note "install state kept (use --purge): $MDG_STATE_FILE"
    fi
else
    ok "install state file"
fi

if [ "$PURGE" = 1 ]; then
    case "$disabled_list" in
        *"$UUID"*) fail "uuid is still in org.gnome.shell disabled-extensions" ;;
        *)         ok "not in org.gnome.shell disabled-extensions" ;;
    esac
fi

# --- input group (informational) -------------------------------------------
# Whether this membership is ours is only known from the state file, which
# --purge removes, so it can never be asserted here - uninstall.sh drops it
# when the state file says we added it.
if id -nG "$CURRENT_USER" 2>/dev/null | grep -qw input; then
    note "'$CURRENT_USER' is in the 'input' group (uninstall keeps a\n        membership it cannot prove it added)"
fi

# --- summary ----------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf '%s\n' "CLEAN: no trace of Middle-Drag Gestures remains."
    exit 0
fi
printf '%s\n' "NOT CLEAN: $FAILURES leftover(s) found."
exit 1
