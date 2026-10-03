#!/usr/bin/env bash
#
# uninstall.sh - remove the Middle-Drag Gestures extension and daemon.
#
# Reverses scripts/install.sh.  By default two things are kept on purpose:
#   * GSettings values under org.gnome.shell.extensions.middle-drag
#   * membership of the 'input' group (other software may need it)
# Pass --purge to remove those as well; the group is only dropped when the
# install state file says this product is what added it.
#
# After running it, ./scripts/verify-clean.sh proves nothing is left.
#
# Usage:
#   ./scripts/uninstall.sh [--purge] [--help]
#
set -euo pipefail
set -E

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
SCHEMA_DST_DIR="${HOME}/.local/share/glib-2.0/schemas"
UDEV_DST="/etc/udev/rules.d/70-middle-drag-uaccess.rules"
# Two earlier releases shipped other names for the same rule; an upgrade must
# not leave a second rule file in charge, so both are cleaned up (identified
# by their content, never by name alone).
UDEV_LEGACY="/etc/udev/rules.d/99-uinput.rules"
UDEV_PREV="/etc/udev/rules.d/99-middle-drag-uinput.rules"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/middle-drag-gestures"

PURGE=0
SKIPPED=()

die() {
    printf '\nError: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

as_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Removal is idempotent, so an unexpected failure is never fatal to the
# system: say so and point at the re-run instead of dying silently.
on_unexpected_error() {
    local rc=$?
    printf '\nError: unexpected failure at line %s (exit %s).\n' \
        "${BASH_LINENO[0]:-?}" "$rc" >&2
    printf 'Nothing here is destructive - run this script again to continue.\n' >&2
    printf 'Then verify with: ./scripts/verify-clean.sh\n' >&2
    exit "$rc"
}
trap on_unexpected_error ERR

for arg in "$@"; do
    case "$arg" in
        --purge)  PURGE=1 ;;
        -h|--help) usage; exit 0 ;;
        *)        die "unknown option: $arg (see --help)" ;;
    esac
done

printf 'Uninstalling Middle-Drag Gestures%s\n' \
    "$([ "$PURGE" = 1 ] && echo ' (--purge)' || echo '')"
printf '=========================================\n'

# What do we know from the install state file?
STATE_GROUP_ADDED="$(state_get group_added 2>/dev/null || echo 0)"
STATE_UINPUT_PERMS="$(state_get uinput_orig_perms 2>/dev/null || echo)"

# Only the udev rule (and possibly the group) needs root; skip it gracefully
# when we cannot elevate, and report it as incomplete at the end.
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
step "Stopping the daemon"

if ! mdg_session_writable; then
    # The manager of this login owns the real unit paths; with a throwaway
    # HOME (tests, experiments) it is not ours to command.
    mdg_session_skip "stopping and disabling middle-drag-daemon.service"
elif systemctl --user is-enabled middle-drag-daemon.service >/dev/null 2>&1 ||
     systemctl --user is-active middle-drag-daemon.service >/dev/null 2>&1; then
    systemctl --user disable --now middle-drag-daemon.service >/dev/null 2>&1 ||
        true
    info "daemon stopped and disabled"
else
    info "daemon unit not enabled"
fi

# ---------------------------------------------------------------------------
step "Removing the daemon and its service"

if [ -e "$DAEMON_DST" ]; then
    rm -f "$DAEMON_DST"
    info "removed $DAEMON_DST"
else
    info "$DAEMON_DST not present"
fi

if [ -e "$UNIT_DST" ]; then
    rm -f "$UNIT_DST"
    info "removed $UNIT_DST"
else
    info "$UNIT_DST not present"
fi
if mdg_session_writable; then
    systemctl --user daemon-reload
    info "systemd user units reloaded"
else
    info "systemd user manager not reloaded (foreign HOME)"
fi

# ---------------------------------------------------------------------------
step "Removing the GNOME Shell extension"

# Works even while the running Shell has not scanned the extension yet
# (gnome-extensions disable fails there and records nothing).
mdg_extension_disable
info "extension disabled"

if [ -d "$EXT_DST" ]; then
    rm -rf "$EXT_DST"
    info "removed $EXT_DST"
else
    info "extension directory not present"
fi

# ---------------------------------------------------------------------------
step "Removing the GSettings schema"

if [ -f "$SCHEMA_XML" ]; then
    rm -f "$SCHEMA_XML"
    if glib-compile-schemas "$SCHEMA_DST_DIR" >/dev/null 2>&1; then
        info "removed $SCHEMA_XML (user schema cache refreshed)"
    else
        info "removed $SCHEMA_XML (cache could not be refreshed; a broken"
        info "*.gschema.xml of another extension may be in $SCHEMA_DST_DIR)"
    fi
else
    info "user schema not present"
fi

if [ "$PURGE" = 1 ]; then
    dconf reset -f "/org/gnome/shell/extensions/middle-drag/" 2>/dev/null ||
        info "warning: could not reset dconf values for $SCHEMA_ID"
    mdg_forget_extension ||
        info "warning: could not clear the uuid from org.gnome.shell"
    info "purged dconf values for $SCHEMA_ID"
else
    info "dconf values for $SCHEMA_ID were kept (use --purge to remove)"
fi

# ---------------------------------------------------------------------------
step "Removing the udev rule"

