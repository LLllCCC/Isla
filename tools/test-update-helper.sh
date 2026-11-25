#!/bin/zsh
# 更新助手脚本的 fixture 测试：替换成功 / staging 缺失回滚。
# 不会碰 /Applications，也不会真的 open App（用 /usr/bin/true 代替）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/Resources/update-helper.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export ISLA_OPEN_BIN=/usr/bin/true
export ISLA_LSREGISTER_BIN=/usr/bin/true
export ISLA_SKIP_PLUGINHOST_KILL=1

run_case() {
  local name="$1" target="$2" staging="$3" old="$4" backup="$5" log="$6"
  sleep 0.2 & local pid=$!
  /bin/sh "$HELPER" "$pid" "$target" "$staging" "$old" "$backup" "$log"
  wait "$pid" 2>/dev/null || true
  echo "  case: $name"
}

echo "=== 更新助手 fixture ==="

# 1) 成功替换
CASE1="$TMP/case1"
mkdir -p "$CASE1/target.app" "$CASE1/staging.app"
echo old > "$CASE1/target.app/marker"
echo new > "$CASE1/staging.app/marker"
run_case "success" "$CASE1/target.app" "$CASE1/staging.app" "$CASE1/old.app" "$CASE1/backup.app" "$CASE1/update.log"
grep -q new "$CASE1/target.app/marker" || { echo "✗ 目标没有被替换"; exit 1; }
grep -q old "$CASE1/backup.app/marker" || { echo "✗ 备份没有生成"; exit 1; }
[ ! -e "$CASE1/staging.app" ] || { echo "✗ staging 没有被移走"; exit 1; }
grep -q '\[update\] done' "$CASE1/update.log" || { echo "✗ 成功日志缺失"; exit 1; }
echo "  ✓ 成功替换 + 备份"

# 2) staging 缺失 → 回滚旧包
CASE2="$TMP/case2"
mkdir -p "$CASE2/target.app"
echo old > "$CASE2/target.app/marker"
mkdir -p "$CASE2/staging-parent"
run_case "rollback" "$CASE2/target.app" "$CASE2/missing.app" "$CASE2/old.app" "$CASE2/backup.app" "$CASE2/update.log" || true
grep -q old "$CASE2/target.app/marker" || { echo "✗ 回滚后目标不是旧包"; exit 1; }
grep -q old "$CASE2/backup.app/marker" || { echo "✗ 回滚时没有备份"; exit 1; }
grep -q 'restoring' "$CASE2/update.log" || { echo "✗ 回滚日志缺失"; exit 1; }
echo "  ✓ staging 缺失时回滚旧包"

echo "✓ 更新助手 fixture 全部通过"
