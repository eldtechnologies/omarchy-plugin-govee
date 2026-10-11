# Changelog

All notable changes to this plugin. The version is set in `manifest.json`;
`eld-govee --version` reads it from there.

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
