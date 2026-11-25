#!/usr/bin/env python3
"""英文界面漏翻审计。

扫描 Swift 源码里的中文字面量，检查它们是否在 Resources/en.lproj/Localizable.strings
里有对应条目；没有的会被列出来（人工判断是 UI 文案还是要排除的日志/内部数据）。

用法：
    python3 tools/i18n-audit.py            # 列出所有漏翻
    python3 tools/i18n-audit.py --quiet    # 只输出统计
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIRS = [os.path.join(ROOT, "Sources", "Isla"),
            os.path.join(ROOT, "Sources", "IslaPluginHost")]
STRINGS = os.path.join(ROOT, "Resources", "en.lproj", "Localizable.strings")

CJK = re.compile(r'[\u4e00-\u9fff]')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

# 这些行里的中文不算 UI 文案（日志 / 调试 / 注释 / 断言）
IGNORE_LINE = re.compile(
    r'//|/\*|print\(|appendLog|NSLog|debugPrint|logger|log\(|assert|precondition|'
    r'fatalError|mark:|TODO|FIXME|@available|#if'
)

# 整块剔除（本来就不是 UI 文案）：
#   · 设置页搜索索引（关键词给用户输入匹配用，不展示）
#   · 歌词「作词/作曲/…」名单关键词（用来识别歌词里的制作信息行）
# 例外文件：里面的中文不是 UI 文案
#   · PlayerProbe：匹配播放器 AX 按钮描述用的关键词（数据，不是文案）
#   · PluginManager / PluginStore / StoreClient：插件安装、校验、网络错误信息 ——
#     面向插件开发者（作者多半是中文使用者），暂保留中文
#   · Sources/IslaPluginHost：JS 宿主内部的诊断信息，由插件作者自己看
EXCEPT_FILES = {
    "PlayerProbe.swift",
    "PluginManager.swift",
    "PluginStore.swift",
    "StoreClient.swift",
}

BLOCKS = [
    re.compile(r'private static let searchIndex: \[SettingsSearchHit\] = \[.*?\n    \]', re.S),
    re.compile(r'let words = \[.*?\]', re.S),
    re.compile(r'let suffixes = \[.*?\]', re.S),
    re.compile(r'let feed: \[\(Double, Double, Bool, String\)\] = \[.*?\n        \]', re.S),
]


def load_keys():
    keys = set()
    if not os.path.exists(STRINGS):
        return keys
    with open(STRINGS, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=', line)
            if m:
                keys.add(m.group(1))
    return keys


def main():
    keys = load_keys()
    missing = []
    total = 0
    for d in SRC_DIRS:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".swift"):
                continue
            if name in EXCEPT_FILES:
                continue
            if "IslaPluginHost" in d:
                continue
            path = os.path.join(d, name)
            with open(path, encoding="utf-8") as f:
                text = f.read()
            for block in BLOCKS:
                text = block.sub("", text)
            for lineno, line in enumerate(text.splitlines(), 1):
                if IGNORE_LINE.search(line):
                    continue
                code = line.split("//")[0]
                for m in LITERAL.finditer(code):
                    s = m.group(1)
                    if not CJK.search(s):
                        continue
                    total += 1
                    if s in keys:
                        continue
                    missing.append((os.path.relpath(path, ROOT), lineno, s))
    if "--quiet" in sys.argv:
        print(f"i18n: {total} 处中文文案，{len(missing)} 处未收录到 en.lproj")
        return 0
    if not missing:
        print(f"✓ 英文界面无漏翻（扫描 {total} 处中文文案）")
        return 0
    print(f"✗ {len(missing)} 处中文文案未收录到 en.lproj：")
    for path, lineno, text in missing:
        print(f"  {path}:{lineno}  \"{text}\"")
    return 1


if __name__ == "__main__":
    sys.exit(main())
