#!/bin/zsh
# 从 Samples/ 重新生成商店包与索引：
#   store/packages/*.zip + store/index.json（重算 sha256 / size）
# 用法：./tools/make-store.sh
# 注意：zip 里的时间戳会变，所以每次生成的 sha256 不同；改完要重新发布商店。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/store"
PKG="$STORE/packages"

mkdir -p "$PKG"
rm -f "$PKG"/*.zip

pack() {
  local sample="$1" id="$2" version="$3"
  ditto -c -k --keepParent "$ROOT/Samples/$sample" "$PKG/$id-$version.zip"
}

pack clipboard-board com.example.clipboard-board 0.4.2
pack web-dashboard   com.example.web-dashboard   0.2.2

python3 - "$STORE" <<'PY'
import hashlib, json, os, sys, datetime

store = sys.argv[1]
items = [
    ("com.example.clipboard-board", "剪贴板看板", "Clipboard Board", "0.4.2",
     "把最近的剪贴板内容排成看板：文本、图片、文件都能复制，固定与删除会同步主 App 历史；概览有「最近复制」卡片，胶囊可显示条数。",
     "Lays recent clipboard items out as a board: text, images and files can be copied; pinning and deleting sync with the main app history. The overview shows a Recent copy card and the capsule can display the item count.",
     ["clipboard", "storage"], "1.5.12"),
    ("com.example.web-dashboard", "数据面板（Web）", "Data Dashboard (Web)", "0.2.2",
     "用自己的 HTML/CSS 画一个网页面板，通过 isla 桥读写存储与剪贴板；演示 kind=web 的插件页。",
     "Builds a dashboard with your own HTML/CSS and reads/writes storage and the clipboard through the isla bridge; demonstrates a kind=web plugin page.",
     ["storage", "clipboard"], "1.6.4"),
]

plugins = []
for pid, name, name_en, ver, summary, summary_en, perms, minver in items:
    rel = f"packages/{pid}-{ver}.zip"
    path = os.path.join(store, rel)
    data = open(path, "rb").read()
    plugins.append({
        "id": pid, "name": name, "nameEn": name_en, "version": ver,
        "summary": summary, "summaryEn": summary_en,
        "author": "Isla", "minAppVersion": minver, "permissions": perms,
        "package": rel,
        "sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
    })

index = {
    "schema": 1,
    "name": "Isla 示例商店",
    "nameEn": "Isla Sample Store",
    "updatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "plugins": plugins,
}
out = os.path.join(store, "index.json")
open(out, "w", encoding="utf-8").write(json.dumps(index, ensure_ascii=False, indent=2) + "\n")
print(f"→ {out}")
for p in plugins:
    print(f"   {p['id']} v{p['version']}  {p['size']} B  sha256={p['sha256'][:12]}…")
PY

echo "→ 记得重新发布 store/（静态托管），并同步 App 里的默认源地址"

# 有私钥就顺手签名：publisher 写进 index.json，再生成 index.json.sig
SIGN_KEY="${ISLA_STORE_KEY:-$HOME/.isla-store-key.json}"
if [ -f "$SIGN_KEY" ]; then
  echo "→ 签名（$SIGN_KEY）"
  mkdir -p "$ROOT/build/.tools"
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    "$ROOT/tools/isla-sign.swift" -o "$ROOT/build/.tools/isla-sign" -framework Cocoa
  "$ROOT/build/.tools/isla-sign" sign "$STORE/index.json" "$SIGN_KEY" \
    --name "${ISLA_STORE_PUBLISHER:-Isla}"
else
  echo "→ 未签名：没有找到 $SIGN_KEY（用 ISLA_STORE_KEY=<path> 指定，或先跑 isla-sign keygen）"
fi
