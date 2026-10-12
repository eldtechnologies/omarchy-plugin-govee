#!/bin/bash
# Remove the Govee plugin. --purge also deletes the API key, groups and state.

set -euo pipefail

plugin_id="com.eldtechnologies.govee"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/eld-govee"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/eld-govee"

omarchy plugin disable "$plugin_id" 2>/dev/null || true
if [[ -L $plugin_dir ]]; then rm "$plugin_dir"; else rm -rf "$plugin_dir"; fi
rm -f "$HOME/.local/bin/eld-govee"
rm -f "$HOME/.config/omarchy/hooks/theme-set.d/eld-govee"
omarchy-shell shell rescanPlugins 2>/dev/null || true

purge=${1:-}
if [[ $purge != "--purge" && $purge != "--keep-config" && -t 0 ]]; then
  read -rp "Delete the stored API key, groups and state too? [y/N] " answer
  [[ $answer == [yY]* ]] && purge="--purge"
fi
if [[ $purge == "--purge" ]]; then
  rm -rf "$config_dir" "$state_dir"
  if command -v secret-tool >/dev/null; then
    secret-tool clear service eld-govee 2>/dev/null || true
  fi
  echo "Removed. Deleting the local copy does not revoke the API key with Govee."
else
  echo "Removed. Your config is still in $config_dir"
fi
