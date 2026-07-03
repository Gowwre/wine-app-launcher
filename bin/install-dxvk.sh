#!/usr/bin/env bash
set -euo pipefail

# install-dxvk.sh
# Installs DXVK (D3D9/10/11 → Vulkan translation) for a Wine prefix.
#
# Usage: install-dxvk.sh [--prefix <path>] [--force]
# Output: JSON

prefix="${WINEPREFIX:-$HOME/.wine}"
force=false

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --force) force=true; shift ;;
    *) echo "{\"error\":\"Unknown option: $1\"}"; exit 1 ;;
  esac
done

# ---- Validate prefix ----
if [ ! -f "$prefix/system.reg" ]; then
  echo "{\"error\":\"Not a valid Wine prefix: $prefix (no system.reg)\"}"
  exit 1
fi

# ---- Check Vulkan ----
vulkan_ok=false
if command -v vulkaninfo &>/dev/null; then
  if vulkaninfo --summary 2>/dev/null | grep -qi 'GPU0'; then
    vulkan_ok=true
  fi
fi

if ! $vulkan_ok; then
  hint=""
  if ! command -v vulkaninfo &>/dev/null; then
    hint="Install vulkan-tools"
  fi
  echo "{\"error\":\"No Vulkan GPU detected\",\"hint\":\"$hint\",\"dxvk_not_installed\":true}"
  exit 1
fi

# ---- Detect DXVK installation sources (in priority order) ----
dxvk_sources=()

# 1. System setup_dxvk (Arch/CachyOS package: dxvk-mingw-git)
if command -v setup_dxvk &>/dev/null; then
  dxvk_sources+=("setup_dxvk")
fi
# 2. /usr/share/dxvk with script
if [ -f "/usr/share/dxvk/setup_dxvk.sh" ]; then
  dxvk_sources+=("system_script")
fi
# 3. winetricks
if command -v winetricks &>/dev/null; then
  dxvk_sources+=("winetricks")
fi

if [ ${#dxvk_sources[@]} -eq 0 ]; then
  cat <<JSONEOF
{
  "error": "No DXVK installation method found",
  "hint": "Install dxvk-mingw-git (Arch) / dxvk (Debian/Ubuntu) / dxvk-bin (AUR) or install winetricks",
  "dxvk_not_installed": true
}
JSONEOF
  exit 1
fi

# ---- Install ----
installed_dlls=()
method=""

for src in "${dxvk_sources[@]}"; do
  case "$src" in
    setup_dxvk)
      if WINEPREFIX="$prefix" setup_dxvk install 2>&1; then
        method="setup_dxvk"
        installed_dlls=("d3d8.dll" "d3d9.dll" "d3d10core.dll" "d3d11.dll" "dxgi.dll")
        break
      fi
      ;;
    system_script)
      if WINEPREFIX="$prefix" /usr/share/dxvk/setup_dxvk.sh install 2>&1; then
        method="setup_dxvk.sh"
        installed_dlls=("d3d8.dll" "d3d9.dll" "d3d10core.dll" "d3d11.dll" "dxgi.dll")
        break
      fi
      ;;
    winetricks)
      if WINEPREFIX="$prefix" winetricks -q dxvk 2>&1; then
        method="winetricks"
        installed_dlls=("d3d8.dll" "d3d9.dll" "d3d10core.dll" "d3d11.dll" "dxgi.dll")
        break
      fi
      ;;
  esac
done

if [ ${#installed_dlls[@]} -eq 0 ]; then
  echo "{\"error\":\"All DXVK installation methods failed\"}"
  exit 1
fi

# ---- Output JSON ----
cat <<JSONEOF
{
  "status": "installed",
  "method": "$method",
  "wine_prefix": "$prefix",
  "dlls": [$(printf '"%s",' "${installed_dlls[@]}" | sed 's/,$//')],
  "revert_command": "WINEPREFIX=$prefix setup_dxvk uninstall"
}
JSONEOF
