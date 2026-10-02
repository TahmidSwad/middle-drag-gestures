#!/usr/bin/env bash
#
# disable.sh - stop the daemon and disable the extension without removing
# anything.  Use scripts/uninstall.sh to remove the installation.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$PROJECT_DIR/scripts/lib.sh"

printf 'Disabling Middle-Drag Gestures\n'

if systemctl --user list-unit-files middle-drag-daemon.service >/dev/null 2>&1; then
    systemctl --user disable --now middle-drag-daemon.service || true
    printf '  daemon stopped and disabled\n'
fi

mdg_extension_disable
printf '  extension disabled\n'

cat <<'EOF'

Everything is still installed; re-enable with ./scripts/enable.sh
The physical mouse is no longer grabbed.
EOF
