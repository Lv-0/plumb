import CoreGraphics

/// 纯函数多屏选屏：不依赖 AppKit/NSScreen，便于单测。
/// “app 原先在哪屏就在哪屏居中/平铺” —— 用窗口中心点归属选屏。
enum ScreenSelection {
    struct EdgeInsets: Equatable {
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// 返回中心点所属屏幕的下标。
    /// - 优先：中心被某屏 `contains`（严格内部，含边界）。
    /// - 回退：中心恰在缝隙/外部时，返回最大重叠面积的屏幕；都不重叠返回 nil。
    static func screenIndex(forCenter center: CGPoint, inScreens screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }

        // 唯一归属：严格 contains。
        for (i, frame) in screens.enumerated() where frame.contains(center) {
            return i
        }

        // 回退：用 1×1 代表矩形取最大重叠，稳定返回首个最大者。
        let dot = CGRect(x: center.x, y: center.y, width: 1, height: 1)
        var best: (index: Int, area: CGFloat)?
        for (i, frame) in screens.enumerated() {
            let area = ScreenSelection.intersectionArea(dot, frame)
            if let b = best {
                if area > b.area { best = (i, area) }
            } else {
                best = (i, area)
            }
        }
        return best?.index
    }

    /// 两矩形交集面积（空集/不相交返回 0）。
    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard a.isNull == false, b.isNull == false,
              a.isEmpty == false, b.isEmpty == false else { return 0 }
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
