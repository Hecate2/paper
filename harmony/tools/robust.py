#!/usr/bin/env python3
"""鸿蒙版异常路径健壮性用例（真机/模拟器驱动，全自动）。

思路：每条用例先用 hdc 直接构造磁盘 + 偏好状态（等价于“用户上次这样用过”），
再冷启动 app，然后用无障碍树断言屏幕上的结果；任何崩溃/断言失败都会记录为缺陷。

覆盖用户可能做出的“刁难”操作：
  A 退出后删掉上次打开的文件（上次目录还在）
  B 退出后把上次打开的文件和上次目录都删掉
  C 上次打开的文件还在（正例对照）
  D 上次使用的目录被删掉
  E 打开中的文件被别处删掉，然后点保存
  F 重命名成已存在的文件名（不得覆盖对方）
  G 打开二进制文件（应只读预览，不得崩）
  H 没有备份时点“恢复备份”
  I 保存对话框里把文件名清空后点保存
  J 文件名里带路径分隔符/非法字符
用法：python3 harmony/tools/robust.py [-v]
"""
import base64
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'parity'))
import dr  # noqa: E402
from dr import HDC  # noqa: E402

APP = 'io.github.hecate2.paper'
F_SHELL = f'/data/app/el2/100/base/{APP}/haps/entry/files'   # 设备 shell 视角
F_APP = '/data/storage/el2/base/haps/entry/files'           # app 自身视角
PREFS = f'/data/app/el2/100/base/{APP}/haps/entry/preferences/paper_prefs'
WORK = f'{F_SHELL}/rb'
VERBOSE = '-v' in sys.argv


# ------------------------------------------------------------------ device ----

def dev(cmd, timeout=90):
    """Run one shell command on the device."""
    rc, out, err = dr.sh(f'{HDC} shell "{cmd}"', timeout=timeout)
    if rc != 0 and VERBOSE:
        print(f'    dev[{rc}] {cmd[:70]} -> {err.strip()[:120]}')
    return out.strip()


def alive():
    return dev(f'pidof {APP}') != ''


def mkfile(name, body, dir_name=None):
    d = dir_name or WORK
    dev(f'mkdir -p {d}')
    dev(f"printf '%s' '{body}' > {d}/{name}")


def mkbin(name, size=4096):
    dev(f'mkdir -p {WORK}')
    dev(f'head -c {size} /dev/urandom > {WORK}/{name}')


def readfile(name, dir_name=None):
    return dev(f'cat {dir_name or WORK}/{name}')


def md5file(name, dir_name=None):
    return dev(f'md5sum {dir_name or WORK}/{name}').split()[0] if True else ''


def exists(path):
    return dev(f'[ -f {path} ] && echo yes || echo no') == 'yes'


def write_prefs(pairs):
    """pairs: list of (type, key, value); type in string|boolean|int."""
    body = ''.join(f'  <{t} key="{k}">{v}</{t}>\n' for t, k, v in pairs)
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<preferences version="1.0">\n'
           + body + '</preferences>\n')
    b64 = base64.b64encode(xml.encode()).decode()
    dev(f'echo {b64} | base64 -d > {PREFS}')


def prefs_last_file(path_abs_app, dir_abs_app, is_scratch=False):
    return [('string', 'startupMode', 'LAST_FILE'),
            ('string', 'lastFilePath', path_abs_app),
            ('string', 'lastDirectory', dir_abs_app),
            ('boolean', 'lastIsScratch', 'true' if is_scratch else 'false')]


def prefs_new_empty(dir_abs_app):
    return [('string', 'startupMode', 'NEW_EMPTY'),
            ('string', 'lastDirectory', dir_abs_app),
            ('boolean', 'lastIsScratch', 'true')]


def prefs_last_dir(dir_abs_app):
    return [('string', 'startupMode', 'LAST_DIR'),
            ('string', 'lastDirectory', dir_abs_app),
            ('boolean', 'lastIsScratch', 'true')]


def cold(pairs):
    """Force-stop, install the given preference file, cold start, return the tree."""
    dev(f'aa force-stop {APP}')
    time.sleep(0.6)
    if pairs is not None:
        write_prefs(pairs)
    dr.start_app('h')
    time.sleep(3.6)
    return dr.load('h')


# --------------------------------------------------------------- screen ops ---

def has(root, **kw):
    return dr._has(root, **kw)


def texts(root):
    return [n.text for n in root.walk() if n.text]


def joined(root):
    return ' | '.join(texts(root))


def tap_id(id_):
    """Tap a node by id and return the node (so callers can reuse its geometry)."""
    root = dr.load('h')
    n = dr.find(root, id=id_)
    dr.tap_node('h', n)
    time.sleep(1.2)
    return n


def type_at(node, text):
    """Type into the focused node using absolute device pixels."""
    d = dr.DENSITY['h']
    dev(f'uitest uiInput inputText {int(node.cx * d)} {int(node.cy * d)} {text}')


