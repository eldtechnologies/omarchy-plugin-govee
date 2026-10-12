#!/bin/bash
# Install the Govee plugin into the Omarchy shell.
#
#   ./install.sh          copy the plugin into ~/.config/omarchy/plugins
#   ./install.sh --link   symlink this checkout instead (for development)

set -euo pipefail

mode=${1:-}
if [[ -n $mode && $mode != "--link" ]] || (( $# > 1 )); then
  echo "usage: ./install.sh [--link]" >&2
  exit 2
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_id="com.eldtechnologies.govee"
plugins_root="$HOME/.config/omarchy/plugins"
plugin_dir="$plugins_root/$plugin_id"
bin_link="$HOME/.local/bin/eld-govee"

# Check the checkout before touching anything.
omarchy plugin validate "$source_dir"

mkdir -p "$plugins_root"

if [[ $mode == "--link" ]]; then
  if [[ -e $plugin_dir && ! -L $plugin_dir ]]; then
    echo "$plugin_dir exists and is not a symlink; remove it first." >&2
    exit 1
  fi
  ln -sfn "$source_dir" "$plugin_dir"
  echo "Linked. The shell does not watch through symlinks: run 'omarchy restart shell' after QML edits."
else
  if [[ -L $plugin_dir ]]; then rm "$plugin_dir"; fi
  mkdir -p "$plugin_dir/bin"
  for file in manifest.json BarWidget.qml Panel.qml LICENSE README.md CHANGELOG.md; do
    install -m 644 "$source_dir/$file" "$plugin_dir/$file"
  done
  install -m 755 "$source_dir/bin/eld-govee" "$plugin_dir/bin/eld-govee"
fi

# Put eld-govee on the PATH, but never replace someone else's file there.
mkdir -p "$HOME/.local/bin"
if [[ -e $bin_link || -L $bin_link ]] && [[ $(readlink "$bin_link" 2>/dev/null) != "$plugin_dir/bin/eld-govee" ]]; then
  echo "Note: $bin_link already exists and is not ours; left it alone." >&2
else
  ln -sfn "$plugin_dir/bin/eld-govee" "$bin_link"
fi

omarchy-shell shell rescanPlugins
omarchy plugin enable "$plugin_id" --section right

config_home=${XDG_CONFIG_HOME:-}
[[ $config_home == /* ]] || config_home="$HOME/.config"
if [[ -r "$config_home/eld-govee/config.json" ]]; then
  printf '\n%s\n' "Govee is in the bar."
else
  printf '\n%s\n' "Govee is in the bar. Click it to connect your lights,"
  printf '%s\n' "or run: eld-govee setup"
fi
