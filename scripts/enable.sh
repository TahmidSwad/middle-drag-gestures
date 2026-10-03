#!/usr/bin/env bash
#
# enable.sh - enable the extension and start the daemon.
#
# Idempotent; the counterpart of disable.sh (which keeps everything
# installed) and uninstall.sh (which removes it).
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$PROJECT_DIR/scripts/lib.sh"

usage() {
    # print the leading comment block, skipping the shebang and any blank
    # line above the title; editing the header can never desync --help the
    # way a hard-coded line range would.
    awk 'NR == 1 {next}
         /^#/ {sub(/^# ?/, ""); if ($0 != "" || seen) {seen = 1; print}; next}
         {exit}' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    '')
        ;;
    *)
        printf 'Usage: %s [--help]\n' "${0##*/}" >&2
        exit 1
        ;;
esac

printf 'Enabling Middle-Drag Gestures\n'

if [ ! -f "${HOME}/.local/bin/middle-drag-daemon.py" ] &&
   [ ! -f "${HOME}/.config/systemd/user/middle-drag-daemon.service" ]; then
    printf '\nError: Middle-Drag Gestures is not installed.\n' >&2
    printf 'Run ./scripts/install.sh first.\n' >&2
    exit 1
fi

if mdg_extension_enable; then
    if [ "${MDG_EXTENSION_ACTIVE:-0}" = 1 ]; then
        printf '  extension enabled\n'
    else
        printf '  extension enabled (GNOME Shell scans extensions only at login)\n'
    fi
else
    printf '  warning: could not enable the extension\n' >&2
fi

systemctl --user daemon-reload
if systemctl --user enable --now middle-drag-daemon.service; then
    printf '  daemon enabled and started\n'
else
    printf '  warning: the daemon did not start - see:\n' >&2
    printf '    journalctl --user -u middle-drag-daemon.service -n 50\n' >&2
fi

printf '\n'
systemctl --user --no-pager --lines=0 status middle-drag-daemon.service || true
printf '\n'
gnome-extensions info "$MDG_UUID" 2>/dev/null || true