removed_udev=0
if [ "$HAVE_ROOT" = 0 ]; then
    if [ -f "$UDEV_DST" ] || [ -f "$UDEV_LEGACY" ] || [ -f "$UDEV_PREV" ]; then
        info "SKIPPED: cannot elevate privileges from this shell."
        info "remove it manually:"
        info "  sudo rm -f $UDEV_DST $UDEV_LEGACY $UDEV_PREV"
        info "  sudo udevadm control --reload-rules"
        SKIPPED+=("udev rule (needs sudo)")
    else
        info "no udev rule installed"
    fi
else
    # Only ever delete files that really are ours: every candidate is matched
    # by content, never by name alone, so an unrelated file that happens to
    # share one of these names is left untouched.
    for rule in "$UDEV_DST" "$UDEV_PREV" "$UDEV_LEGACY"; do
        if [ -f "$rule" ] && grep -q 'KERNEL=="uinput"' "$rule" 2>/dev/null; then
            as_root rm -f "$rule"
            info "removed $rule"
            removed_udev=1
        fi
    done

    if [ "$removed_udev" = 1 ]; then
        as_root udevadm control --reload-rules
        as_root udevadm trigger --subsystem-match=misc
        info "udev rules reloaded"
    else
        info "no udev rule installed"
    fi

    # Deleting the rule does NOT change the permissions already applied to
    # the node: it would keep looking configured until the next reboot, when
    # the kernel recreates it as 0600 root:root.  Put back what we found.
    if [ "$removed_udev" = 1 ] && [ -n "$STATE_UINPUT_PERMS" ] &&
       [ -e /dev/uinput ]; then
        # shellcheck disable=SC2086
        if as_root chmod $STATE_UINPUT_PERMS /dev/uinput 2>/dev/null; then
            info "restored /dev/uinput to $STATE_UINPUT_PERMS"
        else
            info "warning: could not restore /dev/uinput to $STATE_UINPUT_PERMS"
            SKIPPED+=("/dev/uinput permissions")
        fi
    fi

    # Same for the uaccess ACL: deleting the rule does not recompute it, so
    # it stays on the nodes until the next session change.  Strip THIS user's
    # entries to make the removal visible at once; other sessions keep theirs
    # and lose them when those sessions end.
    if [ "$removed_udev" = 1 ] && command -v setfacl >/dev/null 2>&1 &&
       command -v getfacl >/dev/null 2>&1; then
        stripped=0
        for node in /dev/uinput /dev/input/event*; do
            [ -e "$node" ] || continue
            if getfacl -cp "$node" 2>/dev/null |
               grep -qE "^user:${CURRENT_USER}:"; then
                if as_root setfacl -x "u:$CURRENT_USER" "$node" 2>/dev/null; then
                    stripped=$((stripped + 1))
                fi
            fi
        done
        if [ "$stripped" -gt 0 ]; then
            info "revoked the uaccess ACL on $stripped node(s) for '$CURRENT_USER'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
if [ "$PURGE" = 1 ]; then
    step "Purging install state"

    if [ "$STATE_GROUP_ADDED" = 1 ]; then
        if [ "$HAVE_ROOT" = 0 ]; then
            info "SKIPPED: removing '$CURRENT_USER' from the 'input' group"
            info "  sudo gpasswd -d $CURRENT_USER input"
            SKIPPED+=("'input' group membership (needs sudo)")
        elif gpasswd -d "$CURRENT_USER" input 2>/dev/null ||
             sudo -n gpasswd -d "$CURRENT_USER" input 2>/dev/null; then
            info "removed '$CURRENT_USER' from the 'input' group"
            info "(takes effect at the next login)"
        else
            info "warning: could not remove '$CURRENT_USER' from 'input'"
            SKIPPED+=("'input' group membership")
        fi
    else
        info "'input' group membership was not added by us - kept"
    fi
fi

step "Removing temporary files"
rm -rf "$CACHE_DIR" 2>/dev/null && info "removed $CACHE_DIR" ||
    info "$CACHE_DIR not present"

if [ "$PURGE" = 1 ]; then
    rm -f "$MDG_STATE_FILE"
    rmdir "$MDG_STATE_DIR" 2>/dev/null || true
    info "removed install state"
elif [ -f "$MDG_STATE_FILE" ]; then
    info "install state kept at $MDG_STATE_FILE (use --purge to remove)"
else
    info "no install state recorded"
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------------------------------"

if [ "${#SKIPPED[@]}" -gt 0 ]; then
    printf '%s\n' "Uninstall INCOMPLETE - these remain:"
    for item in "${SKIPPED[@]}"; do printf '  - %s\n' "$item"; done
    printf '%s\n' "Run the commands above, then check with:"
    if [ "$PURGE" = 1 ]; then
        printf '%s\n' "  ./scripts/verify-clean.sh --purge"
    else
        printf '%s\n' "  ./scripts/verify-clean.sh"
    fi
    if [ "$PURGE" = 0 ]; then
        cat <<'EOF'

Not removed on purpose:
  * your membership of the 'input' group (other software may need it)
  * dconf settings under org.gnome.shell.extensions.middle-drag
EOF
    fi
    exit 1
fi

printf '%s\n' "Middle-Drag Gestures uninstalled."
if [ "$PURGE" = 1 ]; then
    printf '%s\n' "Purged: dconf values, enabled-extensions entry, install state."
else
    cat <<'EOF'

Not removed on purpose (rerun with --purge to remove them):
  * your membership of the 'input' group (other software may need it)
  * dconf settings under org.gnome.shell.extensions.middle-drag
EOF
fi
cat <<'EOF'

Check for leftovers with:  ./scripts/verify-clean.sh
Log out and log back in so GNOME Shell drops the extension completely.
If the mouse still feels odd, reconnect it or run:
  systemctl --user status middle-drag-daemon.service
EOF
