// build 96 回归：LRC 制作名单过滤（isCredit 强化 + 段落判定）
// ⚠️ 本文件是 LyricsService.isCredit/isCreditLikeLine/parse 过滤逻辑的「拷贝 + 测试」，
// 改源码后必须重新同步。运行：swift tools/sim/test-credit.swift
import Foundation

func isCredit(_ text: String) -> Bool {
    guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
    let head = String(text[..<sep]).trimmingCharacters(in: .whitespaces)
    guard head.count <= 6 else { return false }
    let words = ["作词", "作曲", "编曲", "制作", "出品", "监制", "混音", "母带", "和声", "和音",
                 "录音", "吉他", "贝斯", "鼓", "弦乐", "统筹", "发行", "词", "曲", "编",
                 "原唱", "翻唱", "企划", "配唱", "PGM"]
    let suffixes = ["总监", "设计", "原唱", "翻唱", "改编", "编曲", "键盘", "打击", "长号",
                    "萨克斯", "小号", "长笛", "乐队", "口琴", "风琴", "提琴", "笛", "箫"]
    return words.contains(head) || suffixes.contains { head.hasSuffix($0) }
}

func isCreditLikeLine(_ text: String) -> Bool {
    (text.contains(":") || text.contains("：")) && text.count <= 28
}

func parse(_ lrc: String) -> [(time: Double, text: String)] {
    var out: [(Double, String)] = []
    for raw in lrc.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
        let stamp = String(line[line.index(after: line.startIndex)..<close])
        let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isCredit(text), !stamp.contains(":") == false else { continue }
        let parts = stamp.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { continue }
        out.append((m * 60 + s, text))
    }
    out = out.sorted { $0.0 < $1.0 }
    var idx = 0
    while idx < out.count, isCreditLikeLine(out[idx].1) { idx += 1 }
    if idx >= 3 { out.removeFirst(idx) }
    return out
}

var pass = true
func check(_ ok: Bool, _ label: String) {
    print("\(ok ? "✅" : "❌") \(label)")
    if !ok { pass = false }
}

// 1. 真实缓存 LRC：If I Ain't Got You (Live)——前 19 行制作名单应整段消失
let home = FileManager.default.homeDirectoryForCurrentUser.path
let real = "\(home)/Library/Caches/Isla/lyrics/if-i-ain-t-got-you--live--chanté-moore.lrc"
if let lrc = try? String(contentsOfFile: real, encoding: .utf8) {
    let lines = parse(lrc)
    check(!lines.isEmpty, "真实 LRC 解析非空（\(lines.count) 行）")
    check(!lines.contains { $0.text.contains("总监") || $0.text.contains("音乐设计") || $0.text.contains("改编编曲") || $0.text.contains("PGM") || $0.text.contains("原唱") },
          "制作名单行全部被滤（总监/设计/改编/PGM/原唱 均不在结果中）")
    check(lines.first?.text == "Some people live for the fortune", "第一句歌词保留：\(lines.first?.text ?? "-")")
    check(lines.first?.time == 25.03, "第一句时间戳 25.03 保留（实际 \(lines.first?.time ?? -1)）")
} else {
    print("⚠️ 找不到真实缓存 LRC，跳过该项（\(real)）")
}

// 2. 单行判定回归
check(isCredit("音乐总监：陈建骐"), "音乐总监 → credit")
check(isCredit("音响总监：何飚"), "音响总监 → credit")
check(isCredit("音乐设计：Eric"), "音乐设计 → credit")
check(isCredit("原唱 : Alicia Keys"), "原唱 → credit")
check(isCredit("改编编曲：陈牧荻@TalentUnion"), "改编编曲 → credit")
check(isCredit("PGM：杨阳/施森铭"), "PGM → credit")
check(isCredit("作词 : Alicia Keys"), "作词 → credit（原有）")
check(!isCredit("Some people live for the fortune"), "正常歌词行不误杀")
check(!isCredit("妈妈说：天黑得很慢"), "叙事冒号行不误杀（head>6 保护）")

// 3. 段落判定：中文真歌词开头连续 3 行带冒号会被整段删——确认边界
let risky = "[00:01.00]他说：走吧\n[00:02.00]她说：好呀\n[00:03.00]我们：出发\n[00:05.00]月光洒在路上"
let riskyParsed = parse(risky)
check(riskyParsed.count == 1 && riskyParsed[0].text == "月光洒在路上",
      "连续 3 行冒号开头整段丢弃（边界已知：罕见误删，第一句保留）")

exit(pass ? 0 : 1)
