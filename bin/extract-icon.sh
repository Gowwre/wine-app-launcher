#!/usr/bin/env bash

# extract-icon.sh
# Extracts icons from a PE executable by reading raw bytes at resource
# offsets (parsed by Python), converts to PNG, and installs into hicolor.
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

# ---- Extract icons: Python PE parser reads offsets, dumps DIBs, converts to PNG ----
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

export EXE_PATH="$exe_path"
export WORK_DIR="$work_dir"
export EXE_NAME="$exe_name"
export OUTPUT_DIR="$output_dir"

python3 > "$work_dir/result.json" 2>/dev/null <<'PYEOF'
import json, os, struct, subprocess, sys

exe_path = os.environ.get('EXE_PATH', '')
work_dir_env = os.environ.get('WORK_DIR', '')
exe_name = os.environ.get('EXE_NAME', '')
output_dir_env = os.environ.get('OUTPUT_DIR', '')

with open(exe_path, 'rb') as f:
    data = f.read()

def rva_to_offset(rva, pe_off, ohs, ns):
    for i in range(ns):
        sh = pe_off + 24 + ohs + i * 40
        va = struct.unpack_from('<I', data, sh + 12)[0]
        vs = struct.unpack_from('<I', data, sh + 8)[0]
        ra = struct.unpack_from('<I', data, sh + 20)[0]
        if va <= rva < va + vs:
            return rva - va + ra
    return None

def walk(off, base, depth, path, out):
    if depth > 3:
        return
    nn = struct.unpack_from('<H', data, off + 12)[0]
    ni = struct.unpack_from('<H', data, off + 14)[0]
    eo = off + 16
    for i in range(nn + ni):
        ent = struct.unpack_from('<I', data, eo + i * 8)[0]
        sub = struct.unpack_from('<I', data, eo + i * 8 + 4)[0]
        if sub >> 31:
            so = rva_to_offset(base + (sub & 0x7fffffff), pe_off, ohs, ns)
            if so:
                walk(so, base, depth + 1, path + [ent & 0xffff], out)
        else:
            doff = rva_to_offset(base + sub, pe_off, ohs, ns)
            if doff:
                drva = struct.unpack_from('<I', data, doff)[0]
                dsz = struct.unpack_from('<I', data, doff + 4)[0]
                di = rva_to_offset(drva, pe_off, ohs, ns)
                if di:
                    out.append((path + [ent & 0xffff], di, dsz))

pe_off = struct.unpack_from('<I', data, 0x3c)[0]
ns = struct.unpack_from('<H', data, pe_off + 6)[0]
ohs = struct.unpack_from('<H', data, pe_off + 20)[0]
oho = pe_off + 24
magic = struct.unpack_from('<H', data, oho)[0]
is32 = magic == 0x10b
ndd = struct.unpack_from('<I', data, oho + (92 if is32 else 108))[0]
ddo = oho + (96 if is32 else 112)
if ndd <= 2:
    print(json.dumps({"error": "No resource directory"}))
    sys.exit(0)
rr = struct.unpack_from('<I', data, ddo + 16)[0]
if rr == 0:
    print(json.dumps({"error": "No resources"}))
    sys.exit(0)
ro = rva_to_offset(rr, pe_off, ohs, ns)
if ro is None:
    print(json.dumps({"error": "Cannot resolve resource dir"}))
    sys.exit(0)
out = []
walk(ro, rr, 0, [], out)

icons = [(p, o, s) for p, o, s in out if len(p) >= 1 and p[0] == 3]
saved = []
for path, off, sz in icons:
    raw = data[off:off+sz]
    hs = struct.unpack_from('<I', raw, 0)[0]
    w = struct.unpack_from('<I', raw, 4)[0]
    dh = struct.unpack_from('<I', raw, 8)[0]
    h = dh // 2
    bpp = struct.unpack_from('<H', raw, 14)[0]
    if w == 0: w = 256
    if h == 0: h = 256
    if w > 256 or h > 256 or w < 16 or h < 16:
        continue
    row = ((w * bpp + 31) // 32) * 4
    tga = os.path.join(work_dir_env, f'{exe_name}_{w}.tga')
    with open(tga, 'wb') as out_f:
        out_f.write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, w, h, bpp, 0x20))
        for y in range(h):
            rs = hs + (h - 1 - y) * row
            out_f.write(raw[rs:rs + w * 4])
    png = os.path.join(work_dir_env, f'{exe_name}_{w}.png')
    try:
        subprocess.run(['magick', tga, png], capture_output=True, timeout=10, check=True)
        if os.path.getsize(png) > 100:
            saved.append((w, png))
    except Exception:
        pass
if not saved:
    print(json.dumps({"error": "No icons converted"}))
    sys.exit(0)
print(json.dumps({"sizes": [(w, p) for w, p in saved]}))
PYEOF

# Parse result
if [ ! -f "$work_dir/result.json" ]; then
  echo "{\"error\":\"Python script failed\"}"
  exit 1
fi

result=$(cat "$work_dir/result.json")
if echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'sizes' in d else 1)" 2>/dev/null; then
  :
else
  error_msg=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo "unknown error")
  echo "{\"error\":\"$error_msg\"}"
  exit 1
fi

# Install icons
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
done < <(echo "$result" | python3 -c "
import json, sys
r = json.load(sys.stdin)
for w, p in r['sizes']:
    print(f'{w}|{p}')
")
installed_entries+="]"

icon_count=$(echo "$installed_entries" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")

# index.theme
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

cat <<JSONEOF
{
  "app_name": "$exe_name",
  "icon_count": $icon_count,
  "sizes": $installed_entries,
  "icon_theme_path": "$theme_dir"
}
JSONEOF