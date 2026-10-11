#!/bin/bash
# 大文件黑盒压测 v2（单会话、无重启、无清框：全靠“追加输入”的确定性）：
# 空草稿 → 种子 eee → 开查找（query=e，replacement=33×e，只输一次）
# → 替换 ×4（3B→99B→3.2KB→108KB→3.5MB）→ replacement 追加一个 e（34×e）
# → 替换 ×1（≈7MB，过 5MB 可编辑线）→ 存盘 → 冷重进验证只读 → 查找计数。
set -u
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
DIR="$(cd "$(dirname "$0")" && pwd)"
SHOTS="$DIR/shots"
BUNDLE=io.github.hecate2.paper
PASS=0; FAIL=0
T0=$(date +%s)
E33=$(python3 -c "print('e'*33)")

pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
shot() { $HDC shell snapshot_display -f /data/local/tmp/e2e.jpeg >/dev/null 2>&1; $HDC file recv /data/local/tmp/e2e.jpeg "$SHOTS/$1.jpeg" >/dev/null 2>&1; }
tap()  { python3 "$DIR/tap.py" "$1" ${2:-0} 2>&1 | grep -E "^(TAP|NOT-FOUND|No Error)" | tail -2; sleep 2; }
typein_at() {
  C=$(python3 "$DIR/tap.py" --coords "$1" 2>/dev/null | head -1)
  [ -n "$C" ] && { $HDC shell uitest uiInput inputText $C "$2" >/dev/null 2>&1; sleep 2; } || { echo "NOT-FOUND(input-target) $1"; return 1; }
}
has_text() {
  $HDC shell uitest dumpLayout -p /data/local/tmp/e2e_ui.json >/dev/null 2>&1
  $HDC file recv /data/local/tmp/e2e_ui.json /tmp/e2e_ui.json >/dev/null 2>&1
  python3 -c "import json,sys; d=json.load(open('/tmp/e2e_ui.json')); s=json.dumps(d,ensure_ascii=False); sys.exit(0 if '''$1''' in s else 1)"
}
phase() { echo "== $1 (t+$(( $(date +%s) - T0 ))s) =="; }
abort() { echo "ABORT: $1"; shot abort; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }
disk_size() {
  $HDC file recv "/data/app/el2/100/base/$BUNDLE/haps/entry/files/$1" /tmp/e2e_sz.bin >/dev/null 2>&1 && wc -c < /tmp/e2e_sz.bin || echo 0
}

mkdir -p "$SHOTS"
$HDC shell aa start -a EntryAbility -b $BUNDLE >/dev/null 2>&1; sleep 4

phase "0. 收敛到空草稿（关掉一切对话框/菜单/查找栏）"
tap "取消" >/dev/null 2>&1; sleep 1
tap "取消" >/dev/null 2>&1; sleep 1
tap actionClose; sleep 1
has_text "不保存" && tap "不保存" || true
sleep 2
tap browserNewFile || abort "到不了空草稿"
sleep 2
has_text "未命名" || abort "空草稿标题不对"
$HDC shell uitest uiInput inputText 630 1100 "eee" >/dev/null 2>&1; sleep 2
shot big-00-seed

phase "1. 开查找，query=e replacement=33e（各输一次）"
tap actionFind; sleep 1
has_text "查找…" || abort "查找栏没打开"
typein_at findInput "e" || abort "query 输入失败"
typein_at replaceInput "$E33" || abort "replacement 输入失败"
shot big-01-findready

phase "2. 替换 ×4（指数放大，每轮计时）"
i=1
while [ $i -le 4 ]; do
  S=$(date +%s); tap findReplaceAll || abort "第${i}轮替换点不上"
  echo "round $i replace-all took $(( $(date +%s) - S ))s"
  i=$((i+1))
done
shot big-02-grown
echo "(期望内容 ~3.5MB 全 e)"

phase "3. replacement 追加一个 e（33→34），再替换一次（≈7MB 过线）"
typein_at replaceInput "e" || abort "replacement 追加失败"
S=$(date +%s); tap findReplaceAll || abort "过线轮替换点不上"
echo "x2 replace-all took $(( $(date +%s) - S ))s"
tap findClose; sleep 1
shot big-03-big

phase "4. 存盘记名"
tap actionSave; sleep 2
if has_text "保存文件"; then
  echo "(save dialog directly)"
elif has_text "此目录为空"; then
  tap browserPickDir; sleep 2
else
  shot big-04-nosavedialog; abort "存盘既没弹对话框也没进选目录"
fi
has_text "保存文件" || abort "存盘没弹保存对话框"
typein_at saveNameInput "-big7m"
FN=$(python3 -c "
import json
d=json.load(open('/tmp/e2e_ui.json'))
def w(n):
    a=n.get('attributes',{})
    if a.get('id')=='saveNameInput': print(a.get('text','')); return True
    return any(w(c) for c in (n.get('children') or []))
w(d)" | tr -d '\r\n')
echo "saving as: $FN"
[ -n "$FN" ] || abort "读不到对话框文件名"
S=$(date +%s); tap "保存"; sleep 12
if has_text "是否覆盖"; then echo "(overwrite confirm)"; tap "保存"; sleep 12; fi
echo "save ~7MB took $(( $(date +%s) - S ))s (含对话框)"
SZ=$(disk_size "$FN"); echo "on-disk bytes: $SZ"
[ "$SZ" -gt 5000000 ] && pass "7MB 落盘 ($SZ B)" || fail "7MB 落盘 ($SZ B)"
shot big-04-saved

phase "5. 冷重进：应进只读分层"
$HDC shell aa force-stop $BUNDLE >/dev/null 2>&1; sleep 2
$HDC shell aa start -a EntryAbility -b $BUNDLE >/dev/null 2>&1; sleep 10
shot big-05-reopen
has_text "只读" && pass "超 5MB 只读横幅" || fail "超 5MB 只读横幅"

phase "6. 只读下查找计数（20万上限），计时"
tap actionFind; sleep 1
typein_at findInput "ee" || abort "只读查找输入失败"
S=$(date +%s); sleep 12; shot big-06-find
echo "find over 7MB took >=$(( $(date +%s) - S ))s wall"
has_text "200000" && pass "命中上限 200000" || fail "命中上限 200000"
tap findClose; sleep 1

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL（7MB 文件留存在模拟器沙箱，属测试代价）"
[ "$FAIL" -eq 0 ]
