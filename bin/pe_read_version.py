#!/usr/bin/env python3
"""
Read VS_VERSION_INFO from a PE executable and extract the app name
(FileDescription > ProductName > OriginalFilename).

Usage: pe_read_version.py <exe_path>
Output: JSON with {"app_name": "..."} or {"app_name": ""} if not found.
"""

import json, struct, sys

from pe_resources import parse


def read_version_info(exe_path):
    with open(exe_path, 'rb') as f:
        data = f.read()

    resources = parse(data)
    # Type 16 = RT_VERSION
    versions = [r for r in resources if len(r[0]) >= 1 and r[0][0] == 16]

    for path, off, sz in versions:
        raw = data[off:off + sz]

        def read_utf16(offset):
            end = offset
            while end + 2 <= len(raw):
                if raw[end] == 0 and raw[end + 1] == 0:
                    break
                end += 2
            return raw[offset:end].decode('utf-16-le', errors='replace')

        for key in ('FileDescription', 'ProductName', 'OriginalFilename'):
            key_bytes = key.encode('utf-16-le')
            idx = 0
            while True:
                idx = raw.find(key_bytes, idx)
                if idx == -1:
                    break
                val_start = idx + len(key_bytes)
                if val_start < len(raw) and (raw[val_start] != 0 or raw[val_start + 1] != 0):
                    val = read_utf16(val_start)
                    if val:
                        return val
                idx += 2

    return ''


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: pe_read_version.py <exe_path>"}))
        sys.exit(1)

    name = read_version_info(sys.argv[1])
    print(json.dumps({"app_name": name}))
