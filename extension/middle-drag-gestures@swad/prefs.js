import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
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


export default class MiddleDragPreferences extends ExtensionPreferences {

    fillPreferencesWindow(window) {
        window.set_default_size(640, 720);

        const settings = this.getSettings();

        const page = new Adw.PreferencesPage();
        window.add(page);

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