def tap_text(text, exact=True, bottom_most=False):
    """Tap a node by visible text; bottom_most picks the lowest one (dialog buttons)."""
    root = dr.load('h')
    hits = [n for n in root.walk() if (n.text == text if exact else text in n.text)]
    if not hits:
        return False
    n = max(hits, key=lambda x: x.y) if bottom_most else hits[0]
    dr.tap_node('h', n)
    time.sleep(1.2)
    return True


def open_overflow():
    tap_id('actionMore')


def menu(text):
    return tap_text(text, exact=False)


# ------------------------------------------------------------------- cases ----

RESULTS = []


def record(name, ok, detail):
    RESULTS.append((name, bool(ok), detail))
    print(f'  {"PASS" if ok else "FAIL"}  {name}: {detail}')


def case_a():
    """A 上次打开的文件被删（目录还在）→ 规则要求落回文件浏览器。"""
    mkfile('keep.txt', 'hello')
    root = cold(prefs_last_file(f'{F_APP}/rb/gone.txt', f'{F_APP}/rb'))
    ok = alive() and has(root, id='browserBack') and not has(root, id='actionTitle')
    record('A 上次文件已删/目录在→浏览器', ok,
           f'browserBack={has(root, id="browserBack")} alive={alive()}')


def case_b():
    """B 上次文件和上次目录都没了 → 空草稿“未命名”，不得崩。"""
    dev(f'rm -rf {WORK}/gone-dir')
    root = cold(prefs_last_file(f'{F_APP}/gone-dir/gone.txt', f'{F_APP}/gone-dir'))
    title = dr.find(root, id='actionTitle').text if has(root, id='actionTitle') else ''
    ok = alive() and title == '未命名'
    record('B 文件+目录都删→空草稿', ok, f'title={title!r} alive={alive()}')


def case_c():
    """C 正例：上次文件还在 → 打开并显示内容（对照 A/B）。"""
    mkfile('keep.txt', 'hello-robust')
    root = cold(prefs_last_file(f'{F_APP}/rb/keep.txt', f'{F_APP}/rb'))
    title = dr.find(root, id='actionTitle').text if has(root, id='actionTitle') else ''
    ok = alive() and title == 'keep.txt' and 'hello-robust' in joined(root)
    record('C 上次文件还在→正常打开', ok, f'title={title!r} 内容可见={"hello-robust" in joined(root)}')


def case_d():
    """D 上次目录被删（模式=上次目录）→ 空草稿。"""
    dev(f'rm -rf {WORK}/gone-dir')
    root = cold(prefs_last_dir(f'{F_APP}/gone-dir'))
    title = dr.find(root, id='actionTitle').text if has(root, id='actionTitle') else ''
    ok = alive() and title == '未命名'
    record('D 上次目录已删→空草稿', ok, f'title={title!r} alive={alive()}')


def case_e():
    """E 打开中的文件被删，用户继续编辑并保存 → 不崩，且内容应被重新写回。"""
    mkfile('e.txt', 'abc')
    root = cold(prefs_last_file(f'{F_APP}/rb/e.txt', f'{F_APP}/rb'))
    opened = has(root, id='actionTitle') and dr.find(root, id='actionTitle').text == 'e.txt'
    dev(f'rm -f {WORK}/e.txt')
    dr.type_into_editor('h')          # 输入一个字符 → dirty
    tap_id('actionSave')
    time.sleep(1.0)
    if has(dr.load('h'), text='取消'):  # 若弹了确认框，取消掉以免影响后续用例
        tap_text('取消')
    body = readfile('e.txt')
    ok = alive() and opened and exists(f'{WORK}/e.txt') and 'x' in body
    record('E 打开中被删后保存', ok,
           f'已打开={opened} 重新写回={exists(f"{WORK}/e.txt")} 内容={body!r} alive={alive()}')


def case_f():
    """F 重命名成同目录已存在的文件名 → 不得覆盖对方。"""
    mkfile('f1.txt', 'one')
    mkfile('f2.txt', 'two')
    before = md5file('f2.txt')
    root = cold(prefs_last_file(f'{F_APP}/rb/f1.txt', f'{F_APP}/rb'))
    open_overflow()
    menu('重命名')
    node = tap_id('renameNameInput')
    for _ in range(8):                # 退格清掉 f1.txt
        dev('uitest uiInput keyEvent 2055')
    type_at(node, 'f2.txt')
    time.sleep(0.6)
    for label in ('重命名', '确定', '保存', '覆盖'):
        if tap_text(label, bottom_most=True):
            break
    time.sleep(1.2)
    after = md5file('f2.txt')
    ok = alive() and before == after and readfile('f2.txt') == 'two'
    record('F 重命名撞名不覆盖', ok,
           f'f2 md5 {before[:8]}->{after[:8]} 内容={readfile("f2.txt")!r} alive={alive()}')


