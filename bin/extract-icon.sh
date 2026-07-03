#!/usr/bin/env bash
set -euo pipefail

# extract-icon.sh
# Extracts icons from a PE executable, converts them to PNG,
# and installs them into the hicolor icon theme.
#
# Usage: extract-icon.sh <exe_path> [--output-dir <dir>]
# Output: JSON

# ---- Helpers ----
json_error() {
  local msg="$1"
  local hint="${2:-}"
  if [ -n "$hint" ]; then
    echo "{\"status\":\"error\",\"error\":\"$msg\",\"hint\":\"$hint\"}"
  else
    echo "{\"status\":\"error\",\"error\":\"$msg\"}"
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()), end="")'
}

# ---- Argument validation ----
if [ $# -lt 1 ]; then
  json_error "Usage: extract-icon.sh <exe_path> [--output-dir <dir>]"
  exit 1
fi

exe_path="$1"
shift

if [ ! -e "$exe_path" ]; then
  json_error "File not found: $exe_path" "Provide a path to a Windows .exe file"
  exit 1
fi

exe_path="$(realpath -- "$exe_path")"

output_dir="${HOME}/.local/share/icons"

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    *) json_error "Unknown option: $1"; exit 1 ;;
  esac
done

if ! file -b "$exe_path" | grep -Eqi 'PE32|PE32+'; then
  json_error "Not a PE executable: $exe_path" "Provide a Windows .exe file"
  exit 1
fi

if ! command -v magick &>/dev/null; then
  json_error "Missing ImageMagick" "Install imagemagick (e.g., sudo pacman -S imagemagick or sudo apt install imagemagick)"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  json_error "Missing python3" "Install Python 3"
  exit 1
fi

mkdir -p "$output_dir"

exe_name="$(basename "$exe_path" .exe | tr '[:upper:]' '[:lower:]')"

# ---- Extract icons ----
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

icon_script="$(dirname "$(realpath "$0")")/pe_extract_icons.py"
py_err="$work_dir/pe_err.txt"
result=$(python3 "$icon_script" "$exe_path" "$work_dir" "$exe_name" 2>"$py_err") || {
  error_msg="Icon extraction failed"
  if [ -s "$py_err" ]; then
    error_msg=$(head -n 1 "$py_err")
  fi
  if [ -n "$result" ]; then
    parsed=$(echo "$result" | python3 -c "import json,sys;print(json.load(sys.stdin).get('error',''))" 2>/dev/null || true)
    [ -n "$parsed" ] && error_msg="$parsed"
  fi
  error_json=$(echo "$error_msg" | json_escape)
  echo "{\"status\":\"error\",\"error\":$error_json}"
  exit 1
}

sizes=$(echo "$result" | python3 -c "
import json, sys
r = json.load(sys.stdin)
if 'sizes' in r:
    for w, p in r['sizes']:
        print(f'{w}|{p}')
" 2>/dev/null)

if [ -z "$sizes" ]; then
  json_error "No icons extracted" "The executable may not contain usable icon resources"
  exit 1
fi

# ---- Install into hicolor theme ----
installed_entries="["
first=true
while IFS='|' read -r size png_path; do
  size_dir="$output_dir/hicolor/${size}x${size}/apps"
  mkdir -p "$size_dir"
  dst="$size_dir/${exe_name}.png"
  cp "$png_path" "$dst"
  $first || installed_entries+=","
  installed_entries+="{\"size\":$size,\"path\":\"$dst\"}"
  first=false
done <<< "$sizes"
installed_entries+="]"

icon_count=$(echo "$installed_entries" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")

# ---- index.theme ----
theme_dir="$output_dir/hicolor"
if [ ! -f "$theme_dir/index.theme" ]; then
  dirs=$(echo "$installed_entries" | python3 -c "
import json, sys
entries = json.load(sys.stdin)
print(','.join(f\"{e['size']}x{e['size']}/apps\" for e in entries))
")
  cat > "$theme_dir/index.theme" <<EOF
[Icon Theme]
Name=Hicolor
Comment=Fallback icon theme
Directories=$dirs
EOF
fi

cache_updated=false
if gtk-update-icon-cache "$theme_dir" &>/dev/null; then
  cache_updated=true
fi

# ---- Output JSON ----
cat <<JSONEOF
{
  "status": "ok",
  "app_name": $(echo "$exe_name" | json_escape),
  "icon_count": $icon_count,
  "sizes": $installed_entries,
  "icon_theme_path": $(echo "$theme_dir" | json_escape),
  "cache_updated": $cache_updated
}
JSONEOF
