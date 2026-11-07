import Foundation
import CoreGraphics

/// 关闭逻辑需要的系统能力。真实实现见 LiveBackend；逻辑检查里用模拟实现。
public protocol WindowBackend: AnyObject {
    /// 当前在屏幕上的全部窗口（不含桌面），从前到后排序。
    func onScreenWindows() -> [CGWindowInfo]
    /// 按窗口编号查询；窗口已不存在时返回 nil（无论是否在屏幕上）。
    func windowInfo(_ id: CGWindowID) -> CGWindowInfo?
    func isAppRunning(_ pid: pid_t) -> Bool
    /// 向应用发送标准的“退出”请求（等同 ⌘Q）。只用于用户明确点了“退出应用”的情况。
    func terminateApp(_ pid: pid_t) -> Bool
    func axWindows(pid: pid_t, timeout: Float, includeSheetCheck: Bool) -> Result<[AXWindowRef], AXAccessError>
    func pressCloseButton(of ref: AXWindowRef, timeout: Float) -> AXActionResult
    /// 重新读取窗口信息（含 sheet 检查）。读不到时返回 nil。
    func refreshAXInfo(_ ref: AXWindowRef, timeout: Float) -> AXWindowInfo?
    func sleep(_ seconds: Double)
    func now() -> TimeInterval
}

/// 对单个窗口执行“核对 → 按关闭按钮 → 观察结果”。在后台线程同步运行。
public final class CloseExecutor {
    public let backend: WindowBackend
    /// 按下后最多观察多久（秒）
    public var observeTimeout: Double = 3.0
    /// 按下请求超时（应用可能卡住或进入模态对话框）后，再观察多久
    public var observeAfterTimeout: Double = 4.0
    public var pollInterval: Double = 0.05
    /// 读取信息时的超时：超过即认为应用无响应，不发送关闭请求
    public var axReadTimeout: Float = 1.0
    public var axPressTimeout: Float = 2.0
    /// 窗口离开屏幕后再确认多久才判定为已关闭（连续两次检查都不在屏幕上，且没有弹出对话框）
    public var offscreenSettle: Double = 0.1
    /// 自检时使用：只允许操作这些进程的窗口
    public var allowedPIDs: Set<pid_t>?

    public init(backend: WindowBackend) {
        self.backend = backend
    }

    public func attempt(_ target: CloseTarget) -> CloseOutcome {
        if let allowed = allowedPIDs, !allowed.contains(target.pid) { return .skipped(.notAllowed) }
        guard backend.isAppRunning(target.pid) else { return .skipped(.appNotRunning) }

        // 1. 窗口仍存在、归属未变、仍在屏幕上
        guard let info = backend.windowInfo(target.windowID) else { return .skipped(.windowGone) }
        guard info.pid == target.pid else { return .skipped(.ownerChanged) }
        guard info.isOnScreen else { return .skipped(.notOnScreen) }

        // 2. 读取该应用的辅助功能窗口（同时检查应用是否有响应）
        let axList: [AXWindowRef]
        switch backend.axWindows(pid: target.pid, timeout: axReadTimeout, includeSheetCheck: false) {
        case .success(let list): axList = list
        case .failure(.notTrusted): return .failed(.notTrusted)
        case .failure(.appUnresponsive): return .skipped(.appUnresponsive)
        case .failure(.appGone): return .skipped(.appNotRunning)
        case .failure(.other(let code)): return .failed(.axError(code))
        }

        // 3. 用最新的窗口列表重新配对，要求唯一
        let onScreen = backend.onScreenWindows()
        guard let current = onScreen.first(where: { $0.windowID == target.windowID }) else {
            return backend.windowInfo(target.windowID) == nil ? .skipped(.windowGone) : .skipped(.notOnScreen)
        }
        guard current.pid == target.pid else { return .skipped(.ownerChanged) }
        let samePID = onScreen.filter { $0.pid == target.pid }
        let verdict = WindowMatcher.match(target: current, peers: samePID, axWindows: axList.map(\.info))
        guard case .unique(let index, _) = verdict else { return .skipped(.notUniquelyIdentified) }
        var ref = axList[index]

        // 4. 关闭按钮存在且可用；窗口上没有正在显示的对话框
        if let fresh = backend.refreshAXInfo(ref, timeout: axReadTimeout) {
            // 刷新后位置尺寸必须仍然一致，防止刚好在这期间窗口被换掉
            guard let f = fresh.frame, WindowMatcher.framesMatch(f, current.bounds) else {
                return .skipped(.notUniquelyIdentified)
            }
            ref = AXWindowRef(info: fresh, handle: ref.handle)
        } else {
            return .skipped(.appUnresponsive)
        }
        if ref.info.hasSheet { return .skipped(.alreadyHasDialog) }
        guard ref.info.hasCloseButton else { return .skipped(.noCloseButton) }
        guard ref.info.closeButtonEnabled else { return .skipped(.closeButtonDisabled) }

        // 5. 按下关闭按钮（等同于点击红色按钮）
        let baseline = Set(samePID.map(\.windowID))
        let press = backend.pressCloseButton(of: ref, timeout: axPressTimeout)
        switch press {
        case .success, .timedOut:
            break
        case .elementGone:
            if backend.windowInfo(target.windowID) == nil { return .closed(.destroyed) }
            return .failed(.pressFailed(-25202))
        case .failed(let code):
            return .failed(.pressFailed(code))
        }

        // 6. 观察真实结果
        return observe(target: target, ref: ref, baseline: baseline, pressTimedOut: press == .timedOut)
    }

