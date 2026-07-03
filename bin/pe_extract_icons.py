#!/usr/bin/env python3
"""
Extract RT_ICON resources from a PE executable, convert each to PNG
via an intermediate TGA, and print the results as JSON.

Usage: pe_extract_icons.py <exe_path> <work_dir> <exe_name>
Output: JSON with {"sizes": [[width, png_path], ...]}
"""

import json, os, struct, subprocess, sys

from pe_resources import parse


def dib_to_png(exe_path, work_dir, exe_name):
    with open(exe_path, 'rb') as f:
        data = f.read()

    resources = parse(data)
    icons = [r for r in resources if len(r[0]) >= 1 and r[0][0] == 3]
    saved = []

    for path, off, sz in icons:
        raw = data[off:off + sz]
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
        tga = os.path.join(work_dir, f'{exe_name}_{w}.tga')
        with open(tga, 'wb') as out:
            out.write(struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, w, h, bpp, 0x20))
            for y in range(h):
                rs = hs + (h - 1 - y) * row
                out.write(raw[rs:rs + w * 4])

        png = os.path.join(work_dir, f'{exe_name}_{w}.png')
        try:
            subprocess.run(['magick', tga, png], capture_output=True, timeout=10, check=True)
            if os.path.getsize(png) > 100:
                saved.append((w, png))
        except Exception:
            pass

    return saved


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(json.dumps({"error": "Usage: pe_extract_icons.py <exe_path> <work_dir> <exe_name>"}))
        sys.exit(1)

    result = dib_to_png(sys.argv[1], sys.argv[2], sys.argv[3])
    if not result:
        print(json.dumps({"error": "No icons converted"}))
        sys.exit(1)

    print(json.dumps({"sizes": [(w, p) for w, p in result]}))
