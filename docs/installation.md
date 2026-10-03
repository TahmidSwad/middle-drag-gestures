# Installation

Tested on **Fedora 44, GNOME Shell 50.5, Wayland** with a USB mouse.

---

## 1. Requirements

| component | package |
| --------- | ------- |
| GNOME Shell on Wayland | `gnome-shell` |
| Python 3 | `python3` |
| evdev bindings | `python3-evdev` |
| D-Bus bindings | `python3-dbus` |
| GObject introspection (GSettings) | `python3-gobject` |
| schema compiler | `glib2` (provides `glib-compile-schemas`) |
| session bus client | `glib2` (provides `gdbus`) |

Install them all (Fedora):

```bash
sudo dnf install python3-evdev python3-dbus python3-gobject glib2
```

Debian / Ubuntu — same components, distribution names:

```bash
sudo apt install python3-evdev python3-dbus python3-gi libglib2.0-bin
```

`scripts/install.sh` checks every row of this table before writing anything
and prints the exact package name for your distribution when one is missing,
so the table is a checklist rather than a prerequisite. Everything here is
ordinary systemd/udev/GNOME material: any distribution with systemd, udev,
logind and GNOME 50 can run the project. Only Fedora 44 (GNOME 50, Wayland)
has actually been tested, and no X11 session has been tested at all - the
daemon is display-server agnostic by construction (it works below the
compositor, straight on evdev), but nothing in this project is validated
outside Wayland.

Kernel side:

```bash
lsmod | grep uinput || sudo modprobe uinput
```

---

## 2. Permissions

The daemon reads `/dev/input/event*` (always `root:input`, mode `0660`) and
writes `/dev/uinput`. This project deliberately does **not** put your account
in the `input` group: a package must not edit `/etc/group` for a user it
cannot know, and a membership only applies at the *next* login anyway.

Instead, the shipped udev rule tags both device classes with `uaccess`, which
is how systemd-logind already hands you `/dev/snd/*`:

```text
/etc/udev/rules.d/70-middle-drag-uaccess.rules
```

```udev
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput", TAG+="uaccess"
SUBSYSTEM=="input", TAG+="uaccess"
```

Two details make that work:

* **the `70-` prefix** — udev applies rules in lexical order, so this file
  must sort before `71-seat.rules` (promotes an `uaccess`-tagged device to a
  seat device) and `73-seat-late.rules` (runs the `uaccess` builtin). With a
  `99-` name the tag would be added too late: on a device's first event —
  exactly what happens at boot — the builtin has already run without
  matching.
* **`OPTIONS+="static_node=uinput"`** — registers `/dev/uinput` in
  `/run/udev/static_node-tags/uaccess/`, the list logind reads when a session
  starts. `/dev/uinput` is a static node (`modules.devname`, created by
  systemd-tmpfiles at boot, before any session exists), so without this
  option a fresh boot leaves it without an ACL at login. Fedora uses the same
  option for `/dev/snd/seq` and `/dev/snd/timer`.

`GROUP`/`MODE` are kept for continuity: the node stays `crw-rw---- root
input`, exactly as before, and that stays the fallback outside a seat
session.

The installer lays the rule down, reloads it and triggers both device
classes; to do it by hand:

```bash
sudo install -m 0644 udev/70-middle-drag-uaccess.rules \
    /etc/udev/rules.d/70-middle-drag-uaccess.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
sudo udevadm trigger --subsystem-match=input
getfacl /dev/uinput           # expect: user:YOU:rw- …
getfacl /dev/input/event3     # expect: user:YOU:rw- …
ls -l /dev/uinput             # expect: crw-rw----. 1 root input 10, 223 …
```

The ACL is granted while your session is running and again at every login —
no logout is needed to pick it up. Verified on Fedora 44 / GNOME 50.5: after
a fresh boot, every input node and `/dev/uinput` carried `user:swad:rw-` one
second after session start, and all three device classes opened with *zero*
supplementary groups.

---

## 3. Install with the script

```bash
./scripts/install.sh
```

It checks **every** dependency first and refuses before writing a single file:
if something cannot work (a missing package, or root needed where `sudo` cannot
ask for a password), it says exactly what to do and exits non-zero with your
home directory untouched.

What it does:

```text
./scripts/install.sh
             │
             ├── preflight: GNOME / Python / evdev / dbus / gi / gdbus,
             │   /dev/uinput, udev rule        ← nothing is written
             │   until all of these pass
             ├── install udev rule, reload, trigger   (sudo; grants this
             │   session its uaccess ACL - no group membership needed)
             ├── install daemon        → ~/.local/bin/middle-drag-daemon.py
             ├── install systemd unit  → ~/.config/systemd/user/
             ├── install extension     → ~/.local/share/gnome-shell/extensions/
             ├── compile GSettings schema (extension dir + user dir)
             ├── enable + restart the daemon
             └── enable the extension
```

