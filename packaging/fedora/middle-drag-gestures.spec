# Fedora RPM for Middle-Drag Gestures: the GNOME Shell extension AND its
# input daemon, so one `dnf install` produces a working system and `dnf
# remove` takes the whole thing back off.
#
# Contents:
#
#   /usr/libexec/middle-drag-daemon
#   /usr/lib/udev/rules.d/70-middle-drag-uaccess.rules
#   /usr/lib/systemd/user/middle-drag-daemon.service
#   /usr/share/gnome-shell/extensions/middle-drag-gestures@swad/
#   /usr/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml
#
# One step remains per user afterwards, because a package cannot perform it
# for an arbitrary account:
#
#   gnome-extensions enable middle-drag-gestures@swad
#
# Device access needs no account change: the rule below tags /dev/uinput and
# every input device with `uaccess`, so systemd-logind grants the active
# local session an ACL when it starts - verified after a fresh boot with zero
# supplementary groups (docs/installation.md).
#
# Known caveat: deleting the udev rule does not recompute the permissions
# already applied to /dev/uinput, so the node keeps 0660 root:input after
# removal until the next reboot recreates it with the kernel default, and the
# uaccess ACL stays on the nodes until the next session change.  This
# package therefore reloads udev rules in %post and %postun but does not
# try to chmod the node - it cannot know what it was before the rule.
#
# Build (Source0 is the GitHub tag archive, so spectool fetches it; a local
# tarball of the same name in ~/rpmbuild/SOURCES is used instead, which is
# how a checkout is built without the network):
#
#   mkdir -p ~/rpmbuild/SOURCES
#   spectool -g -C ~/rpmbuild/SOURCES packaging/fedora/middle-drag-gestures.spec
#   rpmbuild -ba packaging/fedora/middle-drag-gestures.spec
#
#   # offline, straight from a checkout:
#   git archive --format=tar.gz --prefix=middle-drag-gestures-0.1.3/ \
#     -o ~/rpmbuild/SOURCES/middle-drag-gestures-0.1.3.tar.gz HEAD
#   rpmbuild -ba packaging/fedora/middle-drag-gestures.spec
#
# systemd-rpm-macros supplies _userunitdir, _udevrulesdir and the
# %systemd_user_* scriptlets; glib2 supplies glib-compile-schemas, which
# runs in %install to validate the schema and build the extension's own
# gschemas.compiled.
#
# Built and verified on Fedora 44 / GNOME Shell 50.5 (2026-10-03):
# rpmbuild clean with no unpackaged files, `rpm -V` clean after install,
# the udev rule really fires (/dev/uinput -> 0660 root:input, and the session
# gets user:<you>:rw- on it and on every input node one second after login,
# with zero supplementary groups), the system schema resolves for gsettings,
# the extension reaches State: ACTIVE in a running Shell, and the daemon
# grabs the mouse and answers GetStatus on org.gnome.Shell.Extensions.MiddleDrag.
#
# A package cannot perform per-user steps, so one stays manual
# (docs/installation.md):
#
#   gnome-extensions enable middle-drag-gestures@swad
#
# The unit needs no command: 50-middle-drag-gestures.preset makes the
# install scriptlet's `systemctl --global preset` enable it for every
# account (verified with `systemctl --root --global preset` in a throwaway
# root: disabled before the preset file, enabled after).  It starts at the
# next login, or at once with `systemctl --user start middle-drag-daemon.service`.
#
# Removal has one manual half too: run `gnome-extensions disable
# middle-drag-gestures@swad` first, because %preun cannot write the
# user's dconf - otherwise a dangling uuid is left in enabled-extensions
# (docs/installation.md shows how to clean it up after the fact).
# Verified on removal: files gone, schema cache rebuilt, daemon stopped
# with SIGTERM and the grab released, enable symlink cleared; /dev/uinput
# keeps 0660 root:input until reboot.

%global uuid middle-drag-gestures@swad
%global schema_id org.gnome.shell.extensions.middle-drag
%global extensiondir %{_datadir}/gnome-shell/extensions/%{uuid}

Name:           middle-drag-gestures
Version:        0.1.3
Release:        1%{?dist}
Summary:        System-wide middle-mouse drag gestures for GNOME on Wayland

License:        MIT
URL:            https://github.com/TahmidSwad/middle-drag-gestures
Source0:        https://github.com/TahmidSwad/middle-drag-gestures/archive/refs/tags/v%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  glib2

Requires:       gnome-shell
Requires:       python3
Requires:       python3-evdev
Requires:       python3-dbus
Requires:       python3-gobject
Requires:       glib2
Requires:       systemd-udev
# modprobe, for loading uinput
Requires:       kmod

%description
Middle-Drag Gestures adds touchpad-style three-finger gestures to a plain
mouse: hold the middle button and drag left/right to switch workspaces, or
up/down to hide/show the Overview.

The GNOME Shell extension owns the GSettings keys and the preferences UI.
A companion daemon grabs the physical mouse with evdev, forwards every
event through a uinput virtual mouse, consumes the middle button and turns
the drag direction into D-Bus calls to the extension.

The daemon runs as the logged-in user through a systemd user unit and never
as root.

%prep
%autosetup

%build
# Nothing to build: the daemon is a Python script.

%install
# --- daemon ---------------------------------------------------------------
install -D -p -m 0755 daemon/middle-drag-daemon.py \
    %{buildroot}%{_libexecdir}/middle-drag-daemon

# --- udev rule (uaccess tag: logind grants the session device access) ------
install -D -p -m 0644 udev/70-middle-drag-uaccess.rules \
    %{buildroot}%{_udevrulesdir}/70-middle-drag-uaccess.rules

