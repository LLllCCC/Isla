#!/bin/zsh
# 无 Xcode 也能构建：Command Line Tools 自带 swiftc，手写 .app bundle 即可。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Isla.app"
BIN="$APP/Contents/MacOS/Isla"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 先让 LaunchServices 忘掉旧包：否则替换已注册的 bundle 时，
# macOS 27 会把旧包自动移到废纸篓（AppCleaner 随后就会弹窗提示清理）。
if [ -x "$LSREGISTER" ] && [ -d "$APP" ]; then
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
fi

# 旧包先挪出 build/ 再真删：直接 rm 已注册的 bundle 会被 macOS 27 移进废纸篓。
if [ -d "$APP" ]; then
  STALE="$ROOT/build/.stale-$$.app"
  mv "$APP" "$STALE" 2>/dev/null && rm -rf "$STALE"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ 编译 Swift 源码（arm64 + x86_64，Intel 机器也能运行）"
BIN_ARM="$ROOT/build/Isla-arm64"
BIN_X86="$ROOT/build/Isla-x86_64"
for ARCH in arm64 x86_64; do
  OUT="$BIN_ARM"; [ "$ARCH" = "x86_64" ] && OUT="$BIN_X86"
  swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    "$ROOT"/Sources/Isla/*.swift \
    -o "$OUT" \
    -framework Cocoa -framework SwiftUI -framework CoreGraphics -framework WebKit
done
lipo -create -output "$BIN" "$BIN_ARM" "$BIN_X86"
rm -f "$BIN_ARM" "$BIN_X86"

echo "→ 编译插件宿主 IslaPluginHost"
HOST_ARM="$ROOT/build/IslaPluginHost-arm64"
HOST_X86="$ROOT/build/IslaPluginHost-x86_64"
for ARCH in arm64 x86_64; do
  OUT="$HOST_ARM"; [ "$ARCH" = "x86_64" ] && OUT="$HOST_X86"
  swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    "$ROOT"/Sources/IslaPluginHost/*.swift \
    -o "$OUT" \
    -framework JavaScriptCore
done
lipo -create -output "$APP/Contents/MacOS/IslaPluginHost" "$HOST_ARM" "$HOST_X86"
rm -f "$HOST_ARM" "$HOST_X86"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT"/Resources/*.js "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT"/Resources/*.sh "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT"/Resources/*.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp "$ROOT"/Resources/*.png "$APP/Contents/Resources/" 2>/dev/null || true
# 英文界面词表：en.lproj/Localizable.strings（key = 中文原文）
if [ -d "$ROOT/Resources/en.lproj" ]; then
  rm -rf "$APP/Contents/Resources/en.lproj"
  cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"
fi
# 内置示例插件：安装按钮从 Contents/Resources/Samples 复制到用户的插件目录。
if [ -d "$ROOT/Samples" ]; then
  rm -rf "$APP/Contents/Resources/Samples"
  cp -R "$ROOT/Samples" "$APP/Contents/Resources/Samples"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 版本号不再靠手改 Info.plist：默认取最近 tag + BUILD_NUMBER 文件；发版时 tag 完直接构建。
# 优先级：ISLA_VERSION / ISLA_BUILD 环境变量 > BUILD_NUMBER 文件 > 提交数。
# 注意：macOS 默认大小写不敏感，不能叫 BUILD（会与 build/ 目录冲突）。
VERSION="${ISLA_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
BUILD="${ISLA_BUILD:-$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER" 2>/dev/null || true)}"
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)}"
BUILD="${BUILD:-1}"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
  echo "→ 版本 $VERSION ($BUILD)"
fi

echo "→ 签名"
# 本机有「Isla Self Signed」证书就用它：证书身份稳定，TCC 辅助功能授权
# 不会因为每次重新构建（ad-hoc 的 cdhash 变化）而失效。
# 没有证书时回退 ad-hoc；也可用 ISLA_SIGN_IDENTITY 指定其它身份。
SIGN_ID="${ISLA_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ] && security find-certificate -c "Isla Self Signed" >/dev/null 2>&1; then
  SIGN_ID="Isla Self Signed"
fi
SIGN_ID="${SIGN_ID:--}"
echo "   身份：$SIGN_ID"
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/IslaPluginHost" >/dev/null 2>&1 || true
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 || true

echo "构建完成：$APP"
echo "运行：open \"$APP\""
echo "退出：pkill -x Isla"
