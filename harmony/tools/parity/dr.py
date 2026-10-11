#!/usr/bin/env python3
"""Drive the Android emulator (adb) and the HarmonyOS emulator (hdc) so the same
UI state can be dumped, tapped and screenshotted on both platforms.

Coordinates everywhere are **dp**; each platform has a density that converts to
device pixels.  Densities are the ones the two emulators report:

  * Android  1080x2340 @ 2.75  (392.7 x 850.9 dp)
  * Harmony  1260x2720 @ 3.25  (387.7 x 836.9 dp)

Commands
  dump   <p> <name>            dump layout + screenshot into tools/parity/out/
  shot   <p> <name>            screenshot only
  tap    <p> <x> <y> [dx dy]   tap at dp (x,y) plus optional dp offset
  tapnode<p> <id|text>         dump, find node, tap its centre
  back   <p>                   system back
  find   <p> <pattern>         print dp geometry of every matching node
  nodes  <p>                   print the whole tree in dp

<p> is 'a' (android) or 'h' (harmony).
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'
DENSITY = {'a': 2.75, 'h': 3.25}


def sh(cmd, timeout=90):
    p = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')


# ---------------------------------------------------------------- capture ----

def raw_dump(p):
    """Fetch the accessibility tree of the current screen (raw text)."""
    if p == 'a':
        sh('adb shell uiautomator dump /sdcard/wd.xml')
        return sh('adb shell cat /sdcard/wd.xml')[1]
    sh(f'{HDC} shell uitest dumpLayout -p /data/local/tmp/lk.json')
    dst = '/tmp/dr_dump.json'
    sh(f'{HDC} file recv /data/local/tmp/lk.json {dst}')
    with open(dst, 'rb') as fh:
        return fh.read().decode('utf-8', 'replace')


def shot(p, name):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f'{p}_{name}.png')
    if p == 'a':
        rc, data, err = sh('adb exec-out screencap -p > /tmp/dr_shot.png')
        sh(f'cp /tmp/dr_shot.png {path}')
    else:
        sh(f'{HDC} shell snapshot_display -f /data/local/tmp/s.jpeg')
        sh(f'{HDC} file recv /data/local/tmp/s.jpeg /tmp/dr_shot.jpeg')
        sh(f'sips -s format png /tmp/dr_shot.jpeg --out {path}')
    return path


def save(p, name, raw):
    os.makedirs(OUT, exist_ok=True)
    ext = 'xml' if p == 'a' else 'json'
    path = os.path.join(OUT, f'{p}_{name}.{ext}')
    with open(path, 'w') as fh:
        fh.write(raw)
    return path


# ------------------------------------------------------------------ parse ----

class Node:
    __slots__ = ('cls', 'id', 'text', 'desc', 'px', 'parent', 'children', 'raw')

    def __init__(self, cls='', id='', text='', desc='', px=None, raw=''):
        self.cls, self.id, self.text, self.desc = cls, id, text, desc
        self.px = px or (0, 0, 0, 0)
        self.parent = None
        self.children = []
        self.raw = raw

    # dp geometry
    @property
    def x(self): return self._dp()[0]

    @property
    def y(self): return self._dp()[1]

    @property
    def w(self): return self._dp()[2]

    @property
    def h(self): return self._dp()[3]

    @property
    def right(self): return self._dp()[0] + self._dp()[2]

    @property
    def bottom(self): return self._dp()[1] + self._dp()[3]

    @property
    def cx(self): return self._dp()[0] + self._dp()[2] / 2.0

    @property
    def cy(self): return self._dp()[1] + self._dp()[3] / 2.0

    @property
    def d(self): return self._dp()

    def _dp(self):
        return tuple(v for v in self.px)  # set by parse()

    def label(self):
        return f'{self.cls[:14]:14s} x={self.x:6.1f}..{self.right:6.1f} y={self.y:5.1f}..{self.bottom:5.1f} ' \
               f'w={self.w:6.1f} h={self.h:5.1f} id={self.id[:16]:16s} t={self.text[:24]}'

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()

    def ancestors(self):
        n = self.parent
        while n is not None:
            yield n
            n = n.parent


def parse_android(raw, density):
    s = raw
    i = s.find('</hierarchy>')
    if i > 0:
        s = s[:i + len('</hierarchy>')]
    root = ET.fromstring(s)

    def conv(el, parent):
        a = el.attrib
        b = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', a.get('bounds', ''))
        if b is None:
            x1 = y1 = x2 = y2 = 0
        else:
            x1, y1, x2, y2 = (int(v) / density for v in b.groups())
        n = Node(a.get('class', '').split('.')[-1], a.get('resource-id', '').split('/')[-1],
                 a.get('text', ''), a.get('content-desc', ''), (x1, y1, x2 - x1, y2 - y1), raw)
        n.parent = parent
        if parent is not None:
            parent.children.append(n)
        for c in el:
            conv(c, n)
        return n

    return conv(root, None)


def parse_harmony(raw, density):
    import json
    data = json.loads(raw)

    def conv(j, parent):
        a = j.get('attributes', {})
        b = re.findall(r'-?\d+', a.get('bounds') or '')
        if len(b) == 4:
            x1, y1, x2, y2 = (int(v) / density for v in b)
        else:
            x1 = y1 = x2 = y2 = 0
        n = Node((a.get('type') or '').split('.')[-1], a.get('id') or '',
                 (a.get('text') or '').strip(), a.get('description') or '',
                 (x1, y1, x2 - x1, y2 - y1), raw)
        n.parent = parent
        if parent is not None:
            parent.children.append(n)
        for c in j.get('children', []) or []:
            conv(c, n)
        return n

    return conv(data, None)


def load(p, name=None, raw=None):
    """Load a dump: either the live screen (name=None) or out/<p>_<name>.<ext>."""
    if raw is None:
        if name is None:
            raw = raw_dump(p)
        else:
            ext = 'xml' if p == 'a' else 'json'
            with open(os.path.join(OUT, f'{p}_{name}.{ext}')) as fh:
                raw = fh.read()
    return parse_android(raw, DENSITY[p]) if p == 'a' else parse_harmony(raw, DENSITY[p])


def screen(root):
    """Biggest node = the screen."""
    return max(root.walk(), key=lambda n: n.w * n.h)


def find(root, id=None, text=None, desc=None, cls=None, nth=0, exact=False):
    hits = []
    for n in root.walk():
        if id is not None and n.id != id:
            continue
        if cls is not None and n.cls != cls:
            continue
        if desc is not None and n.desc != desc:
            continue
        if text is not None:
            if (n.text == text) if exact else (text in n.text):
                pass
            else:
                continue
        hits.append(n)
    if not hits:
        raise LookupError(f'no node id={id} text={text} desc={desc} cls={cls}')
    return hits[nth]


def tap(p, x, y):
    dx, dy = DENSITY[p], DENSITY[p]
    if p == 'a':
        sh(f'adb shell input tap {int(x * dx)} {int(y * dy)}')
    else:
        sh(f'{HDC} shell uitest uiInput click {int(x * dx)} {int(y * dy)}')


def tap_node(p, node, fx=0.5, fy=0.5):
    tap(p, node.x + node.w * fx, node.y + node.h * fy)


def back(p):
    if p == 'a':
        sh('adb shell input keyevent 4')
    else:
        sh(f'{HDC} shell uitest uiInput keyEvent 2')


def start_app(p):
    if p == 'a':
        sh('adb shell am force-stop io.github.hecate2.paper')
        sh('adb shell am start -n io.github.hecate2.paper/.MainActivity')
    else:
        sh(f'{HDC} shell aa force-stop io.github.hecate2.paper')
        sh(f'{HDC} shell aa start -a EntryAbility -b io.github.hecate2.paper')


def sleep(sec=1.4):
    import time
    time.sleep(sec)


def dismiss_dialog(p):
    root = load(p)
    if p == 'h':
        n = find(root, text='取消', exact=True) if _has(root, text='取消') else None
    else:
        n = find(root, id='button3') if _has(root, id='button3') else None
    if n is not None:
        tap_node(p, n)
        sleep(1.2)


def _has(root, **kw):
    try:
        find(root, **kw)
        return True
    except LookupError:
        return False


def type_into_editor(p):
    """Tap the editor and insert a character so the buffer becomes dirty."""
    root = load(p)
    if p == 'h':
        ed = find(root, cls='TextArea')
        tap_node(p, ed, 0.4, 0.2)
        sleep(1.0)
        sh(f'{HDC} shell uitest uiInput inputText {int(ed.cx * DENSITY[p])} '
           f'{int(ed.cy * DENSITY[p])} x')
    else:
        ed = find(root, cls='EditText')
        tap_node(p, ed, 0.4, 0.2)
        sleep(1.0)
        sh('adb shell input text x')
    sleep(0.6)


def menu_row(p, text):
    root = load(p)
    return find(root, text=text)


SCENARIOS = {
    'editor': [],
    'menu': ['more'],
    'submenu': ['more', ('row', '编码 · ')],
    'save': ['more', ('row', '另存为')],
    'rename': ['more', ('row', '重命名')],
    'close': ['dirty', 'close'],
    'find': ['find'],
}


def ensure_editor(p):
    """Fresh start; if the app lands on the file browser (startup mode = last dir),
    go back to the editor so every scenario starts from the same screen."""
    start_app(p)
    sleep(3.0)
    for _ in range(3):
        try:
            root = load(p)
            if p == 'h' and _has(root, id='actionMore'):
                return
            if p == 'a' and _has(root, desc='More options'):
                return
            if p == 'h' and _has(root, id='browserBack'):
                tap_node(p, find(root, id='browserBack'))
            elif p == 'a' and _has(root, desc='向上导航'):
                tap_node(p, find(root, desc='向上导航'))
            else:
                return
        except Exception:  # noqa: BLE001
            pass
        sleep(1.8)


def setup(p, name):
    """Drive the app on platform p into the named scenario from a fresh start."""
    ensure_editor(p)
    dismiss_dialog(p)
    for step in SCENARIOS[name]:
        if step == 'more':
            root = load(p)
            n = find(root, id='actionMore') if p == 'h' else find(root, desc='More options')
            tap_node(p, n)
        elif step == 'close':
            root = load(p)
            n = find(root, id='actionClose') if p == 'h' else find(root, desc='关闭文件')
            tap_node(p, n)
        elif step == 'find':
            root = load(p)
            n = find(root, id='actionFind') if p == 'h' else find(root, desc='查找替换')
            tap_node(p, n)
        elif step == 'dirty':
            type_into_editor(p)
        elif isinstance(step, tuple) and step[0] == 'row':
            txt = step[1]
            root = load(p)
            hits = [n for n in root.walk() if n.text.startswith(txt)]
            if not hits:
                raise LookupError(f'no menu row {txt!r}')
            n = apply_anchor(p, hits[0], root)
            tap_node(p, n)
        sleep(1.5)
    return True


def apply_anchor(p, node, root):
    """Some nodes are not the click target; redirect to the clickable ancestor/row."""
    for a in node.ancestors():
        if a.cls in ('Row', 'LinearLayout', 'RelativeLayout') and abs(a.h - 48.0) < 1.0:
            return a
    return node


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, p = argv[1], argv[2]
    if cmd == 'setup':
        setup(p, argv[3])
        raw = raw_dump(p)
        print(save(p, argv[3], raw))
        print(shot(p, argv[3]))
        return 0
    if cmd == 'dump':
        raw = raw_dump(p)
        print(save(p, argv[3], raw))
        print(shot(p, argv[3]))
    elif cmd == 'shot':
        print(shot(p, argv[3]))
    elif cmd == 'tap':
        x, y = float(argv[3]), float(argv[4])
        fx = float(argv[5]) if len(argv) > 5 else 0.0
        fy = float(argv[6]) if len(argv) > 6 else 0.0
        tap(p, x + fx, y + fy)
    elif cmd == 'tapnode':
        root = load(p)
        n = find(root, id=argv[3]) if argv[3].isascii() else find(root, text=argv[3])
        tap_node(p, n)
        print('tapped', n.label())
    elif cmd == 'back':
        back(p)
    elif cmd == 'find':
        root = load(p)
        for n in root.walk():
            if argv[3] in n.text or argv[3] == n.id or argv[3] == n.desc:
                print(n.label())
    elif cmd == 'nodes':
        root = load(p)
        t = []
        for n in root.walk():
            if n.text or n.id or n.desc:
                t.append(n.label())
        print('\n'.join(t))
    elif cmd == 'start':
        start_app(p)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
