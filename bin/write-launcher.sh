#!/usr/bin/env bash
set -euo pipefail

# write-launcher.sh
# Creates a shell launcher script and .desktop file for a Wine app.
#
# Usage: write-launcher.sh <config.json>
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

if [ $# -lt 1 ]; then
  echo "{\"error\":\"Usage: write-launcher.sh <config.json>\"}"
  exit 1
fi

config_file="$1"
if [ ! -f "$config_file" ]; then
  echo "{\"error\":\"Config file not found: $config_file\"}"
  exit 1
fi

# Parse config using Python (more reliable than jq for complex JSON)
eval "$(python3 -c "
import json, os, sys

with open('$config_file') as f:
    cfg = json.load(f)

app_name = cfg.get('app_name', '').strip()
exe_path = cfg.get('exe_path', '').strip()

if not app_name or not exe_path:
    print('error=missing_required')
    sys.exit(1)

wine_prefix = cfg.get('wine_prefix', os.path.expanduser('~/.wine'))
profile = cfg.get('profile', 'default')
extra_flags = cfg.get('extra_flags', [])
env_vars = cfg.get('env_vars', {})
icon_name = cfg.get('icon_name', app_name.lower())
categories = cfg.get('categories', 'Utility')
desktop_shortcut = cfg.get('desktop_shortcut', True)

# Determine Windows path from Unix path
import subprocess
result = subprocess.run(
    ['winepath', '-w', exe_path],
    capture_output=True, text=True, timeout=5
)
win_path = result.stdout.strip() if result.returncode == 0 else ''

# Escape for bash
import shlex
print(f'APP_NAME={shlex.quote(app_name)}')
print(f'EXE_PATH={shlex.quote(exe_path)}')
print(f'WIN_PATH={shlex.quote(win_path)}')
print(f'WINE_PREFIX={shlex.quote(wine_prefix)}')
print(f'PROFILE={shlex.quote(profile)}')
print(f'EXTRA_FLAGS={shlex.quote(json.dumps(extra_flags))}')
print(f'ENV_VARS={shlex.quote(json.dumps(env_vars))}')
print(f'ICON_NAME={shlex.quote(icon_name)}')
print(f'CATEGORIES={shlex.quote(categories)}')
print(f'DESKTOP_SHORTCUT={json.dumps(desktop_shortcut)}')
" 2>/dev/null)"

if [ "${error:-}" = "missing_required" ]; then
  echo "{\"error\":\"Config must include app_name and exe_path\"}"
  exit 1
fi

# ---- Resolve output paths ----
script_dir="${HOME}/.local/bin"
desktop_dir="${HOME}/.local/share/applications"
mkdir -p "$script_dir" "$desktop_dir"

script_file="${script_dir}/${APP_NAME}.sh"
desktop_file="${desktop_dir}/${APP_NAME}.desktop"

# ---- Default env vars by profile ----
declare -A default_env
default_env[STAGING_WRITECOPY]="1"
default_env[WINEFSYNC]="1"
default_env[WINEESYNC]="1"

# Merge user env vars over defaults
eval "declare -A extra_env=($(python3 -c "
import json, sys
env = json.loads('${ENV_VARS}')
for k,v in env.items():
    print(f'[{k.lower()}]={v}')
"))"

# ---- Profile-specific defaults ----
flags=()
case "$PROFILE" in
  electron)
    flags+=("--no-sandbox" "--disable-gpu" "--disable-accelerated-2d-canvas")
    flags+=("--disable-gpu-compositing" "--disk-cache-size=0")
    flags+=("--disable-background-networking")
    ;;
  game)
    flags+=("--no-sandbox")
    ;;
esac

# Add extra flags from config
while IFS= read -r f; do
  [ -n "$f" ] && flags+=("$f")
done < <(python3 -c "
import json
fl = json.loads('${EXTRA_FLAGS}')
for f in fl:
    print(f)
" 2>/dev/null || true)

# ---- Write launcher script ----
cat > "$script_file" <<SCRIPT
#!/usr/bin/env bash
export WINEPREFIX="\${WINEPREFIX:-$WINE_PREFIX}"
SCRIPT

# Add env vars
for key in "${!default_env[@]}"; do
  val="${default_env[$key]}"
  low_key=$(echo "$key" | tr '[:upper:]' '[:lower:]')
  if [ -n "${extra_env[$low_key]:-}" ]; then
    val="${extra_env[$low_key]}"
  fi
  echo "export $key=$val" >> "$script_file"
done

# Add user env vars not already set
for key in "${!extra_env[@]}"; do
  upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
  # Skip if already a default
  case "$upper_key" in
    STAGING_WRITECOPY|WINEFSYNC|WINEESYNC) continue ;;
  esac
  echo "export $upper_key=${extra_env[$key]}" >> "$script_file"
done

flags_line=""
for f in "${flags[@]}"; do
  flags_line="$flags_line $f"
done

cat >> "$script_file" <<SCRIPT

exec wine "$EXE_PATH"$flags_line "\$@"
SCRIPT

chmod +x "$script_file"

# ---- Write .desktop file ----
cat > "$desktop_file" <<DESKTOP
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Comment=${APP_NAME} (Wine)
Exec=${script_file} %F
Icon=${ICON_NAME}
Categories=${CATEGORIES}
StartupNotify=true
DESKTOP

# ---- Desktop shortcut ----
shortcut_created=false
if [ "$DESKTOP_SHORTCUT" = "true" ] || [ "$DESKTOP_SHORTCUT" = "True" ]; then
  shortcut_path="${HOME}/Desktop/${APP_NAME}.desktop"
  if [ -d "$(dirname "$shortcut_path")" ]; then
    cp "$desktop_file" "$shortcut_path"
    chmod +x "$shortcut_path"
    shortcut_created=true
  fi
fi

# ---- Rebuild cache ----
kbuildsycoca6 &>/dev/null || kbuildsycoca5 &>/dev/null || true

# ---- Output JSON ----
cat <<JSONEOF
{
  "app_name": "$APP_NAME",
  "profile": "$PROFILE",
  "script": "$script_file",
  "desktop": "$desktop_file",
  "desktop_shortcut": $shortcut_created,
  "flags": [$(printf '"%s",' "${flags[@]}" | sed 's/,$//')],
  "icon_name": "$ICON_NAME"
}
JSONEOF
