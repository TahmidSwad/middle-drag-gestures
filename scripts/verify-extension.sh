#!/usr/bin/env bash
#
# verify-extension.sh - load the extension in a throwaway GNOME Shell and
# check its D-Bus interface and preferences.
#
# Why this exists: GNOME Shell caches extension code and metadata for the
# lifetime of the session, so editing extension.js / prefs.js has no effect
# until you log out.  This script starts a *second*, headless GNOME Shell on
# its own D-Bus session (which loads the files fresh from disk), exercises
# the extension there and then shuts it down again.  Your desktop session is
# not touched.
#
# Usage:
#   ./scripts/verify-extension.sh
#
# Requirements: a running GNOME Wayland session (for the Wayland/XDG
# environment); the extension must be installed under
# ~/.local/share/gnome-shell/extensions/.
#
set -u

# Run everything on a private session bus: a second GNOME Shell must never
# join the real desktop session's bus (it would fight over org.gnome.Shell).
if [ -z "${MIDDLE_DRAG_VERIFY_INNER:-}" ]; then
    if ! command -v dbus-run-session >/dev/null 2>&1; then
        echo "dbus-run-session not found (package dbus-daemon)" >&2
        exit 1
    fi
    exec dbus-run-session -- env MIDDLE_DRAG_VERIFY_INNER=1 bash "$0" "$@"
fi

UUID="middle-drag-gestures@swad"
DEST="org.gnome.Shell.Extensions.MiddleDrag"
OBJPATH="/org/gnome/Shell/Extensions/MiddleDrag"
WAYLAND_NAME="middle-drag-verify"
DURATION=15   # seconds to keep the prefs window open

TMPDIR_VERIFY="$(mktemp -d /tmp/middle-drag-verify.XXXXXX)"
SHELL_LOG="$TMPDIR_VERIFY/shell.log"
PREFS_LOG="$TMPDIR_VERIFY/prefs.log"
FAILURES=0

SHELL_PID=""

cleanup() {
    if [ -n "$SHELL_PID" ] && kill -0 "$SHELL_PID" 2>/dev/null; then
        kill "$SHELL_PID" 2>/dev/null
        wait "$SHELL_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
pass() { printf '  ok   - %s\n' "$*"; }
fail() { printf '  FAIL - %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

if [ ! -d "${HOME}/.local/share/gnome-shell/extensions/${UUID}" ]; then
    say "extension ${UUID} is not installed; run scripts/install.sh first"
    exit 1
fi

say "starting a headless GNOME Shell (logs: ${SHELL_LOG})"
gnome-shell --headless --wayland-display="$WAYLAND_NAME" \
    >"$SHELL_LOG" 2>&1 &
SHELL_PID=$!

ready=0
for _ in $(seq 1 60); do
    if ! kill -0 "$SHELL_PID" 2>/dev/null; then
        break
    fi
    if gdbus introspect --session --dest "$DEST" \
        --object-path "$OBJPATH" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" != 1 ]; then
    say ""
    say "assertions:"
    fail "the shell never exported ${DEST} (did the session restart pick up new code?)"
    say ""
    say "--- shell log tail ---"
    tail -30 "$SHELL_LOG"
    exit 1
fi

say ""
say "assertions:"

METHODS="$(gdbus introspect --session --dest "$DEST" --object-path "$OBJPATH")"
for method in PreviousWorkspace NextWorkspace ShowOverview HideOverview; do
    if printf '%s' "$METHODS" | grep -q "${method}()"; then
        pass "interface exposes ${method}()"
    else
        fail "interface is missing ${method}()"
    fi
done
if printf '%s' "$METHODS" | grep -q "GetStatus(out s status)"; then
    pass "interface exposes GetStatus() with an out argument"
else
    fail "interface is missing GetStatus()"
fi

if printf '%s' "$METHODS" | grep -qE "Overview(Up|Down)\("; then
    fail "legacy OverviewUp/OverviewDown methods are still exported"
else
    pass "legacy OverviewUp/OverviewDown methods are gone"
fi

for method in PreviousWorkspace NextWorkspace ShowOverview HideOverview; do
    if gdbus call --session --dest "$DEST" --object-path "$OBJPATH" \
        --method "${DEST}.${method}" >/dev/null 2>&1; then
        pass "${method}() returned successfully"
    else
        fail "${method}() failed"
    fi
done

STATUS="$(gdbus call --session --dest "$DEST" --object-path "$OBJPATH" \
    --method "${DEST}.GetStatus" 2>&1)"
if printf '%s' "$STATUS" | grep -q '"uuid"'; then
    pass "GetStatus() returns a JSON status blob"
else
    fail "GetStatus() returned: ${STATUS}"
fi

if grep -qi "MiddleDrag. D-Bus service ready" "$SHELL_LOG"; then
    pass "extension logged 'D-Bus service ready'"
else
    fail "extension did not log 'D-Bus service ready'"
fi

if grep -i "${UUID}" "$SHELL_LOG" | grep -qiE "error|critical|failed"; then
    fail "shell log contains errors for ${UUID}:"
    grep -i "${UUID}" "$SHELL_LOG" | grep -iE "error|critical|failed" | sed 's/^/        /'
else
    pass "no JS errors for ${UUID} in the shell log"
fi

# --- preferences ----------------------------------------------------------
say ""
say "opening the preferences window for ${DURATION}s..."
export WAYLAND_DISPLAY="$WAYLAND_NAME"
export GTK_A11Y=none   # accessibility bus is unavailable in this sandbox
timeout "$DURATION" gnome-extensions prefs "$UUID" >"$PREFS_LOG" 2>&1
PREFS_EXIT=$?

# 124 = the window was still open when the timeout fired (success).
#   0 = the window was opened and closed again.
if grep -qi "doesn't have preferences" "$PREFS_LOG"; then
    fail "gnome-extensions could not find prefs.js"
elif grep -qiE "JS ERROR|Traceback" "$PREFS_LOG"; then
    fail "prefs.js raised an error:"
    grep -iE "JS ERROR|Traceback" "$PREFS_LOG" | sed 's/^/        /'
elif ! grep -q "preferences loaded" "$PREFS_LOG"; then
    fail "prefs.js did not finish building the window (no marker in log)"
else
    pass "prefs.js built the window without errors (exit code ${PREFS_EXIT})"
fi

say ""
if [ "$FAILURES" -eq 0 ]; then
    say "all extension checks passed"
    say "logs kept in ${TMPDIR_VERIFY}"
    exit 0
fi

say "${FAILURES} check(s) failed"
say "logs kept in ${TMPDIR_VERIFY}"
exit 1
