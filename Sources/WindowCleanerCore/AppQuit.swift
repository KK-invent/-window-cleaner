import Foundation
import CoreGraphics

// 退出应用：等同于对该应用按 ⌘Q（向它发送标准的“退出”请求）。
// 应用可以弹出“是否保存”等确认框，也可以拒绝退出；这里只观察结果，绝不强制退出、不替用户点任何按钮。
// 这是与“关闭窗口”分开的独立功能：关闭窗口的流程里仍然不会退出任何应用。

public struct QuitTarget: Equatable, Sendable {
    public var pid: pid_t
    public var appName: String

    public init(pid: pid_t, appName: String) {
        self.pid = pid
        self.appName = appName
    }
}

public struct QuitPendingContext {
    public var target: QuitTarget
    /// 发出退出请求前该应用已在屏幕上的窗口；之后多出来的就是确认框
    public var baseline: Set<CGWindowID>

    public init(target: QuitTarget, baseline: Set<CGWindowID>) {
        self.target = target
        self.baseline = baseline
    }
}

public enum QuitOutcome {
    case quit
    case needsUser(QuitPendingContext)
    case skipped(String)
    case failed(String)

    public var status: ItemStatus {
        switch self {
        case .quit: return .closed("应用已退出")
        case .needsUser: return .waitingUser("应用在退出前弹出了确认框，请你自己决定")
        case .skipped(let s): return .skipped(s)
        case .failed(let s): return .failed(s)
        }
    }
}

public final class QuitExecutor {
    public let backend: WindowBackend
    /// 最多等多久（秒）。有些应用退出前要保存状态，会慢一些
    public var timeout: Double = 6.0
    public var pollInterval: Double = 0.1
    /// 新窗口连续出现这么多次检查才算确认框（避开应用退出时一闪而过的窗口）
    public var dialogConfirmTicks = 3
    public var allowedPIDs: Set<pid_t>?

    public init(backend: WindowBackend) {
        self.backend = backend
    }

    public func attempt(_ t: QuitTarget) -> QuitOutcome {
        if let allowed = allowedPIDs, !allowed.contains(t.pid) { return .skipped(SkipReason.notAllowed.text) }
        guard backend.isAppRunning(t.pid) else { return .skipped("应用已经不在运行") }
        let baseline = Set(backend.onScreenWindows().filter { $0.pid == t.pid }.map(\.windowID))
        guard backend.terminateApp(t.pid) else { return .failed("系统没有接受退出请求") }

        let ctx = QuitPendingContext(target: t, baseline: baseline)
        let deadline = backend.now() + timeout
        var dialogTicks = 0
        var tick = 0
        while true {
            if !backend.isAppRunning(t.pid) { return .quit }
            if hasDialog(ctx, checkAX: tick % 5 == 4) {
                dialogTicks += 1
                if dialogTicks >= dialogConfirmTicks { return .needsUser(ctx) }
            } else {
                dialogTicks = 0
            }
            if backend.now() >= deadline {
                return .failed("应用没有在 \(Int(timeout)) 秒内退出（可能正忙或没有响应）；窗口清理不会强制退出它")
            }
            backend.sleep(pollInterval)
            tick += 1
        }
    }

    /// 暂停等待用户处理期间反复调用
    public func checkPending(_ ctx: QuitPendingContext) -> PendingState {
        guard backend.isAppRunning(ctx.target.pid) else { return .closed }
        if hasDialog(ctx, checkAX: false) { return .stillWaiting }
        switch backend.axWindows(pid: ctx.target.pid, timeout: 0.5, includeSheetCheck: true) {
        case .success(let list): return list.contains { $0.info.hasSheet } ? .stillWaiting : .keptOpen
        case .failure: return .stillWaiting // 应用正忙时不下结论
        }
    }

    private func hasDialog(_ ctx: QuitPendingContext, checkAX: Bool) -> Bool {
        let newDialogs = backend.onScreenWindows().filter {
            $0.pid == ctx.target.pid && !ctx.baseline.contains($0.windowID) && WindowMatcher.isDialogCandidate($0)
        }
        if !newDialogs.isEmpty { return true }
        guard checkAX, case .success(let list) = backend.axWindows(pid: ctx.target.pid, timeout: 0.3, includeSheetCheck: true) else {
            return false
        }
        return list.contains { $0.info.hasSheet }
    }
}
