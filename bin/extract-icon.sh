#!/usr/bin/env bash

# extract-icon.sh
# Extracts icons from a PE executable, converts them to PNG,
# and installs them into the hicolor icon theme.
#
# Usage: extract-icon.sh <exe_path> [--output-dir <dir>]
# Output: JSON

exe_path="${1:?Usage: extract-icon.sh <exe_path> [--output-dir <dir>]}"
shift
exe_path="$(realpath -- "$exe_path")"

output_dir="${HOME}/.local/share/icons"

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    *) echo "{\"error\":\"Unknown option: $1\"}"; exit 1 ;;
  esac
done

mkdir -p "$output_dir"

exe_name="$(basename "$exe_path" .exe | tr '[:upper:]' '[:lower:]')"

if ! file -b "$exe_path" | grep -Eqi 'PE32|PE32+'; then
  echo "{\"error\":\"Not a PE executable: $exe_path\"}"
  exit 1
fi

if ! command -v magick &>/dev/null; then
  echo "{\"error\":\"Missing ImageMagick\",\"hint\":\"sudo pacman -S imagemagick\"}"
  exit 1
fi

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
  # JSON-escape the error message
  error_json=$(echo "$error_msg" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')
  echo "{\"error\":$error_json}"
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
  echo "{\"error\":\"No icons extracted\"}"
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

gtk-update-icon-cache "$theme_dir" &>/dev/null || true

# ---- Output JSON ----
cat <<JSONEOF
{
  "app_name": "$exe_name",
  "icon_count": $icon_count,
  "sizes": $installed_entries,
  "icon_theme_path": "$theme_dir"
}
JSONEOF
