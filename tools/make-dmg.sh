#!/bin/zsh
# 生成 ad-hoc 分发的 DMG + ZIP（不需要 Apple 开发者账号）。
#
#   ./tools/make-dmg.sh          # 先跑过 build.sh；产物在 dist/
#   ./tools/make-dmg.sh --sign   # 额外尝试用 Developer ID 重签 + 硬运行时（需要本机证书）
#
# 当前包用本机自签证书「Isla Self Signed」签名，没有 Apple 公证：
# 首次打开需要「右键 → 打开」，之后正常双击。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Isla.app"
DIST="$ROOT/dist"
STAGE="$ROOT/build/dmg-stage"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo dev)"
BUILD="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)"
NAME="Isla-$VERSION-$BUILD"

if [ ! -d "$APP" ]; then
  echo "找不到 $APP，请先运行 ./build.sh" >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/Isla.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/INSTALL-README.txt" "$STAGE/安装说明.txt"

if [ "${1:-}" = "--sign" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID' | head -1 | sed 's/.*"\(.*\)"/\1/')"
  if [ -n "$IDENTITY" ]; then
    echo "→ 用 $IDENTITY 重签"
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$STAGE/Isla.app"
  else
    echo "! 没找到 Developer ID 证书，保持自签"
  fi
fi

# UDZO = 压缩只读 DMG；卷名会显示在 Finder 侧边栏
hdiutil create -volname "Isla $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"
rm -rf "$STAGE"

cd "$DIST"
shasum -a 256 "$NAME.dmg" "$NAME.zip" > "$NAME.sha256"

echo "DMG: $DIST/$NAME.dmg"
echo "ZIP: $DIST/$NAME.zip"
cat "$NAME.sha256" | sed 's#^#  #'
du -h "$NAME.dmg" "$NAME.zip" | sed 's#^#  #'
