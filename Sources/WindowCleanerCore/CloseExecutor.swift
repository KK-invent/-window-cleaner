import Foundation
import CoreGraphics

/// 关闭逻辑需要的系统能力。真实实现见 LiveBackend；逻辑检查里用模拟实现。
public protocol WindowBackend: AnyObject {
    /// 当前在屏幕上的全部窗口（不含桌面），从前到后排序。
    func onScreenWindows() -> [CGWindowInfo]
    /// 所有桌面上的窗口，也包含全屏、最小化和隐藏应用的窗口。
    func allWindows() -> [CGWindowInfo]
    /// 按窗口编号查询；窗口已不存在时返回 nil（无论是否在屏幕上）。
    func windowInfo(_ id: CGWindowID) -> CGWindowInfo?
    func isAppRunning(_ pid: pid_t) -> Bool
    func isAppHidden(_ pid: pid_t) -> Bool
    /// 向应用发送标准的“退出”请求（等同 ⌘Q）。只用于用户明确点了“退出应用”的情况。
    func terminateApp(_ pid: pid_t) -> Bool
    /// 只检查确认框，不读取窗口标题、位置、尺寸或关闭按钮。timeout 为整次检查的时间预算。
    func appHasDialog(pid: pid_t, timeout: Float) -> Result<Bool, AXAccessError>
    func axWindows(pid: pid_t, timeout: Float, includeSheetCheck: Bool) -> Result<[AXWindowRef], AXAccessError>
    func pressCloseButton(of ref: AXWindowRef, timeout: Float) -> AXActionResult
    /// 重新读取窗口信息（含 sheet 检查）。读不到时返回 nil。
    func refreshAXInfo(_ ref: AXWindowRef, timeout: Float) -> AXWindowInfo?
    /// 应用是否已明确报告这个窗口对象不存在（辅助功能返回“元素无效”）。超时、应用忙时返回 false。
    func axWindowIsGone(_ ref: AXWindowRef, timeout: Float) -> Bool
    func sleep(_ seconds: Double)
    func now() -> TimeInterval
}

/// 关闭一个窗口的分段耗时：核对、按下、观察，以及观察期间辅助功能检查的开销。
public struct CloseTiming {
    public var verify: Double = 0
    public var press: Double = 0
    public var observe: Double = 0
    public var ticks: Int = 0
    public var axChecks: Int = 0
    public var axTime: Double = 0

    public var text: String {
        "核对 \(Int(verify * 1000))ms 按下 \(Int(press * 1000))ms 观察 \(Int(observe * 1000))ms（\(ticks)次，辅助检查 \(axChecks)次/\(Int(axTime * 1000))ms）"
    }
}

/// 对单个窗口执行“核对 → 按关闭按钮 → 观察结果”。在后台线程同步运行。
public final class CloseExecutor {
    public let backend: WindowBackend
    /// 按下后最多观察多久（秒）
    public var observeTimeout: Double = 3.0
    /// 按下请求超时（应用可能卡住或进入模态对话框）后，再观察多久
    public var observeAfterTimeout: Double = 4.0
    public var pollInterval: Double = 0.02
    /// 关窗淡出开始的判定：窗口透明度降到按下时的这个比例以下
    public var fadeRatio: Double = 0.97
    /// 读取信息时的超时：超过即认为应用无响应，不发送关闭请求
    public var axReadTimeout: Float = 1.0
    public var axPressTimeout: Float = 2.0
    /// 窗口离开屏幕后再确认多久才判定为已关闭（连续两次检查都不在屏幕上，且没有弹出对话框）
    public var offscreenSettle: Double = 0.1
    /// 自检时使用：只允许操作这些进程的窗口
    public var allowedPIDs: Set<pid_t>?
    public private(set) var lastTiming = CloseTiming()

    public init(backend: WindowBackend) {
        self.backend = backend
    }

    public func attempt(_ target: CloseTarget) -> CloseOutcome {
        lastTiming = CloseTiming()
        let start = backend.now()
        let outcome = attemptCore(target, start: start)
        if lastTiming.verify == 0 { lastTiming.verify = backend.now() - start }
        return outcome
    }

