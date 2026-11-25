#!/bin/zsh
# 构建并安装到 /Applications，注册为登录项。
# 用法：./install.sh [--no-login]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Isla.app"
SRC="$ROOT/build/Isla.app"

"$ROOT/build.sh"

echo "→ 退出正在运行的实例"
pkill -x Isla 2>/dev/null || true
sleep 0.6

# 已注册的 bundle 直接 rm 会被 macOS 27 挪进废纸篓（AppCleaner 随即弹窗），先挪出再删
if [ -d "$APP" ]; then
  STALE="/tmp/.isla-old-$$.app"
  mv "$APP" "$STALE" 2>/dev/null && rm -rf "$STALE"
fi

echo "→ 安装到 $APP"
ditto "$SRC" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [ "${1:-}" != "--no-login" ]; then
  echo "→ 注册登录项"
  "$APP/Contents/MacOS/Isla" --set-login on || echo "⚠️ 登录项注册失败，可在设置窗口里手动打开"
else
  "$APP/Contents/MacOS/Isla" --login-status || true
fi

echo "→ 启动"
open "$APP"
echo "完成：$APP"
