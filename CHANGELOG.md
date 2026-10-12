# Changelog

All notable changes to this plugin. The version is set in `manifest.json`;
`eld-govee --version` reads it from there.

## 0.3.0 — 2026-10-13

Security hardening, after a full review of the plugin before its marketplace
listing. Nothing found allowed running code, reading the API key or writing
outside the plugin's own files; these fixes are about what a noisy or
hostile device on your network, or a broken answer from Govee, could do.

### Security

- A host on your network could add made-up lights by the thousand, and
  they were remembered for good. Now only replies from a network this
  machine is directly on count, one light per address, at most 64 per scan.
  Between scans only lights on your account or remembered ones keep an
  address, and a light is remembered only after it also answers a status
  request: for a month, and at most 128 of them. A light claimed from two
  addresses is not trusted on the LAN.
- A malformed packet or cloud answer could crash a refresh or a command,
  and a crash mid-command left the panel showing a change that never
  happened. Everything from the network is now type-checked, and a command
  that fails, is stopped or runs out of time rolls back exactly the lights
  it did not change.
- Every helper run has an overall time limit, and the panel stops any run
  that hangs, so a dead network can no longer stall it.
- The LAN reply port is no longer shared (`SO_REUSEADDR`), so another
  program on it is reported instead of silently taking the replies.
- A locked keyring or a dismissed unlock prompt is now an error; the key
  only goes to the config file when there is no keyring at all. Removing
  the key reports failure instead of claiming success. Demo mode can no
  longer change the real key.
- Files are created private from the start, never through a planted link,
  and temporary files are cleaned up. Theme files are read as bounded
  bytes, and only if they are regular files.
- Light names reach `notify-send` and the helper's command line as text,
  never as options or markup.
- Changes to `config.json` are serialised (without holding the lock over
  the network), so quick clicks cannot lose a group or a name, and a slow
  refresh no longer overwrites a newer result.
- The theme hook runs the installed plugin's own copy, never a `PATH`
  lookup, and older hooks are rewritten. `install.sh` and `uninstall.sh`
  never replace or delete files that are not the plugin's. CI actions are
  pinned to commits.

### Added

- `eld-govee forget <light>` (or `--offline` for all that are gone) and a
  **Forget** button, for LAN-only lights.
- The panel shows local network errors, such as another program holding
  the LAN port.

### Changed

- The firewall hint no longer guesses a subnet when it cannot read yours,
  and says that the rule is permanent and covers the whole subnet.
- README: how to remove everything after `omarchy plugin remove`; SECURITY.md
  describes the theme hook, the LAN limits and the key handling exactly.

## 0.2.1 — 2026-10-12

### Fixed

- Error notifications (`--notify`) escape markup, so a light's name is
  always shown as written.

### Added

- `preview.png` for the Omarchy plugin marketplace. README screenshots have
  clean rounded corners.

## 0.2.0 — 2026-10-12

### Added

- **Follow theme.** A light or group can take your Omarchy theme's colour
  whenever the theme changes: a switch in the panel, or
  `eld-govee theme follow`. It uses the colour Omarchy gives RGB keyboards,
  at full strength, and only recolours lights that are on. The plugin adds
  an Omarchy `theme-set` hook while anything follows the theme, and removes
  it when nothing does.
- `theme` as a colour: `eld-govee color Office theme`, or the theme dot in
  the panel.
- **Demo mode** (`eld-govee demo on`): five made-up lights and two groups,
  for screenshots and trying the plugin without Govee hardware. Your own
  config and API key are untouched.

### Fixed

- The version in the panel footer stayed at the old one after an update,
  until the shell restarted.

### Changed

- README: keybindings in Hyprland's Lua format (`bindings.lua`), on keys
  that are free in a stock Omarchy. Screenshots retaken in demo mode.

## 0.1.0 — 2026-10-11

First release.

- Bar bulb that lights while any light is on; middle-click switches
  everything, scroll dims or brightens the lights that are on.
- Panel with a switch, brightness, colour swatches, a hue strip, a white
  temperature slider and scenes for every light.
- Groups of lights with their own controls, made in the panel or with
  `eld-govee group`.
- Rename lights in the panel; LAN-only lights, which only report a model
  number, say "click to rename" until they have a name.
- LAN control first, with the Govee cloud API as fallback, and for names
  and scenes. LAN-only mode without an API key.
- Setup inside the panel; the API key is stored in the desktop keyring.
- Detects when `ufw` blocks LAN replies and shows the rule to add.
- `eld-govee` command for keybindings and scripts, with `--notify`.
