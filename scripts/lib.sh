#!/usr/bin/env bash
#
# lib.sh - shared helpers for the Middle-Drag Gestures scripts.
#
# Sourced by install.sh, uninstall.sh, enable.sh, disable.sh and
# verify-clean.sh.  Not meant to be executed directly.
#
# shellcheck shell=bash

MDG_UUID="${MDG_UUID:-middle-drag-gestures@swad}"
MDG_SCHEMA="${MDG_SCHEMA:-org.gnome.shell.extensions.middle-drag}"
MDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/middle-drag-gestures"
MDG_STATE_FILE="$MDG_STATE_DIR/state"

info() { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

# ---------------------------------------------------------------------------
# mdg_session_writable -> 0 when it is safe to touch Shell/dconf/systemd here
#
# install.sh and uninstall.sh are routinely run with a throwaway HOME - that
# is how tests/install_matrix.sh and the experiments in the docs work - but
# the services these scripts write to do not follow $HOME:
#
#   * `gsettings set` writes through the dconf service of *this login*, so it
#     lands in the real ~/.config/dconf/user whatever HOME the client had.
#     (Reads do use the client's path - which is why a fake HOME reads empty
#     while its writes still escape.)
#   * `gnome-extensions` talks to the running Shell.
#   * `systemctl --user` talks to the manager of this login, whose unit
#     paths were fixed when it started.
#
# Observed for real: running install_matrix.sh stopped a live, working
# daemon with SIGTERM and stripped our uuid out of the real
# enabled-extensions - a test switching off the user's product.  So from a
# HOME that is not this user's own, on the login bus, session-level steps
# are skipped and reported.  A private bus (dbus-run-session, used by
# verify-extension.sh) is isolated by construction and stays allowed.
MDG_SESSION_SKIPPED=0
mdg_session_writable() {
    case "${DBUS_SESSION_BUS_ADDRESS:-}" in
        "" | *"unix:path=/run/user/$(id -u)/bus"*) : ;;   # login bus: check HOME
        *) return 0 ;;                                    # private bus: isolated
    esac
    local real
    real="$(getent passwd -- "$(id -un)" 2>/dev/null | cut -d: -f6)"
    [ -n "$real" ] && [ "${HOME%/}" = "${real%/}" ]
}
# mdg_session_skip <what> - record a deliberate skip; never fails the caller
mdg_session_skip() {
    MDG_SESSION_SKIPPED=1
    info "skipped $1: HOME=${HOME:-unset} is not the home of $(id -un), and the"
    info "  login session's Shell/dconf/systemd are not ours to change from there"
}

# ---------------------------------------------------------------------------
# Install state
#
# ~/.local/state/middle-drag-gestures/state is written by install.sh after a
# fully successful run and read by uninstall.sh.  It records what this product
# changed outside the user's own files - specifically whether WE added the
# 'input' group membership (so --purge never removes a membership that was
# already there) and how /dev/uinput looked before our udev rule touched it.
# ---------------------------------------------------------------------------

# state_get <key> -> value, or non-zero when there is no state file yet
state_get() {
    [ -f "$MDG_STATE_FILE" ] || return 1
    sed -n "s/^$1=//p" "$MDG_STATE_FILE" | head -n 1
}

