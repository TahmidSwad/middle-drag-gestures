# Fedora RPM for Middle-Drag Gestures: the GNOME Shell extension AND its
# input daemon, so one `dnf install` produces a working system and `dnf
# remove` takes the whole thing back off.
#
# Contents:
#
#   /usr/libexec/middle-drag-daemon
#   /usr/lib/udev/rules.d/99-middle-drag-uinput.rules
#   /usr/lib/systemd/user/middle-drag-daemon.service
#   /usr/share/gnome-shell/extensions/middle-drag-gestures@swad/
#   /usr/share/glib-2.0/schemas/org.gnome.shell.extensions.middle-drag.gschema.xml
#
# Two steps remain per user afterwards, because a package cannot perform
# them for an arbitrary account.  Both take effect at the next login:
#
#   1. sudo usermod -aG input "$USER"    # read /dev/input, write /dev/uinput
#   2. gnome-extensions enable middle-drag-gestures@swad
#
# See docs/installation.md for the details.
#
# Known caveat: deleting the udev rule does not recompute the permissions
# already applied to /dev/uinput, so the node keeps 0660 root:input after
# removal until the next reboot recreates it with the kernel default.  This
# package therefore reloads udev rules in %post and %postun but does not
# try to chmod the node - it cannot know what it was before the rule.
#
# Build (Source0 has no real URL in this repository, so `spectool -g` does
# not work - make the tarball from the checkout instead):
#
#   mkdir -p ~/rpmbuild/SOURCES
#   git archive --format=tar.gz --prefix=middle-drag-gestures-0.1.0/ \
#     -o ~/rpmbuild/SOURCES/middle-drag-gestures-0.1.0.tar.gz HEAD
#   rpmbuild -ba packaging/fedora/middle-drag-gestures.spec
#
# systemd-rpm-macros supplies _userunitdir, _udevrulesdir and the
# %systemd_user_* scriptlets; glib2 supplies glib-compile-schemas, which
# runs in %install to validate the schema and build the extension's own
# gschemas.compiled.
#
# Built and verified on Fedora 44 / GNOME Shell 50.5 (2026-10-03):
# rpmbuild clean with no unpackaged files, `rpm -V` clean after install,
# the udev rule really fires (/dev/uinput -> 0660 root:input), the system
# schema resolves for gsettings, the extension reaches State: ACTIVE in a
# running Shell, and the daemon grabs the mouse and answers GetStatus on
# org.gnome.Shell.Extensions.MiddleDrag.
#
# A package cannot perform per-user steps, so these two stay manual
# (docs/installation.md):
#
#   sudo usermod -aG input "$USER"                  # applies at next login
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
Version:        0.1.0
Release:        1%{?dist}
Summary:        System-wide middle-mouse drag gestures for GNOME on Wayland

License:        MIT
URL:            https://example.invalid/middle-drag-gestures
Source0:        %{name}-%{version}.tar.gz

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

# --- udev rule (grants the 'input' group access to /dev/uinput) -----------
install -D -p -m 0644 udev/99-middle-drag-uinput.rules \
    %{buildroot}%{_udevrulesdir}/99-middle-drag-uinput.rules

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
# Make the new rule take effect without a reboot.
udevadm control --reload-rules > /dev/null 2>&1 || :
udevadm trigger --subsystem-match=misc > /dev/null 2>&1 || :

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
%{_udevrulesdir}/99-middle-drag-uinput.rules
%{_userunitdir}/middle-drag-daemon.service
%{_userpresetdir}/50-middle-drag-gestures.preset
%{extensiondir}/
%{_datadir}/glib-2.0/schemas/%{schema_id}.gschema.xml

%changelog
* Sat Oct 03 2026 Swad <swad@localhost> - 0.1.0-1
- Initial package: GNOME Shell extension, GSettings schema, input daemon,
  udev rule and systemd user unit (previously the daemon half only)
- Build the extension's gschemas.compiled at build time
- Reload udev rules and rebuild the schema cache in %post/%postun
