# wine-app-launcher

Turn any Windows `.exe` (or `.lnk`) into a native Linux desktop app with Wine — profile detection, DXVK, icon extraction, launcher scripts, and `.desktop` files.

Designed for use with **opencode** (AI agent skill), but each script works standalone.

## Quick start

```bash
# 1. Detect the app
bin/detect-profile.sh ~/.wine/drive_c/.../MyApp.exe

# 2. Extract icons (requires ImageMagick)
bin/extract-icon.sh ~/.wine/drive_c/.../MyApp.exe

# 3. Create launcher + desktop entry
cat > config.json <<EOF
{"app_name":"MyApp","exe_path":"$HOME/.wine/.../MyApp.exe","profile":"electron","icon_name":"myapp","categories":"Utility;"}
EOF
bin/write-launcher.sh config.json

# 4. Install DXVK for better D3D→Vulkan performance (optional)
bin/install-dxvk.sh --prefix ~/.wine
```

## Scripts

| Script | Input | Output |
|--------|-------|--------|
| `bin/detect-profile.sh` | exe/lnk path | JSON: app name, type (electron/game/default), Vulkan status, flags |
| `bin/extract-icon.sh` | exe path | JSON: icon sizes installed to hicolor theme |
| `bin/write-launcher.sh` | JSON config | Shell script + .desktop file |
| `bin/install-dxvk.sh` | wine prefix | JSON: installed DLLs, revert command |

## Profiles

Detected automatically from PE contents:

- **electron** — `chrome_*.pak`, `vk_swiftshader.dll`, `libEGL.dll` → adds `--no-sandbox --disable-gpu` flags
- **game** — `UnityPlayer.dll`, Unreal Engine → recommends DXVK
- **default** — everything else → basic Wine launcher

## Dependencies

- **Python 3** (universal)
- **ImageMagick** (`magick`) — for icon conversion (skip if missing)
- **icoutils** (`wrestool`) — for PE metadata extraction (skip if missing)
- **DXVK** — optional, distro-specific (`dxvk-mingw-git` on Arch, `dxvk` on Debian/Ubuntu)

## How it works

All scripts follow the same contract: read from argv/env, write JSON to stdout, errors to stderr. No filesystem side-effects outside what they report. Designed to let an AI agent orchestrate the workflow while the scripts handle deterministic work.
