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
#   ./scripts/verify-clean.sh [--purge] [--scope=script|system|all] [--help]
#
#   --purge    additionally assert that everything only --purge removes is
#              gone: dconf values, the enabled-extensions entry, the
#              disabled-extensions entry and the install state file.
#
#   --scope=   which install method to judge.  The default, `all`, demands a
#              clean machine whichever way it was installed with:
#                script   paths install.sh writes (~/.local, ~/.config,
#                         /etc/udev, the install state file)
#                system   paths the Fedora RPM owns (/usr, /usr/lib/udev,
#                         /usr/lib/systemd, the package itself)
#              The session-level assertions - enabled-extensions and dconf
#              values - run under `all` only: a dconf key cannot be
#              attributed to one method or the other, so a narrow scope
#              reports what it can prove and stays quiet about the rest.
#
#              tests/install_matrix.sh passes --scope=script so it can test
#              the script's own cycle while the RPM is installed; that case
#              is reported as a note, never silently hidden.
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
UDEV_DST="/etc/udev/rules.d/70-middle-drag-uaccess.rules"
UDEV_LEGACY="/etc/udev/rules.d/99-uinput.rules"
UDEV_PREV="/etc/udev/rules.d/99-middle-drag-uinput.rules"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/middle-drag-gestures"

PURGE=0
SCOPE="all"
for arg in "$@"; do
    case "$arg" in
        --purge)   PURGE=1 ;;
        --scope=all|--scope=script|--scope=system) SCOPE="${arg#--scope=}" ;;
        --scope=*)
            printf 'Error: unknown scope: %s (use script, system or all)\n' \
                "${arg#--scope=}" >&2
            exit 2 ;;
        -h|--help) sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         printf 'Error: unknown option: %s (see --help)\n' "$arg" >&2; exit 2 ;;
    esac
done

FAILURES=0
ok()   { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf 'note: %s\n' "$*"; }

# Which install method's leftovers are ours to judge (see --help).
want_script() { [ "$SCOPE" != system ]; }
want_system() { [ "$SCOPE" != script ]; }

printf 'Verifying that Middle-Drag Gestures is fully removed%s%s\n' \
    "$([ "$PURGE" = 1 ] && echo ' (--purge)' || echo '')" \
    "$([ "$SCOPE" != all ] && echo " (--scope=$SCOPE)" || echo '')"
printf '=========================================================\n\n'

# --- files (script install) -------------------------------------------------
if want_script; then
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
fi   # want_script

# --- system files (Fedora RPM install) -------------------------------------
# `dnf install` puts everything under /usr instead of ~/.local.  Without the
# checks below, verify-clean would print CLEAN over a live RPM install.
if want_system; then
for sys in \
    "/usr/libexec/middle-drag-daemon" \
    "/usr/lib/udev/rules.d/70-middle-drag-uaccess.rules" \
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

# The package enables its unit *globally* (50-middle-drag-gestures.preset
# applied by the install scriptlet), so this symlink sits in /etc and belongs
# to the package rather than to any one account.
GLOBAL_WANTS="/etc/systemd/user/graphical-session.target.wants/middle-drag-daemon.service"
if [ -L "$GLOBAL_WANTS" ] || [ -e "$GLOBAL_WANTS" ]; then
    fail "unit is still enabled globally: $GLOBAL_WANTS"
else
    ok "no globally enabled unit"
fi
else
    # Judging only the script's paths while the package is installed is a
    # deliberate choice (the matrix does it) - say so rather than hide it.
    if command -v rpm >/dev/null 2>&1 && rpm -q middle-drag-gestures >/dev/null 2>&1; then
        note "rpm package is installed but out of scope for --scope=script - run without --scope to judge the whole machine"
    fi
fi   # want_system

# --- udev (script install writes to /etc, the RPM to /usr/lib/udev) --------
if want_script; then
for rule in "$UDEV_DST" "$UDEV_PREV" "$UDEV_LEGACY"; do
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
fi   # want_script

# --- systemd ---------------------------------------------------------------
# Three distinct things must be gone: the unit files (user, /etc, /usr), the
# symlink systemd creates when the unit is enabled, and the running daemon.
if want_script; then
if [ -e "$UNIT_DST" ]; then
    fail "unit file still present: $UNIT_DST"
else
    ok "unit file $(basename "$UNIT_DST") absent"
fi
fi   # want_script

# The enable symlink lives in the same directory for both methods, so it is
# checked under every scope and attributed by where it points.
enabled_links="$(find "${HOME}/.config/systemd/user" -name 'middle-drag-daemon.service' \
    -type l 2>/dev/null)"
