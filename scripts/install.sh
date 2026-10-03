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
#   /etc/udev/rules.d/70-middle-drag-uaccess.rules     (root, via sudo)
#
# Contract (this is the shipping installer):
#
#   * preflight first - every dependency, source-file, device and privilege
#     check runs before a single byte is written, so a failed check can never
#     leave a half-installed system behind
#   * single pass     - one run, then at most ONE logout/login (GNOME loads
#     extension code only at login; device access needs no logout at all - the
#     udev rule's uaccess ACL is granted to the running session)
#   * idempotent      - safe to re-run after every code change; already
#     correct steps are detected and skipped
#
# Usage:
#   ./scripts/install.sh [--user-only] [--no-start] [--no-systemd] [--help]
#
#   --user-only  skip every root step (modprobe, udev rule).
#                Intended for CI/tests: the daemon cannot work until the
#                privileged steps have been performed.
#   --no-start   install and enable everything but do not start the daemon,
#                so tests do not grab the physical mouse.
#   --no-systemd do not talk to systemd at all (no daemon-reload, enable or
#                start).  Needed when installing into a HOME that differs
#                from the one the user manager started with: the manager
#                resolves unit paths from its own environment, so enable
#                would fail there for reasons unrelated to this product.
#
set -euo pipefail
set -E   # make the ERR trap fire inside functions too

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
UDEV_SRC="$PROJECT_DIR/udev/70-middle-drag-uaccess.rules"
UDEV_DST="/etc/udev/rules.d/70-middle-drag-uaccess.rules"
UDEV_LEGACY="/etc/udev/rules.d/99-uinput.rules"
# Earlier releases shipped this rule under an older name; an upgrade must not
# leave a second rule file in charge, so it is removed by content below.
UDEV_PREV="/etc/udev/rules.d/99-middle-drag-uinput.rules"

# Called before anything has been written: the system is untouched.
fail_preflight() {
    printf '\nError: %s\n' "$*" >&2
    printf 'Nothing was installed or modified.\n' >&2
    exit 1
}

# Called after installation has started: roll back, then point at the
# cleanup path.
die() {
    printf '\nError: %s\n' "$*" >&2
    rollback
    printf 'Run ./scripts/uninstall.sh for a complete cleanup.\n' >&2
    exit 1
}

