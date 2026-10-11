#!/usr/bin/env python3
"""Automated UI-parity test: run the same geometry/ink checks against the Android
dump+screenshot and the HarmonyOS dump+screenshot of the same screen.

Every check is one line of the spec below: a label, a function of the measured
quantities, the Android reference value and a tolerance.  The harness reports

    check | android | harmony | delta(android-harmony) | tol | result

and exits non-zero when any row fails.  Sources for each snapshot:

    out/a_<scenario>.xml + out/a_<scenario>.png    (adb)
    out/h_<scenario>.json + out/h_<scenario>.png   (hdc)

Capture with tools/parity/dr.py; scenarios: editor, menu, submenu, close.
"""
import os
import sys

import dr
import pngtool

REF = {
    # measured on API 30 / density 2.75 (see harmony/README.md "实测清单")
    'bar_h': 56.0,
    'item_h': 48.0,
    'item_inset_y': 4.0,
    'icon': 24.0,
}

FAILS = []
BAR = {}
# Tolerances absorb the deliberate, documented platform differences:
#  * ArkUI clips the popup shadow box inside the window, so a right-aligned popup
#    lands ~3dp further left than the Android one (same panel width, same anchor);
#  * Android/Material and ArkUI use different fonts, so only ink *ratios* and icon
#    *shapes* are compared where text metrics are involved.
SUB_RIGHT_TOL = 3.0


