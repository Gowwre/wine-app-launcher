#!/usr/bin/env python3
"""
PE resource directory parser. Used by other scripts in this repo.
Reads a PE file and enumerates its resource entries.

Output: JSON array of {path, offset, size} for each resource leaf.
"""

import json, struct, sys

def parse(data):
    pe_off = struct.unpack_from('<I', data, 0x3c)[0]
    ns = struct.unpack_from('<H', data, pe_off + 6)[0]
    ohs = struct.unpack_from('<H', data, pe_off + 20)[0]
    oho = pe_off + 24
    magic = struct.unpack_from('<H', data, oho)[0]
    is32 = magic == 0x10b
    ndd = struct.unpack_from('<I', data, oho + (92 if is32 else 108))[0]
    if ndd <= 2:
        return []
    ddo = oho + (96 if is32 else 112)
    rr = struct.unpack_from('<I', data, ddo + 16)[0]
    if rr == 0:
        return []

    def rva_to_offset(rva):
        for i in range(ns):
            sh = pe_off + 24 + ohs + i * 40
            va = struct.unpack_from('<I', data, sh + 12)[0]
            vs = struct.unpack_from('<I', data, sh + 8)[0]
            ra = struct.unpack_from('<I', data, sh + 20)[0]
            if va <= rva < va + vs:
                return rva - va + ra
        return None

    ro = rva_to_offset(rr)
    if ro is None:
        return []

    results = []

    def walk(off, base, depth, path):
        if depth > 3:
            return
        nn = struct.unpack_from('<H', data, off + 12)[0]
        ni = struct.unpack_from('<H', data, off + 14)[0]
        eo = off + 16
        for i in range(nn + ni):
            ent = struct.unpack_from('<I', data, eo + i * 8)[0]
            sub = struct.unpack_from('<I', data, eo + i * 8 + 4)[0]
            if sub >> 31:
                so = rva_to_offset(base + (sub & 0x7fffffff))
                if so:
                    walk(so, base, depth + 1, path + [ent & 0xffff])
            else:
                doff = rva_to_offset(base + sub)
                if doff:
                    drva = struct.unpack_from('<I', data, doff)[0]
                    dsz = struct.unpack_from('<I', data, doff + 4)[0]
                    di = rva_to_offset(drva)
                    if di:
                        results.append((path + [ent & 0xffff], di, dsz))

    walk(ro, rr, 0, [])
    return results


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: pe_resources.py <exe_path>"}), file=sys.stderr)
        sys.exit(1)
    with open(sys.argv[1], 'rb') as f:
        resources = parse(f.read())
    print(json.dumps(resources))