usage() {
    sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Transaction support
#
# Everything this run creates is recorded, so a failure part-way through can
# put the system back the way it was.  Paths that already existed (an
# upgrade) are never deleted - keeping the new files is better than ending
# up with nothing - and that is stated explicitly in the failure message.
# ---------------------------------------------------------------------------
CREATED=()
UDEV_CREATED=0
ORIG_UINPUT_PERMS=""
ROLLING_BACK=0

# note_created PATH - record that PATH does not exist yet.  Call it BEFORE
# creating the path.
note_created() {
    if [ ! -e "$1" ]; then
        CREATED+=("$1")
    fi
}

rollback() {
    local path
    if [ "$ROLLING_BACK" = 1 ]; then
        return 0
    fi
    ROLLING_BACK=1
    trap - ERR

    if [ "${#CREATED[@]}" -eq 0 ] && [ "$UDEV_CREATED" = 0 ]; then
        printf '\nNothing had been changed yet - nothing to undo.\n' >&2
        return 0
    fi

    printf '\nRolling back the changes this run made:\n' >&2
    for path in ${CREATED[@]+"${CREATED[@]}"}; do
        if [ -e "$path" ]; then
            rm -rf "$path"
            printf '  removed %s\n' "$path" >&2
        fi
    done

    # If our schema was removed from the shared directory, refresh its cache
    # so no stale entry for our extension survives the rollback.
    if [ -d "$SCHEMA_DST_DIR" ] &&
       [ ! -f "$SCHEMA_DST_DIR/${SCHEMA_ID}.gschema.xml" ]; then
        glib-compile-schemas "$SCHEMA_DST_DIR" >/dev/null 2>&1 || true
    fi

    if [ "$UDEV_CREATED" = 1 ]; then
        rm -f "$UDEV_DST"
        udevadm control --reload-rules 2>/dev/null || true
        printf '  removed %s\n' "$UDEV_DST" >&2
        if [ -n "$ORIG_UINPUT_PERMS" ] && [ -e /dev/uinput ]; then
            if mdg_apply_uinput_perms "$ORIG_UINPUT_PERMS"; then
                printf '  restored /dev/uinput to %s\n' "$ORIG_UINPUT_PERMS" >&2
            else
                printf '  warning: could not restore /dev/uinput to %s\n' \
                    "$ORIG_UINPUT_PERMS" >&2
            fi
        fi
        UDEV_CREATED=0
    fi

    systemctl --user daemon-reload >/dev/null 2>&1 || true
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/middle-drag-gestures" \
        2>/dev/null || true
    printf 'Pre-existing files were left as they are.\n' >&2
    return 0
}

on_unexpected_error() {
    local rc=$?
    printf '\nError: unexpected failure at line %s (exit %s).\n' \
        "${BASH_LINENO[0]:-?}" "$rc" >&2
    rollback
    printf 'Run ./scripts/uninstall.sh for a complete cleanup.\n' >&2
    exit "$rc"
}
trap on_unexpected_error ERR

# ---------------------------------------------------------------------------
# Install state
#
# Written only after a fully successful install.  It records what this
# product changed outside the user's own files, so `uninstall.sh --purge`
# can undo exactly that - and nothing that was already there (a pre-existing
# 'input' group membership is never removed).  Releases up to this one added
# the user to the 'input' group; this one never does, but the flag is carried
# forward so an older install's membership stays removable.
# ---------------------------------------------------------------------------
write_state() {
    local prev_group prev_perms version new_group
    prev_group="$(state_get group_added || true)"
    prev_perms="$(state_get uinput_orig_perms || true)"
    version="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo unknown)"

    # Keep the oldest known pristine permissions: if our rule was already
    # applied when this run started, the value just measured is ours.
    ORIG_UINPUT_PERMS="${prev_perms:-$ORIG_UINPUT_PERMS}"

    # Only ever preserve a flag written by an older install.
    new_group=0
    if [ "${prev_group:-0}" = 1 ]; then
        new_group=1
    fi

    mkdir -p "$MDG_STATE_DIR"
    cat > "$MDG_STATE_FILE" <<EOF
version=$version
installed_at=$(date -Iseconds 2>/dev/null || date)
group_added=$new_group
uinput_orig_perms=$ORIG_UINPUT_PERMS
EOF
    chmod 0644 "$MDG_STATE_FILE" 2>/dev/null || true
}


# Root helper: only udev rules and modprobe need privileges.
as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

USER_ONLY=0
NO_START=0
NO_SYSTEMD=0
for arg in "$@"; do
    case "$arg" in
        --user-only) USER_ONLY=1 ;;
        --no-start)  NO_START=1 ;;
        --no-systemd) NO_SYSTEMD=1; NO_START=1 ;;
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

# Remember how /dev/uinput looks right now: removing the udev rule alone
# leaves the old mode on the node (it looks configured but breaks on the
# next reboot), so the uninstaller puts this value back.
if [ -e /dev/uinput ]; then
    ORIG_UINPUT_PERMS="$(stat -c '%a %u %g' /dev/uinput 2>/dev/null || true)"
fi

# What will this run need root for?  Collected first so the installer can
# either authenticate once up front or refuse before changing anything.
NEED_ROOT=()
[ -e /dev/uinput ] || NEED_ROOT+=("/dev/uinput is missing (modprobe uinput)")
[ -f "$UDEV_DST" ] || NEED_ROOT+=("udev rule $UDEV_DST is not installed")

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
    [ -f "$UDEV_DST" ] || UDEV_CREATED=1
    note_created "$UDEV_DST"
    if [ "$(id -u)" = 0 ]; then
        install -m 0644 "$UDEV_SRC" "$UDEV_DST"
    else
        printf '%s\n' "$(cat "$UDEV_SRC")" | sudo tee "$UDEV_DST" >/dev/null
        sudo chmod 0644 "$UDEV_DST"
    fi
    info "installed $UDEV_DST"

    as_root udevadm control --reload-rules
    # misc re-evaluates /dev/uinput, input re-evaluates every input node:
    # both receive the uaccess tag - and, while a session is active, the ACL -
    # without waiting for the next event or the next login.
    as_root udevadm trigger --subsystem-match=misc
    as_root udevadm trigger --subsystem-match=input
    info "udev rules reloaded"