    private func attemptCore(_ target: CloseTarget, start: TimeInterval) -> CloseOutcome {
        if let allowed = allowedPIDs, !allowed.contains(target.pid) { return .skipped(.notAllowed) }
        guard backend.isAppRunning(target.pid) else { return .skipped(.appNotRunning) }
        guard !backend.isAppHidden(target.pid) else { return .skipped(.notOnScreen) }

        // 1. 窗口仍存在、归属未变；当前桌面模式不能跨桌面执行。
        guard let info = backend.windowInfo(target.windowID) else { return .skipped(.windowGone) }
        guard info.pid == target.pid else { return .skipped(.ownerChanged) }
        guard info.isOnScreen || target.allowOffscreen else { return .skipped(.notOnScreen) }

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
        let all = backend.allWindows()
        guard let current = all.first(where: { $0.windowID == target.windowID }) else {
            return backend.windowInfo(target.windowID) == nil ? .skipped(.windowGone) : .skipped(.notOnScreen)
        }
        guard current.pid == target.pid else { return .skipped(.ownerChanged) }
        guard current.isOnScreen || target.allowOffscreen else { return .skipped(.notOnScreen) }
        let samePID = all.filter { $0.pid == target.pid }
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
        if ref.info.isMinimized || backend.isAppHidden(target.pid) { return .skipped(.notOnScreen) }
        if ref.info.hasSheet { return .skipped(.alreadyHasDialog) }
        guard ref.info.hasCloseButton else { return .skipped(.noCloseButton) }
        guard ref.info.closeButtonEnabled else { return .skipped(.closeButtonDisabled) }

        // 5. 按下关闭按钮（等同于点击红色按钮）
        let baseline = Set(samePID.map(\.windowID))
        let pressStart = backend.now()
        lastTiming.verify = pressStart - start
        let press = backend.pressCloseButton(of: ref, timeout: axPressTimeout)
        lastTiming.press = backend.now() - pressStart
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
        return observe(target: target, ref: ref, baseline: baseline, pressTimedOut: press == .timedOut,
                       wasOnScreen: current.isOnScreen, startAlpha: current.alpha)
    }

    private func observe(target: CloseTarget, ref: AXWindowRef, baseline: Set<CGWindowID>, pressTimedOut: Bool,
                         wasOnScreen: Bool, startAlpha: Double) -> CloseOutcome {
        let observeStart = backend.now()
        defer { lastTiming.observe = backend.now() - observeStart }
        let deadline = observeStart + (pressTimedOut ? observeAfterTimeout : observeTimeout)
        var offscreenSince: TimeInterval?
        var tick = 0
        while true {
            lastTiming.ticks = tick + 1
            guard let info = backend.windowInfo(target.windowID) else { return .closed(.destroyed) }

            let newDialogs = backend.allWindows().filter {
                $0.pid == target.pid && !baseline.contains($0.windowID) &&
                    WindowMatcher.isDialogCandidate($0, includeOffscreen: target.allowOffscreen)
            }
            if !newDialogs.isEmpty {
                return .needsUser(PendingContext(target: target, kind: .dialogWindow, baseline: baseline, windowRef: ref, wasOnScreen: wasOnScreen))
            }
            // 系统正在播放关窗淡出（约 0.3 秒），且应用已明确报告该窗口对象不存在：关闭已经发生，
            // 不必等淡出动画结束、窗口记录被系统删除。没有新确认框是前提（上面已检查）。
            if wasOnScreen, info.isOnScreen, startAlpha > 0, info.alpha < startAlpha * fadeRatio,
               timedAX({ backend.axWindowIsGone(ref, timeout: 0.1) }) {
                return .closed(.destroyed)
            }
            // 每约 60 毫秒检查一次表单式确认框（淡出期间窗口已无效，无需再查）
            if tick % 3 == 0, let fresh = timedAX({ backend.refreshAXInfo(ref, timeout: 0.5) }), fresh.hasSheet {
                return .needsUser(PendingContext(target: target, kind: .sheet, baseline: baseline, windowRef: ref, wasOnScreen: wasOnScreen))
            }

            if wasOnScreen && !info.isOnScreen {
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
                if wasOnScreen && !info.isOnScreen { return .closed(.removedFromScreen) }
                return .failed(pressTimedOut ? .unresponsiveAfterPress : .stillOpen)
            }
            backend.sleep(pollInterval)
            tick += 1
        }
    }

    private func timedAX<T>(_ body: () -> T) -> T {
        let t0 = backend.now()
        defer {
            lastTiming.axChecks += 1
            lastTiming.axTime += backend.now() - t0
        }
        return body()
    }

    /// 暂停等待用户处理期间反复调用：确认框是否还在、窗口是否已关闭。
    public func checkPending(_ ctx: PendingContext) -> PendingState {
        guard let info = backend.windowInfo(ctx.target.windowID) else { return .closed }
        if ctx.wasOnScreen && !info.isOnScreen { return .closed }
        let newDialogs = backend.allWindows().filter {
            $0.pid == ctx.target.pid && !ctx.baseline.contains($0.windowID) &&
                WindowMatcher.isDialogCandidate($0, includeOffscreen: ctx.target.allowOffscreen)
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