    private func observe(target: CloseTarget, ref: AXWindowRef, baseline: Set<CGWindowID>, pressTimedOut: Bool) -> CloseOutcome {
        let deadline = backend.now() + (pressTimedOut ? observeAfterTimeout : observeTimeout)
        var offscreenSince: TimeInterval?
        var tick = 0
        while true {
            guard let info = backend.windowInfo(target.windowID) else { return .closed(.destroyed) }

            let newDialogs = backend.onScreenWindows().filter {
                $0.pid == target.pid && !baseline.contains($0.windowID) && WindowMatcher.isDialogCandidate($0)
            }
            if !newDialogs.isEmpty {
                return .needsUser(PendingContext(target: target, kind: .dialogWindow, baseline: baseline, windowRef: ref))
            }
            if tick % 3 == 0, info.isOnScreen,
               let fresh = backend.refreshAXInfo(ref, timeout: 0.5), fresh.hasSheet {
                return .needsUser(PendingContext(target: target, kind: .sheet, baseline: baseline, windowRef: ref))
            }

            if !info.isOnScreen {
                let t = backend.now()
                if let since = offscreenSince {
                    if t - since >= offscreenSettle { return .closed(.removedFromScreen) }
                } else {
                    offscreenSince = t
                }
            } else {
                offscreenSince = nil
            }

            if backend.now() >= deadline {
                if !info.isOnScreen { return .closed(.removedFromScreen) }
                return .failed(pressTimedOut ? .unresponsiveAfterPress : .stillOpen)
            }
            backend.sleep(pollInterval)
            tick += 1
        }
    }

    /// 暂停等待用户处理期间反复调用：确认框是否还在、窗口是否已关闭。
    public func checkPending(_ ctx: PendingContext) -> PendingState {
        guard let info = backend.windowInfo(ctx.target.windowID) else { return .closed }
        if !info.isOnScreen { return .closed }
        let newDialogs = backend.onScreenWindows().filter {
            $0.pid == ctx.target.pid && !ctx.baseline.contains($0.windowID) && WindowMatcher.isDialogCandidate($0)
        }
        if !newDialogs.isEmpty { return .stillWaiting }
        guard let fresh = backend.refreshAXInfo(ctx.windowRef, timeout: 0.5) else {
            // 读不到（应用可能正忙）时不下结论
            return .stillWaiting
        }
        return fresh.hasSheet ? .stillWaiting : .keptOpen
    }

    /// 队列结束后复查：之前判为失败或等待的窗口，是否后来关闭了。
    public func isGoneNow(_ id: CGWindowID) -> Bool {
        backend.windowInfo(id) == nil
    }
}
