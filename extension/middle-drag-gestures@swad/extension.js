import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';


const BUS_NAME = 'org.gnome.Shell.Extensions.MiddleDrag';
const OBJECT_PATH = '/org/gnome/Shell/Extensions/MiddleDrag';

// The D-Bus API is the contract with the input daemon.  Method names
// describe the *operation*, not the gesture direction, so that the daemon
// can map configured actions onto them (see daemon/middle-drag-daemon.py).
const IFACE_XML = `
<node>
  <interface name="org.gnome.Shell.Extensions.MiddleDrag">
    <method name="PreviousWorkspace"/>
    <method name="NextWorkspace"/>
    <method name="ShowOverview"/>
    <method name="HideOverview"/>
    <method name="GetStatus">
      <arg type="s" direction="out" name="status"/>
    </method>
  </interface>
</node>
`;


export default class MiddleDragGestures extends Extension {

    enable() {
        this._dbusImpl = Gio.DBusExportedObject.wrapJSObject(
            IFACE_XML,
            this
        );

        this._dbusImpl.export(
            Gio.DBus.session,
            OBJECT_PATH
        );

        try {
            const result = Gio.DBus.session.call_sync(
                'org.freedesktop.DBus',
                '/org/freedesktop/DBus',
                'org.freedesktop.DBus',
                'RequestName',
                new GLib.Variant(
                    '(su)',
                    [BUS_NAME, 0]
                ),
                new GLib.VariantType('(u)'),
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );

            const reply = result.deepUnpack()[0];

            console.log(
                `[MiddleDrag] D-Bus RequestName result: ${reply}`
            );

            if (reply !== 1 && reply !== 4) {
                throw new Error(
                    `Failed to acquire D-Bus name: ${reply}`
                );
            }
        } catch (e) {
            console.error(
                `[MiddleDrag] D-Bus registration failed: ${e}`
            );

            this._dbusImpl.unexport();
            this._dbusImpl = null;
            return;
        }

        const settings = this.getSettings();
        console.log(
            `[MiddleDrag] D-Bus service ready (enabled=` +
            `${settings.get_boolean('enabled')}, ` +
            `threshold=${settings.get_int('threshold')}, ` +
            `device=${settings.get_string('device')})`
        );
    }

    disable() {
        if (this._dbusImpl) {
            this._dbusImpl.unexport();
            this._dbusImpl = null;
        }

        try {
            Gio.DBus.session.call_sync(
                'org.freedesktop.DBus',
                '/org/freedesktop/DBus',
                'org.freedesktop.DBus',
                'ReleaseName',
                new GLib.Variant(
                    '(s)',
                    [BUS_NAME]
                ),
                new GLib.VariantType('(u)'),
                Gio.DBusCallFlags.NONE,
                -1,
                null
            );
        } catch (e) {
            console.error(
                `[MiddleDrag] D-Bus release failed: ${e}`
            );
        }

        console.log('[MiddleDrag] D-Bus service disabled');
    }

    // -----------------------------------------------------------------
    // D-Bus methods
    // -----------------------------------------------------------------

    PreviousWorkspace() {
        this._switchWorkspace(-1);
    }

    NextWorkspace() {
        this._switchWorkspace(1);
    }

    ShowOverview() {
        Main.overview.show();
    }

    HideOverview() {
        Main.overview.hide();
    }

    // Introspectable status blob, mainly for docs/troubleshooting.
    GetStatus() {
        const settings = this.getSettings();

        return JSON.stringify({
            uuid: this.uuid,
            version: this.metadata.version,
            shellVersion: this.metadata['shell-version'].join('.'),
            dbusName: BUS_NAME,
            enabled: settings.get_boolean('enabled'),
            threshold: settings.get_int('threshold'),
            device: settings.get_string('device'),
        });
    }

    // -----------------------------------------------------------------

    _switchWorkspace(direction) {
        const wm = global.workspace_manager;

        const current = wm.get_active_workspace_index();
        const targetIndex = current + direction;

        if (targetIndex < 0 ||
            targetIndex >= wm.get_n_workspaces())
            return;

        wm.get_workspace_by_index(targetIndex)
            .activate(global.get_current_time());
    }
}
