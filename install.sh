#!/bin/bash
# Copies both status line scripts into the Claude config dir and points settings.json at them.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "install: jq is required (brew install jq)" >&2; exit 1; }

src=$(cd "$(dirname "$0")" && pwd)
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dest="$config_dir/claude-statusline"
settings="$config_dir/settings.json"

mkdir -p "$dest"
cp "$src/statusline-command.sh" "$src/subagent-statusline.sh" "$dest/"
chmod +x "$dest/statusline-command.sh" "$dest/subagent-statusline.sh"

if [ -f "$settings" ]; then
  cp "$settings" "$settings.bak"
else
  printf '{}\n' > "$settings"
fi

tmp=$(mktemp)
jq --arg main "bash $dest/statusline-command.sh" --arg sub "bash $dest/subagent-statusline.sh" '
  .statusLine = {type: "command", command: $main, refreshInterval: 60}
  | .subagentStatusLine = {type: "command", command: $sub}
' "$settings" > "$tmp"
mv "$tmp" "$settings"

echo "installed: $settings now runs $dest/statusline-command.sh (previous settings in $settings.bak)"
