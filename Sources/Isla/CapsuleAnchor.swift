import CoreGraphics

/// 胶囊水平锚点的纯计算。
///
/// 单独拎出来是为了能写断言（tools/sim/anchor）：锚点、加宽方向、偏移夹取
/// 这三件事很容易改出「胶囊跑到屏幕外 / 加宽方向反了」这种玄学问题，
/// 放在纯函数里就能用几十行断言钉死。
enum CapsuleAnchor {

    /// 加宽时胶囊往哪边长。
    enum Direction {
        case left, right, both
    }

    /// 歌词加宽时胶囊中心落在哪。
    /// - slot: 未加宽时的基准锚点（屏幕中线 / 用户拖到的位置）
    /// - extra: 加宽出来的额外宽度
    static func widened(slot: CGFloat, extra: CGFloat, direction: Direction,
                        screen: CGRect, overlayWidth: CGFloat) -> CGFloat {
        guard extra > 0.5 else { return slot }
        let half = overlayWidth / 2
        switch direction {
        case .left:
            // 向左长：中心左移半个增量，同时不能越过屏幕左边界
            return max(screen.minX + half + 4, slot - extra / 2)
        case .right:
            return min(screen.maxX - half - 4, slot + extra / 2)
        case .both:
            // 两边同时长：中心不动
            return slot
        }
    }

    /// 把用户拖出来的水平偏移夹在屏幕内（胶囊不能被拖到看不见的地方）。
    static func clamped(slot: CGFloat, offset: CGFloat,
                        screen: CGRect, overlayWidth: CGFloat) -> CGFloat {
        guard offset != 0 else { return slot }
        let half = overlayWidth / 2
        let minX = screen.minX + half + 4
        let maxX = screen.maxX - half - 4
        guard maxX > minX else { return slot }
        return min(maxX, max(minX, slot + offset))
    }

    /// 拖动时用：当前窗口位置对应的偏移量（相对「不含偏移的基准锚点」）。
    static func offset(forCurrentX currentX: CGFloat, baseAnchor: CGFloat) -> CGFloat {
        currentX - baseAnchor
    }

    /// 偏移落盘前的安全夹取，避免拖到离谱的值。
    static func sanitizedOffset(_ offset: CGFloat) -> Double {
        Double(max(-400, min(400, offset)))
    }
}
