#!/bin/zsh
# 自动化验收：几何不变量（I1） + 空闲资源占用。
# 用法：./tools/verify.sh [CPU 采样秒数]
# 说明：几何断言需要面板在屏上；面板收起时会临时用演示模式重启，验完自动恢复。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 默认验 dev 包；若当前跑的是 /Applications 那份，就验那份、验完也恢复那份
BUNDLE="${ISLA_BUNDLE_ID:-com.yopo.isla}"
RUNNING=$(lsappinfo info -only bundlepath $(lsappinfo find bundleid="$BUNDLE") 2>/dev/null | sed -n 's/.*bundle path="\(.*\)"/\1/p')
APP="${RUNNING:-$ROOT/build/Isla.app}"
BUILD="$ROOT/build/.tools"
mkdir -p "$BUILD"

if ! pgrep -x Isla >/dev/null; then
  echo "✗ Isla 未运行，先 open \"$APP\""
  exit 1
fi

echo "→ 编译验收工具"
swiftc -O "$ROOT/tools/verify-windows.swift" -o "$BUILD/verify-windows" || exit 1
swiftc -O "$ROOT/tools/verify-follow.swift"  -o "$BUILD/verify-follow"  || exit 1
swiftc -O "$ROOT/tools/sample-proc.swift"   -o "$BUILD/sample-proc"    || exit 1

RESTORE=0
restore() {
  if [ "$RESTORE" = 1 ]; then
    defaults write "$BUNDLE" demo -bool false
    pkill -x Isla 2>/dev/null
    sleep 0.8
    open "$APP"
  fi
}
trap restore EXIT

echo
echo "=== 1. 面板零遮挡（I1；居中浮胶囊单独计数）==="
if ! "$BUILD/verify-windows" >/dev/null 2>&1; then
  echo "面板当前收起 → 以演示模式重启，取真实窗口做断言"
  RESTORE=1
  defaults write "$BUNDLE" demo -bool true
  pkill -x Isla 2>/dev/null
  sleep 0.8
  open "$APP"
  sleep 2.5
fi
if ! "$BUILD/verify-windows"; then
  echo "✗ 存在窗口越过菜单栏下沿"
  exit 2
fi

echo
echo "=== 1b. 居中形态：面板跟随浮胶囊 ==="
if ! ISLA_BUNDLE_ID="$BUNDLE" "$BUILD/verify-follow"; then
  echo "✗ 面板没有跟随浮胶囊"
  exit 5
fi

echo
echo "=== 2. 资源占用（收起态；CPU < 1.2%，内存 < 60MB）==="
RESTORE=1
defaults write "$BUNDLE" demo -bool false
pkill -x Isla 2>/dev/null
sleep 0.8
open "$APP"
sleep 1.5
RESTORE=0

PID=$(pgrep -x Isla | head -1)
OUT=$("$BUILD/sample-proc" "$PID" "${1:-4}")
echo "$OUT"
CPU=$(echo "$OUT" | sed -n 's/.*cpu=\([0-9.]*\)%.*/\1/p')
MEM=$(echo "$OUT" | sed -n 's/.*mem=\([0-9.]*\) MB.*/\1/p')
# 预算说明：静止时约 0.05%；如果正在播带歌词的歌，胶囊按所选帧率（30/60/90/120）
# 重绘滚动歌词，实测 30fps≈0.6%、60fps≈0.9%，所以这里的红线放到 1.2%。
awk -v c="$CPU" 'BEGIN{exit !(c<1.2)}' || { echo "✗ CPU 超预算（>1.2%）"; exit 3; }
awk -v m="$MEM" 'BEGIN{exit !(m<60)}'  || { echo "✗ 常驻内存超预算"; exit 4; }

echo
echo "✓ 验收通过"