class Snap:
    """One platform's dump + screenshot, with the derived pieces the spec needs."""

    def __init__(self, p, scenario):
        self.p = p
        self.density = dr.DENSITY[p]
        self.root = dr.load(p, scenario)
        ext = 'png'
        self.img_path = os.path.join(dr.OUT, f'{p}_{scenario}.{ext}')
        self._img = None
        self.scenario = scenario

    # -- raw access -----------------------------------------------------------
    @property
    def img(self):
        if self._img is None:
            self._img = pngtool.read_png(self.img_path)
        return self._img

    def node(self, **kw):
        try:
            return dr.find(self.root, **kw)
        except LookupError:
            return None

    @property
    def screen(self):
        return dr.screen(self.root)

    # -- derived rect helpers -------------------------------------------------
    def row_of(self, title):
        """The 48dp row containing a titled menu item."""
        t = self.node(text=title)
        if t is None:
            return None
        for a in t.ancestors():
            if abs(a.h - REF['item_h']) < 0.6:
                return a
        return t.parent

    def panel_of(self, row):
        """Highest ancestor sharing the row's left edge and width (= popup panel)."""
        panel = row
        for a in row.ancestors():
            if abs(a.x - row.x) < 0.6 and abs(a.w - row.w) < 0.6:
                panel = a
        return panel

    def rows(self, titles):
        out = [self.row_of(t) for t in titles]
        return [r for r in out if r is not None]

    # -- pixel helpers --------------------------------------------------------
    def ink(self, node, pad=6):
        """Ink bbox of a node's box, in dp (relative to the screen)."""
        w, h, px = self.img
        d = self.density
        x0 = max(0, int((node.x) * d) - pad)
        y0 = max(0, int((node.y) * d) - pad)
        x1 = min(w, int((node.right) * d) + pad)
        y1 = min(h, int((node.bottom) * d) + pad)
        counts = {}
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = px[y * w + x][:3]
                counts[c] = counts.get(c, 0) + 1
        bg = max(counts, key=counts.get)
        bx0, by0, bx1, by1, n, kin = x1, y1, x0, y0, 0, {}
        for y in range(y0, y1):
            for x in range(x0, x1):
                c = px[y * w + x][:3]
                if max(abs(c[i] - bg[i]) for i in range(3)) > 40:
                    n += 1
                    kin[c] = kin.get(c, 0) + 1
                    bx0, by0 = min(bx0, x), min(by0, y)
                    bx1, by1 = max(bx1, x), max(by1, y)
        dark = min(kin, key=lambda c: 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) if kin else bg
        # Colour of a coloured label, read through JPEG + anti-aliasing: average the
        # *bluest 30%* of the ink pixels (a single extreme pixel would be JPEG ringing).
        cand = sorted(kin, key=lambda c: -(c[2] - c[0]))[:max(1, len(kin) // 3)] if kin else []
        blue = (sum(c[0] for c in cand) // len(cand), sum(c[1] for c in cand) // len(cand),
                sum(c[2] for c in cand) // len(cand)) if cand else bg
        return {
            'bcolor': blue,
            'n': n,
            'w': (bx1 - bx0 + 1) / d if n else 0.0,
            'h': (by1 - by0 + 1) / d if n else 0.0,
            'x': bx0 / d,
            'y': by0 / d,
            'right': (bx1 + 1) / d,
            'bottom': (by1 + 1) / d,
            'color': dark,
            'bg': bg,
        }


# --------------------------------------------------------------------- spec --

TITLES7 = ['新建', '打开', '重命名', '另存为', '编码 · ', '恢复备份', '设置']
TITLES5 = ['自动检测', 'UTF-8', 'GBK', 'GB18030', 'Big5', 'UTF-16', 'Latin-1']

DLG_W = 372.4


def _panel_left(s):
    """AlertDialog window = screen - 372.4dp centred; the panel is inset 16dp inside it
    on Android (android_dialog_content), while the HarmonyOS custom panel *is* the window."""
    win = (_screen(s).w - DLG_W) / 2
    return win + (16.0 if s.p == 'a' else 0.0)


def _dlg_w(s):
    """Width of the dialog *panel*: Android's Material panel is inset 16dp inside the
    window; the HarmonyOS customStyle panel is the whole window."""
    return 340.4 if s.p == 'a' else 372.4


def _dlg_right(s):
    return _panel_left(s) + _dlg_w(s)


def _dlg_title(s):
    return s.node(id='alertTitle') if s.p == 'a' else s.node(text='保存文件')


def _dlg_input(s):
    return s.node(id='filenameInput') if s.p == 'a' else s.node(id='saveNameInput')


def _dlg_label(s):
    return s.node(text='保存到：')


def _dlg_browse(s):
    return s.node(id='btnBrowse') if s.p == 'a' else s.node(id='saveBrowse')


def _dlg_btn(s, n):
    if s.p == 'a':
        return s.node(id=f'button{n}')
    return s.node(id='saveOk' if n == 1 else 'saveCancel')


def _msg_title(s):
    return s.node(id='alertTitle') if s.p == 'a' else s.node(text='关闭文件', exact=True)


def _msg_body(s):
    return s.node(id='message') if s.p == 'a' else s.node(text='当前文件有未保存的修改', exact=True)


def _msg_btn(s, role):
    """role: 'neutral' | 'negative' | 'positive' (android ids button3/2/1)."""
    if s.p == 'a':
        return s.node(id={'neutral': 'button3', 'negative': 'button2', 'positive': 'button1'}[role])
    return s.node(id={'neutral': 'dlgNeutral', 'negative': 'dlgNegative',
                      'positive': 'dlgPositive'}[role])


CHECKS = {
    'close': [
        ('title ink left inset', lambda s: _msg_title(s).x - _panel_left(s), 24.0, 1.5),
        ('title bottom -> msg top', lambda s: _msg_body(s).y - _msg_title(s).bottom, 8.0, 1.0),
        # Android's message view spans the full panel (pad=0 keeps the panel edge out
        # of the ink box), so measure where the *text ink* starts
        ('msg ink left inset',
         lambda s: s.ink(_msg_body(s), pad=0)['x'] - _panel_left(s), 25.1, 2.0),
        ('msg top -> btn top', lambda s: _msg_btn(s, 'positive').y - _msg_body(s).y, 52.0, 1.5),
        ('neutral left inset', lambda s: _msg_btn(s, 'neutral').x - _panel_left(s), 12.0, 1.5),
        ('positive right inset',
         lambda s: _dlg_right(s) - _msg_btn(s, 'positive').right, 12.0, 1.5),
        ('btn h', lambda s: _msg_btn(s, 'positive').h, 54.2, 1.0),
        ('btn w neutral', lambda s: _msg_btn(s, 'neutral').w, 64.0, 1.5),
        ('btn w negative', lambda s: _msg_btn(s, 'negative').w, 66.5, 2.5),
        ('btn w positive', lambda s: _msg_btn(s, 'positive').w, 94.9, 2.5),
        ('btn gap n/p', lambda s: _msg_btn(s, 'positive').x - _msg_btn(s, 'negative').right, 0.0, 1.0),
        ('btn h all equal',
         lambda s: _msg_btn(s, 'neutral').bottom - _msg_btn(s, 'positive').bottom, 0.0, 1.0),
    ],
    'save': [
        ('title ink left inset', lambda s: _dlg_title(s).x - _panel_left(s), 24.0, 1.5),
        ('title bottom -> input top', lambda s: _dlg_input(s).y - _dlg_title(s).bottom, 8.0, 1.0),
        ('input left inset', lambda s: _dlg_input(s).x - _panel_left(s), 20.0, 1.5),
        ('input h', lambda s: _dlg_input(s).h, 42.2, 1.0),
        ('label left inset', lambda s: _dlg_label(s).x - _panel_left(s), 20.0, 1.5),
        # label sits centred in the 40dp dir row, whose top is 12dp below the input
        ('dir row top gap',
         lambda s: _dlg_label(s).y - (40 - _dlg_label(s).h) / 2 - _dlg_input(s).bottom, 12.0, 1.5),
        ('browse btn w', lambda s: _dlg_browse(s).w, 40.0, 1.0),
        ('browse btn h', lambda s: _dlg_browse(s).h, 40.0, 1.0),
        ('browse right inset',
         lambda s: _dlg_right(s) - _dlg_browse(s).right, 20.0, 1.5),
        ('btn h', lambda s: _dlg_btn(s, 1).h, 54.2, 1.0),
        ('btn w', lambda s: _dlg_btn(s, 1).w, 64.0, 1.5),
        ('btn gap', lambda s: _dlg_btn(s, 1).x - _dlg_btn(s, 2).right, 0.0, 1.0),
        ('btn right inset',
         lambda s: _dlg_right(s) - _dlg_btn(s, 1).right, 12.0, 1.5),
        ('btn bottom gap',
         lambda s: _dlg_browse(s).bottom - _dlg_btn(s, 1).bottom, 470.2 - 528.4, 1.5),
    ],
    'editor': [
        ('bar h', lambda s: _bar_h(s), 56.0, 1.0),
        ('close item w', lambda s: _item(s, 'actionClose', '关闭文件').w, 48.0, 1.0),
        ('save item w', lambda s: _item(s, 'actionSave', '保存').w, 48.0, 1.0),
        ('find item w', lambda s: _item(s, 'actionFind', '查找替换').w, 48.0, 1.0),
        ('more item w', lambda s: _item(s, 'actionMore', 'More options').w, 40.4, 1.5),
        ('item h', lambda s: _item(s, 'actionClose', '关闭文件').h, 48.0, 1.0),
        ('item top inset', lambda s: _item(s, 'actionClose', '关闭文件').y - _bar(s).y, 4.0, 1.0),
        ('title left inset', lambda s: _title_node(s).x - _bar(s).x, 16.0, 1.5),
        ('more right inset',
         lambda s: s.screen.right - _item(s, 'actionMore', 'More options').right, 0.0, 1.0),
        ('close icon ink h', lambda s: s.ink(_item(s, 'actionClose', '关闭文件'))['h'], None, 1.5),
        ('save icon ink h', lambda s: s.ink(_item(s, 'actionSave', '保存'))['h'], None, 1.5),
        ('more icon ink h', lambda s: s.ink(_item(s, 'actionMore', 'More options'))['h'], None, 1.5),
    ],
    'menu': [
        ('panel w', lambda s: _panel(s, TITLES7).w, 196.0, 0.6),
        ('panel right inset', lambda s: _screen(s).right - _panel(s, TITLES7).right, 4.0, 3.0),
        ('panel top = item top', lambda s: _panel(s, TITLES7).y - _more(s).y, 0.0, 1.2),
        ('rows', lambda s: float(len(s.rows(TITLES7))), 7.0, 0.1),
        ('row h', lambda s: s.rows(TITLES7)[0].h, 48.0, 0.6),
        ('row pitch', lambda s: s.rows(TITLES7)[1].y - s.rows(TITLES7)[0].y, 48.0, 0.6),
        ('title left inset', lambda s: s.node(text='新建').x - _panel(s, TITLES7).x, 16.0, 1.0),
        ('enc title w', lambda s: s.node(text='编码 · ').w, 132.0, 1.5),
        ('enc arrow size', lambda s: _arrow(s).h, 24.0, 1.5),
        ('enc arrow right inset', lambda s: _panel(s, TITLES7).right - _arrow(s).right, 16.0, 1.5),
        ('enc title/arrow gap', lambda s: _arrow(s).x - s.node(text='编码 · ').right, 8.0, 1.5),
    ],
    'submenu': [
        ('panel w', lambda s: _panel(s, TITLES5).w, 226.2, 0.6),
        ('panel right inset', lambda s: _screen(s).right - _panel(s, TITLES5).right, 0.0, SUB_RIGHT_TOL),
        ('panel top = item top', lambda s: _panel(s, TITLES5).y - _more(s).y, 0.0, 1.2),
        ('rows', lambda s: float(len(s.rows(TITLES5))), 7.0, 0.1),
        ('row h', lambda s: s.rows(TITLES5)[0].h, 48.0, 0.6),
        ('header h', lambda s: _header_row(s).h, 48.0, 0.6),
        ('header title left inset',
         lambda s: s.node(text='编码 · ').x - _panel(s, TITLES5).x, 16.0, 1.0),
        ('header/item ink ratio',
         lambda s: s.ink(s.node(text='编码 · '))['h'] / s.ink(s.node(text='自动检测'))['h'],
         0.879, 0.05),
        ('header text R', lambda s: float(s.ink(s.node(text='编码 · '))['bcolor'][0]), 33.0, 25.0),
        ('header text B-R',
         lambda s: float(s.ink(s.node(text='编码 · '))['bcolor'][2]
                     - s.ink(s.node(text='编码 · '))['bcolor'][0]), 210.0, 30.0),
        ('item title w', lambda s: s.node(text='自动检测').w, 162.2, 1.5),
        ('checkbox right inset',
         lambda s: _panel(s, TITLES5).right - _checkbox(s)['right'], 23.2, 1.5),
        ('checkbox box w', lambda s: _checkbox(s)['w'], 18.2, 1.5),
        ('checkbox box h', lambda s: _checkbox(s)['h'], 18.2, 1.5),
        ('checkbox centre on row',
         lambda s: abs((_checkbox(s)['y'] + _checkbox(s)['h'] / 2)
                       - (s.rows(TITLES5)[0].y + 24)), 0.0, 1.5),
        ('checkbox fill R', lambda s: float(_checkbox(s)['color'][0]), 33.0, 45.0),
        ('checkbox fill B', lambda s: float(_checkbox(s)['color'][2]), 243.0, 45.0),
    ],
}


def _chan(c, i):
    return float(c[i])


def _bar_h(s):
    bar = _bar(s)
    return bar.h


def _screen(s):
    """The display rect: Android's uiautomator reports only the *focused* window
    (the popup or the dialog) for those states, so always take the display size from
    the platform's editor snapshot when it is available."""
    if s.scenario != 'editor' and BAR.get(s.p) is not None:
        return BAR[s.p].screen
    return s.screen


def _more(s):
    """The ⋮ action-bar item: read from the platform's *editor* snapshot, because
    Android's popup dump contains only the popup window (no action bar)."""
    if s.scenario in ('menu', 'submenu'):
        ed = BAR.get(s.p)
        if ed is not None:
            return _item(ed, 'actionMore', 'More options')
    return _item(s, 'actionMore', 'More options')


def _bar(s):
    """The 56dp dark action bar."""
    t = s.node(id='actionTitle') or s.node(text='test_lines') or _title_node(s)
    if s.p == 'a':
        n = s.node(cls='FrameLayout', id='action_bar_container')
        return n
    for a in t.ancestors():
        if abs(a.h - 56.0) < 0.6 and a.w > s.screen.w * 0.9:
            return a
    return t.parent


def _android_bar(s):
    return _bar(s).h


def _item(s, hid, desc):
    if s.p == 'h':
        return s.node(id=hid)
    return s.node(desc=desc)


def _title_node(s):
    if s.p == 'a':
        # first TextView inside the action bar (the file title)
        bar = s.node(cls='FrameLayout', id='action_bar_container')
        for n in bar.walk():
            if n.cls == 'TextView':
                return n
    return s.node(id='actionTitle')


def _panel(s, titles):
    return s.panel_of(s.rows(titles)[0])


def _arrow(s):
    if s.p == 'h':
        row = s.node(id='menuEncoding')
    else:
        row = s.row_of('编码 · ')
    cand = [n for n in row.walk() if n.cls in ('Image', 'ImageView')]
    if not cand:
        raise LookupError('no arrow image in the encoding row')
    # the arrow is the right-most image
    return max(cand, key=lambda n: n.right)


def _header_row(s):
    if s.p == 'h':
        t = s.node(text='编码 · ')
        for a in t.ancestors():
            if abs(a.h - 48.0) < 0.6:
                return a
    # android: the header row is the parent chain element with the checkbox-less content
    t = s.node(text='编码 · ')
    for a in t.ancestors():
        if abs(a.h - 48.0) < 0.6:
            return a
    return t.parent


def _checkbox(s):
    """Ink of the first (checked) encoding checkbox, in dp, plus its fill colour."""
    row = s.rows(TITLES5)[0]
    title = s.node(text='自动检测')
    d = s.density
    w, h, px = s.img
    x0 = int((title.right + 2) * d)
    x1 = int((row.right - 4) * d)
    y0 = int((row.y + 3) * d)
    y1 = int((row.bottom - 3) * d)
    bx0, by0, bx1, by1, n, kin = x1, y1, x0, y0, 0, {}
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            c = px[y * w + x][:3]
            if max(abs(c[i] - 250) for i in range(3)) > 40:
                n += 1
                kin[c] = kin.get(c, 0) + 1
                bx0, by0 = min(bx0, x), min(by0, y)
                bx1, by1 = max(bx1, x), max(by1, y)
    dom = max(kin, key=kin.get) if kin else (0, 0, 0)
    return {
        'w': (bx1 - bx0 + 1) / d if n else 0.0,
        'h': (by1 - by0 + 1) / d if n else 0.0,
        'x': bx0 / d,
        'y': by0 / d,
        'right': (bx1 + 1) / d,
        'bottom': (by1 + 1) / d,
        'color': dom,
        'n': n,
    }


def run(scenario, tol_scale=1.0):
    snaps = {}
    for p in ('a', 'h'):
        try:
            snaps[p] = Snap(p, scenario)
            snaps[p].root  # force load
            if scenario != 'editor':
                BAR[p] = Snap(p, 'editor')
        except Exception as e:  # noqa: BLE001
            print(f'!! cannot load {p} snapshot for "{scenario}": {e}')
            return 2
    print(f'\n=== {scenario} ===')
    print(f'{"check":28s} {"android":>10s} {"harmony":>10s} {"Δ":>8s} {"tol":>6s}  result')
    for label, fn, expect, tol in CHECKS[scenario]:
        tol = tol * tol_scale
        try:
            va = fn(snaps['a'])
            va = float(va)
        except Exception as e:  # noqa: BLE001
            print(f'{label:28s} {"ERR":>10s} {"":>10s} {"":>8s} {tol:6.2f}  android: {e}')
            FAILS.append((scenario, label, 'android-error'))
            continue
        try:
            vh = float(fn(snaps['h']))
        except Exception as e:  # noqa: BLE001
            print(f'{label:28s} {va:10.2f} {"ERR":>10s} {"":>8s} {tol:6.2f}  harmony: {e}')
            FAILS.append((scenario, label, 'harmony-error'))
            continue
        delta = va - vh
        ref_ok = expect is None or abs(va - expect) <= tol + 1.0
        same = abs(delta) <= tol
        if ref_ok and same:
            res = 'ok'
        elif not ref_ok:
            res = f'AND-REF({expect:g})'
            FAILS.append((scenario, label, res))
        else:
            res = 'DIFF'
            FAILS.append((scenario, label, res))
        print(f'{label:28s} {va:10.2f} {vh:10.2f} {delta:8.2f} {tol:6.2f}  {res}')
    return 0


def main(argv):
    scen = argv[1:] or ['editor', 'menu', 'submenu', 'save', 'close']
    rc = 0
    for s in scen:
        rc |= run(s)
    print('\n--- summary ---')
    if FAILS:
        for s, l, r in FAILS:
            print(f'FAIL {s}: {l} ({r})')
        print(f'{len(FAILS)} check(s) failed')
        return 1
    print('all checks passed')
    return rc


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