fi

# Earlier releases shipped this rule under two other names; remove them so a
# re-run never leaves two rule files in charge.  Every candidate is matched by
# content, never by name alone.
for old_rule in "$UDEV_PREV" "$UDEV_LEGACY"; do
    if [ "$HAVE_ROOT" = 1 ] && [ -f "$old_rule" ] &&
       grep -q 'KERNEL=="uinput"' "$old_rule" 2>/dev/null; then
        as_root rm -f "$old_rule"
        info "removed legacy $old_rule"
    fi
done

if [ -e /dev/uinput ]; then
    info "/dev/uinput: $(ls -l /dev/uinput | awk '{print $1, $3, $4}')"
fi
if [ "$HAVE_ROOT" = 1 ]; then
    info "session access comes from the uaccess ACL - no group membership needed"
fi

# ---------------------------------------------------------------------------
# 2. Daemon + systemd user service
# ---------------------------------------------------------------------------
step "Installing the input daemon"

note_created "$DAEMON_DST"
install -D -m 0755 "$DAEMON_SRC" "$DAEMON_DST"
info "$DAEMON_DST"

note_created "$UNIT_DST"
install -D -m 0644 "$UNIT_SRC" "$UNIT_DST"
info "$UNIT_DST"

if [ "$NO_SYSTEMD" = 1 ]; then
    info "daemon-reload skipped (--no-systemd)"
elif ! mdg_session_writable; then
    mdg_session_skip "the systemd user daemon-reload"
else
    systemctl --user daemon-reload
fi

# ---------------------------------------------------------------------------
# 3. GNOME extension + GSettings schema
# ---------------------------------------------------------------------------
step "Installing the GNOME Shell extension"

EXT_CHANGED=0
if ! cmp -s "$EXT_SRC/extension.js" "$EXT_DST/extension.js" 2>/dev/null ||
   ! cmp -s "$EXT_SRC/prefs.js" "$EXT_DST/prefs.js" 2>/dev/null ||
   ! cmp -s "$EXT_SRC/metadata.json" "$EXT_DST/metadata.json" 2>/dev/null; then
    EXT_CHANGED=1
fi

# Build the complete extension in a staging directory and swap it in only
# once every file is present and the schema compiles: a failure can then
# never leave a half-written extension behind, and an upgrade keeps the
# previous working copy until the new one is proven good.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/middle-drag-gestures"
mkdir -p "$CACHE_DIR"
EXT_STAGE="$(mktemp -d "$CACHE_DIR/ext.XXXXXX")"
CREATED+=("$EXT_STAGE")

install -m 0644 "$EXT_SRC/extension.js"   "$EXT_STAGE/extension.js"
install -m 0644 "$EXT_SRC/prefs.js"       "$EXT_STAGE/prefs.js"
install -m 0644 "$EXT_SRC/metadata.json"  "$EXT_STAGE/metadata.json"
install -m 0644 "$EXT_SRC/stylesheet.css" "$EXT_STAGE/stylesheet.css"
install -m 0644 "$EXT_SRC/LICENSE"        "$EXT_STAGE/LICENSE" 2>/dev/null || true
if [ -d "$EXT_SRC/icons" ]; then
    cp -r "$EXT_SRC/icons" "$EXT_STAGE/icons" 2>/dev/null || true
fi

# The extension's own Gio.Settings looks for schemas/gschemas.compiled next
# to metadata.json, and enable() reads it - without this the extension
# throws as soon as it is enabled.
mkdir -p "$EXT_STAGE/schemas"
install -m 0644 "$SCHEMA_SRC" "$EXT_STAGE/schemas/"
glib-compile-schemas --strict "$EXT_STAGE/schemas" ||
    die "the extension's GSettings schema does not compile"
[ -f "$EXT_STAGE/schemas/gschemas.compiled" ] ||
    die "glib-compile-schemas produced no output for the extension schema"
info "extension schema compiled"

