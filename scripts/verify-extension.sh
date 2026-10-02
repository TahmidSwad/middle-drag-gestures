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
# Output layout: <tmpdir>/shell.log    messages from the nested shell
#                <tmpdir>/prefs.log    messages from `gnome-extensions prefs`
#                <tmpdir>/session.log  messages from dbus-daemon and from
#                                      D-Bus activated services (the prefs
#                                      host runs there, see below)
#
set -u

# Run everything on a private session bus: a second GNOME Shell must never
# join the real desktop session's bus (it would fight over org.gnome.Shell).
#
# The session log exists because `gnome-extensions prefs` does not run
# prefs.js itself - it D-Bus-activates /usr/share/gnome-shell/
# org.gnome.Shell.Extensions, which is spawned by *dbus-daemon* and therefore
# writes to dbus-daemon's stderr.  Redirecting the `gnome-extensions` process
# (as you would naturally do) captures nothing at all.  dbus-daemon inherits
# the stderr of dbus-run-session, so redirecting before the exec catches it.
if [ -z "${MIDDLE_DRAG_VERIFY_INNER:-}" ]; then
    if ! command -v dbus-run-session >/dev/null 2>&1; then
        echo "dbus-run-session not found (package dbus-daemon)" >&2
        exit 1
    fi
    VERIFY_TMP="$(mktemp -d /tmp/middle-drag-verify.XXXXXX)"
    SESSION_LOG="$VERIFY_TMP/session.log"
    : > "$SESSION_LOG"
    exec dbus-run-session -- \
        env MIDDLE_DRAG_VERIFY_INNER=1 \
            MIDDLE_DRAG_VERIFY_TMP="$VERIFY_TMP" \
            MIDDLE_DRAG_SESSION_LOG="$SESSION_LOG" \
        bash "$0" "$@" 2>>"$SESSION_LOG"
fi

UUID="middle-drag-gestures@swad"
DEST="org.gnome.Shell.Extensions.MiddleDrag"
OBJPATH="/org/gnome/Shell/Extensions/MiddleDrag"
WAYLAND_NAME="middle-drag-verify"
PREFS_TIMEOUT=10   # seconds to wait for the prefs host to report back

TMPDIR_VERIFY="${MIDDLE_DRAG_VERIFY_TMP:-$(mktemp -d /tmp/middle-drag-verify.XXXXXX)}"
SESSION_LOG="${MIDDLE_DRAG_SESSION_LOG:-$TMPDIR_VERIFY/session.log}"
SHELL_LOG="$TMPDIR_VERIFY/shell.log"
PREFS_LOG="$TMPDIR_VERIFY/prefs.log"
FAILURES=0

SHELL_PID=""

cleanup() {
    kill_prefs_host
    if [ -n "$SHELL_PID" ] && kill -0 "$SHELL_PID" 2>/dev/null; then
        kill "$SHELL_PID" 2>/dev/null
        wait "$SHELL_PID" 2>/dev/null
    fi
}

# The prefs host is a separate process on our private bus.  Only kill the one
# belonging to this session - the desktop session may run its own.
kill_prefs_host() {
    local mine="${DBUS_SESSION_BUS_ADDRESS:-}" pid
    [ -n "$mine" ] || return 0
    for pid in $(pgrep -f "gjs .*org\.gnome\.Shell\.Extensions" 2>/dev/null); do
        if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null |
            grep -qxF "DBUS_SESSION_BUS_ADDRESS=$mine"; then
            kill "$pid" 2>/dev/null
        fi
    done
    return 0
}

trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
pass() { printf '  ok   - %s\n' "$*"; }
fail() { printf '  FAIL - %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# Poll a log file until a pattern shows up or the timeout expires.
wait_for_log() {
    local file="$1" pattern="$2" timeout="${3:-$PREFS_TIMEOUT}" waited=0
    while [ "$waited" -lt "$((timeout * 2))" ]; do
        if [ -f "$file" ] && grep -q -- "$pattern" "$file"; then
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    return 1
}

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
    say "--- session log tail ---"
    tail -30 "$SESSION_LOG"
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
say "opening the preferences window (waiting up to ${PREFS_TIMEOUT}s)..."
export WAYLAND_DISPLAY="$WAYLAND_NAME"
export GTK_A11Y=none   # accessibility bus is unavailable in this sandbox

# gnome-extensions returns as soon as it has asked the service to activate,
# so its exit code tells us nothing; the service logs into SESSION_LOG.
gnome-extensions prefs "$UUID" >"$PREFS_LOG" 2>&1
PREFS_EXIT=$?

if grep -qi "doesn't have preferences" "$PREFS_LOG"; then
    fail "gnome-extensions could not find prefs.js"
elif wait_for_log "$SESSION_LOG" "preferences loaded"; then
    # Give a JS error raised after fillPreferencesWindow() a moment to land.
    sleep 1.5
    if grep -qiE "JS ERROR|Traceback" "$SESSION_LOG" "$PREFS_LOG" 2>/dev/null; then
        fail "prefs.js raised an error:"
        grep -ihE "JS ERROR|Traceback" "$SESSION_LOG" "$PREFS_LOG" 2>/dev/null |
            sed 's/^/        /'
    else
        pass "prefs.js built the preferences window without errors"
    fi
elif grep -qiE "JS ERROR|Traceback" "$SESSION_LOG" "$PREFS_LOG" 2>/dev/null; then
    fail "prefs.js raised an error:"
    grep -ihE "JS ERROR|Traceback" "$SESSION_LOG" "$PREFS_LOG" 2>/dev/null |
        sed 's/^/        /'
else
    fail "prefs host never reported the window (gnome-extensions exit ${PREFS_EXIT}; see ${SESSION_LOG})"
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
