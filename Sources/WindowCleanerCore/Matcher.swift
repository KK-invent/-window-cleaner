import Foundation
import CoreGraphics

/// 把“窗口服务器里的窗口（有缩略图、有窗口编号）”和“辅助功能里的窗口（有关闭按钮）”配对。
///
/// Apple 公开接口没有提供从辅助功能窗口直接取得窗口编号的方法（只有私有接口可以），
/// 所以这里使用保守规则：同一进程 + 位置尺寸一致，并且必须唯一；
/// 有重叠时才借助窗口标题区分，并且要求所有重叠窗口的标题都已知且互不相同。
/// 任何不确定的情况都判为“无法唯一确认”，宁可不关也不误关。
public enum WindowMatcher {
    /// 允许的坐标误差（点）。辅助功能接口返回浮点坐标，窗口服务器返回整数坐标。
    public static let tolerance: CGFloat = 1.0

    public enum Verdict: Equatable, Sendable {
        case unique(axIndex: Int, usedTitle: Bool)
        case ambiguous(candidates: Int)
        case notFound
    }

    public static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// - Parameters:
    ///   - target: 要配对的窗口服务器窗口
    ///   - peers: 同一进程当前在屏幕上的其他窗口（任意层级）
    ///   - axWindows: 同一进程在辅助功能里列出的全部窗口
    public static func match(target: CGWindowInfo, peers: [CGWindowInfo], axWindows: [AXWindowInfo]) -> Verdict {
        // 屏幕上的目标不可能是最小化窗口；其他桌面的目标需要保留所有候选，再用唯一性判断。
        let candidates = axWindows.enumerated().filter { _, ax in
            guard !(target.isOnScreen && ax.isMinimized), let f = ax.frame else { return false }
            return framesMatch(f, target.bounds)
        }
        if candidates.isEmpty { return .notFound }

        let overlapping = peers.filter {
            $0.pid == target.pid && $0.windowID != target.windowID && framesMatch($0.bounds, target.bounds)
        }
        if candidates.count == 1 && overlapping.isEmpty {
            return .unique(axIndex: candidates[0].offset, usedTitle: false)
        }

        // 有重叠：只有在标题都已知且互不相同的情况下才借助标题区分。
        let total = candidates.count + overlapping.count
        guard let title = target.title, !title.isEmpty else { return .ambiguous(candidates: total) }
        for peer in overlapping {
            guard let peerTitle = peer.title, !peerTitle.isEmpty, peerTitle != title else {
                return .ambiguous(candidates: total)
            }
        }
        let sameTitle = candidates.filter { $0.element.title == title }
        if sameTitle.count == 1 {
            return .unique(axIndex: sameTitle[0].offset, usedTitle: true)
        }
        return .ambiguous(candidates: total)
    }

    /// 是否像一个对话框/表单窗口（用于判断关闭后是否弹出了确认框）。
    public static func isDialogCandidate(_ w: CGWindowInfo, includeOffscreen: Bool = false) -> Bool {
        (w.isOnScreen || includeOffscreen) && w.alpha > 0.01 && (0...20).contains(w.layer) && w.bounds.width >= 60 && w.bounds.height >= 40
    }
}
