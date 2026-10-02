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
# Contract (this is the shipping installer):
#
#   * preflight first - every dependency, source-file, device and privilege
#     check runs before a single byte is written, so a failed check can never
#     leave a half-installed system behind
#   * single pass     - one run, then at most ONE logout/login (GNOME loads
#     extension code and supplementary groups only at login)
#   * idempotent      - safe to re-run after every code change; already
#     correct steps are detected and skipped
#
# Usage:
#   ./scripts/install.sh [--user-only] [--no-start] [--help]
#
#   --user-only  skip every root step (modprobe, udev rule, input group).
#                Intended for CI/tests: the daemon cannot work until the
#                privileged steps have been performed.
#   --no-start   install and enable everything but do not start the daemon,
#                so tests do not grab the physical mouse.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$PROJECT_DIR/scripts/lib.sh"
UUID="$MDG_UUID"
SCHEMA_ID="$MDG_SCHEMA"
CURRENT_USER="${USER:-$(id -un)}"

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

# Called before anything has been written: the system is untouched.
fail_preflight() {
    printf '\nError: %s\n' "$*" >&2
    printf 'Nothing was installed or modified.\n' >&2
    exit 1
}

# Called after installation has started: point at the rollback path.
die() {
    printf '\nError: %s\n' "$*" >&2
    printf 'Run ./scripts/uninstall.sh to remove any partial install.\n' >&2
    exit 1
}

usage() {
    sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Root helper: only udev rules, usermod and modprobe need privileges.
as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

USER_ONLY=0
NO_START=0
for arg in "$@"; do
    case "$arg" in
        --user-only) USER_ONLY=1 ;;
        --no-start)  NO_START=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           fail_preflight "unknown option: $arg (see --help)" ;;
    esac
done

printf 'Installing Middle-Drag Gestures\n'
printf '===============================\n'

# ---------------------------------------------------------------------------
# 0. Preflight - NOTHING is written until every check below has passed.
# ---------------------------------------------------------------------------
step "Preflight checks"

command -v gnome-shell >/dev/null 2>&1 ||
    fail_preflight "gnome-shell not found - this project only targets GNOME"
info "gnome-shell: $(gnome-shell --version 2>/dev/null | head -1)"

case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*|*gnome*) info "desktop session: ${XDG_CURRENT_DESKTOP}" ;;
    *) info "warning: XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-}' does not look like GNOME" ;;
esac

command -v python3 >/dev/null 2>&1 || fail_preflight "python3 not found"
command -v systemctl >/dev/null 2>&1 || fail_preflight "systemctl not found"
command -v glib-compile-schemas >/dev/null 2>&1 ||
    fail_preflight "glib-compile-schemas not found (package glib2 / libglib2.0-bin)"

if ! command -v gnome-extensions >/dev/null 2>&1; then
    info "warning: gnome-extensions not found - the extension cannot be enabled from this shell"
fi

for module in evdev dbus gi; do
    if ! python3 -c "import $module" >/dev/null 2>&1; then
        case "$module" in
            evdev) hint="python3-evdev (dnf) / python3-evdev (apt)" ;;
            dbus)  hint="python3-dbus (dnf) / python3-dbus (apt)" ;;
            gi)    hint="python3-gobject (dnf) / python3-gi (apt)" ;;
        esac
        fail_preflight "python3 cannot import '$module' - install the package '$hint'"
    fi
done
info "python3 modules: evdev, dbus, gi"

for src in "$DAEMON_SRC" "$UNIT_SRC" "$SCHEMA_SRC" \
           "$EXT_SRC/extension.js" "$EXT_SRC/prefs.js" "$EXT_SRC/metadata.json"; do
    [ -f "$src" ] || fail_preflight "missing source file: $src"
done
info "source files present"

# What will this run need root for?  Collected first so the installer can
# either authenticate once up front or refuse before changing anything.
NEED_ROOT=()
[ -e /dev/uinput ] || NEED_ROOT+=("/dev/uinput is missing (modprobe uinput)")
[ -f "$UDEV_DST" ] || NEED_ROOT+=("udev rule $UDEV_DST is not installed")
id -nG "$CURRENT_USER" | grep -qw input ||
    NEED_ROOT+=("user '$CURRENT_USER' is not in the 'input' group")

HAVE_ROOT=0
SKIPPED=()
if [ "${#NEED_ROOT[@]}" -eq 0 ]; then
    HAVE_ROOT=1
    info "no privileged step required (already configured)"
