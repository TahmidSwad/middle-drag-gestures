#!/usr/bin/env bash
#
# install_matrix.sh - release test matrix for the installer/uninstaller.
#
# This is the scripted equivalent of "install it, break it, remove it, prove
# it is gone".  Every scenario runs against an isolated HOME so the real
# session is never touched, except the optional --real round trip.
#
# Scenarios:
#    1  fail-fast      root needed but unavailable  -> refuse, write nothing
#    2  missing dep    python module import fails   -> refuse, write nothing
#    3  clean install  -> success, files + state present
#    4  re-run         -> idempotent success
#    5  verify         -> verify-clean fails while installed
#    6  rollback       -> mid-run failure undoes itself, keeps foreign files
#    7  uninstall      -> success, verify-clean passes
#    8  purge          -> dconf/state gone, verify-clean --purge passes
#    9  real session   (only with --real) install/disable round trip in the
#                       actual home directory, which is the only place
#                       'systemctl --user enable' can work
#
# Usage: ./tests/install_matrix.sh [--real] [--help]
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
UNINSTALL="$ROOT/scripts/uninstall.sh"
VERIFY="$ROOT/scripts/verify-clean.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdg-matrix.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REAL=0
for arg in "$@"; do
    case "$arg" in
        --real) REAL=1 ;;
        -h|--help) sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Error: unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

PASS=0
FAIL=0
SKIP=0
CURRENT=""

# isolated HOME: only the user's own files land there.  systemd is skipped
# because the user manager resolves unit paths from the HOME it started
# with, so enable cannot work under a different one (install.sh --no-systemd).
run_install() {
    local home="$1"; shift
    HOME="$home" XDG_CACHE_HOME="$home/.cache" XDG_STATE_HOME="$home/.local/state" \
        "$INSTALL" "$@" < /dev/null
}
run_uninstall() {
    local home="$1"; shift
    HOME="$home" XDG_CACHE_HOME="$home/.cache" XDG_STATE_HOME="$home/.local/state" \
        "$UNINSTALL" "$@" < /dev/null
}
run_verify() {
    local home="$1"; shift
    # --scope=script: this suite proves the *script's* cycle.  A live RPM
    # install is a different method and out of scope here; verify-clean notes
    # it rather than pretending it is not there.  Use verify-clean without
    # --scope to judge the whole machine.
    HOME="$home" XDG_CACHE_HOME="$home/.cache" XDG_STATE_HOME="$home/.local/state" \
        "$VERIFY" --scope=script "$@" < /dev/null
}

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$CURRENT"; }
bad()  {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n        %s\n' "$CURRENT" "$1"
    if [ -f "$CURRENT_LOG" ]; then
        sed 's/^/        | /' "$CURRENT_LOG" | tail -n 20
    fi
}
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s (%s)\n' "$CURRENT" "$1"; }

# expect_rc <expected|nonzero> <actual>
expect_rc() {
    case "$1" in
        nonzero) [ "$2" -ne 0 ] ;;
        *)       [ "$2" -eq "$1" ] ;;
    esac
}
# assert_absent PATH... - all must be missing
assert_absent() {
    local p
    for p in "$@"; do
        [ -e "$p" ] && return 1
    done
    return 0
}
# assert_present PATH... - all must exist
assert_present() {
    local p
    for p in "$@"; do
        [ -e "$p" ] || return 1
    done
    return 0
}

EXT_DIR=".local/share/gnome-shell/extensions/middle-drag-gestures@swad"
DAEMON=".local/bin/middle-drag-daemon.py"
UNIT=".config/systemd/user/middle-drag-daemon.service"
SCHEMA_XML=".local/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml"
STATE=".local/state/middle-drag-gestures/state"

new_home() {
    local h="$WORK/$1"
    rm -rf "$h"; mkdir -p "$h"
    printf '%s' "$h"
}

printf 'Middle-Drag Gestures - install/uninstall matrix\n'
printf '==============================================\n\n'

# --- 1. fail-fast ----------------------------------------------------------
CURRENT="1 fail-fast (root needed, no sudo)"
CURRENT_LOG="$WORK/01-failfast.log"
if sudo -n true 2>/dev/null; then
    skip "sudo is cached non-interactively here, cannot simulate its absence"
else
    H="$(new_home s1)"
    run_install "$H" > "$CURRENT_LOG" 2>&1
    rc=$?
    if expect_rc nonzero "$rc" &&
       assert_absent "$H/$DAEMON" "$H/$UNIT" "$H/$EXT_DIR" "$H/$SCHEMA_XML"; then
        ok
    else
        bad "expected a refusal before any file was written (rc=$rc)"
    fi
fi

# --- 2. missing dependency -------------------------------------------------
CURRENT="2 fail-fast (missing python module)"
CURRENT_LOG="$WORK/02-missingdep.log"
mkdir -p "$WORK/badmod"
printf 'raise ImportError("simulated by install_matrix")\n' > "$WORK/badmod/evdev.py"
H="$(new_home s2)"
PYTHONPATH="$WORK/badmod" run_install "$H" --user-only --no-systemd > "$CURRENT_LOG" 2>&1
rc=$?
if expect_rc nonzero "$rc" &&
   assert_absent "$H/$DAEMON" "$H/$EXT_DIR" "$H/$SCHEMA_XML"; then
    ok
else
    bad "expected a refusal naming the missing module (rc=$rc)"
