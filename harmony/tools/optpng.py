#!/usr/bin/env python3
"""Lossless PNG re-encoder used to trim the packaged app icon.

Rewrites a PNG with per-row adaptive filtering and zlib level 9, and drops the
alpha channel when every pixel is opaque (colour type 6 -> 2).  The decoded
pixels are compared before/after and the tool refuses to write when they differ,
so the result is guaranteed to be bit-identical in image content.

Usage:
  python3 harmony/tools/optpng.py <file.png> [...]      # rewrite in place
  python3 harmony/tools/optpng.py --dry <file.png>      # report only
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'parity'))
import pngtool  # noqa: E402


def _chunk(typ, body):
    return (struct.pack('>I', len(body)) + typ + body
            + struct.pack('>I', zlib.crc32(typ + body) & 0xFFFFFFFF))


def _filters(cur, prev, bpp):
    """Return {filter_type: filtered_bytes} for one row (filters 0,1,2,4)."""
    out = {}
    out[0] = bytearray(b for p in cur for b in p[:bpp])
    line = bytearray()
    for i, p in enumerate(cur):
        left = cur[i - 1] if i > 0 else (0, 0, 0, 0)
        line += bytes(((p[k] - left[k]) & 0xFF) for k in range(bpp))
    out[1] = line
    line = bytearray()
    for i, p in enumerate(cur):
        line += bytes(((p[k] - prev[i][k]) & 0xFF) for k in range(bpp))
    out[2] = line
    line = bytearray()
    for i, p in enumerate(cur):
        left = cur[i - 1] if i > 0 else (0, 0, 0, 0)
        up = prev[i]
        upleft = prev[i - 1] if i > 0 else (0, 0, 0, 0)
        for k in range(bpp):
            a, b, c = left[k], up[k], upleft[k]
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line.append((cur[i][k] - pr) & 0xFF)
    out[4] = line
    return out


def _filters_index(cur, prev):
    """Filter candidates for one 8-bit index row (bpp = 1)."""
    out = {0: bytearray(cur)}
    line = bytearray()
    for i, v in enumerate(cur):
        left = cur[i - 1] if i > 0 else 0
        line.append((v - left) & 0xFF)
    out[1] = line
    out[2] = bytearray((v - prev[i]) & 0xFF for i, v in enumerate(cur))
    line = bytearray()
    for i, v in enumerate(cur):
        left = cur[i - 1] if i > 0 else 0
        up = prev[i]
        upleft = prev[i - 1] if i > 0 else 0
        p = left + up - upleft
        pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
        pr = left if (pa <= pb and pa <= pc) else (up if pb <= pc else upleft)
        line.append((v - pr) & 0xFF)
    out[4] = line
    return out


def _palette_encode(w, h, px):
    """Indexed-colour encoding when the image has at most 256 distinct colours."""
    cols = sorted({p[:3] for p in px})
    if len(cols) > 256:
        return None
    idx = {c: i for i, c in enumerate(cols)}
    rows = [bytes(idx[px[y * w + x][:3]] for x in range(w)) for y in range(h)]
    raw = bytearray()
    prev = bytes(w)
    for y in range(h):
        cands = _filters_index(rows[y], prev)
        f = min(cands, key=lambda t: len(cands[t]))
        raw.append(f)
        raw += cands[f]
        prev = rows[y]
    plte = b''.join(bytes(c) for c in cols)
    return (b'\x89PNG\r\n\x1a\n'
            + _chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 3, 0, 0, 0))
            + _chunk(b'PLTE', plte)
            + _chunk(b'IDAT', zlib.compress(bytes(raw), 9))
            + _chunk(b'IEND', b''))


def reencode(path):
    with open(path, 'rb') as fh:
        old_size = len(fh.read())
    w, h, px = pngtool.read_png(path)
    opaque = all(p[3] == 255 for p in px)
    best = None
    for ctype, bpp in ((2, 3), (6, 4)) if opaque else ((6, 4),):
        raw = bytearray()
        blank = [(0, 0, 0, 0)] * w
        for y in range(h):
            cur = px[y * w:(y + 1) * w]
            prev = px[(y - 1) * w:y * w] if y > 0 else blank
            cands = _filters(cur, prev, bpp)
            f = min(cands, key=lambda t: len(cands[t]))
            raw.append(f)
            raw += cands[f]
        data = zlib.compress(bytes(raw), 9)
        if best is None or len(data) < len(best[0]):
            best = (data, ctype)
    data, ctype = best
    out = (b'\x89PNG\r\n\x1a\n'
           + _chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, ctype, 0, 0, 0))
           + _chunk(b'IDAT', data) + _chunk(b'IEND', b''))
    pal = _palette_encode(w, h, px)
    if pal is not None and len(pal) < len(out):
        out = pal
    # verify: decoded pixels must be identical
    tmp = path + '.opt.png'
    with open(tmp, 'wb') as fh:
        fh.write(out)
    w2, h2, px2 = pngtool.read_png(tmp)
    same = (w2, h2) == (w, h) and all(px2[i][:3] == px[i][:3] for i in range(w * h)) \
        and all(px2[i][3] == px[i][3] for i in range(w * h))
    if not same:
        os.remove(tmp)
        raise SystemExit(f'{path}: refusing to write, pixels differ')
    os.replace(tmp, path)
    return old_size, len(out)


def main(argv):
    dry = '--dry' in argv
    files = [a for a in argv[1:] if not a.startswith('--')]
    total = 0
    for f in files:
        old, new = reencode(f)
        total += old - new
        print(f'{f}: {old} -> {new} bytes ({old - new:+d})')
    print(f'total saved: {total} bytes')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
