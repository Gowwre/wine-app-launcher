---
name: wine-app-launcher
description: >
  Use when the user wants to turn a Windows .exe or .lnk into a native Linux
  desktop application with Wine. Covers profile detection, DXVK install, icon
  extraction, launcher script creation, and .desktop file generation.
  Trigger words: "wine", "windows app", "exe", ".lnk", "launcher", "desktop entry".
---

# Wine App Launcher Skill

## Workflow

### 1. Detect app profile

Always start here. This resolves the exe path and determines app type.

```bash
bin/detect-profile.sh <exe_or_lnk_path>
```

Outputs JSON with:
- `app_name` — display name (from PE metadata or filename)
- `exe_path` — resolved absolute path  
- `profile` — `"electron"`, `"game"`, or `"default"`
- `dxvk_recommended` — bool
- `vulkan_available` — bool
- `has_icons` — bool
- `electron_flags` — array of recommended flags (if electron)

**If input is a .lnk:** script returns an error with `lnk_target`. Resolve the .exe path manually from the target field, then re-run with the actual .exe.

**If icon extraction fails or DXVK is unavailable:** skip and log — never block the user.

### 2. Offer choices to the user

After detection, use the profile to recommend:

| Profile | DXVK? | Electron flags? | Icon extraction? |
|---------|-------|-----------------|------------------|
| electron | Yes | Yes | Yes |
| game | Yes | No | Yes |
| default | No (unless user asks) | Safe flags only | Yes |

Present the plan clearly — which scripts will run and what they'll do. Let the user confirm or ask for changes before proceeding.

### 3. Install DXVK (if recommended and accepted)

```bash
bin/install-dxvk.sh [--prefix <path>]
```

Handles:
- `setup_dxvk` (Arch/CachyOS `dxvk-mingw-git`)
- `winetricks dxvk` (fallback)
- Graceful skip if no Vulkan or no install method found

**If `pkexec` / `sudo` fails non-interactively:** tell the user what package to install and how, then continue.

### 4. Extract icons

```bash
bin/extract-icon.sh <exe_path> [--output-dir <dir>]
```

Requires ImageMagick. If not installed, skip and use `Icon=wine` in the .desktop file.

Installs into `~/.local/share/icons/hicolor/*/apps/` and runs `gtk-update-icon-cache`.

### 5. Write launcher script and .desktop file

Build a JSON config file with the gathered info, then:

```bash
bin/write-launcher.sh <config.json>
```

The config JSON structure:

```json
{
  "app_name": "Zalo",
  "exe_path": "/home/user/.wine/.../Zalo.exe",
  "profile": "electron",
  "extra_flags": ["--no-sandbox", "--disable-gpu"],
  "icon_name": "zalo",
  "categories": "Network;InstantMessaging;",
  "desktop_shortcut": true
}
```

This creates:
- `~/.local/bin/<app>.sh` — launcher script with env vars + flags
- `~/.local/share/applications/<app>.desktop` — app menu entry
- `~/Desktop/<app>.desktop` — optional desktop shortcut

### 6. Verify

Check the .desktop file has the correct `Icon=` and `Exec=` fields. Rebuild icon cache if needed (`kbuildsycoca6` for KDE, `gtk-update-icon-cache` otherwise).

## File layout

```
.opencode/skills/wine-app-launcher/
  SKILL.md
  bin/
    detect-profile.sh   # PE analysis, type detection → JSON
    extract-icon.sh     # Icon extraction + PNG conversion + theme install
    write-launcher.sh   # Generate .sh + .desktop files
    install-dxvk.sh     # DXVK setup for Wine prefix
```

## General principles

- **Ask before acting.** Present the detected profile and the planned steps.  
- **Fail gracefully.** Any step can fail — log the error, explain why, and offer to skip.  
- **No assumptions about distro.** Probe for tools (`which`), don't hardcode package managers.  
- **No sudo from scripts.** If root is needed (DXVK install), try `pkexec` first, fall back to instructions.  
- **Clean JSON IO.** Every script reads env/config, writes JSON to stdout. Never print diagnostics to stdout — use stderr.  
- **Don't hallucinate paths.** All paths come from script output or user confirmation.
