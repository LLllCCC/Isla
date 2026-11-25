#!/bin/zsh
# Isla 一键自检：断言 + 英文界面审计 + 商店签名 + 运行态资源。
#
#   ./tools/selfcheck.sh          # 全量（会编译四个模拟器）
#   ./tools/selfcheck.sh --fast   # 跳过重新编译（用已编译的模拟器）
#   ./tools/selfcheck.sh --ci     # CI：跳过需要运行中 App / 安装包 / 本地商店网络的步骤
#
# 退出码非 0 = 有检查没过。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAST=0
CI=0
[ "${1:-}" = "--fast" ] && FAST=1
[ "${1:-}" = "--ci" ] && CI=1

fail=0
step() { echo ""; echo "=== $1 ==="; }

step "1/5 模拟断言（display / anchor / update / helper / store）"
# 注意：不要加 -target arm64-apple-macos14.0
#   带显式 deployment target 时 ATS 会拦掉对 127.0.0.1 的 http 请求，
#   商店模拟的本地服务器就连不上（表现为「Could not connect to the server」）。
build_sim() {
  local dir="$1" entry="$2" out="$3"; shift 3
  ( cd "$dir" && swiftc -O -swift-version 5 "$entry" "$@" -o "$out" -framework Cocoa ) || return 1
}
if [ $FAST -eq 0 ]; then
  build_sim tools/sim/display main.swift simdisplay ../../../Sources/Isla/DisplaySelection.swift || { echo "✗ display 编译失败"; fail=1; }
  build_sim tools/sim/anchor  main.swift simanchor  ../../../Sources/Isla/CapsuleAnchor.swift   || { echo "✗ anchor 编译失败"; fail=1; }
  build_sim tools/sim/update  main.swift simupdate  ../../../Sources/Isla/UpdateAppcast.swift ../../../Sources/Isla/StoreClient.swift ../../../Sources/Isla/L10n.swift || { echo "✗ update 编译失败"; fail=1; }
  build_sim tools/sim/store   StoreSim.swift simstore ../../../Sources/Isla/StoreClient.swift  || { echo "✗ store 编译失败"; fail=1; }
fi
./tools/sim/display/simdisplay | tail -1 || fail=1
./tools/sim/anchor/simanchor   | tail -1 || fail=1
./tools/sim/update/simupdate   | tail -1 || fail=1
./tools/test-update-helper.sh  | tail -1 || fail=1
# 商店模拟要起本地 http 服务器：
#   · 必须把二进制拷到工作区外再跑 —— 放在工作区里跑会连不上自己的本地服务器
#     （同二进制放 /tmp 跑就正常，怀疑是工作区沙箱对子进程网络/ATS 的干扰）
#   · 刚编译完机器负载高时可能抢不到端口 → 再重试一次
if [ $CI -eq 0 ]; then
  SIM_TMP="$(mktemp -d)"
  cp tools/sim/store/simstore "$SIM_TMP/simstore"
  store_ok=0
  for attempt in 1 2; do
    if "$SIM_TMP/simstore" store tools/sim/store/fixtures | tail -1; then store_ok=1; break; fi
    [ $attempt -eq 1 ] && echo "  (商店模拟第一次失败，重试)"
  done
  rm -rf "$SIM_TMP"
  [ $store_ok -eq 1 ] || fail=1
else
  echo "! CI 模式：跳过本地商店服务器模拟"
fi

step "2/5 英文界面漏翻审计"
python3 tools/i18n-audit.py || fail=1

step "3/5 商店索引签名"
if [ -x ./build/.tools/isla-sign ]; then
  ./build/.tools/isla-sign verify store/index.json store/index.json.sig "$HOME/.isla-store-key.json" || fail=1
else
  echo "! 还没编译 isla-sign（先跑 build.sh）"
fi

if [ $CI -eq 0 ]; then
  step "4/5 运行态资源（需要 App 在跑）"
  ./tools/verify.sh 5 | tail -3 || fail=1

  step "5/5 安装包与线上一致性"
  LATEST_DMG=$(ls -t dist/Isla-*.dmg 2>/dev/null | head -1)
  if [ -n "$LATEST_DMG" ]; then
    BASE=$(basename "$LATEST_DMG")
    LOCAL=$(shasum -a 256 "$LATEST_DMG" | awk '{print $1}')
    echo "本地 $BASE → $LOCAL"
    if [ -f "dist/$BASE.sha256" ]; then
      grep -q "$LOCAL" "dist/$BASE.sha256" && echo "✓ 与 .sha256 一致" || { echo "✗ 与 .sha256 不一致"; fail=1; }
    fi
  else
    echo "! dist/ 里没有安装包（先跑 tools/make-dmg.sh）"
  fi
else
  step "4/5 运行态资源"
  echo "! CI 模式：跳过（需要运行中的 App）"
  step "5/5 安装包一致性"
  echo "! CI 模式：跳过（不读 dist）"
fi

echo ""
if [ $fail -eq 0 ]; then
  echo "✓ 自检全部通过"
else
  echo "✗ 自检有失败项"
fi
exit $fail
