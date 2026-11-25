#!/bin/zsh
# 生成并签名 App 更新 appcast（单文件 envelope）。
#
#   ./tools/make-appcast.sh <version> <build> <zip> [dmg] [notes-file]
#
# 环境变量：
#   ISLA_APPCAST_KEY       私钥路径（默认 ~/.isla-appcast-key.json）
#   ISLA_APPCAST_OUT       输出路径（默认 dist/appcast.json）
#   ISLA_APPCAST_ZIP_URL   覆盖 zip 的下载地址（默认 GitHub Release 固定 tag URL）
#   ISLA_APPCAST_DMG_URL   覆盖 dmg 的下载地址
#
# 产物：<out>（单文件 envelope，payload 里带 sha256/size/version/build）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
BUILD="${2:-}"
ZIP="${3:-}"
DMG="${4:-}"
NOTES="${5:-}"
KEY="${ISLA_APPCAST_KEY:-$HOME/.isla-appcast-key.json}"
OUT="${ISLA_APPCAST_OUT:-$ROOT/dist/appcast.json}"

if [ -z "$VERSION" ] || [ -z "$BUILD" ] || [ -z "$ZIP" ]; then
  echo "用法：./tools/make-appcast.sh <version> <build> <zip> [dmg] [notes-file]" >&2
  exit 2
fi
if [ ! -f "$ZIP" ]; then echo "找不到 zip：$ZIP" >&2; exit 1; fi
if [ -n "$DMG" ] && [ ! -f "$DMG" ]; then echo "找不到 dmg：$DMG" >&2; exit 1; fi
if [ ! -f "$KEY" ]; then echo "找不到 appcast 私钥：$KEY" >&2; exit 1; fi

ZIP_NAME="$(basename "$ZIP")"
DMG_NAME=""
[ -n "$DMG" ] && DMG_NAME="$(basename "$DMG")"
ZIP_URL="${ISLA_APPCAST_ZIP_URL:-https://github.com/LLllCCC/Isla/releases/download/v$VERSION/$ZIP_NAME}"
DMG_URL="${ISLA_APPCAST_DMG_URL:-}"
if [ -n "$DMG" ] && [ -z "$DMG_URL" ]; then
  DMG_URL="https://github.com/LLllCCC/Isla/releases/download/v$VERSION/$DMG_NAME"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$TMP/payload.json"

python3 - "$VERSION" "$BUILD" "$ZIP" "$DMG" "$ZIP_URL" "$DMG_URL" "$NOTES" "$PAYLOAD" <<'PY'
import datetime, hashlib, json, os, sys

version, build, zip_path, dmg_path, zip_url, dmg_url, notes_path, out = sys.argv[1:9]

def shafile(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

payload = {
    "version": version,
    "build": int(build),
    "zip": zip_url,
    "zipSha256": shafile(zip_path),
    "zipSize": os.path.getsize(zip_path),
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if dmg_path:
    payload["dmg"] = dmg_url
    payload["dmgSha256"] = shafile(dmg_path)
    payload["dmgSize"] = os.path.getsize(dmg_path)
if notes_path and os.path.exists(notes_path):
    with open(notes_path, encoding="utf-8") as f:
        notes = f.read().strip()
    if notes:
        payload["notes"] = notes

with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
print(f"→ payload {out}  build={build}  zip={payload['zipSize']} B")
PY

mkdir -p "$ROOT/build/.tools"
if [ ! -x "$ROOT/build/.tools/isla-appcast" ] || [ "$ROOT/tools/isla-appcast.swift" -nt "$ROOT/build/.tools/isla-appcast" ]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    "$ROOT/tools/isla-appcast.swift" -o "$ROOT/build/.tools/isla-appcast" -framework Cocoa
fi

mkdir -p "$(dirname "$OUT")"
"$ROOT/build/.tools/isla-appcast" "$PAYLOAD" "$KEY" "$OUT"
echo "✓ appcast：$OUT"
