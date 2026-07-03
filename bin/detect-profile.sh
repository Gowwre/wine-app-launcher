#!/usr/bin/env bash
set -euo pipefail

# detect-profile.sh
# Analyzes a Windows executable and its directory to determine
# the app type, metadata, and recommended optimizations.
#
# Usage: detect-profile.sh <exe_or_lnk_path>
# Output: JSON to stdout

input_path="${1:?Usage: detect-profile.sh <exe_or_lnk_path>}"
input_path="$(realpath "$input_path")"

# ---- Resolve .lnk to target exe ----
if file -b "$input_path" | grep -Eqi 'MS windows shortcut'; then
  # Try to extract LocalBasePath from .lnk binary
  local_base_path=$(strings "$input_path" | grep -E '^[A-Z]:\\' | head -1)
  if [ -n "$local_base_path" ]; then
    echo "{\"warning\":\"Input is a .lnk pointing to $local_base_path\",\"lnk_target\":\"$local_base_path\"}" >&2
  fi
  echo "{\"error\":\"Input is a .lnk shortcut. Resolve the actual .exe path first.\",\"lnk_target\":\"$local_base_path\"}" >&2
  exit 1
fi

# ---- Validate it's a PE ----
if ! file -b "$input_path" | grep -Eqi 'PE32|PE32+'; then
  echo "{\"error\":\"Not a Windows PE executable: $input_path\"}"
  exit 1
fi

exe_dir="$(dirname "$input_path")"
exe_name="$(basename "$input_path" .exe)"
exe_name_lower="$(echo "$exe_name" | tr '[:upper:]' '[:lower:]')"

# ---- Architecture ----
arch="win32"
if file -b "$input_path" | grep -qi 'x86-64'; then
  arch="win64"
fi

# ---- PE metadata (ProductName, FileDescription) ----
app_name=""
if command -v wrestool &>/dev/null; then
  pe_raw=$(wrestool --raw --type=version "$input_path" 2>/dev/null)
  if [ -n "$pe_raw" ]; then
    # Parse VS_VERSION_INFO with Python (extracts StringFileInfo entries)
    app_name=$(python3 -c "
import struct, sys

data = sys.stdin.buffer.read()

def parse_string(data, offset):
    """Read a UTF-16LE null-terminated string at offset."""
    end = offset
    while end + 2 <= len(data):
        if data[end] == 0 and data[end+1] == 0:
            break
        end += 2
    return data[offset:end].decode('utf-16-le', errors='replace')

def find_key(data, key):
    """Find a key in VS_VERSION_INFO StringFileInfo."""
    key_bytes = key.encode('utf-16-le')
    idx = 0
    while True:
        idx = data.find(key_bytes, idx)
        if idx == -1:
            break
        val_start = idx + len(key_bytes)
        if val_start < len(data) and (data[val_start] != 0 or data[val_start+1] != 0):
            return parse_string(data, val_start)
        idx += 2
    return ''

# Try FileDescription first, then ProductName
for k in ['FileDescription', 'ProductName', 'OriginalFilename']:
    v = find_key(data, k)
    if v:
        print(v)
        sys.exit(0)
print('')
" <<< "$pe_raw" 2>/dev/null || true)
  fi
fi
# Fallback: use filename minus .exe as app name
[ -z "$app_name" ] && app_name="$(echo "$exe_name" | sed 's/[^a-zA-Z0-9 ]//g')"
[ -z "$app_name" ] && app_name="$exe_name"

# ---- Detect app type ----
profile="default"
confidence="low"
reasons=()

# Check for Electron
if ls "$exe_dir"/chrome_*.pak &>/dev/null 2>&1; then
  profile="electron"
  confidence="high"
  reasons+=("chrome_*.pak files found")
fi
if ls "$exe_dir"/vk_swiftshader.dll &>/dev/null 2>&1; then
  [ "$profile" != "electron" ] && profile="electron" && confidence="medium"
  reasons+=("vk_swiftshader.dll found")
fi
if ls "$exe_dir"/libEGL.dll &>/dev/null 2>&1; then
  [ "$profile" != "electron" ] && profile="electron" && confidence="medium"
  reasons+=("libEGL.dll found")
fi
if strings "$input_path" 2>/dev/null | grep -qi 'electron_node' 2>/dev/null; then
  profile="electron"
  confidence="high"
  reasons+=("electron_node symbols found in binary")
fi

# Check for Unity game
if [ -f "$exe_dir/UnityPlayer.dll" ] || ls "$exe_dir"/UnityPlayer*.dll &>/dev/null 2>&1; then
  profile="game"
  confidence="high"
  reasons+=("UnityPlayer.dll found")
fi

# Check for common game engines
if ls "$exe_dir"/*.pak &>/dev/null 2>&1 && [ "$profile" = "default" ]; then
  # Could be Unreal Engine or other
  if strings "$input_path" 2>/dev/null | grep -qi 'unreal\|ue4\|ue5' 2>/dev/null; then
    profile="game"
    confidence="medium"
    reasons+=("Unreal Engine game detected")
  fi
fi

# ---- DXVK recommendation ----
dxvk_recommended=false
if [ "$profile" = "electron" ] || [ "$profile" = "game" ]; then
  dxvk_recommended=true
fi

# Check Vulkan availability
vulkan_available=false
if command -v vulkaninfo &>/dev/null; then
  if vulkaninfo --summary 2>/dev/null | grep -qi 'GPU0'; then
    vulkan_available=true
  fi
fi

# ---- Icon availability ----
has_icons=false
icon_count=0
if command -v wrestool &>/dev/null; then
  icon_count=$(wrestool -l "$input_path" 2>/dev/null | grep -c '\-\-type=3' || true)
  if [ "$icon_count" -gt 0 ]; then
    has_icons=true
  fi
fi

# ---- Generate Electron flags if applicable ----
electron_flags=()
if [ "$profile" = "electron" ]; then
  electron_flags+=("--no-sandbox" "--disable-gpu" "--disable-accelerated-2d-canvas")
  electron_flags+=("--disable-gpu-compositing" "--disk-cache-size=0")
  electron_flags+=("--disable-background-networking")
fi

# ---- Output JSON ----
cat <<JSONEOF
{
  "app_name": "$app_name",
  "exe_path": "$input_path",
  "exe_dir": "$exe_dir",
  "arch": "$arch",
  "profile": "$profile",
  "profile_confidence": "$confidence",
  "profile_reasons": [$(printf '"%s",' "${reasons[@]}" | sed 's/,$//')],
  "wine_prefix": "${WINEPREFIX:-$HOME/.wine}",
  "dxvk_recommended": $dxvk_recommended,
  "vulkan_available": $vulkan_available,
  "has_icons": $has_icons,
  "icon_count": $icon_count,
  "electron_flags": [$(printf '"%s",' "${electron_flags[@]}" | sed 's/,$//')]
}
JSONEOF