install -d -m 0755 "$(dirname "$EXT_DST")"
if [ -d "$EXT_DST" ]; then
    # Two renames, so the old copy survives if either one fails.
    EXT_BACKUP="$CACHE_DIR/ext-previous.$$"
    rm -rf "$EXT_BACKUP"
    mv -T "$EXT_DST" "$EXT_BACKUP"
    if mv -T "$EXT_STAGE" "$EXT_DST"; then
        rm -rf "$EXT_BACKUP"
    else
        mv -T "$EXT_BACKUP" "$EXT_DST" 2>/dev/null || true
        die "could not move the staged extension to $EXT_DST"
    fi
else
    note_created "$EXT_DST"
    mv -T "$EXT_STAGE" "$EXT_DST" ||
        die "could not move the staged extension to $EXT_DST"
fi
info "$EXT_DST"

# The shared user schema directory may contain other extensions' schemas, so
# a strict failure there is not fatal by itself - what matters is whether the
# daemon's settings resolve afterwards.
note_created "$SCHEMA_DST_DIR/${SCHEMA_ID}.gschema.xml"
install -d -m 0755 "$SCHEMA_DST_DIR"
install -m 0644 "$SCHEMA_SRC" "$SCHEMA_DST_DIR/"
if ! SCHEMA_OUTPUT="$(glib-compile-schemas "$SCHEMA_DST_DIR" 2>&1)"; then
    info "warning: glib-compile-schemas reported problems:"
    printf '%s\n' "$SCHEMA_OUTPUT" | sed 's/^/      /' >&2
fi

if ! gsettings get "$SCHEMA_ID" threshold >/dev/null 2>&1; then
    die "schema $SCHEMA_ID is not usable by gsettings - check for a broken
      *.gschema.xml in $SCHEMA_DST_DIR (output above)"
fi
info "user schema installed and readable ($SCHEMA_DST_DIR)"

# ---------------------------------------------------------------------------
# 4. Enable everything
# ---------------------------------------------------------------------------
step "Enabling extension and daemon"

if [ "${MDG_SESSION_SKIPPED:-0}" = 1 ]; then
    info "extension enable left to the live session - see above"
elif mdg_extension_enable; then
    if [ "${MDG_EXTENSION_ACTIVE:-0}" = 1 ]; then
        info "extension enabled (active now)"
    else
        info "extension enabled (the Shell scans extensions only at login)"
    fi
else
    info "warning: could not record the extension as enabled - run:"
    info "  gnome-extensions enable $UUID"
fi

if [ "$NO_SYSTEMD" = 1 ]; then
    info "systemd untouched (--no-systemd): no daemon-reload, enable or start"
elif ! mdg_session_writable; then
    mdg_session_skip "enabling and starting middle-drag-daemon.service"
elif [ "$NO_START" = 1 ]; then
    systemctl --user enable middle-drag-daemon.service >/dev/null 2>&1 ||
        die "could not enable middle-drag-daemon.service"
    info "daemon enabled but not started (--no-start)"
else
    systemctl --user enable middle-drag-daemon.service >/dev/null 2>&1 ||
        die "could not enable middle-drag-daemon.service"
    if systemctl --user restart middle-drag-daemon.service; then
        info "daemon restarted (enabled at login)"
    else
        info "warning: the daemon did not start - see:"
        info "  journalctl --user -u middle-drag-daemon.service -n 50"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
# Everything succeeded: record what was changed outside the user's files so
# `uninstall.sh --purge` can undo exactly that.
write_state

sleep 1
printf '\n%s\n' "----------------------------------------------------------------"

if [ "${#SKIPPED[@]}" -gt 0 ]; then
    printf '%s\n' "Middle-Drag Gestures installed INCOMPLETELY (--user-only)."
    printf '%s\n' "Skipped, so the daemon will not work until you run:"
    for reason in "${SKIPPED[@]}"; do printf '  - %s\n' "$reason"; done
    printf '%s\n' "Re-run this installer from a terminal with sudo."
elif [ "$NO_SYSTEMD" = 1 ]; then
    printf '%s\n' "Middle-Drag Gestures installed (systemd untouched: the unit was"
    printf '%s\n' "not enabled or started - that is what --no-systemd means)."
elif [ "${MDG_SESSION_SKIPPED:-0}" = 1 ]; then
    printf '%s\n' "Middle-Drag Gestures installed (session-level steps skipped:"
    printf '%s\n' "foreign HOME, so the live Shell/dconf/systemd were left alone)."
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
