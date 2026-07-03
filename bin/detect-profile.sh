#!/usr/bin/env bash
set -euo pipefail

# detect-profile.sh
# Analyzes a Windows executable and its directory to determine
# the app type, metadata, and recommended optimizations.
#
# Usage: detect-profile.sh <exe_or_lnk_path>
# Output: JSON to stdout

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
  # JSON-escape a string read from stdin.
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()), end="")'
}

# ---- Argument validation ----
if [ $# -lt 1 ]; then
  json_error "Usage: detect-profile.sh <exe_or_lnk_path>"
  exit 1
fi

input_path="$1"

if [ ! -e "$input_path" ]; then
  json_error "File not found: $input_path" "Provide a path to a Windows .exe or .lnk file"
  exit 1
fi

input_path="$(realpath "$input_path")"

# ---- Resolve .lnk to target exe ----
if file -b "$input_path" | grep -Eqi 'MS windows shortcut'; then
  local_base_path=$(strings "$input_path" 2>/dev/null | grep -E '^[A-Z]:\\' | head -1 || true)
  printf '{"status":"error","error":"Input is a .lnk shortcut. Resolve the actual .exe path first.","lnk_target":%s}\n' "$(echo "$local_base_path" | json_escape)"
  exit 1
fi

# ---- Validate it's a PE ----
if ! file -b "$input_path" | grep -Eqi 'PE32|PE32+'; then
  json_error "Not a Windows PE executable: $input_path" "Provide a Windows .exe file"
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
warnings=()
app_name=""
if command -v python3 &>/dev/null; then
  version_script="$(dirname "$(realpath "$0")")/pe_read_version.py"
  version_result=$(python3 "$version_script" "$input_path" 2>&1) || {
    warnings+=("pe_read_version.py failed: $(echo "$version_result" | head -1)")
  }
  app_name=$(echo "$version_result" | python3 -c "import json,sys;print(json.load(sys.stdin).get('app_name',''))" 2>/dev/null || true)
else
  warnings+=("python3 not found; using filename as app name")
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
vulkan_hint=""
if command -v vulkaninfo &>/dev/null; then
  if vulkaninfo --summary 2>/dev/null | grep -qi 'GPU0'; then
    vulkan_available=true
  else
    vulkan_hint="vulkaninfo found but no GPU0 detected"
  fi
else
  vulkan_hint="Install vulkan-tools to verify Vulkan support"
fi

# ---- Icon availability ----
has_icons=false
icon_count=0
if command -v wrestool &>/dev/null; then
  icon_count=$(wrestool -l "$input_path" 2>/dev/null | grep -c '\-\-type=3' || true)
  if [ "$icon_count" -gt 0 ]; then
    has_icons=true
  fi
else
  warnings+=("wrestool not found; cannot verify icon availability")
fi

# ---- Generate Electron flags if applicable ----
electron_flags=()
if [ "$profile" = "electron" ]; then
  electron_flags+=("--no-sandbox" "--disable-gpu" "--disable-accelerated-2d-canvas")
  electron_flags+=("--disable-gpu-compositing" "--disk-cache-size=0")
  electron_flags+=("--disable-background-networking")
fi

# ---- Build arrays safely ----
reasons_json="["
first=true
for r in "${reasons[@]}"; do
  $first || reasons_json+=","
  reasons_json+=$(echo "$r" | json_escape)
  first=false
done
reasons_json+="]"

warnings_json="["
first=true
for w in "${warnings[@]}"; do
  $first || warnings_json+=","
  warnings_json+=$(echo "$w" | json_escape)
  first=false
done
warnings_json+="]"

flags_json="["
first=true
for f in "${electron_flags[@]}"; do
  $first || flags_json+=","
  flags_json+=$(echo "$f" | json_escape)
  first=false
done
flags_json+="]"

# ---- Output JSON ----
cat <<JSONEOF
{
  "status": "ok",
  "app_name": $(echo "$app_name" | json_escape),
  "exe_path": $(echo "$input_path" | json_escape),
  "exe_dir": $(echo "$exe_dir" | json_escape),
  "arch": "$arch",
  "profile": "$profile",
  "profile_confidence": "$confidence",
  "profile_reasons": $reasons_json,
  "wine_prefix": $(echo "${WINEPREFIX:-$HOME/.wine}" | json_escape),
  "dxvk_recommended": $dxvk_recommended,
  "vulkan_available": $vulkan_available,
  "vulkan_hint": $(echo "$vulkan_hint" | json_escape),
  "has_icons": $has_icons,
  "icon_count": $icon_count,
  "electron_flags": $flags_json,
  "warnings": $warnings_json
}
JSONEOF
