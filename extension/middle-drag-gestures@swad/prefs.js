import Adw from 'gi://Adw';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Gtk from 'gi://Gtk';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';


// Values must stay in sync with the Action enum in
// schemas/org.gnome.shell.extensions.middle-drag.gschema.xml and with
// ACTION_METHODS in daemon/middle-drag-daemon.py.
const ACTIONS = [
    {value: 'none', label: 'Do nothing'},
    {value: 'next-workspace', label: 'Next workspace'},
    {value: 'previous-workspace', label: 'Previous workspace'},
    {value: 'show-overview', label: 'Show Overview'},
    {value: 'hide-overview', label: 'Hide Overview'},
];

const BY_ID_DIR = '/dev/input/by-id';

// The name the daemon (and this extension) put on the session bus; see
// ACTION_METHODS in daemon/middle-drag-daemon.py.
const DAEMON_DBUS_NAME = 'org.gnome.Shell.Extensions.MiddleDrag';

// What to run on a machine that has the extension but no daemon - the state
// you get from installing only the extension bundle, which cannot write to
// /etc/udev/rules.d or manage systemd units.
// install.sh needs the rest of the checkout beside it, so the release
// tarball is fetched rather than the lone script, and the commands are shown
// for reading before they are pasted.  Keep the tag in step with VERSION.
const INSTALL_COMMAND = [
    '# 1. dependencies - the installer prints the right names for your distro too:',
    '#    Fedora:       sudo dnf install python3-evdev python3-dbus python3-gobject',
    '#    Debian/Ubuntu: sudo apt install python3-evdev python3-dbus python3-gi libglib2.0-bin',
    '# 2. install (udev rule + systemd unit + extension + schema, then starts the daemon):',
    'curl -fsSL -o /tmp/middle-drag-gestures.tar.gz https://github.com/TahmidSwad/middle-drag-gestures/archive/refs/tags/v0.1.3.tar.gz',
    'tar -xzf /tmp/middle-drag-gestures.tar.gz -C /tmp',
    'less /tmp/middle-drag-gestures-0.1.3/scripts/install.sh   # optional: read it first',
    'bash /tmp/middle-drag-gestures-0.1.3/scripts/install.sh',
].join('\n');


export default class MiddleDragPreferences extends ExtensionPreferences {

    fillPreferencesWindow(window) {
        window.set_default_size(640, 720);

        const settings = this.getSettings();

        const page = new Adw.PreferencesPage();
        window.add(page);

        page.add(this._statusGroup());
        page.add(this._generalGroup(settings));
        page.add(this._horizontalGroup(settings));
        page.add(this._verticalGroup(settings));
        page.add(this._deviceGroup(settings));
        page.add(this._aboutGroup());

        console.log('[MiddleDrag] preferences loaded');
    }

    // -----------------------------------------------------------------
    // Groups
    // -----------------------------------------------------------------

    _statusGroup() {
        const group = new Adw.PreferencesGroup({
            title: 'Input daemon',
            description: 'Gestures only fire while the background daemon is ' +
                'running - it reads the middle button and hands the gesture ' +
                'to GNOME Shell.',
        });

        const row = new Adw.ActionRow({title: 'Checking\u2026'});
        const icon = new Gtk.Image({icon_name: 'content-loading-symbolic'});
        row.add_suffix(icon);
        group.add(row);

        const installBox = this._installBox();
        installBox.visible = false;
        group.add(installBox);

        const apply = owned => {
            if (owned) {
                row.title = 'Running';
                row.subtitle = `Owns ${DAEMON_DBUS_NAME} on the session bus.`;
                icon.icon_name = 'emblem-ok-symbolic';
                installBox.visible = false;
                return;
            }
            row.title = 'Not running';
            row.subtitle = 'The extension is here, but nothing is reading ' +
                'the middle button yet - run the commands below once, as ' +
                'your own user.';
            icon.icon_name = 'dialog-warning-symbolic';
            installBox.visible = true;
        };

        this._queryDaemon(apply);

        // Live update: while this window is open, the row flips as soon as
        // the installer claims the name (or the daemon stops).
        Gio.DBus.session.signal_subscribe(
            'org.freedesktop.DBus',
            'org.freedesktop.DBus',
            'NameOwnerChanged',
            '/org/freedesktop/DBus',
            'org.freedesktop.DBus',
            Gio.DBusSignalFlags.NONE,
            (_connection, _sender, _path, _interface, _signal, params) => {
                const [name, , owner] = params.deep_unpack();
                if (name === DAEMON_DBUS_NAME)
                    apply(owner !== '');
            });

        return group;
    }

