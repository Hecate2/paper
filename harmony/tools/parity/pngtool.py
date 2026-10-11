#!/usr/bin/env python3
"""Tiny pure-python PNG helper (no PIL/numpy in this environment).

Commands:
  decode <in.png>                      -> prints size + colour type
  crop   <in.png> <out.png> x0 y0 x1 y1 [scale]
  runs   <in.png> <y> [x0 x1]          -> horizontal colour runs on row y
  colruns<in.png> <x> [y0 y1]          -> vertical colour runs on column x
  px     <in.png> <x> <y> [...]        -> pixel values
  round  <in.png> x0 y0 x1 y1          -> corner-radius estimate of a bright box
  ink    <in.png> x0 y0 x1 y1 [tol]    -> bbox of pixels differing from the modal colour
  diff   <a> <b> x0 y0 x1 y1 [scale]   -> mean/max per-cell delta between two images
Coordinates are pixels, (0,0) = top-left.
"""
import struct
import sys
import zlib


def _unfilter(raw: bytes, width: int, height: int, bpp: int) -> bytearray:
    stride = width * bpp
    out = bytearray(stride * height)
    pos = 0
    prev = bytearray(stride)
    for y in range(height):
        ft = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ft == 0:
            pass
        elif ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise ValueError(f'bad filter {ft}')
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def read_png(path):
    with open(path, 'rb') as fh:
        data = fh.read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a png')
    pos, idat, pal, trns = 8, bytearray(), None, None
    width = height = depth = ctype = None
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b'IHDR':
            width, height, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
            if interlace:
                raise ValueError('interlaced png unsupported')
        elif typ == b'PLTE':
            pal = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif typ == b'tRNS':
            trns = list(body)
        elif typ == b'IDAT':
            idat += body
        elif typ == b'IEND':
            break
    raw = zlib.decompress(bytes(idat))
    if depth != 8:
        raise ValueError(f'bit depth {depth} unsupported')
    if ctype == 2:
        bpp = 3
    elif ctype == 6:
        bpp = 4
    elif ctype == 3:
        bpp = 1
    else:
        raise ValueError(f'colour type {ctype} unsupported')
    flat = _unfilter(raw, width, height, bpp)
    px = []
    if ctype == 3:
        for i in range(width * height):
            r, g, b = pal[flat[i]]
            px.append((r, g, b, 255))
    else:
        for i in range(width * height):
            o = i * bpp
            if bpp == 3:
                px.append((flat[o], flat[o + 1], flat[o + 2], 255))
            else:
                px.append((flat[o], flat[o + 1], flat[o + 2], flat[o + 3]))
    return width, height, px


def write_png(path, width, height, px):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            r, g, b, a = px[y * width + x]
            raw += bytes((r, g, b, a))

    def chunk(typ, body):
        return (struct.pack('>I', len(body)) + typ + body
                + struct.pack('>I', zlib.crc32(typ + body) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    with open(path, 'wb') as fh:
        fh.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
                 + chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b''))


def crop(px, w, h, x0, y0, x1, y1, scale=1):
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(w, x1), min(h, y1)
    cw, ch = x1 - x0, y1 - y0
    out = []
    for y in range(y0, y1):
        row = px[y * w + x0:y * w + x1]
        for _ in range(scale):
            for p in row:
                for _ in range(scale):
                    out.append(p)
    return cw * scale, ch * scale, out


def runs_of(vals, axis_label):
    out, start = [], 0
    for i in range(1, len(vals) + 1):
        if i == len(vals) or vals[i] != vals[start]:
            out.append((start, i - 1, vals[start]))
            start = i
    for a, b, v in out:
        print(f'{axis_label} {a:5d}..{b:5d} len={b - a + 1:4d} rgba={v}')


def main(argv):
    cmd = argv[1]
    if cmd == 'decode':
        w, h, _ = read_png(argv[2])
        print(f'{argv[2]}: {w}x{h}')
    elif cmd == 'crop':
        w, h, px = read_png(argv[2])
        x0, y0, x1, y1 = (int(v) for v in argv[4:8])
        scale = int(argv[8]) if len(argv) > 8 else 1
        cw, ch, cpx = crop(px, w, h, x0, y0, x1, y1, scale)
        write_png(argv[3], cw, ch, cpx)
        print(f'{argv[3]}: {cw}x{ch}')
    elif cmd == 'runs':
        w, h, px = read_png(argv[2])
        y = int(argv[3])
        x0 = int(argv[4]) if len(argv) > 4 else 0
        x1 = int(argv[5]) if len(argv) > 5 else w
        row = px[y * w:x * 1 * w] if False else [px[y * w + x] for x in range(x0, x1)]
        runs_of(row, f'x(offset {x0})')
    elif cmd == 'colruns':
        w, h, px = read_png(argv[2])
        x = int(argv[3])
        y0 = int(argv[4]) if len(argv) > 4 else 0
        y1 = int(argv[5]) if len(argv) > 5 else h
        vals = [px[y * w + x] for y in range(y0, y1)]
        runs_of(vals, f'y(offset {y0})')
    elif cmd == 'ink':
        w, h, px = read_png(argv[2])
        x0, y0, x1, y1 = (int(v) for v in argv[3:7])
        tol = int(argv[7]) if len(argv) > 7 else 60
        counts = {}
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = px[y * w + x][:3]
                counts[c] = counts.get(c, 0) + 1
        bg = max(counts, key=counts.get)
        bx0, by0, bx1, by1, n = x1, y1, x0, y0, 0
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = px[y * w + x][:3]
                if max(abs(c[i] - bg[i]) for i in range(3)) > tol:
                    n += 1
                    bx0, by0 = min(bx0, x), min(by0, y)
                    bx1, by1 = max(bx1, x), max(by1, y)
        print(f'bg={bg} ink={n}')
        if n:
            print(f'bbox x={bx0}..{bx1} y={by0}..{by1} w={bx1 - bx0 + 1} h={by1 - by0 + 1}')
    elif cmd == 'diff':
        wa, ha, a = read_png(argv[2])
        wb, hb, b = read_png(argv[3])
        x0, y0, x1, y1 = (int(v) for v in argv[4:8])
        scale = float(argv[8]) if len(argv) > 8 else 1.0
        tot = 0.0
        mx = 0
        n = 0
        rows = []
        for y in range(y0, y1):
            rowmax = 0
            for x in range(x0, x1):
                ax = int(x * scale)
                if ax >= wa or y >= ha or x >= wb or y >= hb:
                    continue
                pa = a[y * wa + ax][:3]
                pb = b[y * wb + x][:3]
                d = max(abs(pa[i] - pb[i]) for i in range(3))
                tot += d
                mx = max(mx, d)
                rowmax = max(rowmax, d)
                n += 1
            rows.append((y, rowmax))
        print(f'cells={n} mean={tot / max(1, n):.1f} max={mx}')
        worst = sorted(rows, key=lambda r: -r[1])[:8]
        print('worst rows (y, maxdelta): ' + ', '.join(f'{y}:{d}' for y, d in worst))
    elif cmd == 'px':
        w, h, px = read_png(argv[2])
        for pair in argv[3:]:
            x, y = (int(v) for v in pair.split(','))
            print(f'({x},{y}) = {px[y * w + x]}')
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
