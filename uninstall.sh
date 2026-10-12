#!/bin/bash
# Remove the Govee plugin. --purge also deletes the API key, groups and state;
# --keep-config keeps them without asking.

set -euo pipefail

purge=${1:-}
if [[ -n $purge && $purge != "--purge" && $purge != "--keep-config" ]] || (( $# > 1 )); then
  echo "usage: ./uninstall.sh [--purge | --keep-config]" >&2
  exit 2
fi

# XDG base directories must be absolute; anything else means the default.
xdg() { if [[ ${1:-} == /* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

plugin_id="com.eldtechnologies.govee"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"
config_dir="$(xdg "${XDG_CONFIG_HOME:-}" "$HOME/.config")/eld-govee"
state_dir="$(xdg "${XDG_STATE_HOME:-}" "$HOME/.local/state")/eld-govee"
bin_link="$HOME/.local/bin/eld-govee"
hooks_dir="$HOME/.config/omarchy/hooks/theme-set.d"

omarchy plugin disable "$plugin_id" 2>/dev/null || true
if [[ -L $plugin_dir ]]; then rm "$plugin_dir"; else rm -rf "$plugin_dir"; fi
# Only our own link, and only our own theme hook.
if [[ -L $bin_link && $(readlink "$bin_link") == "$plugin_dir/bin/eld-govee" ]]; then rm "$bin_link"; fi
if [[ -f $hooks_dir/eld-govee ]] && grep -q "Installed by eld-govee" "$hooks_dir/eld-govee"; then
  rm "$hooks_dir/eld-govee"
fi
rm -f "$hooks_dir"/.eld-govee.*.tmp "$hooks_dir"/eld-govee.tmp.*
omarchy-shell shell rescanPlugins 2>/dev/null || true

if [[ -z $purge && -t 0 ]]; then
  read -rp "Delete the stored API key, groups and state too? [y/N] " answer || answer=""
  if [[ $answer == [yY]* ]]; then purge="--purge"; fi
fi
if [[ $purge == "--purge" ]]; then
  rm -rf "$config_dir" "$state_dir"
  if command -v secret-tool >/dev/null && ! error=$(secret-tool clear service eld-govee 2>&1); then
    # No Secret Service at all means there is no key there to delete.
    if ! grep -qE "org\.freedesktop\.secrets was not provided by any|ServiceUnknown|Cannot autolaunch D-Bus|Cannot spawn a message bus|DBUS_SESSION_BUS_ADDRESS" <<<"$error"; then
      echo "Removed, but the keyring did not delete the API key ($error). Remove it with:" >&2
      echo "  secret-tool clear service eld-govee" >&2
      exit 1
    fi
  fi
  echo "Removed. Deleting the local copy does not revoke the API key with Govee."
else
  echo "Removed. Your config is still in $config_dir"
fi
