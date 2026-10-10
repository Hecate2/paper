#!/usr/bin/env python3
"""uitest 辅助：按文本或 id 点控件。返回点击坐标，未找到则 exit 2。"""
import json
import subprocess
import sys

HDC = [
    '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'
]


def run(*args: str) -> str:
    r = subprocess.run(list(*args) if len(args) == 1 and isinstance(args[0], list) else list(args),
                       capture_output=True, text=True)
    return r.stdout + r.stderr


def dump() -> dict:
    run(HDC + ['shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/e2e_ui.json'])
    run(HDC + ['file', 'recv', '/data/local/tmp/e2e_ui.json', '/tmp/e2e_ui.json'])
    with open('/tmp/e2e_ui.json', encoding='utf-8') as f:
        return json.load(f)


def find(node: dict, want: str, out: list) -> None:
    import re
    a = node.get('attributes', {})
    text = a.get('text', '')
    cid = a.get('id', '')
    bounds = a.get('bounds', '')
    clickable = a.get('clickable', '')
    if bounds and (want in text or (cid and want == cid)):
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
        if m:
            x0, y0, x1, y1 = map(int, m.groups())
            out.append(((x0 + x1) // 2, (y0 + y1) // 2, text, cid, clickable))
    for c in node.get('children') or []:
        find(c, want, out)


def main() -> int:
    args = sys.argv[1:]
    coords_only = False
    if args and args[0] == '--coords':
        coords_only = True
        args = args[1:]
    want = args[0]
    idx = int(args[1]) if len(args) > 1 else 0
    hits: list = []
    find(dump(), want, hits)
    # 可点击的优先
    hits.sort(key=lambda h: 0 if h[4] == 'true' else 1)
    if idx >= len(hits):
        print(f'NOT-FOUND {want} (found {len(hits)})')
        return 2
    x, y, text, cid, _click = hits[idx]
    if coords_only:
        print(f'{x} {y}')
        return 0
    print(f'TAP {want} -> ({x},{y}) text={text!r} id={cid!r}')
    print(run(HDC + ['shell', 'uitest', 'uiInput', 'click', str(x), str(y)]).strip())
    return 0


if __name__ == '__main__':
    sys.exit(main())