# mdg_apply_uinput_perms "<mode> <uid> <gid>" - put /dev/uinput back exactly
# as it was found (`stat -c '%a %u %g'`).  Deleting the udev rule does not
# change the permissions already applied to the node, so without this the
# device keeps looking configured until the next reboot, when the kernel
# recreates it as 0600 root:root and the daemon silently dies.
# Returns non-zero when the privileges are not available.
mdg_apply_uinput_perms() {
    local mode uid gid
    read -r mode uid gid <<< "$1"
    [ -n "${mode:-}" ] && [ -n "${uid:-}" ] && [ -e /dev/uinput ] || return 1
    if [ "$(id -u)" = 0 ]; then
        chown "$uid:$gid" /dev/uinput 2>/dev/null &&
            chmod "$mode" /dev/uinput 2>/dev/null
    else
        sudo -n chown "$uid:$gid" /dev/uinput 2>/dev/null &&
            sudo -n chmod "$mode" /dev/uinput 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Enabling / disabling the extension
# ---------------------------------------------------------------------------
#
# GNOME Shell scans extension directories only at login.  In a running
# session, therefore, `gnome-extensions enable <uuid>` for a freshly copied
# extension answers "does not exist" (exit 2) and records NOTHING - leaving a
# successful install silently disabled after the relogin.  Verified on GNOME
# Shell 50.5: ListExtensions omits the new directory, ReloadExtension is not
# implemented, and D-Bus activation answers for org.gnome.Shell.Extensions.
#
# So: ask the Shell first (works when it already knows the extension, e.g.
# re-runs after a login), then fall back to writing the GSettings keys the
# Shell reads when it starts - which is exactly the login the installer
# already requires.

# mdg_set_enabled_flag <1|0>
mdg_set_enabled_flag() {
    mdg_session_writable || {
        mdg_session_skip "writing enabled-extensions/disabled-extensions"
        return 0
    }
    command -v python3 >/dev/null 2>&1 || {
        info "warning: python3 missing; cannot record the extension state"
        return 1
    }
    command -v gsettings >/dev/null 2>&1 || {
        info "warning: gsettings missing; cannot record the extension state"
        return 1
    }
    python3 - "$MDG_UUID" "$1" <<'PY'
import ast
import subprocess
import sys

uuid = sys.argv[1]
enable = sys.argv[2] == "1"


def read(key):
    out = subprocess.run(
        ["gsettings", "get", "org.gnome.shell", key],
        capture_output=True, text=True, check=True,
    )
    raw = out.stdout.strip()
    # An unset array prints as "@as []" (a GVariant type annotation), which
    # ast.literal_eval rejects - this is the normal state on a fresh machine.
    if raw.startswith("@") and " " in raw:
        raw = raw.split(" ", 1)[1]
    return ast.literal_eval(raw)


def write(key, values):
    subprocess.run(
        ["gsettings", "set", "org.gnome.shell", key, repr(values)],
        check=True,
    )


enabled = read("enabled-extensions")
disabled = read("disabled-extensions")

if enable:
    if uuid not in enabled:
        enabled.append(uuid)
    if uuid in disabled:
        disabled.remove(uuid)
else:
    if uuid in enabled:
        enabled.remove(uuid)
    if uuid not in disabled:
        disabled.append(uuid)

write("enabled-extensions", enabled)
write("disabled-extensions", disabled)
PY
}

# mdg_extension_enable -> 0 when the extension will be active, 1 on failure
mdg_extension_enable() {
    mdg_session_writable || {
        mdg_session_skip "enabling the extension in the running Shell"
        return 0
    }
    if command -v gnome-extensions >/dev/null 2>&1 &&
       gnome-extensions enable "$MDG_UUID" 2>/dev/null; then
        MDG_EXTENSION_ACTIVE=1
        return 0
    fi
    # Shell has not scanned the directory yet: it will pick this up at login.
    if mdg_set_enabled_flag 1; then
        MDG_EXTENSION_ACTIVE=0
        return 0
    fi
    return 1
}

# mdg_extension_disable
mdg_extension_disable() {
    mdg_session_writable || {
        mdg_session_skip "disabling the extension in the running Shell"
        return 0
    }
    if command -v gnome-extensions >/dev/null 2>&1; then
        gnome-extensions disable "$MDG_UUID" 2>/dev/null || true
    fi
    mdg_set_enabled_flag 0 || true
}

# mdg_forget_extension - drop every trace from org.gnome.shell (used by
# `uninstall.sh --purge`; keeps dconf/free of stale uuids)
mdg_forget_extension() {
    mdg_session_writable || {
        mdg_session_skip "purging the uuid from org.gnome.shell"
        return 0
    }
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$MDG_UUID" <<'PY'
import ast
import subprocess
import sys

uuid = sys.argv[1]


def read(key):
    out = subprocess.run(
        ["gsettings", "get", "org.gnome.shell", key],
        capture_output=True, text=True, check=True,
    )
    raw = out.stdout.strip()
    # An unset array prints as "@as []" (a GVariant type annotation), which
    # ast.literal_eval rejects - this is the normal state on a fresh machine.
    if raw.startswith("@") and " " in raw:
        raw = raw.split(" ", 1)[1]
    return ast.literal_eval(raw)


def write(key, values):
    subprocess.run(
        ["gsettings", "set", "org.gnome.shell", key, repr(values)],
        check=True,
    )


for key in ("enabled-extensions", "disabled-extensions"):
    values = read(key)
    if uuid in values:
        values.remove(uuid)
        write(key, values)
PY
}
