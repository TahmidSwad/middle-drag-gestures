#!/usr/bin/env bash
#
# package-extension.sh - build the GNOME Extensions bundle in dist/.
#
#   dist/middle-drag-gestures@swad.shell-extension.zip
#
# The bundle contains the extension (metadata.json, extension.js, prefs.js,
# stylesheet.css, the GSettings schema and its compiled form) plus the LICENSE,
# which extensions.gnome.org reviewers expect to find in it.  The daemon, udev
# rule and systemd unit are distributed separately - an
# extension bundle cannot write to /etc/udev/rules.d or manage systemd
# units.  See docs/installation.md and packaging/fedora/.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

UUID="middle-drag-gestures@swad"
SRC="$PROJECT_DIR/extension/$UUID"
OUT_DIR="$PROJECT_DIR/dist"
SCHEMA_XML="schemas/org.gnome.shell.extensions.middle-drag.gschema.xml"

command -v gnome-extensions >/dev/null 2>&1 || {
    echo "gnome-extensions not found" >&2
    exit 1
}
command -v zip >/dev/null 2>&1 || {
    echo "zip not found" >&2
    exit 1
}

# 1. Compile the schema inside the extension directory: Gio.Settings looks
#    for schemas/gschemas.compiled next to the extension's metadata.
glib-compile-schemas --strict "$SRC/schemas"
echo "compiled $SCHEMA_XML"

# 2. Pack. gnome-extensions pack includes *.xml under schemas/ but not the
#    compiled form.
mkdir -p "$OUT_DIR"
gnome-extensions pack --force --quiet -o "$OUT_DIR" "$SRC"
ZIP="$OUT_DIR/$UUID.shell-extension.zip"

# 3. --extra-source flattens paths, so add the compiled schema at the right
#    location ourselves.
(cd "$SRC" && zip -q "$ZIP" schemas/gschemas.compiled)

# 3b. LICENSE lives at the repository root rather than inside the extension
#     directory, and -j drops it at the top level of the bundle.  The RPM
#     installs the same file beside the extension.
(cd "$PROJECT_DIR" && zip -q -j "$ZIP" LICENSE)

# 4. Verify the bundle carries everything a fresh install needs.
echo
echo "bundle contents:"
unzip -l "$ZIP"

missing=0
for entry in \
    LICENSE \
    metadata.json \
    extension.js \
    prefs.js \
    stylesheet.css \
    "$SCHEMA_XML" \
    schemas/gschemas.compiled
do
    if ! unzip -l "$ZIP" | grep -q " $entry\$"; then
        echo "MISSING from bundle: $entry" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] || exit 1

META_VERSION="$(sed -n 's/.*"version": *\([0-9]*\).*/\1/p' "$SRC/metadata.json")"
RELEASE_VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
echo
# GNOME Extensions requires an integer "version" in metadata.json, so it is
# a monotonically increasing counter while VERSION is the project's
# semantic version.  They are deliberately different.
echo "metadata.json version : $META_VERSION (integer counter for extensions.gnome.org)"
echo "VERSION file          : $RELEASE_VERSION (project release)"

echo
echo "wrote $ZIP"
