#!/usr/bin/env bash
set -euo pipefail

# write-launcher.sh
# Thin shell wrapper around write_launcher.py.
# Creates a shell launcher script and .desktop file for a Wine app.
#
# Usage: write-launcher.sh [--dry-run] <config.json>
#   config JSON fields:
#     - app_name: string (required)
#     - exe_path: string (required)
#     - wine_prefix: string (default: ~/.wine)
#     - profile: string (default: "default")
#     - extra_flags: string[] (optional Wine/Electron flags)
#     - env_vars: object (optional env vars)
#     - icon_name: string (optional, default: app_name)
#     - categories: string (optional, default: "Utility")
#     - desktop_shortcut: boolean (optional, default: true)
#
# Output: JSON

dry_run=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run="--dry-run"; shift ;;
    --) shift; break ;;
    -*) echo '{"status":"error","error":"Unknown option: '"$1"'"}'; exit 1 ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ]; then
  echo '{"status":"error","error":"Usage: write-launcher.sh [--dry-run] <config.json>"}'
  exit 1
fi

config_file="$1"
if [ ! -f "$config_file" ]; then
  echo "{\"status\":\"error\",\"error\":\"Config file not found: $config_file\"}"
  exit 1
fi

launcher_script="$(dirname "$(realpath "$0")")/write_launcher.py"
exec python3 "$launcher_script" $dry_run "$config_file"