elif [ "$USER_ONLY" = 1 ]; then
    info "warning: --user-only, privileged steps are skipped:"
    for reason in "${NEED_ROOT[@]}"; do info "  - $reason"; done
    SKIPPED=("${NEED_ROOT[@]}")
elif [ "$(id -u)" = 0 ]; then
    HAVE_ROOT=1
elif [ -t 0 ] && sudo -v 2>/dev/null; then
    HAVE_ROOT=1
    info "sudo: authenticated"
elif sudo -n true 2>/dev/null; then
    HAVE_ROOT=1
else
    msg="this installation needs root for:"
    for reason in "${NEED_ROOT[@]}"; do msg="$msg
  - $reason"; done
    fail_preflight "$msg
Run this installer from a terminal where sudo can ask for your password,
or pass --user-only to install the user-writable parts only."
fi

# ---------------------------------------------------------------------------
# 1. uinput device node + udev rule
# ---------------------------------------------------------------------------
step "Ensuring /dev/uinput is usable"

if [ ! -e /dev/uinput ]; then
    if [ "$HAVE_ROOT" = 1 ]; then
        command -v modprobe >/dev/null 2>&1 ||
            die "/dev/uinput is missing and modprobe is unavailable"
        info "loading the uinput kernel module"
        as_root modprobe uinput || die "could not load the uinput kernel module"
        [ -e /dev/uinput ] || die "modprobe ran but /dev/uinput is still missing"
    else
        SKIPPED+=("/dev/uinput is missing (modprobe uinput)")
        info "skipped: /dev/uinput is missing and --user-only was given"
    fi
else
    info "/dev/uinput present"
fi

step "Installing udev rule"

if [ "$USER_ONLY" = 1 ]; then
    info "skipped (--user-only)"
elif [ -f "$UDEV_DST" ] && cmp -s "$UDEV_SRC" "$UDEV_DST"; then
    info "already up to date ($UDEV_DST)"
else
    if [ "$(id -u)" = 0 ]; then
        install -m 0644 "$UDEV_SRC" "$UDEV_DST"
    else
        printf '%s\n' "$(cat "$UDEV_SRC")" | sudo tee "$UDEV_DST" >/dev/null
        sudo chmod 0644 "$UDEV_DST"
    fi
    info "installed $UDEV_DST"

    as_root udevadm control --reload-rules
    as_root udevadm trigger --subsystem-match=misc
    info "udev rules reloaded"
fi

if [ "$HAVE_ROOT" = 1 ] && [ -f "$UDEV_LEGACY" ] &&
   grep -q 'KERNEL=="uinput"' "$UDEV_LEGACY" 2>/dev/null; then
    as_root rm -f "$UDEV_LEGACY"
    info "removed legacy $UDEV_LEGACY"
fi

if [ -e /dev/uinput ]; then
    info "/dev/uinput: $(ls -l /dev/uinput | awk '{print $1, $3, $4}')"
fi

# ---------------------------------------------------------------------------
# 2. input group membership
#
# The daemon opens /dev/input/event* (0660 root:input, set by the distro's
# 50-udev-default.rules) and /dev/uinput (0660 root:input, set by our rule).
# Supplementary groups only apply to NEW sessions, so a membership added here
# takes effect at the next login - which the user already needs for GNOME to
# reload extension.js.  That is why this installer never asks for a second run.
# ---------------------------------------------------------------------------
step "Checking input group membership"

GROUP_ADDED=0
if id -nG "$CURRENT_USER" | grep -qw input; then
    info "user '$CURRENT_USER' is in the input group"
elif [ "$USER_ONLY" = 1 ]; then
    info "warning: '$CURRENT_USER' is not in the input group; the daemon cannot work"
else
    info "adding '$CURRENT_USER' to the input group"
    as_root usermod -aG input "$CURRENT_USER"
    GROUP_ADDED=1
fi

# ---------------------------------------------------------------------------
# 3. Daemon + systemd user service
# ---------------------------------------------------------------------------
step "Installing the input daemon"

install -D -m 0755 "$DAEMON_SRC" "$DAEMON_DST"
info "$DAEMON_DST"

install -D -m 0644 "$UNIT_SRC" "$UNIT_DST"
info "$UNIT_DST"

systemctl --user daemon-reload

# ---------------------------------------------------------------------------
# 4. GNOME extension + GSettings schema
# ---------------------------------------------------------------------------
step "Installing the GNOME Shell extension"

