import Foundation
import Darwin

/// 实时网速：每秒读一次所有物理接口的累计字节数，差分得到上下行速率。
/// 用 getifaddrs（Darwin 公开 API），零第三方依赖；3 秒滑动平均做平滑。
final class NetworkSpeedService {
    static let shared = NetworkSpeedService()

    /// 下行 / 上行速率（B/s，已平滑）
    private(set) var downBPS: Double = 0
    private(set) var upBPS: Double = 0

    private var lastRx: Int64 = -1
    private var lastTx: Int64 = -1
    private var lastAt: Date?
    /// 最近 3 次差分，用于滑动平均
    private var downHistory: [Double] = []
    private var upHistory: [Double] = []

    /// 排除回环与虚拟隧道，只统计真实物理/桥接网卡
    private let skipPrefixes: Set<String> = ["lo", "utun", "awdl", "llw", "bridge", "demux", "ipsec"]

    func sample() {
        var rxTotal: Int64 = 0
        var txTotal: Int64 = 0
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return }
        defer { freeifaddrs(ifaddrsPtr) }

        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let name = ifa.ifa_name {
                let base = String(cString: name)
                let stem = base.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? base
                if !skipPrefixes.contains(where: { stem.hasPrefix($0) }),
                   let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    rxTotal += Int64(d.ifi_ibytes)
                    txTotal += Int64(d.ifi_obytes)
                }
            }
            p = ifa.ifa_next
        }

        let now = Date()
        defer { lastRx = rxTotal; lastTx = txTotal; lastAt = now }
        guard lastRx >= 0, let prev = lastAt, now.timeIntervalSince(prev) > 0.05 else { return }
        let dt = now.timeIntervalSince(prev)
        let down = max(0, Double(rxTotal - lastRx) / dt)
        let up = max(0, Double(txTotal - lastTx) / dt)

        downHistory.append(down); upHistory.append(up)
        if downHistory.count > 3 { downHistory.removeFirst() }
        if upHistory.count > 3 { upHistory.removeFirst() }
        downBPS = downHistory.reduce(0, +) / Double(downHistory.count)
        upBPS = upHistory.reduce(0, +) / Double(upHistory.count)
    }

    /// B/s → 人读格式（999 KB/s 以内 KB，再大 MB）
    static func format(_ bps: Double) -> String {
        if bps < 1024 { return "\(Int(bps.rounded()))B/s" }
        if bps < 1024 * 1024 { return String(format: "%.0fKB/s", bps / 1024) }
        return String(format: "%.1fMB/s", bps / 1024 / 1024)
    }

    /// 胶囊专用短格式：88pt 宽里要同时放波形和数字，不再带 /s 后缀。
    static func formatCompact(_ bps: Double) -> String {
        if bps < 1024 { return "\(Int(bps.rounded()))B" }
        if bps < 1024 * 1024 { return String(format: "%.0fK", bps / 1024) }
        return String(format: "%.1fM", bps / 1024 / 1024)
    }
}