    _queryDaemon(apply) {
        // NameHasOwner(s) -> (b).  Gio.DBus.session.call() takes its
        // arguments positionally: the GVariant *parameters* come before the
        // GVariantType *reply type* - with them swapped, GJS throws a
        // TypeError while marshalling and the preferences window never
        // opens, before any of this runs.
        Gio.DBus.session.call(
            'org.freedesktop.DBus',
            '/org/freedesktop/DBus',
            'org.freedesktop.DBus',
            'NameHasOwner',
            new GLib.Variant('(s)', [DAEMON_DBUS_NAME]),
            new GLib.VariantType('(b)'),
            Gio.DBusCallFlags.NONE,
            -1,
            null,
            (connection, result) => {
                let owned = false;
                try {
                    owned = connection.call_finish(result).deep_unpack()[0];
                } catch (e) {
                    console.error(`[MiddleDrag] daemon lookup failed: ${e}`);
                }
                apply(owned);
            });
    }

    _installBox() {
        const box = new Gtk.Box({
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            margin_start: 12,
            margin_end: 12,
            margin_bottom: 12,
        });

        const note = new Gtk.Label({
            label: 'One-off, with root: the installer checks every ' +
                'dependency before writing a single byte, enables the ' +
                'extension, starts the daemon and says whether a relogin is ' +
                'needed. Requires systemd + udev + GNOME 50.',
            wrap: true,
            xalign: 0,
        });
        box.append(note);

        const buffer = new Gtk.TextBuffer();
        buffer.set_text(INSTALL_COMMAND, -1);
        const view = new Gtk.TextView({
            buffer,
            editable: false,
            cursor_visible: false,
            monospace: true,
            wrap_mode: Gtk.WrapMode.WORD_CHAR,
        });
        const scroll = new Gtk.ScrolledWindow({
            child: view,
            min_content_height: 132,
            hexpand: true,
        });
        scroll.add_css_class('card');
        box.append(scroll);

        const copy = new Gtk.Button({label: 'Copy commands'});
        copy.add_css_class('suggested-action');
        copy.connect('clicked', () => {
            const clipboard = Gdk.Display.get_default()?.get_clipboard();
            if (!clipboard)
                return;
            clipboard.set_text(INSTALL_COMMAND);
            copy.label = 'Copied';
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 2000, () => {
                copy.label = 'Copy commands';
                return GLib.SOURCE_REMOVE;
            });
        });
        box.append(copy);