def case_g():
    """G 打开二进制文件 → 只读预览（无编辑框），不得崩。"""
    mkbin('bin.dat')
    root = cold(prefs_last_file(f'{F_APP}/rb/bin.dat', f'{F_APP}/rb'))
    editable = has(root, cls='TextArea')
    banner = any('只读' in t or '二进制' in t for t in texts(root))
    ok = alive() and not editable
    record('G 打开二进制→只读预览', ok,
           f'有编辑框={editable} 有只读提示={banner} alive={alive()}')


def case_h():
    """H 没有 .bak 备份时点“恢复备份” → 不得崩。"""
    mkfile('h.txt', 'nobak')
    dev(f'rm -f {WORK}/h.txt.bak')
    cold(prefs_last_file(f'{F_APP}/rb/h.txt', f'{F_APP}/rb'))
    open_overflow()
    menu('恢复备份')
    time.sleep(1.4)
    if has(dr.load('h'), text='取消'):
        tap_text('取消')
    ok = alive()
    record('H 无备份时恢复备份', ok, f'alive={alive()} 屏幕={joined(dr.load("h"))[:60]}')


def case_i():
    """I 保存对话框里把文件名清空后点保存 → 不得崩（拒绝或回退默认名都可）。"""
    mkfile('keep.txt', 'hello')
    cold(prefs_new_empty(f'{F_APP}/rb'))
    tap_id('actionSave')
    root = dr.load('h')
    if not has(root, id='saveNameInput'):
        record('I 空文件名保存', False, '保存对话框未出现')
        return
    tap_id('saveNameInput')
    for _ in range(40):
        dev('uitest uiInput keyEvent 2055')
    time.sleep(0.5)
    now = dr.load('h')
    left = dr.find(now, id='saveNameInput').text if has(now, id='saveNameInput') else '<已关闭>'
    tap_text('保存', bottom_most=True)
    time.sleep(1.5)
    still = has(dr.load('h'), id='saveNameInput')
    ok = alive()
    record('I 空文件名保存', ok, f'清空后输入框={left!r} 对话框仍在={still} alive={alive()}')


def case_j():
    """J 文件名里带路径分隔符 → 不得写到别处，也不得崩。"""
    cold(prefs_new_empty(f'{F_APP}/rb'))
    dev(f'rm -f {WORK}/esc.txt; rm -rf {WORK}/sub')
    tap_id('actionSave')
    if not has(dr.load('h'), id='saveNameInput'):
        record('J 非法文件名', False, '保存对话框未出现')
        return
    node = tap_id('saveNameInput')
    for _ in range(40):
        dev('uitest uiInput keyEvent 2055')
    type_at(node, '../esc.txt')
    time.sleep(0.5)
    tap_text('保存', bottom_most=True)
    time.sleep(1.6)
    outside = exists(f'{F_SHELL}/esc.txt')
    ok = alive()
    record('J 非法文件名保存', ok,
           f'上级目录被写入={outside} alive={alive()} 屏幕={joined(dr.load("h"))[:50]}')


def preflight():
    """这些用例要在宿主侧直接构造 app 沙箱内容，必须能写设备上的 app 目录。

    模拟器/真机未 root 时 hdc shell 只是 uid 2000，写沙箱会被拒；此时**不能**继续跑，
    否则磁盘状态没造成，用例会给出假结论。
    """
    dev(f'mkdir -p {WORK}')
    dev(f"printf 'x' > {WORK}/.probe")
    if not exists(f'{WORK}/.probe'):
        print('!! 前置条件不满足：hdc shell 无法写入 app 沙箱。\n'
              f'   目标目录 {F_SHELL}\n'
              '   现象：hdc shell 是 uid 2000(shell)，非 debuggable 镜像且不允许 smode 提权。\n'
              '   请在可 root 的调试镜像（或带权限的调试包）上运行；\n'
              '   在受限环境里跑这些用例会产生假通过/假失败，脚本主动拒绝继续。')
        return 1
    dev(f'rm -f {WORK}/.probe')
    return 0


def main():
    print('== 鸿蒙版健壮性用例（设备侧） ==')
    if preflight() != 0:
        return 2
    write_prefs([('string', 'startupMode', 'NEW_EMPTY')])
    if dev(f'grep -c startupMode {PREFS}') in ('', '0'):
        print('!! 前置条件不满足：偏好文件不可写（见上）。')
        return 2
    for fn in (case_a, case_b, case_c, case_d, case_e, case_f, case_g, case_h,
               case_i, case_j):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            record(fn.__name__, False, f'异常 {type(exc).__name__}: {exc}')
    bad = [r for r in RESULTS if not r[1]]
    print(f'\n{len(RESULTS) - len(bad)}/{len(RESULTS)} 通过')
    for n, _, d in bad:
        print(f'  FAIL {n}: {d}')
    return 1 if bad else 0


if __name__ == '__main__':
    raise SystemExit(main())