Every step records what it created, so a failure further down rolls those
files back and exits non-zero - a failed install never leaves half an
installation behind (exercised by `tests/install_matrix.sh`).

**One logout, and only for the code.** The udev rule grants this session its
uaccess ACL the moment it is triggered, so device access needs no logout at
all. What still requires a login is GNOME Shell reloading the extension's
code, so the script prints

```text
ACTION REQUIRED: log out and log back in (once).
```

and leaves the daemon start to that login. Everything else (extension
enabled, unit enabled) is already in place; there is no second pass.

Root is needed only for the udev rule. The script asks once,
non-interactively, and refuses up front if it cannot get it. Other flags:

| flag | purpose |
| ---- | ------- |
| `--user-only` | skip the root steps (udev rule) - the daemon then cannot open the mouse, see [troubleshooting](troubleshooting.md) |
| `--no-start` | install and enable everything but do not start the daemon |
| `--no-systemd` | do not touch systemd at all (used by `tests/install_matrix.sh`) |
| `--help` | full usage |

### Important: GNOME Shell reloads extension code only at login

The daemon restarts immediately, but `extension.js` and `prefs.js` are cached
by the Shell. **Log out and back in** after updating the extension. Until you
do, the running Shell still exports the pre-rename methods and the daemon
logs one notice:

```text
the running extension predates the D-Bus method rename; gestures keep
working through the legacy OverviewUp() fallback. …
```

Vertical gestures keep working meanwhile through that fallback; nothing is
broken while you wait for your next login.

To test extension changes *without* logging out, use:

```bash
./scripts/verify-extension.sh
```

which loads the extension in a throwaway headless GNOME Shell. It works on a
clean checkout too: if the extension is not installed it stages a private copy
of the working tree (and never touches your real dconf).

### The Fedora RPM (the other full route - do not mix the two)

`packaging/fedora/middle-drag-gestures.spec` packages the whole product -
extension, prefs, GSettings schema, daemon, udev rule and user unit - into
`/usr`. Pick either this route or `./scripts/install.sh`, not both: they
write to different places (`/usr` vs `~/.local`, `/usr/lib/systemd/user` vs
`~/.config/systemd/user`), and the user-local copy would shadow the package.

```bash
sudo dnf install -y rpm-build rpmdevtools

# Source0 is the GitHub tag archive, so spectool fetches it for rpmbuild:
mkdir -p ~/rpmbuild/SOURCES
spectool -g -C ~/rpmbuild/SOURCES packaging/fedora/middle-drag-gestures.spec

rpmbuild -ba packaging/fedora/middle-drag-gestures.spec
sudo dnf install ~/rpmbuild/RPMS/noarch/middle-drag-gestures-*.rpm
```