found_link=0
for link in $enabled_links; do
    found_link=1
    # The link lives in the same place for both methods; its target tells us
    # whose it is (a script install points into $HOME, an RPM into /usr).
    target="$(readlink -f "$link" 2>/dev/null || true)"
    case "$SCOPE:$target" in
        script:"$HOME"/*|all:*)
            fail "unit is still enabled: $link -> ${target:-?}" ;;
        script:*)
            note "enabled symlink points at the RPM's unit - out of scope for --scope=script: $link" ;;
        system:"$HOME"/*)
            note "enabled symlink belongs to the script install - out of scope for --scope=system: $link" ;;
        system:*|all:*)
            fail "unit is still enabled: $link -> ${target:-?}" ;;
    esac
done
if [ "$found_link" = 0 ]; then
    ok "no enabled symlink"
fi

if want_system; then
for unit in "/etc/systemd/user/middle-drag-daemon.service" \
            "/usr/lib/systemd/user/middle-drag-daemon.service"; do
    if [ -e "$unit" ]; then
        fail "unit file still present: $unit"
    else
        ok "unit file $(basename "$unit") absent"
    fi
done
fi   # want_system

# These two talk to the user manager of *this login*, whose unit paths came
# from its own HOME rather than ours.  Under a throwaway HOME they would judge
# someone else's session - observed: a matrix run reported the live daemon as
# still running - so skip them and say so.
if mdg_session_writable; then
    if systemctl --user is-active --quiet middle-drag-daemon.service 2>/dev/null; then
        # Both installs use the same unit name, so ask systemd which file it
        # actually loaded before deciding whose leftover this is.
        frag="$(systemctl --user show -p FragmentPath --value \
            middle-drag-daemon.service 2>/dev/null || true)"
        case "$SCOPE:$frag" in
            all:*|script:"$UNIT_DST"|system:/usr/lib/systemd/user/middle-drag-daemon.service)
                fail "daemon service is still running ($frag)" ;;
            script:*)
                note "a daemon is running from the RPM install - out of scope for --scope=script" ;;
            system:*)
                note "a daemon is running from the script install - out of scope for --scope=system" ;;
            *)
                fail "daemon service is still running (unit file unknown: ${frag:-none})"
                ;;
        esac
    else
        ok "daemon service not running"
    fi

    # The manager can hold a unit in memory after its file has been deleted;
    # that clears at the next daemon-reload or login, so it is only a note
    # unless a unit file actually exists somewhere.
    load_state="$(systemctl --user show -p LoadState --value \
        middle-drag-daemon.service 2>/dev/null || echo unknown)"
    if [ "$load_state" = "not-found" ] || [ "$load_state" = "unknown" ]; then
        ok "systemd manager has no record of the unit"
    else
        # No unit file exists anywhere (checked above), so this is only the
        # manager's in-memory copy, which drops at the next daemon-reload.
        note "systemd manager still holds '$load_state' in memory - clears at\n        next daemon-reload or login"
    fi
else
    note "skipped live systemd checks (foreign HOME): they would report this login's manager, not the tree under test"
fi

# --- extension state in org.gnome.shell ------------------------------------
# Only under `all`: the same uuid in these keys could have been written by
# either method, and there is no way to prove whose it is.
if [ "$SCOPE" = all ]; then
enabled_list="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")"
disabled_list="$(gsettings get org.gnome.shell disabled-extensions 2>/dev/null || echo "[]")"

case "$enabled_list" in
    *"$UUID"*) fail "uuid is still in org.gnome.shell enabled-extensions" ;;
    *)         ok "not enabled in org.gnome.shell" ;;
esac
else
    note "org.gnome.shell keys not judged under --scope=$SCOPE (they belong to both methods)"
    disabled_list="[]"
fi

# --- dconf -----------------------------------------------------------------
# Same attribution problem as the keys above: these values are not labeled
# with the method that wrote them, so they belong to `all`.
if [ "$SCOPE" = all ]; then
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
fi

# --- install state (written by the script installer only) -------------------
if want_script; then
if [ -f "$MDG_STATE_FILE" ]; then
    if [ "$PURGE" = 1 ]; then
        fail "install state file remains: $MDG_STATE_FILE"
    else
        note "install state kept (use --purge): $MDG_STATE_FILE"
    fi
else
    ok "install state file"
fi
fi   # want_script

if [ "$PURGE" = 1 ] && [ "$SCOPE" = all ]; then
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

# --- uaccess ACL on the device nodes (informational) -----------------------
# Removing the udev rule does not recompute the ACL logind already granted:
# it stays on the nodes until the next session change (usually a reboot).
# uninstall.sh strips the current user's entries when it can, so anything
# left here belongs to another session or an older run - a note, never a
# failure, because /dev is runtime state and not owned by any install path.
if command -v getfacl >/dev/null 2>&1; then
    acl_leftovers=""
    for node in /dev/uinput /dev/input/event*; do
        [ -e "$node" ] || continue
        if getfacl -cp "$node" 2>/dev/null | grep -qE "^user:${CURRENT_USER}:"; then
            acl_leftovers="$acl_leftovers $node"
        fi
    done
    if [ -n "$acl_leftovers" ]; then
        note "uaccess ACL for '$CURRENT_USER' still on:$acl_leftovers (clears at the next session change)"
    fi
fi

# --- summary ----------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf '%s\n' "CLEAN: no trace of Middle-Drag Gestures remains."
    exit 0
fi
printf '%s\n' "NOT CLEAN: $FAILURES leftover(s) found."
exit 1