EXT_CHANGED=0
if ! cmp -s "$EXT_SRC/extension.js" "$EXT_DST/extension.js" 2>/dev/null ||
   ! cmp -s "$EXT_SRC/prefs.js" "$EXT_DST/prefs.js" 2>/dev/null ||
   ! cmp -s "$EXT_SRC/metadata.json" "$EXT_DST/metadata.json" 2>/dev/null; then
    EXT_CHANGED=1
fi

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
glib-compile-schemas --strict "$EXT_DST/schemas" ||
    die "failed to compile $EXT_DST/schemas"
[ -f "$EXT_DST/schemas/gschemas.compiled" ] ||
    die "failed to compile $EXT_DST/schemas/gschemas.compiled"
info "extension schema compiled"

install -d -m 0755 "$SCHEMA_DST_DIR"
install -m 0644 "$SCHEMA_SRC" "$SCHEMA_DST_DIR/"
glib-compile-schemas --strict "$SCHEMA_DST_DIR" ||
    die "failed to compile $SCHEMA_DST_DIR"
[ -f "$SCHEMA_DST_DIR/gschemas.compiled" ] ||
    die "failed to compile $SCHEMA_DST_DIR/gschemas.compiled"
info "user schema installed ($SCHEMA_DST_DIR)"

gsettings get "$SCHEMA_ID" threshold >/dev/null 2>&1 ||
    die "schema $SCHEMA_ID is not usable by gsettings"
info "gsettings can read $SCHEMA_ID"

# ---------------------------------------------------------------------------
# 5. Enable everything
# ---------------------------------------------------------------------------
step "Enabling extension and daemon"

if mdg_extension_enable; then
    if [ "${MDG_EXTENSION_ACTIVE:-0}" = 1 ]; then
        info "extension enabled (active now)"
    else
        info "extension enabled (the Shell scans extensions only at login)"
    fi
else
    info "warning: could not record the extension as enabled - run:"
    info "  gnome-extensions enable $UUID"
fi

systemctl --user enable middle-drag-daemon.service >/dev/null 2>&1 ||
    die "could not enable middle-drag-daemon.service"

if [ "$GROUP_ADDED" = 1 ]; then
    info "daemon enabled; it starts automatically at the next login"
    info "(the 'input' group only applies to new sessions)"
elif [ "$NO_START" = 1 ]; then
    info "daemon enabled but not started (--no-start)"
else
    if systemctl --user restart middle-drag-daemon.service; then
        info "daemon restarted (enabled at login)"
    else
        info "warning: the daemon did not start - see:"
        info "  journalctl --user -u middle-drag-daemon.service -n 50"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
sleep 1
printf '\n%s\n' "----------------------------------------------------------------"

if [ "${#SKIPPED[@]}" -gt 0 ]; then
    printf '%s\n' "Middle-Drag Gestures installed INCOMPLETELY (--user-only)."
    printf '%s\n' "Skipped, so the daemon will not work until you run:"
    for reason in "${SKIPPED[@]}"; do printf '  - %s\n' "$reason"; done
    printf '%s\n' "Re-run this installer from a terminal with sudo."
elif [ "$GROUP_ADDED" = 1 ]; then
    printf '%s\n' "Middle-Drag Gestures installed. The daemon starts at next login."
elif [ "$NO_START" = 1 ]; then
    printf '%s\n' "Middle-Drag Gestures installed (daemon enabled, not started)."
elif systemctl --user is-active --quiet middle-drag-daemon.service; then
    printf '%s\n' "Middle-Drag Gestures installed successfully."
else
    printf '%s\n' "Middle-Drag Gestures installed, but the daemon is not running."
    printf '%s\n' "Check: journalctl --user -u middle-drag-daemon.service -n 100"
fi

# What actually requires the single relogin?
RELOGIN=()
if [ "$GROUP_ADDED" = 1 ]; then
    RELOGIN+=("'input' group membership applies to new sessions only")
fi
if [ "$EXT_CHANGED" = 1 ]; then
    RELOGIN+=("GNOME Shell loads extension code only at login")
fi
if [ "${MDG_EXTENSION_ACTIVE:-1}" = 0 ]; then
    RELOGIN+=("the Shell only scans extension directories at login")
fi

if [ "${#RELOGIN[@]}" -gt 0 ]; then
    printf '\n%s\n' "  ACTION REQUIRED: log out and log back in (once)."
    for reason in "${RELOGIN[@]}"; do printf '    - %s\n' "$reason"; done
    cat <<'EOF'

  Nothing else is needed: everything listed above becomes active with
  that single relogin.
EOF
else
    printf '\n%s\n' "No relogin required - nothing that needs it changed."
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
EOF
