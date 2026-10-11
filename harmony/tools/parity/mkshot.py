#!/usr/bin/env python3
"""Build harmony/tools/parity/shot.html — a self-contained side-by-side viewer.

Pairs out/a_<name>.png (Android) with out/h_<name>.png (HarmonyOS) and embeds
both as base64 data URIs so the preview tab needs no other files.

Usage:  python3 mkshot.py [name ...]                 # full screenshots
        python3 mkshot.py --crop X0 Y0 X1 Y1 [name..] # crop in **dp**, same scale

--crop renders both sides at the same pixels-per-dp scale, so identical dp
geometry looks pixel-identical and differences are obvious at a glance.
"""
import base64
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
HTML = os.path.join(HERE, 'shot.html')
SCALE = 2.0  # px per dp in --crop mode


def data_uri(path: str) -> str:
    with open(path, 'rb') as fh:
        return 'data:image/png;base64,' + base64.b64encode(fh.read()).decode()


def crop_data_uri(path, density, rect, scale):
    import pngtool
    w, h, px = pngtool.read_png(path)
    x0, y0, x1, y1 = (int(v * density) for v in rect)
    cw, ch, cpx = pngtool.crop(px, w, h, x0, y0, x1, y1, 1)
    # nearest-neighbour resample to a common px-per-dp scale
    tw = int((rect[2] - rect[0]) * scale)
    th = int((rect[3] - rect[1]) * scale)
    out = []
    for y in range(th):
        sy = min(ch - 1, int(y * ch / th))
        row = cpx[sy * cw:(sy + 1) * cw]
        for x in range(tw):
            out.append(row[min(cw - 1, int(x * cw / tw))])
    tmp = os.path.join(OUT, '_crop.png')
    pngtool.write_png(tmp, tw, th, out)
    with open(tmp, 'rb') as fh:
        return 'data:image/png;base64,' + base64.b64encode(fh.read()).decode(), tw, th


def main() -> int:
    args = sys.argv[1:]
    rect = None
    global SCALE
    if args and args[0] == '--crop':
        rect = tuple(float(v) for v in args[1:5])
        args = args[5:]
        if args and args[0].startswith('@'):
            SCALE = float(args[0][1:])
            args = args[1:]
    names = args
    if not names:
        names = sorted(
            f[2:-4] for f in os.listdir(OUT)
            if f.endswith('.png') and f.startswith('a_')
        )
    figs = []
    for name in names:
        a = os.path.join(OUT, 'a_' + name + '.png')
        h = os.path.join(OUT, 'h_' + name + '.png')
        cells = []
        for label, path, density in (('Android', a, 2.75), ('HarmonyOS', h, 3.25)):
            if rect is not None and os.path.exists(path):
                uri, tw, th = crop_data_uri(path, density, rect, SCALE)
                cells.append(
                    f'<figure><figcaption>{label} — {name} '
                    f'({rect[0]:g},{rect[1]:g})..({rect[2]:g},{rect[3]:g}) dp @{SCALE:g}px/dp</figcaption>'
                    f'<img src="{uri}"></figure>'
                )
                continue
            if not os.path.exists(path):
                cells.append(f'<figure><figcaption>{label} (missing {os.path.basename(path)})'
                             '</figcaption></figure>')
                continue
            cells.append(
                f'<figure><figcaption>{label} — {name}</figcaption>'
                f'<img src="{data_uri(path)}"></figure>'
            )
        figs.append(f'<div class="pair{" crop" if rect else ""}">' + ''.join(cells) + '</div>')
    doc = f'''<!doctype html><html><head><meta charset="utf-8"><title>parity shots</title><style>
body{{margin:0;background:#1b1b1b;color:#eee;font:12px/1.5 system-ui;padding:12px}}
.pair{{display:flex;gap:14px;align-items:flex-start;margin-bottom:18px;flex-wrap:wrap}}
figure{{margin:0}} figcaption{{padding:2px 0;color:#9ad}} img{{display:block;border:1px solid #555}}
img{{max-height:760px}}
.crop img{{max-height:none;image-rendering:pixelated}}
</style></head><body>
{''.join(figs) if figs else '<p>no screenshots in out/</p>'}
</body></html>
'''
    with open(HTML, 'w') as fh:
        fh.write(doc)
    print(f'wrote {HTML} with {len(figs)} pair(s): {", ".join(names) or "-"}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
