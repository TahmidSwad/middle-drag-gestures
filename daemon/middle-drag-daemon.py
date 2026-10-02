#!/usr/bin/env python3

import subprocess
import time

from evdev import InputDevice, UInput, ecodes


DEVICE = "/dev/input/by-id/usb-SIGMACHIP_Usb_Mouse-event-mouse"

THRESHOLD = 100

DBUS_DEST = "org.gnome.Shell.Extensions.MiddleDrag"
DBUS_PATH = "/org/gnome/Shell/Extensions/MiddleDrag"
DBUS_IFACE = "org.gnome.Shell.Extensions.MiddleDrag"


def call_gnome(method):
    result = subprocess.run(
        [
            "gdbus",
            "call",
            "--session",
            "--dest", DBUS_DEST,
            "--object-path", DBUS_PATH,
            "--method", f"{DBUS_IFACE}.{method}",
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"D-Bus error: {result.stderr.strip()}")
    else:
        print(f"Action: {method}")


def create_virtual_mouse():

    capabilities = {
        ecodes.EV_KEY: [
            ecodes.BTN_LEFT,
            ecodes.BTN_RIGHT,
            ecodes.BTN_MIDDLE,
        ],

        ecodes.EV_REL: [
            ecodes.REL_X,
            ecodes.REL_Y,
            ecodes.REL_WHEEL,
            ecodes.REL_HWHEEL,
        ],
    }

    ui = UInput(
        capabilities,
        name="Middle Drag Virtual Mouse",
        version=1,
    )

    time.sleep(0.2)

    print("Virtual mouse created.")

    return ui


def main():

    physical = InputDevice(DEVICE)

    print(f"Physical device: {physical.name}")
    print(f"Physical path:   {physical.path}")

    ui = None

    try:

        ui = create_virtual_mouse()

        physical.grab()

        print("Physical mouse grabbed.")
        print("Middle button is now reserved.")
        print("Press Ctrl+C to stop.")
        print()

        dragging = False
        fired = False

        dx = 0
        dy = 0

        for event in physical.read_loop():

            # -------------------------------------------------
            # BUTTONS
            # -------------------------------------------------

            if event.type == ecodes.EV_KEY:

                # Middle button
                if event.code == ecodes.BTN_MIDDLE:

                    if event.value == 1:
                        dragging = True
                        fired = False
                        dx = 0
                        dy = 0

                        print("MIDDLE DOWN")

                    elif event.value == 0:

                        if dragging:
                            print("MIDDLE UP")

                        dragging = False
                        fired = False

                    # Do NOT forward middle.
                    continue

                # Forward left/right buttons.
                if event.code in (
                    ecodes.BTN_LEFT,
                    ecodes.BTN_RIGHT,
                ):
                    ui.write(
                        event.type,
                        event.code,
                        event.value,
                    )

                    ui.syn()

            # -------------------------------------------------
            # MOUSE MOVEMENT / WHEEL
            # -------------------------------------------------

            elif event.type == ecodes.EV_REL:

                # Forward movement and scrolling.
                ui.write(
                    event.type,
                    event.code,
                    event.value,
                )

                # Track middle drag.
                if dragging and not fired:

                    if event.code == ecodes.REL_X:
                        dx += event.value

                    elif event.code == ecodes.REL_Y:
                        dy += event.value

                    if max(abs(dx), abs(dy)) >= THRESHOLD:

                        fired = True

                        print(
                            f"DRAG: dx={dx}, dy={dy}"
                        )

                        # -------------------------------------------------
                        # REVERSED HORIZONTAL GESTURES
                        # -------------------------------------------------

                        if abs(dx) > abs(dy):

                            # Physical LEFT → Next workspace
                            if dx < 0:
                                print(
                                    "GESTURE: LEFT → NEXT WORKSPACE"
                                )
                                call_gnome(
                                    "NextWorkspace"
                                )

                            # Physical RIGHT → Previous workspace
                            else:
                                print(
                                    "GESTURE: RIGHT → PREVIOUS WORKSPACE"
                                )
                                call_gnome(
                                    "PreviousWorkspace"
                                )

                        # -------------------------------------------------
                        # REVERSED VERTICAL GESTURES
                        # -------------------------------------------------

                        else:

                            # Physical UP → Close Overview
                            if dy < 0:
                                print(
                                    "GESTURE: UP → CLOSE OVERVIEW"
                                )
                                call_gnome(
                                    "OverviewDown"
                                )

                            # Physical DOWN → Open Overview
                            else:
                                print(
                                    "GESTURE: DOWN → OPEN OVERVIEW"
                                )
                                call_gnome(
                                    "OverviewUp"
                                )

                ui.syn()

            elif event.type == ecodes.EV_SYN:
                continue

    except KeyboardInterrupt:

        print()
        print("Stopping...")

    finally:

        try:
            physical.ungrab()
            print("Physical mouse released.")
        except Exception:
            pass

        if ui is not None:
            try:
                ui.close()
                print("Virtual mouse removed.")
            except Exception:
                pass


if __name__ == "__main__":
    main()
