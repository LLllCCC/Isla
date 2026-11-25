import Foundation

/// 歌词：按「曲名 + 歌手」去网易云取同步歌词（失败回退 QQ 音乐），按播放进度算当前句。
///
/// 设计取舍：
/// - 只用标题/歌手做匹配，不需要各播放器私有协议；匹配不到就静默失败（胶囊回退显示标题）。
/// - LRC 全部解析成 [(时间, 文本)]，当前句 = 最后一个 time <= elapsed 的行。
/// - 缓存按「曲名-歌手」哈希落在 ~/Library/Caches/Isla/lyrics/，同一首歌不重复请求。
final class LyricsService {

    struct Line {
        let time: Double
        let text: String
    }

    static let shared = LyricsService()

    private var key = ""
    private var lines: [Line] = []
    /// 上一帧命中的歌词行（供 current() 增量查找）
    private var lastIndex = 0
    /// 上一次 sync 的歌名/歌手，用来跳过「同一首歌」的重复拼 key
    private var lastSyncTitle = ""
    private var lastSyncArtist = ""
    private var loading = false
    private var lastFetchAt = Date.distantPast
    private let queue = DispatchQueue(label: "com.yopo.isla.lyrics", qos: .utility)

    /// 调试用：`defaults write com.yopo.isla lyricsDebug "New Soul|Vox Angeli|200"`
    private var debugTrack: (title: String, artist: String, duration: Double)? {
        guard let raw = UserDefaults.standard.string(forKey: "lyricsDebug") else { return nil }
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], parts.count > 2 ? (Double(parts[2]) ?? 200) : 200)
    }

    var activeKey: String { key }
    var hasLines: Bool { !lines.isEmpty }

    /// 调试模式下用「启动至今的秒数」当播放进度，方便没有真实播放时验证滚动/逐字。
    private let debugStart = Date()
    var debugElapsed: Double? {
        guard debugTrack != nil else { return nil }
        return Date().timeIntervalSince(debugStart)
    }

    /// 当前应该显示的歌词（没有就返回 nil）
    func current(elapsed: Double) -> (text: String, progress: Double)? {
        guard !lines.isEmpty else { return nil }
        // elapsed 单调递增：从上次命中的位置往后找，摊销 O(1)。
        // 旧实现每次全表扫描，60fps 下一秒要扫 60×N 次，白烧 CPU。
        var idx = min(max(0, lastIndex - 1), lines.count - 1)
        var i = idx
        var found = false
        while i < lines.count {
            if lines[i].time <= elapsed + 0.15 { idx = i; found = true; i += 1 } else { break }
        }
        if !found { idx = 0 }
        lastIndex = idx
        let text = lines[idx].text
        guard !text.isEmpty else { return ("♪", 0) }
        let start = lines[idx].time
        let end = idx + 1 < lines.count ? lines[idx + 1].time : start + 4
        let span = max(0.8, end - start)
        let p = min(1, max(0, (elapsed - start) / span))
        return (text, p)
    }

    /// 曲目变化时触发拉取；同一首歌直接复用内存/磁盘缓存。
    func sync(title: String, artist: String, duration: Double) {
        let track = debugTrack
        let t = track?.title ?? title
        let a = track?.artist ?? artist
        guard !t.isEmpty else {
            if !key.isEmpty { key = ""; lines = [] }
            return
        }
        // 同一首歌直接短路：不必每帧拼 key（小字符串分配在 60fps 下也很吵）
        if t == lastSyncTitle && a == lastSyncArtist {
            if lines.isEmpty, !loading,
               Date().timeIntervalSince(lastFetchAt) > 20 { fetch(title: t, artist: a) }
            return
        }
        lastSyncTitle = t
        lastSyncArtist = a
        let newKey = "\(t)-\(a)".lowercased()
        if newKey == key {
            // 上次没取到（网络失败/没收录）时给一次重试机会，不然这首歌永远不会再试
            if lines.isEmpty, !loading,
               Date().timeIntervalSince(lastFetchAt) > 20 { fetch(title: t, artist: a) }
            return
        }
        key = newKey
        lastIndex = 0
        // 换歌必须立刻清空：旧实现保留上一首的歌词等新 LRC，
        // 结果换到没有歌词的内容（直播/纯音乐/视频）时，胶囊会一直显示上一首的歌词并且跟着时间往前走。
        lines = []
        lastFetchAt = .distantPast
        guard let cached = loadCache(key: newKey) else {
            fetch(title: t, artist: a)
            return
        }
        lines = parse(cached)
    }

    // MARK: - 取歌词

    private func fetch(title: String, artist: String) {
        guard !loading else { return }
        loading = true
        lastFetchAt = Date()
        let q = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        neteaseSearch(q) { [weak self] songID in
            guard let self else { return }
            if let id = songID {
                self.neteaseLyric(id: id) { lrc in
                    self.finish(lrc, key: self.key)
                }
            } else {
                self.qqSearch(q) { mid in
                    guard let mid else { self.loading = false; return }
                    self.qqLyric(mid: mid) { lrc in
                        self.finish(lrc, key: self.key)
                    }
                }
            }
        }
    }

    private func finish(_ lrc: String?, key: String) {
        loading = false
        guard let lrc, !lrc.isEmpty else { return }
        if self.key == key {
            lines = parse(lrc)
        }
        saveCache(lrc, key: key)
    }

    private func get(_ url: String, referer: String, completion: @escaping (Data?) -> Void) {
        guard let u = URL(string: url) else { completion(nil); return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async { completion(data) }
        }.resume()
    }

    private func neteaseSearch(_ query: String, completion: @escaping (Int?) -> Void) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        get("https://music.163.com/api/search/get/web?s=\(q)&type=1&limit=1", referer: "https://music.163.com") { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = obj["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let id = songs.first?["id"] as? Int else { completion(nil); return }
            completion(id)
        }
    }

    private func neteaseLyric(id: Int, completion: @escaping (String?) -> Void) {
        get("https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1", referer: "https://music.163.com") { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrc = obj["lrc"] as? [String: Any],
                  let text = lrc["lyric"] as? String else { completion(nil); return }
            completion(text)
        }
    }

    private func qqSearch(_ query: String, completion: @escaping (String?) -> Void) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        get("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(q)&format=json&n=1", referer: "https://y.qq.com") { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let song = d["song"] as? [String: Any],
                  let list = song["list"] as? [[String: Any]],
                  let mid = list.first?["songmid"] as? String else { completion(nil); return }
            completion(mid)
        }
    }

    private func qqLyric(mid: String, completion: @escaping (String?) -> Void) {
        get("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(mid)&format=json&nobase64=1",
            referer: "https://y.qq.com") { data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["lyric"] as? String else { completion(nil); return }
            completion(text)
        }
    }

    // MARK: - LRC 解析 / 缓存

    /// 制作信息行（作词/作曲/编曲…）不是歌词，别占着胶囊。
    private func isCredit(_ text: String) -> Bool {
        guard let sep = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let head = String(text[..<sep]).trimmingCharacters(in: .whitespaces)
        guard head.count <= 6 else { return false }
        let words = ["作词", "作曲", "编曲", "制作", "出品", "监制", "混音", "母带", "和声", "和音",
                     "录音", "吉他", "贝斯", "鼓", "弦乐", "统筹", "发行", "词", "曲", "编",
                     "原唱", "翻唱", "企划", "配唱", "PGM"]
        // 「音乐总监/音响总监/音乐设计/改编编曲/乐队队长/萨克斯」这类标签枚举不完，
        // 用后缀兜底（2026-11-20 用户反馈：「音乐总监：陈建骐」逐句闪过胶囊）。
        let suffixes = ["总监", "设计", "原唱", "翻唱", "改编", "编曲", "键盘", "打击", "长号",
                        "萨克斯", "小号", "长笛", "乐队", "口琴", "风琴", "提琴", "笛", "箫"]
        return words.contains(head) || suffixes.contains { head.hasSuffix($0) }
    }

    /// 制作名单「段落」判定：很多 LRC（尤其 QQ 音乐/综艺翻唱）在正歌前塞一整排
    /// 「标签：人名」，每行 1 秒——单行枚举不完（PGM/乐队队长/键盘…），
    /// 但它们高度同质：**开头连续多行都带冒号且偏短**。连续 ≥3 行即整段丢弃，
    /// 到第一句真歌词为止。中文歌词开头连续三行都带冒号的情形极罕见。
    private func isCreditLikeLine(_ text: String) -> Bool {
        (text.contains(":") || text.contains("：")) && text.count <= 28
    }

    private func parse(_ lrc: String) -> [Line] {
        var out: [Line] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let stamp = String(line[line.index(after: line.startIndex)..<close])
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isCredit(text), !stamp.contains(":") == false else { continue }
            let parts = stamp.split(separator: ":")
            guard parts.count == 2,
                  let m = Double(parts[0]),
                  let s = Double(parts[1]) else { continue }
            out.append(Line(time: m * 60 + s, text: text))
        }
        out = out.sorted { $0.time < $1.time }
        // 制作名单段落过滤（见 isCreditLikeLine 注释）：吃掉正歌前连续的「标签：人名」块
        var idx = 0
        while idx < out.count, isCreditLikeLine(out[idx].text) { idx += 1 }
        if idx >= 3 { out.removeFirst(idx) }
        return out
    }

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Isla/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheURL(_ key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return cacheDir.appendingPathComponent(String(safe.prefix(80)) + ".lrc")
    }

    private func loadCache(key: String) -> String? {
        try? String(contentsOf: cacheURL(key), encoding: .utf8)
    }

    private func saveCache(_ lrc: String, key: String) {
        try? lrc.write(to: cacheURL(key), atomically: true, encoding: .utf8)
    }
}
