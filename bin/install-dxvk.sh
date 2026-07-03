#!/usr/bin/env bash
set -euo pipefail

# install-dxvk.sh
# Installs DXVK (D3D9/10/11 → Vulkan translation) for a Wine prefix.
#
# Usage: install-dxvk.sh [--prefix <path>] [--force] [--dry-run]
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

# ---- Argument parsing ----
prefix="${WINEPREFIX:-$HOME/.wine}"
force=false
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --force) force=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    *) json_error "Unknown option: $1"; exit 1 ;;
  esac
done

# ---- Validate prefix ----
if [ ! -f "$prefix/system.reg" ]; then
  json_error "Not a valid Wine prefix: $prefix (no system.reg)" "Provide a valid Wine prefix with --prefix or set WINEPREFIX"
  exit 1
fi

# ---- Check Vulkan ----
vulkan_ok=false
vulkan_hint=""
if command -v vulkaninfo &>/dev/null; then
  if vulkaninfo --summary 2>/dev/null | grep -qi 'GPU0'; then
    vulkan_ok=true
  else
    vulkan_hint="vulkaninfo found but no GPU0 detected"
  fi
else
  vulkan_hint="Install vulkan-tools to verify Vulkan support"
fi

if ! $vulkan_ok; then
  json_error "No Vulkan GPU detected" "$vulkan_hint"
  exit 1
fi

# ---- Check existing DXVK ----
system32="$prefix/drive_c/windows/system32"
dxvk_dlls=("d3d8.dll" "d3d9.dll" "d3d10core.dll" "d3d11.dll" "dxgi.dll")
already_installed=false
if [ -d "$system32" ]; then
  already_installed=true
  for dll in "${dxvk_dlls[@]}"; do
    if [ ! -L "$system32/$dll" ]; then
      already_installed=false
      break
    fi
  done
fi

if $already_installed && ! $force; then
  printf '{"status":"ok","state":"already_installed","wine_prefix":%s,"dlls":[%s],"revert_command":%s}\n' \
    "$(echo "$prefix" | json_escape)" \
    "$(printf '"%s",' "${dxvk_dlls[@]}" | sed 's/,$//')" \
    "$(echo "WINEPREFIX=$prefix setup_dxvk uninstall" | json_escape)"
  exit 0
fi

# ---- Detect DXVK installation sources (in priority order) ----
dxvk_sources=()

if command -v setup_dxvk &>/dev/null; then
  dxvk_sources+=("setup_dxvk")
fi
if [ -f "/usr/share/dxvk/setup_dxvk.sh" ]; then
  dxvk_sources+=("system_script")
fi
if command -v winetricks &>/dev/null; then
  dxvk_sources+=("winetricks")
fi

if [ ${#dxvk_sources[@]} -eq 0 ]; then
  json_error "No DXVK installation method found" "Install dxvk-mingw-git (Arch) / dxvk (Debian/Ubuntu) / dxvk-bin (AUR) or install winetricks"
  exit 1
fi

if $dry_run; then
  printf '{"status":"ok","state":"would_install","wine_prefix":%s,"methods":[%s],"dlls":[%s]}\n' \
    "$(echo "$prefix" | json_escape)" \
    "$(printf '"%s",' "${dxvk_sources[@]}" | sed 's/,$//')" \
    "$(printf '"%s",' "${dxvk_dlls[@]}" | sed 's/,$//')"
  exit 0
fi

# ---- Install ----
installed_dlls=()
method=""
attempted=()

for src in "${dxvk_sources[@]}"; do
  case "$src" in
    setup_dxvk)
      attempted+=("setup_dxvk")
      if WINEPREFIX="$prefix" setup_dxvk install 2>&1; then
        method="setup_dxvk"
        installed_dlls=("${dxvk_dlls[@]}")
        break
      fi
      ;;
    system_script)
      attempted+=("setup_dxvk.sh")
      if WINEPREFIX="$prefix" /usr/share/dxvk/setup_dxvk.sh install 2>&1; then
        method="setup_dxvk.sh"
        installed_dlls=("${dxvk_dlls[@]}")
        break
      fi
      ;;
    winetricks)
      attempted+=("winetricks")
      if WINEPREFIX="$prefix" winetricks -q dxvk 2>&1; then
        method="winetricks"
        installed_dlls=("${dxvk_dlls[@]}")
        break
      fi
      ;;
  esac
done

if [ ${#installed_dlls[@]} -eq 0 ]; then
  attempted_json="[$(printf '"%s",' "${attempted[@]}" | sed 's/,$//')]"
  printf '{"status":"error","error":"All DXVK installation methods failed","attempted":%s,"hint":"Check that your Wine prefix is 64-bit and that Vulkan works"}\n' "$attempted_json"
  exit 1
fi

# ---- Output JSON ----
printf '{"status":"ok","state":"installed","method":%s,"wine_prefix":%s,"dlls":[%s],"revert_command":%s}\n' \
  "$(echo "$method" | json_escape)" \
  "$(echo "$prefix" | json_escape)" \
  "$(printf '"%s",' "${installed_dlls[@]}" | sed 's/,$//')" \
  "$(echo "WINEPREFIX=$prefix setup_dxvk uninstall" | json_escape)"
