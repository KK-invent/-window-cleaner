import Foundation
import CoreGraphics

// 正常退出（等同 ⌘Q），不强制退出、不处理原应用的保存选项。
// 关闭窗口与退出应用仍是两条独立的操作路径。
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
    /// 发送请求前已有的窗口；之后新增的窗口可能是确认框。
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

/// 将请求时间、观察时间和弹窗检查开销分开记录，避免把程序自身的等待算到目标应用头上。
public struct QuitTiming {
    public var prepare: Double = 0
    public var request: Double = 0
    public var observe: Double = 0
    public var dialogChecks: Int = 0
    public var dialogTime: Double = 0

    public var text: String {
        "准备 \(Int(prepare * 1000))ms 请求 \(Int(request * 1000))ms 观察 \(Int(observe * 1000))ms 弹窗检查 \(dialogChecks)次/\(Int(dialogTime * 1000))ms"
    }
}

public final class QuitExecutor {
    public let backend: WindowBackend
    /// 这是观察上限，不是固定等待时间；一旦发现进程结束就立即返回。
    public var timeout: Double = 6.0
    public var pollInterval: Double = 0.02
    public var dialogInterval: Double = 0.15
    public var axInterval: Double = 0.5
    /// 整次辅助功能检查共用预算，不会按窗口数、属性数累加超时。
    public var axBudget: Float = 0.12
    public var dialogSettle: Double = 0.15
    public var allowedPIDs: Set<pid_t>?
    public private(set) var lastTiming = QuitTiming()

    public init(backend: WindowBackend) {
        self.backend = backend
    }

    public func attempt(_ t: QuitTarget) -> QuitOutcome {
        lastTiming = QuitTiming()
        let start = backend.now()
        if let allowed = allowedPIDs, !allowed.contains(t.pid) { return .skipped(SkipReason.notAllowed.text) }
        guard backend.isAppRunning(t.pid) else { return .skipped("应用已经不在运行") }
        let baseline = Set(backend.onScreenWindows().filter { $0.pid == t.pid }.map(\.windowID))
        let requestStart = backend.now()
        lastTiming.prepare = requestStart - start
        let accepted = backend.terminateApp(t.pid)
        let observeStart = backend.now()
        lastTiming.request = observeStart - requestStart
        if !accepted {
            return backend.isAppRunning(t.pid) ? .failed("系统没有接受退出请求") : .quit
        }

        let ctx = QuitPendingContext(target: t, baseline: baseline)
        let deadline = observeStart + timeout
        var nextDialogCheck = observeStart
        var nextAXCheck = observeStart + axInterval
        var dialogSince: Double?
        var axDialog = false

        func finish(_ result: QuitOutcome) -> QuitOutcome {
            lastTiming.observe = backend.now() - observeStart
            return result
        }

        while true {
            // 快路径只看进程是否结束；不再每轮读取完整的辅助功能窗口信息。
            if !backend.isAppRunning(t.pid) { return finish(.quit) }
            let now = backend.now()
            if now >= deadline {
                return finish(.failed("应用没有在 \(Int(timeout)) 秒内退出（可能正忙或没有响应）；扫把不会强制退出它"))
            }
            if now >= nextDialogCheck {
                let checkStart = backend.now()
                var dialog = hasNewDialog(ctx)
                if !dialog && backend.now() >= nextAXCheck {
                    let remaining = deadline - backend.now()
                    if remaining > 0, case .success(let found) = backend.appHasDialog(pid: t.pid, timeout: min(axBudget, Float(remaining))) {
                        axDialog = found
                    }
                    nextAXCheck = backend.now() + axInterval
                }
                dialog = dialog || axDialog
                lastTiming.dialogChecks += 1
                lastTiming.dialogTime += backend.now() - checkStart
                // 系统读取返回时应用可能已经退出，先复核，避免继续睡眠或误报确认框。
                if !backend.isAppRunning(t.pid) { return finish(.quit) }
                if dialog {
                    if let since = dialogSince {
                        if backend.now() - since >= dialogSettle { return finish(.needsUser(ctx)) }
                    } else {
                        dialogSince = backend.now()
                    }
                } else {
                    dialogSince = nil
                }
                nextDialogCheck = backend.now() + dialogInterval
            }
            let remaining = deadline - backend.now()
            if remaining > 0 { backend.sleep(min(pollInterval, remaining)) }
        }
    }

    public func checkPending(_ ctx: QuitPendingContext) -> PendingState {
        guard backend.isAppRunning(ctx.target.pid) else { return .closed }
        if hasNewDialog(ctx) { return .stillWaiting }
        let result = backend.appHasDialog(pid: ctx.target.pid, timeout: axBudget)
        guard backend.isAppRunning(ctx.target.pid) else { return .closed }
        switch result {
        case .success(let found): return found ? .stillWaiting : .keptOpen
        case .failure: return .stillWaiting // 应用正忙或权限不足，不假报用户已取消。
        }
    }

    private func hasNewDialog(_ ctx: QuitPendingContext) -> Bool {
        backend.onScreenWindows().contains {
            $0.pid == ctx.target.pid && !ctx.baseline.contains($0.windowID) && WindowMatcher.isDialogCandidate($0)
        }
    }
}
