# Fedora RPM for the Middle-Drag Gestures input daemon.
#
# Scope: this package ships the *daemon half* of the project only -
#
#   /usr/libexec/middle-drag-daemon
#   /usr/lib/udev/rules.d/99-middle-drag-uinput.rules
#   /usr/lib/systemd/user/middle-drag-daemon.service
#
# The GNOME Shell extension is distributed as an extension bundle
# (dist/middle-drag-gestures@swad.shell-extension.zip), because extensions
# are installed per user and an extension bundle cannot write to /etc/udev
# or manage systemd units.  See plan.md sections 48-49.
#
# The daemon needs the extension's GSettings schema
# (org.gnome.shell.extensions.middle-drag); without it, it falls back to
# built-in defaults and logs a warning.
#
# Build (from a release tarball):
#
#   spectool -g middle-drag-gestures.spec
#   rpmbuild -ba middle-drag-gestures.spec
#
# This is a starting point and has not been built in CI.

Name:           middle-drag-gestures
Version:        0.1.0
Release:        1%{?dist}
Summary:        System-wide middle-mouse drag gestures for GNOME on Wayland

License:        MIT
URL:            https://example.invalid/middle-drag-gestures
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

Requires:       python3
Requires:       python3-evdev
Requires:       python3-dbus
Requires:       python3-gobject
Requires:       glib2
# /dev/uinput
Requires:       kmod

%description
A companion daemon for the Middle-Drag Gestures GNOME Shell extension.
It grabs the physical mouse with evdev, forwards every event through a
uinput virtual mouse, consumes the middle button and turns middle-drag
gestures (left/right/up/down) into D-Bus calls that switch workspaces
and toggle the Overview.

The daemon runs as the logged-in user through a systemd user unit and
never as root.

%prep
%autosetup

%build
# Nothing to build: the daemon is a Python script.

%install
install -D -p -m 0755 daemon/middle-drag-daemon.py \
    %{buildroot}%{_libexecdir}/middle-drag-daemon

install -D -p -m 0644 udev/99-middle-drag-uinput.rules \
    %{buildroot}%{_udevrulesdir}/99-middle-drag-uinput.rules

install -d -m 0755 %{buildroot}%{_userunitdir}
# The packaged daemon lives in libexec, not in the user's home directory.
sed -e 's|^ExecStart=.*|ExecStart=%{_libexecdir}/middle-drag-daemon|' \
    daemon/middle-drag-daemon.service \
    > %{buildroot}%{_userunitdir}/middle-drag-daemon.service
chmod 0644 %{buildroot}%{_userunitdir}/middle-drag-daemon.service

%pre
# The daemon needs read access to /dev/input/event* and write access to
# /dev/uinput; the udev rule grants both to the 'input' group.

%post
%systemd_user_post middle-drag-daemon.service

%preun
%systemd_user_preun middle-drag-daemon.service

%postun
%systemd_user_postun middle-drag-daemon.service

%files
%license LICENSE
%doc README.md docs/architecture.md docs/installation.md docs/troubleshooting.md
%{_libexecdir}/middle-drag-daemon
%{_udevrulesdir}/99-middle-drag-uinput.rules
%{_userunitdir}/middle-drag-daemon.service

%changelog
* Thu Oct 02 2026 Swad <swad@localhost> - 0.1.0-1
- Initial package: input daemon, udev rule, systemd user unit
