# AGENTS.md — instructions for coding agents

Project status: **shipped and dormant.** v0.1.3 is the latest release (Fedora 44 /
GNOME 50 / Wayland only — the only configuration tested). Nothing moves without
the user deciding to develop again.

## Read first

`README.md` → `docs/architecture.md` → `docs/installation.md`. This file only
holds what those do not say; do **not** duplicate them here — every fact has one
home, and docs that disagree are a bug.

## Verification battery (run before any commit, all must pass)

```bash
python3 -m unittest discover -s tests      # 37 unit tests
python3 tests/integration_test.py          # full end-to-end (live uinput)
./scripts/verify-extension.sh              # 14 assertions + prefs window
./scripts/package-extension.sh             # bundle incl. LICENSE
bash -n scripts/*.sh tests/*.sh            # every script parses
```

`verify-extension.sh` is the gate that caught the shipped v0.1.1 prefs bug —
never declare work done without it. `verify-clean.sh` must report NOT CLEAN
while the product is installed; that is correct.

## Conventions

- **Commits**: one per phase, identity `swad <swad@localhost>`:
  `git -c user.name='swad' -c user.email='swad@localhost' commit …`
- **`sudo` is the user's, never yours.** Hand them commands; they paste output.
- **Claims must be provable from the repo.** State only Fedora 44 / GNOME 50 /
  Wayland as tested; no extensions.gnome.org submission, ever (history in
  `CHANGELOG.md` may mention it — that stays).
- **The user runs VS Code alongside you.** After editing a file they have open,
  expect a save-conflict dialog: advise *Revert File* for a stale buffer,
  *Overwrite* only for a deliberate edit, then diff-check against HEAD. This
  hazard has already caused one silent README regression (`94166d4`).

## Environment quirks

- Not installed: `make`, `shellcheck`, `spectool`. Use the commands above and
  `curl` for the spec's `Source0` instead.
- RPM layout differs from script layout: the package ships the udev rule at
  `/usr/lib/udev/rules.d/`, `install.sh` puts it at `/etc/udev/rules.d/`.
  Fedora's `brp-mangle-shebangs` rewrites the packaged daemon's shebang to
  `/usr/bin/python3` — expected, not drift.
- Releases: tag → build RPM from the tag archive → publish on GitHub with the
  asset byte-compared to the local build. `README.md` pins the current URL.