        return box;
    }

    _generalGroup(settings) {
        const group = new Adw.PreferencesGroup({
            title: 'General',
            description: 'Changes apply immediately — the daemon picks them ' +
                'up without a restart.',
        });

        const enableRow = new Adw.SwitchRow({
            title: 'Enable gestures',
            subtitle: 'Hold the middle mouse button and drag. When off, the ' +
                'middle button behaves normally again.',
        });
        settings.bind('enabled', enableRow, 'active',
            Gio.SettingsBindFlags.DEFAULT);
        group.add(enableRow);

        const thresholdRow = new Adw.SpinRow({
            title: 'Gesture threshold',
            subtitle: 'Pixels of movement before a drag counts as a gesture',
            adjustment: new Gtk.Adjustment({
                lower: 10,
                upper: 1000,
                step_increment: 10,
                page_increment: 50,
            }),
        });
        thresholdRow.value = settings.get_int('threshold');
        thresholdRow.connect('notify::value', () => {
            const value = Math.round(thresholdRow.value);
            if (value !== settings.get_int('threshold'))
                settings.set_int('threshold', value);
        });
        settings.connect('changed::threshold', () => {
            const value = settings.get_int('threshold');
            if (value !== Math.round(thresholdRow.value))
                thresholdRow.value = value;
        });
        group.add(thresholdRow);

        return group;
    }

    _horizontalGroup(settings) {
        const group = new Adw.PreferencesGroup({
            title: 'Horizontal gestures',
            description: 'Drag with the middle button held down.',
        });

        group.add(this._actionRow('Drag left', settings, 'left-action'));
        group.add(this._actionRow('Drag right', settings, 'right-action'));

        return group;
    }

    _verticalGroup(settings) {
        const group = new Adw.PreferencesGroup({
            title: 'Vertical gestures',
            description: 'Positive Y in Linux points downwards, so the ' +
                'mappings below are intentionally not reversed.',
        });

        group.add(this._actionRow('Drag up', settings, 'up-action'));
        group.add(this._actionRow('Drag down', settings, 'down-action'));

        return group;
    }

    _deviceGroup(settings) {
        const group = new Adw.PreferencesGroup({
            title: 'Input device',
            description: 'The daemon grabs this device directly. Keep ' +
                '"Automatic" unless you have several mice.',
        });

        const values = ['auto'];
        const labels = ['Automatic'];

        for (const path of this._listEventDevices()) {
            values.push(path);
            labels.push(path.replace('/dev/input/by-id/', ''));
        }

        // Make sure a manually configured device is selectable even when it
        // is not currently plugged in.
        const configured = settings.get_string('device');
        if (configured && configured !== 'auto' &&
            !values.includes(configured)) {
            values.push(configured);
            labels.push(`${configured} (not present)`);
        }

        const row = new Adw.ComboRow({
            title: 'Mouse',
            subtitle: 'Devices that expose BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, ' +
                'REL_X and REL_Y',
            model: Gtk.StringList.new(labels),
        });

        const sync = () => {
            const index = values.indexOf(settings.get_string('device'));
            const selected = index === -1 ? 0 : index;
            if (row.selected !== selected)
                row.selected = selected;
        };
        sync();

        row.connect('notify::selected', () => {
            const value = values[row.selected];
            if (value && value !== settings.get_string('device'))
                settings.set_string('device', value);
        });
        settings.connect('changed::device', sync);

        group.add(row);
        return group;
    }

    _aboutGroup() {
        const group = new Adw.PreferencesGroup({title: 'About'});

        const info = new Adw.ActionRow({
            title: 'Middle-Drag Gestures',
            subtitle: `Version ${this.metadata.version} · ` +
                `GNOME Shell ${this.metadata['shell-version'].join(', ')} · ` +
                'daemon speaks D-Bus ' +
                'org.gnome.Shell.Extensions.MiddleDrag',
        });
        group.add(info);

        return group;
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    _actionRow(title, settings, key) {
        const values = ACTIONS.map(action => action.value);
        const row = new Adw.ComboRow({
            title,
            model: Gtk.StringList.new(ACTIONS.map(action => action.label)),
        });

        const sync = () => {
            const index = values.indexOf(settings.get_string(key));
            const selected = index === -1 ? 0 : index;
            if (row.selected !== selected)
                row.selected = selected;
        };
        sync();

        row.connect('notify::selected', () => {
            const value = values[row.selected];
            if (value && value !== settings.get_string(key))
                settings.set_string(key, value);
        });
        settings.connect(`changed::${key}`, sync);

        return row;
    }

    _listEventDevices() {
        const paths = [];
        try {
            const dir = Gio.File.new_for_path(BY_ID_DIR);
            const enumerator = dir.enumerate_children(
                'standard::name',
                Gio.FileQueryInfoFlags.NONE,
                null
            );

            const names = [];
            let info;
            while ((info = enumerator.next_file(null)) !== null)
                names.push(info.get_name());
            enumerator.close(null);

            names
                .filter(name => name.includes('-event-'))
                .sort()
                .forEach(name => paths.push(`${BY_ID_DIR}/${name}`));
        } catch (e) {
            // /dev/input/by-id may be unreadable; "Automatic" still works.
        }

        return paths;
    }
}
