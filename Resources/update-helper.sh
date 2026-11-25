#!/bin/sh
# Isla 更新助手：等旧 App 退出后，原子替换 bundle 并重启。
# 参数：PID TARGET STAGING OLD BACKUP LOG
# 由 UpdateInstaller 复制到 ~/Library/Application Support/Isla/updater/ 后执行。
set -u
PID="$1"; TARGET="$2"; STAGING="$3"; OLD="$4"; BACKUP="$5"; LOG="$6"
OPEN_BIN="${ISLA_OPEN_BIN:-/usr/bin/open}"
LSREGISTER="${ISLA_LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
exec >>"$LOG" 2>&1
echo "[update] $(date '+%Y-%m-%d %H:%M:%S') start pid=$PID"
echo "[update] target=$TARGET"

i=0
while kill -0 "$PID" 2>/dev/null; do
  sleep 0.2
  i=$((i+1))
  if [ "$i" -ge 300 ]; then
    echo "[update] timeout; terminating"
    kill -TERM "$PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$PID" 2>/dev/null || true
    break
  fi
done

if [ "${ISLA_SKIP_PLUGINHOST_KILL:-0}" != "1" ]; then
  /usr/bin/pkill -x IslaPluginHost 2>/dev/null || true
fi
sleep 0.4

"$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true

if [ -d "$TARGET" ]; then
  if ! /usr/bin/ditto "$TARGET" "$BACKUP"; then
    echo "[update] backup failed; abort"
    "$OPEN_BIN" -n "$TARGET"
    exit 1
  fi
  if ! mv "$TARGET" "$OLD"; then
    echo "[update] move old failed; abort"
    "$OPEN_BIN" -n "$TARGET"
    exit 1
  fi
fi

if ! mv "$STAGING" "$TARGET"; then
  echo "[update] move staging failed; restoring"
  [ -d "$OLD" ] && mv "$OLD" "$TARGET"
  "$OPEN_BIN" -n "$TARGET"
  exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if ! "$OPEN_BIN" -n "$TARGET"; then
  echo "[update] open failed; restoring"
  "$LSREGISTER" -u "$TARGET" >/dev/null 2>&1 || true
  rm -rf "$TARGET"
  [ -d "$OLD" ] && mv "$OLD" "$TARGET"
  "$OPEN_BIN" -n "$TARGET"
  exit 1
fi

"$LSREGISTER" -u "$OLD" >/dev/null 2>&1 || true
TMPOLD="/tmp/.isla-old-$$.app"
mv "$OLD" "$TMPOLD" 2>/dev/null && rm -rf "$TMPOLD"
echo "[update] done"
