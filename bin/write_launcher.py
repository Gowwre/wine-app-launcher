#!/usr/bin/env python3
"""
Generate a Wine launcher script and .desktop entry from a JSON config.

Usage: write_launcher.py <config.json>
Output: JSON describing the created files.
"""

import json
import os
import pathlib
import shlex
import subprocess
import sys


DEFAULT_ENV = {
    "STAGING_WRITECOPY": "1",
    "WINEFSYNC": "1",
    "WINEESYNC": "1",
}

PROFILE_FLAGS = {
    "electron": [
        "--no-sandbox",
        "--disable-gpu",
        "--disable-accelerated-2d-canvas",
        "--disable-gpu-compositing",
        "--disk-cache-size=0",
        "--disable-background-networking",
    ],
    "game": ["--no-sandbox"],
}


def _safe_name(app_name: str) -> str:
    """Return a filesystem-safe basename from the app name."""
    safe = "".join(c if c.isalnum() or c in (" ", "-", "_") else "_" for c in app_name)
    return safe.replace(" ", "_")


def read_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_config(cfg: dict) -> tuple[str, str]:
    app_name = cfg.get("app_name", "").strip()
    exe_path = cfg.get("exe_path", "").strip()
    if not app_name or not exe_path:
        raise ValueError("Config must include app_name and exe_path")
    return app_name, exe_path


def build_flags(profile: str, extra_flags: list) -> list[str]:
    flags = list(PROFILE_FLAGS.get(profile, []))
    flags.extend(extra_flags)
    return flags


def write_launcher_script(
    script_file: pathlib.Path,
    exe_path: str,
    wine_prefix: str,
    flags: list[str],
    env_vars: dict,
) -> None:
    merged_env = dict(DEFAULT_ENV)
    for key, value in env_vars.items():
        merged_env[key.upper()] = value

    lines = [
        "#!/usr/bin/env bash",
        f'export WINEPREFIX="${{WINEPREFIX:-{shlex.quote(wine_prefix)}}}"',
    ]
    for key, value in merged_env.items():
        lines.append(f"export {key}={shlex.quote(str(value))}")

    flags_str = " ".join(shlex.quote(f) for f in flags)
    if flags_str:
        flags_str = " " + flags_str

    lines.append("")
    lines.append(f'exec wine {shlex.quote(exe_path)}{flags_str} "$@"')

    script_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    script_file.chmod(0o755)


def write_desktop_file(
    desktop_file: pathlib.Path,
    app_name: str,
    script_file: pathlib.Path,
    icon_name: str,
    categories: str,
) -> None:
    content = "\n".join(
        [
            "[Desktop Entry]",
            "Type=Application",
            f"Name={app_name}",
            f"Comment={app_name} (Wine)",
            f"Exec={script_file} %F",
            f"Icon={icon_name}",
            f"Categories={categories}",
            "StartupNotify=true",
            "",
        ]
    )
    desktop_file.write_text(content, encoding="utf-8")
    desktop_file.chmod(0o755)


def create_desktop_shortcut(desktop_file: pathlib.Path, safe_name: str) -> pathlib.Path | None:
    shortcut_path = pathlib.Path.home() / "Desktop" / f"{safe_name}.desktop"
    try:
        shortcut_path.write_text(desktop_file.read_text(encoding="utf-8"), encoding="utf-8")
        shortcut_path.chmod(0o755)
        return shortcut_path
    except Exception:
        return None


def rebuild_icon_cache() -> None:
    for cmd in ("kbuildsycoca6", "kbuildsycoca5"):
        try:
            subprocess.run([cmd], capture_output=True, timeout=10, check=False)
            return
        except Exception:
            pass


def main(config_path: str) -> None:
    cfg = read_config(config_path)
    app_name, exe_path = validate_config(cfg)

    wine_prefix = cfg.get("wine_prefix", os.path.expanduser("~/.wine"))
    profile = cfg.get("profile", "default")
    extra_flags = cfg.get("extra_flags", [])
    env_vars = cfg.get("env_vars", {})
    icon_name = cfg.get("icon_name", app_name.lower())
    categories = cfg.get("categories", "Utility")
    desktop_shortcut = cfg.get("desktop_shortcut", True)

    safe_name = _safe_name(app_name)

    script_dir = pathlib.Path.home() / ".local" / "bin"
    desktop_dir = pathlib.Path.home() / ".local" / "share" / "applications"
    script_dir.mkdir(parents=True, exist_ok=True)
    desktop_dir.mkdir(parents=True, exist_ok=True)

    script_file = script_dir / f"{safe_name}.sh"
    desktop_file = desktop_dir / f"{safe_name}.desktop"

    flags = build_flags(profile, extra_flags)
    write_launcher_script(script_file, exe_path, wine_prefix, flags, env_vars)
    write_desktop_file(desktop_file, app_name, script_file, icon_name, categories)

    shortcut_path = None
    if desktop_shortcut:
        shortcut_path = create_desktop_shortcut(desktop_file, safe_name)

    rebuild_icon_cache()

    result = {
        "app_name": app_name,
        "profile": profile,
        "script": str(script_file),
        "desktop": str(desktop_file),
        "desktop_shortcut": shortcut_path is not None,
        "flags": flags,
        "icon_name": icon_name,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: write_launcher.py <config.json>"}))
        sys.exit(1)

    try:
        main(sys.argv[1])
    except FileNotFoundError as exc:
        print(json.dumps({"error": f"Config file not found: {exc.filename}"}))
        sys.exit(1)
    except ValueError as exc:
        print(json.dumps({"error": str(exc)}))
        sys.exit(1)
    except Exception as exc:
        print(json.dumps({"error": f"Unexpected error: {exc}"}))
        sys.exit(1)