# --- systemd user unit ----------------------------------------------------
install -d -m 0755 %{buildroot}%{_userunitdir}
# The packaged daemon lives in libexec, not in the user's home directory.
sed -e 's|^ExecStart=.*|ExecStart=%{_libexecdir}/middle-drag-daemon|' \
    daemon/middle-drag-daemon.service \
    > %{buildroot}%{_userunitdir}/middle-drag-daemon.service
chmod 0644 %{buildroot}%{_userunitdir}/middle-drag-daemon.service

# --- systemd user preset ---------------------------------------------------
# Fedora's default policy for user units is `disable *` (see
# 99-default-disable.preset), and the install scriptlet applies that policy
# with `systemctl --global preset`.  Without this file the daemon installs
# disabled in every account - the package looks installed but does nothing
# until each user runs `systemctl --user enable` themselves.
install -D -p -m 0644 packaging/fedora/middle-drag-gestures.preset \
    %{buildroot}%{_userpresetdir}/50-middle-drag-gestures.preset

# --- GNOME Shell extension ------------------------------------------------
install -d -m 0755 %{buildroot}%{extensiondir}
cp -p extension/%{uuid}/extension.js \
      extension/%{uuid}/prefs.js \
      extension/%{uuid}/metadata.json \
      extension/%{uuid}/stylesheet.css \
      extension/%{uuid}/LICENSE \
      extension/%{uuid}/README.md \
    %{buildroot}%{extensiondir}/
if [ -d extension/%{uuid}/icons ]; then
    cp -r extension/%{uuid}/icons %{buildroot}%{extensiondir}/
fi

# The extension looks for schemas/gschemas.compiled next to metadata.json
# and throws as soon as it is enabled without it.  Build it here rather
# than shipping a locally generated copy, and let --strict fail the build
# if the schema is broken.
install -d -m 0755 %{buildroot}%{extensiondir}/schemas
install -p -m 0644 extension/%{uuid}/schemas/*.gschema.xml \
    %{buildroot}%{extensiondir}/schemas/
glib-compile-schemas --strict %{buildroot}%{extensiondir}/schemas

# --- system GSettings schema (read by the daemon) -------------------------
# The shared /usr/share/glib-2.0/schemas/gschemas.compiled is deliberately
# not in %files: it is unowned and rebuilt by %post/%postun below.
install -d -m 0755 %{buildroot}%{_datadir}/glib-2.0/schemas
install -p -m 0644 extension/%{uuid}/schemas/%{schema_id}.gschema.xml \
    %{buildroot}%{_datadir}/glib-2.0/schemas/

%post
%systemd_user_post middle-drag-daemon.service
# No file trigger for schemas on this distro, so rebuild the cache here.
glib-compile-schemas %{_datadir}/glib-2.0/schemas > /dev/null 2>&1 || :
# Make the new rule take effect without a reboot: misc covers /dev/uinput,
# input re-evaluates the tag on every input node so the session's ACL lands
# without waiting for a reboot.
udevadm control --reload-rules > /dev/null 2>&1 || :
udevadm trigger --subsystem-match=misc > /dev/null 2>&1 || :
udevadm trigger --subsystem-match=input > /dev/null 2>&1 || :

# The one step a package must not perform: switching on extension code inside
# a user's compositor is per-user opt-in and dconf belongs to the running
# session, so say it where the user is looking.
echo ""
echo "Middle-Drag Gestures installed. Next (as your own user, not root):"
echo "  gnome-extensions enable middle-drag-gestures@swad"
echo "then log out and log back in once - GNOME Shell loads extension code at login."
echo ""

%preun
%systemd_user_preun middle-drag-daemon.service

%postun
%systemd_user_postun middle-drag-daemon.service
if [ $1 -eq 0 ]; then
    # Really removed (not upgraded): drop our schema and stop advertising
    # a rule that is no longer on disk.
    glib-compile-schemas %{_datadir}/glib-2.0/schemas > /dev/null 2>&1 || :
    udevadm control --reload-rules > /dev/null 2>&1 || :
    udevadm trigger --subsystem-match=misc > /dev/null 2>&1 || :
fi

%files
%license LICENSE
%doc README.md CHANGELOG.md docs/architecture.md docs/installation.md docs/troubleshooting.md
%{_libexecdir}/middle-drag-daemon
%{_udevrulesdir}/70-middle-drag-uaccess.rules
%{_userunitdir}/middle-drag-daemon.service
%{_userpresetdir}/50-middle-drag-gestures.preset
%{extensiondir}/
%{_datadir}/glib-2.0/schemas/%{schema_id}.gschema.xml

%changelog
* Sat Oct 03 2026 Swad <swad@localhost> - 0.1.3-1
- Swap the vertical gestures: middle + drag up now opens the Overview
  and down closes it - schema defaults and the daemon's fallback table
  both updated, so the two agree by test

* Sat Oct 03 2026 Swad <swad@localhost> - 0.1.2-1
- Fix the preferences window, which failed to open since 0.1.1: the
  daemon status lookup passed a GVariantType where the D-Bus method
  parameters belong
- The systemd user unit's Documentation link points at the repository
  instead of the developer's checkout
- Documentation rewritten: requirements up front, one verify/remove block
  for every install route, no extensions.gnome.org references, release
  procedure documented

* Sat Oct 03 2026 Swad <swad@localhost> - 0.1.1-1
- Preferences window reports daemon status and shows the install commands
- LICENSE included in the extension bundle
- Install instructions and dependency names for non-Fedora distributions

* Sat Oct 03 2026 Swad <swad@localhost> - 0.1.0-1
- Initial package: GNOME Shell extension, GSettings schema, input daemon,
  udev rule and systemd user unit (previously the daemon half only)
- Build the extension's gschemas.compiled at build time
- Reload udev rules and rebuild the schema cache in %post/%postun