Or skip the build entirely: install the `.rpm` asset attached to each
[GitHub release](https://github.com/TahmidSwad/middle-drag-gestures/releases):

```bash
sudo dnf install https://github.com/TahmidSwad/middle-drag-gestures/releases/download/v0.1.3/middle-drag-gestures-0.1.3-1.fc44.noarch.rpm
```

The unit **enables itself**. Fedora's default policy for user units is
`disable *` (`/usr/lib/systemd/user-preset/99-default-disable.preset`), and
`%post` applies that policy with `systemctl --global preset` - so the package
ships `50-middle-drag-gestures.preset`, without which it installs dead in
every account. With it, preset resolves to `enabled` and a symlink appears in
`/etc/systemd/user/graphical-session.target.wants/` for every account.

A package still cannot act inside *your* session, so afterwards:

```bash
gnome-extensions enable middle-drag-gestures@swad     # immediate
systemctl --user start middle-drag-daemon.service     # immediate; already enabled
```

`start` only covers the current session - the next login starts the daemon
by itself.

**No account changes are needed.** `dnf install` does not touch your groups,
and it does not have to: the packaged rule tags `/dev/uinput` and every input
device with `uaccess`, so logind grants the session its ACL when you log in -
the daemon opens both device classes with zero supplementary groups. (Older
releases relied on `sudo usermod -aG input "$USER"`; if you still carry that
membership it is simply redundant now, and the package leaves it alone.)

> **Verified** on Fedora 44 / GNOME Shell 50.5 (2026-10-03): `rpmbuild`
> completed with no unpackaged files, `rpm -V` clean after install, the udev
> rule really fired (`/dev/uinput` → `0660 root:input`, and one second after
> login the session held `user:swad:rw-` on `/dev/uinput` and on all 20 input
> nodes; `setpriv --clear-groups` then opened uinput, a keyboard and a mouse
> with zero supplementary groups), `gsettings` resolved the system schema
> (`threshold = 100`), the extension reached `State: ACTIVE` in a running
> Shell, and the daemon grabbed the mouse and answered `GetStatus` over
> D-Bus. Installing a second time after `dnf remove` reproduced all of it.
> The preset's effect was checked with `systemctl --root … --global preset`
> in a throwaway root: `disabled` without the preset file, `enabled` with it.

---

## 4. Manual installation

<details>
<summary>For people who prefer to do every step themselves</summary>

```bash
UUID=middle-drag-gestures@swad

# 1. extension
mkdir -p ~/.local/share/gnome-shell/extensions/$UUID/schemas
cp extension/$UUID/{extension.js,prefs.js,metadata.json,stylesheet.css,LICENSE} \
   ~/.local/share/gnome-shell/extensions/$UUID/
cp extension/$UUID/schemas/*.xml \
   ~/.local/share/gnome-shell/extensions/$UUID/schemas/
glib-compile-schemas ~/.local/share/gnome-shell/extensions/$UUID/schemas/

# 2. schema for the daemon
mkdir -p ~/.local/share/glib-2.0/schemas
cp extension/$UUID/schemas/*.xml ~/.local/share/glib-2.0/schemas/
glib-compile-schemas ~/.local/share/glib-2.0/schemas/

# 3. daemon
install -D -m 0755 daemon/middle-drag-daemon.py ~/.local/bin/middle-drag-daemon.py

# 4. systemd user unit
install -D -m 0644 daemon/middle-drag-daemon.service \
    ~/.config/systemd/user/middle-drag-daemon.service
systemctl --user daemon-reload

# 5. udev rule (root)
sudo install -m 0644 udev/70-middle-drag-uaccess.rules \
    /etc/udev/rules.d/70-middle-drag-uaccess.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
sudo udevadm trigger --subsystem-match=input

# 6. enable
gnome-extensions enable $UUID
systemctl --user enable --now middle-drag-daemon.service
```

</details>

---

## 5. Enabling, disabling, removing

```bash
./scripts/enable.sh            # extension on + daemon started
./scripts/disable.sh           # both off, nothing removed
./scripts/uninstall.sh         # remove every file
./scripts/uninstall.sh --purge # ...plus settings, state and group note
./scripts/verify-clean.sh      # exit 0 only if nothing is left
./scripts/verify-clean.sh --purge
```

Equivalent by hand:

```bash
systemctl --user enable --now middle-drag-daemon.service
gnome-extensions enable middle-drag-gestures@swad

systemctl --user disable --now middle-drag-daemon.service
gnome-extensions disable middle-drag-gestures@swad
```

Uninstalling deliberately **keeps** two things, and says so:

* your dconf settings under `org.gnome.shell.extensions.middle-drag`
* an `input` group membership - other software may need it

`--purge` removes both, plus the install state file, and drops the `input`
membership **only** when the install state file says *this project* added it,
which only a release from before the uaccess rule can claim - a membership
you already had yourself is never touched. Releases that install today never
modify groups at all, so there is usually nothing to undo: access comes from
the uaccess ACL described in [§2 Permissions](#2-permissions), which the
removal of the udev rule takes back with it.

### Removing the RPM

```bash
gnome-extensions disable middle-drag-gestures@swad        # BEFORE removal
sudo dnf remove middle-drag-gestures
```

`dnf remove` takes care of the files, rebuilds the GSettings cache (a later
`gsettings get` correctly reports *No such schema*), stops the daemon
gracefully — the journal shows `SIGTERM` → `virtual mouse removed` →
`physical mouse released` — and clears the enable symlink, even though the
scriptlet runs as root. How it reaches into your session: `%systemd_user_preun`
calls Fedora's `systemd-update-helper remove-user-units`, which runs one
`systemctl --global disable` (that is the symlink, in
`/etc/systemd/user/…wants`) and then `systemctl --user -M NN@ disable --now`
against every running `user@NN` (that is the daemon, stopped in place). No
manual `systemctl` line is needed for either half.

That helper is only invoked `if [ -x /usr/lib/systemd/systemd-update-helper ]`,
so a system without it - a non-Fedora rpm distro installing this RPM - would
get neither half; there, run the second half yourself:

```bash
systemctl --user disable --now middle-drag-daemon.service
```

Two things it cannot reach, because both live in your session:

* **The `enabled-extensions` entry.** A package cannot write your dconf, so
  the uuid stays behind and GNOME Shell keeps reporting the extension as
  `Enabled: Yes` against a path that no longer exists, until the next login.
  Disable *before* removing. If you already removed it, filter the uuid out
  yourself (do **not** reset the key — that would drop your other
  extensions):

  ```bash
  gsettings set org.gnome.shell enabled-extensions \
    "$(gsettings get org.gnome.shell enabled-extensions \
        | sed -e "s/'middle-drag-gestures@swad', //g" \
              -e "s/, 'middle-drag-gestures@swad'//g" \
              -e "s/'middle-drag-gestures@swad'//g")"
  ```

* **`/dev/uinput` keeps `0660 root:input`** until the next reboot: udev
  reloads the rule set but does not recompute permissions on a node it no
  longer matches.

`./scripts/verify-clean.sh` fails on the first of these, so run it after
removing.

### Proving it is gone

`verify-clean.sh` is the counterpart of `install.sh`: it asserts every path
the installer writes, the systemd enabled symlink, the running daemon, the
gsettings entries and (with `--purge`) dconf and the install state. It prints
one `ok:` line per check, `FAIL:` naming anything left behind, and exits
non-zero if the machine is not clean:

```bash
./scripts/verify-clean.sh
#   CLEAN: no trace of Middle-Drag Gestures remains.
```

By default it judges the whole machine. When only one method matters - or
when one of them is deliberately still installed - narrow it:

```bash
./scripts/verify-clean.sh --scope=script   # what install.sh wrote (~/.local, ~/.config, /etc/udev)
./scripts/verify-clean.sh --scope=system    # what the RPM owns (/usr, the package)
```

A narrow run never hides what it skipped: a live RPM install reports
`note: rpm package is installed but out of scope for --scope=script`, and
`enabled-extensions`/dconf are judged under `all` only, because those keys
are not labelled with the method that wrote them.

**Running the scripts in a throwaway `HOME` is safe.** They check first
whether `$HOME` is actually your own and, if not, skip everything that
would reach the *live* session - `gsettings` writes (which go through the
running dconf service, not through `HOME`), `gnome-extensions`, and your
`systemctl --user`. Each skip is printed as `skipped ...`. Without that
guard, a test run could disable your real extension: the test matrix once
stopped a working daemon with SIGTERM and removed the uuid from
`enabled-extensions`.

After uninstalling, **log out and log back in** so GNOME Shell drops the
extension completely - it only rescans extension directories at login.

---

## 6. Verifying the installation

```bash
# extension
gnome-extensions info middle-drag-gestures@swad
#   Enabled: Yes
#   State: ACTIVE

# daemon
systemctl --user status middle-drag-daemon.service
#   Active: active (running)

journalctl --user -u middle-drag-daemon.service -n 20 --no-pager
#   … physical mouse grabbed; middle button reserved (threshold=100px …)

# D-Bus service
gdbus introspect --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag

gdbus call --session \
  --dest org.gnome.Shell.Extensions.MiddleDrag \
  --object-path /org/gnome/Shell/Extensions/MiddleDrag \
  --method org.gnome.Shell.Extensions.MiddleDrag.GetStatus

# automatic discovery
python3 ~/.local/bin/middle-drag-daemon.py --list-devices
```

Then hold the middle button, drag left, and you should land on the next
workspace.

---

## 7. Configuration

```bash
gnome-extensions prefs middle-drag-gestures@swad
```

or with `gsettings` directly:

```bash
SCHEMA=org.gnome.shell.extensions.middle-drag

gsettings list-recursively $SCHEMA
gsettings set $SCHEMA threshold 150
gsettings set $SCHEMA enabled false
gsettings set $SCHEMA left-action 'previous-workspace'
gsettings set $SCHEMA device auto
```

Available actions: `none`, `next-workspace`, `previous-workspace`,
`show-overview`, `hide-overview`.

Changes are picked up by the running daemon immediately - no restart needed.

The daemon also accepts command-line overrides, handy for a one-off run in
the foreground:

| flag | effect |
| ---- | ------ |
| `--device PATH` | grab this device instead of the `device` setting (`auto` picks the first match) |
| `--threshold PIXELS` | use this threshold for this run instead of the `threshold` setting |
| `--list-devices` | print every suitable input device and exit |
| `-v` / `--verbose` | debug logging, including each detected gesture |

---

## 8. Logs

```bash
journalctl --user -u middle-drag-daemon.service -f     # follow the daemon
journalctl -b /usr/bin/gnome-shell --no-pager | grep MiddleDrag   # extension
```

For a verbose daemon run:

```bash
systemctl --user stop middle-drag-daemon.service
python3 ~/.local/bin/middle-drag-daemon.py --verbose
```

Something not working? See [troubleshooting.md](troubleshooting.md).
