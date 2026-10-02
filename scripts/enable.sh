#!/usr/bin/env bash
#
# enable.sh - enable the extension and start the daemon.
#
set -euo pipefail

UUID="middle-drag-gestures@swad"

printf 'Enabling Middle-Drag Gestures\n'

if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions enable "$UUID" && printf '  extension enabled\n'
else
    printf '  warning: gnome-extensions not found\n'
fi

systemctl --user daemon-reload
systemctl --user enable --now middle-drag-daemon.service
printf '  daemon enabled and started\n'

printf '\n'
systemctl --user --no-pager --lines=0 status middle-drag-daemon.service || true
printf '\n'
gnome-extensions info "$UUID" 2>/dev/null || true