fi

# --- 3. clean install ------------------------------------------------------
CURRENT="3 clean install"
CURRENT_LOG="$WORK/03-install.log"
H="$(new_home s3)"
if run_install "$H" --user-only --no-systemd > "$CURRENT_LOG" 2>&1 &&
   assert_present "$H/$DAEMON" "$H/$UNIT" "$H/$EXT_DIR/extension.js" \
                  "$H/$EXT_DIR/schemas/gschemas.compiled" "$H/$SCHEMA_XML" \
                  "$H/$STATE"; then
    ok
else
    bad "files or install state missing after a successful install"
fi

# --- 4. idempotent re-run --------------------------------------------------
CURRENT="4 re-run (idempotent)"
CURRENT_LOG="$WORK/04-rerun.log"
if run_install "$H" --user-only --no-systemd > "$CURRENT_LOG" 2>&1; then
    ok
else
    bad "re-running the installer must succeed"
fi

# --- 5. verify-clean must fail while installed -----------------------------
CURRENT="5 verify-clean detects an install"
CURRENT_LOG="$WORK/05-verify-installed.log"
if run_verify "$H" > "$CURRENT_LOG" 2>&1; then
    bad "verify-clean passed while the product is installed"
else
    ok
fi

# --- 6. rollback -----------------------------------------------------------
CURRENT="6 rollback on mid-run failure"
CURRENT_LOG="$WORK/06-rollback.log"
H="$(new_home s6)"
# A file where the installer must create a directory: fails after the daemon,
# unit and extension have already been written.
mkdir -p "$H/.local/share/glib-2.0"
: > "$H/.local/share/glib-2.0/schemas"
run_install "$H" --user-only --no-systemd > "$CURRENT_LOG" 2>&1
rc=$?
if expect_rc nonzero "$rc" &&
   assert_absent "$H/$DAEMON" "$H/$UNIT" "$H/$EXT_DIR" "$H/$STATE" &&
   [ -f "$H/.local/share/glib-2.0/schemas" ]; then
    ok
else
    bad "rollback must remove what it created and keep foreign files (rc=$rc)"
fi

# --- 7. uninstall ----------------------------------------------------------
CURRENT="7 uninstall"
CURRENT_LOG="$WORK/07-uninstall.log"
H="$WORK/s3"
if run_uninstall "$H" > "$CURRENT_LOG" 2>&1 &&
   assert_absent "$H/$DAEMON" "$H/$UNIT" "$H/$EXT_DIR" "$H/$SCHEMA_XML"; then
    # verify-clean must pass; state/dconf "notes" are allowed without --purge
    if run_verify "$H" >> "$CURRENT_LOG" 2>&1; then
        ok
    else
        bad "verify-clean found leftovers after a normal uninstall"
    fi
else
    bad "uninstall failed or left files behind"
fi

# --- 8. purge --------------------------------------------------------------
CURRENT="8 uninstall --purge"
CURRENT_LOG="$WORK/08-purge.log"
H="$(new_home s8)"
run_install "$H" --user-only --no-systemd > "$CURRENT_LOG" 2>&1 &&
run_uninstall "$H" --purge >> "$CURRENT_LOG" 2>&1
rc=$?
if expect_rc 0 "$rc" && run_verify "$H" --purge >> "$CURRENT_LOG" 2>&1; then
    ok
else
    bad "purged state must satisfy verify-clean --purge (rc=$rc)"
fi

# --- 9. real session round trip (opt-in) -----------------------------------
CURRENT="9 real home round trip"
CURRENT_LOG="$WORK/09-real.log"
if [ "$REAL" = 0 ]; then
    skip "opt-in: pass --real to exercise the actual home directory"
else
    # --no-start keeps the daemon from grabbing the physical mouse; this is
    # also the only scenario where 'systemctl --user enable' can work, since
    # the user manager resolves unit paths from the HOME it started with.
    rc_install=0
    "$INSTALL" --user-only --no-start > "$CURRENT_LOG" 2>&1 || rc_install=$?

    enabled=1
    systemctl --user is-enabled middle-drag-daemon.service >/dev/null 2>&1 ||
        enabled=0

    # verify-clean must report leftovers while installed ...
    rc_v_installed=0
    "$VERIFY" --scope=script >> "$CURRENT_LOG" 2>&1 || rc_v_installed=$?

    rc_uninstall=0
    "$UNINSTALL" </dev/null >> "$CURRENT_LOG" 2>&1 || rc_uninstall=$?

    # ... and pass once uninstalled.
    rc_v_clean=0
    "$VERIFY" --scope=script </dev/null >> "$CURRENT_LOG" 2>&1 || rc_v_clean=$?

    if [ "$rc_install" = 0 ] && [ "$enabled" = 1 ] &&
       [ "$rc_v_installed" -ne 0 ] && [ "$rc_uninstall" = 0 ] &&
       [ "$rc_v_clean" = 0 ]; then
        ok
    else
        bad "cycle: install=$rc_install enabled=$enabled verify-installed=$rc_v_installed uninstall=$rc_uninstall verify-clean=$rc_v_clean"
    fi
fi

# --- summary ---------------------------------------------------------------
printf '\n%s\n' "----------------------------------------------"
printf 'passed %d   failed %d   skipped %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\nRESULT: FAILED\n'
    exit 1
fi
printf '\nRESULT: OK\n'
exit 0
