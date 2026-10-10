#!/bin/bash
# 白纸鸿蒙版真机/模拟器 E2E（全自动，需模拟器已启动且 hdc 可连）。
# 用法：bash harmony/tests/e2e/e2e.sh
# 每步截图进 tests/e2e/shots/（已进 .gitignore），PASS/FAIL 逐行打印。
set -u
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
DIR="$(cd "$(dirname "$0")" && pwd)"
SHOTS="$DIR/shots"
BUNDLE=io.github.hecate2.paper
HAP="$DIR/../../entry/build/default/outputs/default/entry-default-unsigned.hap"
PASS=0; FAIL=0

log()  { echo "$1"; }
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
shot() { $HDC shell snapshot_display -f /data/local/tmp/e2e.jpeg >/dev/null 2>&1; $HDC file recv /data/local/tmp/e2e.jpeg "$SHOTS/$1.jpeg" >/dev/null 2>&1; }
tap()  { python3 "$DIR/tap.py" "$1" ${2:-0} | tail -1; sleep 2; }
typein() { $HDC shell uitest uiInput inputText "$1" "$2" "$3" >/dev/null 2>&1; sleep 2; }
typein_at() { # $1 文本/id 定位控件后输入 $2
  C=$(python3 "$DIR/tap.py" --coords "$1" 2>/dev/null | head -1)
  [ -n "$C" ] && typein $C "$2" || { echo "NOT-FOUND(input-target) $1"; return 1; }
}
has_text() { # $1 文本在当前界面是否存在（dumpLayout 断言）
  $HDC shell uitest dumpLayout -p /data/local/tmp/e2e_ui.json >/dev/null 2>&1
  $HDC file recv /data/local/tmp/e2e_ui.json /tmp/e2e_ui.json >/dev/null 2>&1
  python3 -c "import json,sys; d=json.load(open('/tmp/e2e_ui.json')); s=json.dumps(d,ensure_ascii=False); sys.exit(0 if '''$1''' in s else 1)"
}

mkdir -p "$SHOTS"
[ -f "$HAP" ] || { echo "HAP 不存在，先构建"; exit 1; }

log "== 0. 清数据，保证确定性首跑 =="
$HDC shell bm clean -n $BUNDLE -d >/dev/null 2>&1
sleep 2
$HDC shell aa start -a EntryAbility -b $BUNDLE | tail -1
sleep 4
shot 00-launch
has_text "未命名" && pass "冷启动空草稿" || fail "冷启动空草稿"

log "== 1. 输入并首次保存（选目录流程） =="
typein 630 1100 "e2e-hello白纸"
tap actionSave; shot 01-after-save-tap
has_text "此目录为空" && pass "无目录史进选目录页" || fail "无目录史进选目录页"
tap browserPickDir; shot 02-save-dialog
has_text "保存文件" && pass "保存对话框" || fail "保存对话框"
tap saveOk; sleep 3; shot 03-saved
FN=$($HDC shell "ls /data/app/el2/100/base/$BUNDLE/haps/entry/files/ 2>/dev/null" | tr -d '\r' | grep '\.txt$' | grep -v '\.bak$' | head -1)
[ -n "$FN" ] && pass "文件已落盘: $FN" || fail "文件已落盘"
$HDC file recv "/data/app/el2/100/base/$BUNDLE/haps/entry/files/$FN" /tmp/e2e_v1.txt >/dev/null 2>&1
grep -q "e2e-hello白纸" /tmp/e2e_v1.txt 2>/dev/null && pass "落盘内容正确" || fail "落盘内容正确"
echo "$FN" > /tmp/e2e_fn.txt

log "== 2. 二次保存产生 .bak =="
typein 630 1100 "-v2"
tap actionSave; sleep 3
$HDC file recv "/data/app/el2/100/base/$BUNDLE/haps/entry/files/$FN.bak" /tmp/e2e_bak.txt >/dev/null 2>&1
grep -q "e2e-hello白纸$" /tmp/e2e_bak.txt 2>/dev/null && pass ".bak 保留上一版" || { cat /tmp/e2e_bak.txt; fail ".bak 保留上一版"; }
shot 04-second-save

log "== 3. 关闭重进：记住上次文件 =="
tap actionClose; sleep 1; shot 05-close-dialog
has_text "不保存" && pass "关闭确认框" || fail "关闭确认框"
tap "不保存"; sleep 2; shot 06-browser
has_text "$FN" && pass "关闭后进浏览器并列出文件" || fail "关闭后进浏览器并列出文件"
tap "$FN"; sleep 3; shot 07-reopened
has_text "e2e-hello白纸-v2" && pass "点文件重开内容正确" || fail "点文件重开内容正确"

log "== 4. 查找替换 =="
tap actionFind; sleep 1
typein_at findInput "白纸"; sleep 2; shot 08-find
has_text "1/1" && pass "查找到 1/1" || fail "查找到 1/1"
tap findReplaceAll; sleep 2; shot 09-replaced
has_text "e2e-hello-v2" && pass "全部替换生效" || fail "全部替换生效"
tap findClose; sleep 1

log "== 5. 恢复备份 =="
tap actionMore; sleep 1
tap "恢复备份"; sleep 1; shot 10-restore-dialog
tap "保存"; sleep 3; shot 11-restored
has_text "e2e-hello白纸" && pass "从 .bak 恢复" || fail "从 .bak 恢复"

log "== 6. 设置页 =="
tap actionMore; sleep 1
tap "设置"; sleep 2; shot 12-settings
has_text "启动时打开" && pass "设置页" || fail "设置页"
tap settingsBack; sleep 2
has_text "e2e-hello白纸" && pass "设置返回编辑器" || fail "设置返回编辑器"

log "== 7. 编码切换 =="
tap actionMore; sleep 1
tap "编码"; sleep 1; shot 13-encoding
has_text "GBK" && pass "编码选项框" || fail "编码选项框"
tap "GBK"; sleep 2
tap actionMore; sleep 1; shot 14-gbk
has_text "编码 · GBK" && pass "编码菜单显示 GBK" || fail "编码菜单显示 GBK"
tap "返回" 2>/dev/null; $HDC shell uitest uiInput keyEvent Back >/dev/null 2>&1; sleep 1

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL shots=$SHOTS"
[ "$FAIL" -eq 0 ]
