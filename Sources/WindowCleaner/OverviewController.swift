import AppKit
import SwiftUI

/// 覆盖全屏的总览窗口。无边框窗口默认不能成为键盘焦点，这里放开以便接收 Esc。
/// 总览显示期间请系统隐藏程序坞和菜单栏（全屏应用的标准做法），鼠标移到屏幕底部不会让程序坞放大或弹出；
/// 总览收起后立即恢复。这个设置只在窗口清理处于前台时生效。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        Self.setSystemBarsHidden(true)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        Self.setSystemBarsHidden(false)
    }

    override func close() {
        super.close()
        Self.setSystemBarsHidden(false)
    }

    static func setSystemBarsHidden(_ hidden: Bool) {
        let options: NSApplication.PresentationOptions = hidden ? [.hideDock, .hideMenuBar] : []
        guard NSApp.presentationOptions != options else { return }
        NSApp.presentationOptions = options
        // 记录系统实际生效的设置（程序坞是否真的被隐藏）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let current = NSApp.currentSystemPresentationOptions
            TimingLog.append("dock request=\(hidden ? "hide" : "show") effectiveHideDock=\(current.contains(.hideDock)) effectiveHideMenuBar=\(current.contains(.hideMenuBar)) appActive=\(NSApp.isActive)")
        }
    }
}

/// 浮动小面板：暂停时提示用户处理原应用的确认框；授权时显示进度。点击会激活本应用。
final class HelperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum PauseDecision {
    case proceed
    case stop
}

@MainActor
final class OverviewController: NSObject {
    let model = OverviewModel()
    let backend = LiveBackend()
    lazy var executor = CloseExecutor(backend: backend)
    /// 自检时限定只能操作测试宿主的进程
    var allowedPIDs: Set<pid_t>?
    /// 自检时由自检程序代替用户处理暂停
    var pauseHandler: (() async -> PauseDecision)?

    private var overlay: OverlayWindow?
    private var panel: HelperPanel?
    private var thumbnailTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var keyMonitor: Any?
    private var pauseContinuation: CheckedContinuation<PauseDecision, Never>?
    private var loadGeneration = 0

    var isOverlayVisible: Bool { overlay?.isVisible == true }
    var isBusy: Bool { model.phase == .running || model.phase == .paused || workerRunning }
    var isWaitingForPermission: Bool { panel?.isVisible == true && model.phase == .needsPermission }

    lazy var actions = OverviewActions(
        cardClicked: { [weak self] e in self?.cardClicked(e) },
        appClicked: { [weak self] a in self?.appClicked(a) },
        tabClicked: { [weak self] k in self?.tabClicked(k) },
        tabMarqueeFinished: { [weak self] ks in self?.tabMarqueeFinished(ks) },
        closeTabGroup: { [weak self] ks in self?.closeTabGroup(ks) },
        appMarqueeFinished: { [weak self] list in self?.appMarqueeFinished(list) },
        switchPage: { [weak self] p in self?.switchPage(p) },
        requestTabsPermission: { [weak self] in self?.requestTabsPermission() },
        openAutomationSettings: { [weak self] in self?.openAutomationSettings() },
        reloadTabs: { [weak self] in self?.loadTabs() },
        backgroundClicked: { [weak self] in self?.backgroundClicked() },
        marqueeFinished: { [weak self] list in self?.marqueeFinished(list) },
        dismiss: { [weak self] in self?.dismiss(hideApp: true, animated: true) },
        closeSelected: { [weak self] in self?.startClosing() },
        stop: { [weak self] in self?.model.stopRequested = true },
        refresh: { [weak self] in self?.reload(reason: "刷新", t0: CACurrentMediaTime()) },
        finish: { [weak self] in self?.dismiss(hideApp: true, animated: true) },
        openAccessibility: { [weak self] in self?.openPermissionSettings(accessibility: true) },
        openScreenRecording: { [weak self] in self?.openPermissionSettings(accessibility: false) },
        recheckPermissions: { [weak self] in self?.reload(reason: "重新检测权限", t0: CACurrentMediaTime()) },
        relaunch: { [weak self] in self?.relaunch() }
    )

    // MARK: 显示 / 隐藏

    /// 唤出总览。reason 只用于耗时记录。
    func show(reason: String) {
        let t0 = CACurrentMediaTime()
        releaseTask?.cancel()
        releaseTask = nil
        if isBusy {
            // 正在关闭时再次点击：只把当前界面提到前面
            if model.phase == .paused { panel?.orderFrontRegardless() } else { overlay?.makeKeyAndOrderFront(nil) }
            return
        }
        if isOverlayVisible { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        closePanel()
        let window = ensureOverlay()
        if let screen = screenWithMouse() {
            window.setFrame(screen.frame, display: false)
        }
        model.reset()
        model.page = .windows
        model.phase = .loading
        model.timingText = ""
        // 进入动画：窗口淡入，界面从略大缩放到正常
        model.exiting = false
        model.shown = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        animateContentScale(from: 1.035, to: 1, duration: 0.3, timing: .easeOut, keep: false)
        model.shown = true
        installKeyMonitor()
        let processMs = reason == "启动" ? TimingLog.msSinceProcessStart() : nil
        DispatchQueue.main.async { [weak self] in
            let ms = (CACurrentMediaTime() - t0) * 1000
            var line = "show reason=\(reason) overlayVisible=\(Int(ms))ms \(TimingLog.memoryText())"
            if let processMs { line += " processStart→overlay=\(Int(processMs + ms))ms" }
            TimingLog.append(line)
            self?.lastOverlayMs = ms
            self?.lastProcessMs = processMs.map { $0 + ms }
        }
        reload(reason: reason, t0: t0)
    }

    private var lastOverlayMs: Double = 0
    private var lastProcessMs: Double?

    func dismiss(hideApp: Bool = true, animated: Bool = false) {
        guard !isBusy else { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        cancelLoading()
        stopPermissionPolling()
        removeKeyMonitor()
        closePanel()
        let finish = { [weak self] in
            guard let self else { return }
            self.overlay?.orderOut(nil)
            self.overlay?.alphaValue = 1
            self.overlay?.contentView?.layer?.removeAnimation(forKey: "wcScale")
            self.overlay?.contentView?.layer?.transform = CATransform3DIdentity
            if animated { TimingLog.append("dismissed (animated) \(TimingLog.memoryText())") }
            self.model.reset()
            self.model.phase = .loading
            self.model.activeCount = 0
            self.scheduleRelease()
            // 交还焦点给之前的应用
            if hideApp { NSApp.hide(nil) }
        }
        if animated, let overlay, overlay.isVisible {
            model.exiting = true
            model.shown = false
            animateContentScale(from: 1, to: 0.97, duration: 0.22, timing: .easeIn, keep: true)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in finish() }
            })
        } else {
            finish()
        }
    }

    /// 进入/退出时整体轻微缩放：直接在合成层上做，不重画界面，几乎不占额外内存
    private func animateContentScale(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
                                     timing: CAMediaTimingFunctionName, keep: Bool) {
        guard !model.reduceMotion, let view = overlay?.contentView else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let b = layer.bounds
        // 以画面中心为基准缩放（AppKit 图层的原点在左下角）
        func t(_ s: CGFloat) -> CATransform3D {
            var m = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            m = CATransform3DScale(m, s, s, 1)
            return CATransform3DTranslate(m, -b.midX, -b.midY, 0)
        }
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = t(from)
        anim.toValue = t(to)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: timing)
        if keep {
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
        }
        layer.add(anim, forKey: "wcScale")
    }

    // MARK: 省内存：总览关闭一段时间后释放整个界面

    private var releaseTask: Task<Void, Never>?

    /// 关闭 30 秒内再打开仍然很快；超过 30 秒释放总览窗口和界面占用的内存，下次打开时重建（慢几十毫秒）
    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled, let o = self.overlay, !o.isVisible, !self.isBusy else { return }
            // 正式关闭（不只是隐藏），应用的窗口列表才不再持有它，界面和图层才会真正释放
            o.contentView = nil
            o.close()
            self.overlay = nil
            self.model.thumbnails = [:]
            self.model.favicons = [:]
            // 把空出来的内存真正还给系统
            malloc_zone_pressure_relief(nil, 0)
            TimingLog.append("overlay released after idle \(TimingLog.memoryText())")
        }
    }

    // MARK: 没有窗口时自动退出

    private var autoDismissTask: Task<Void, Never>?

    /// 自动退出总览的规则：
    /// - 关完最后一个窗口（最后一步是关窗口）→ 自动退出；
    /// - 打开时就没有窗口，或刚退出了某个应用 → 只要下方应用栏还有应用可以退出，就不自动退出；
    /// - 还有没关成的窗口（跳过、失败、等你处理）时不退出，以便看到原因。自检期间不自动退出。
    func checkAutoDismiss() {
        guard allowedPIDs == nil, isOverlayVisible, model.page == .windows,
              model.phase == .selecting || model.phase == .finished,
              !workerRunning, clickQueue.isEmpty, !model.marqueeActive else { return }
        let remainingWindows = model.entries.filter { !model.vanished.contains($0.id) }
        let remainingApps = model.apps.filter { !model.vanishedApps.contains($0.id) }
        let closedAllWindows = model.summary.closed > 0 && lastActionKind == .window
        guard remainingWindows.isEmpty, closedAllWindows || remainingApps.isEmpty else {
            autoDismissTask?.cancel()
            autoDismissTask = nil
            return
        }
        // 刚关完最后一个：等卡片淡出后退出；打开时就什么都没有：让提示停留 1 秒左右
        let delay = closedAllWindows ? 0.45 : 1.1
        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let stillEmpty = self.model.entries.allSatisfy { self.model.vanished.contains($0.id) }
            guard stillEmpty, self.isOverlayVisible, !self.workerRunning, self.clickQueue.isEmpty,
                  self.model.phase == .selecting || self.model.phase == .finished else { return }
            TimingLog.append("auto-dismiss reason=\(closedAllWindows ? "关完最后一个窗口" : "没有窗口也没有应用")")
            self.dismiss(hideApp: true, animated: true)
        }
    }

    /// 自检用：向本应用发送一次真实的 Esc 按键事件，走与用户按键相同的处理路径
    func simulateEscapeKey() {
        guard let overlay else { return }
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.windowNumber,
                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                    isARepeat: false, keyCode: 53) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    func didResignActive() {
        if workerRunning { return }
        // 选择阶段切到别的应用（例如 Cmd-Tab），就像调度中心一样收起，不关闭任何窗口
        if isOverlayVisible && (model.phase == .selecting || model.phase == .loading || model.phase == .finished || model.phase == .needsPermission) {
            cancelLoading()
            stopPermissionPolling()
            removeKeyMonitor()
            overlay?.orderOut(nil)
            model.reset()
            scheduleRelease()
        }
    }

    private func ensureOverlay() -> OverlayWindow {
        if let overlay { return overlay }
        let screen = screenWithMouse() ?? NSScreen.main!
        let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .statusBar
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.title = "窗口清理"
        model.onCardsVanished = { [weak self] in
            self?.scheduleCompaction()
            self?.checkAutoDismiss()
        }
        let hosting = NSHostingView(rootView: OverviewRoot(model: model, actions: actions))
        // 不让界面内容反过来改变窗口尺寸：总览始终与屏幕一样大
        hosting.sizingOptions = []
        w.contentView = hosting
        overlay = w
        return w
    }

    private func screenWithMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.handleEscape()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// 点空白处：和按 Esc 完全一样
    func backgroundClicked() {
        lastPointerAction = CACurrentMediaTime()
        TimingLog.append("dismiss reason=点击空白处 \(TimingLog.memoryText())")
        handleEscape()
    }

    /// Esc：选择阶段退出总览且不关闭任何窗口；正在关闭时不做任何事（请用“停止剩余”）
    func handleEscape() {
        guard isOverlayVisible else { return }
        if model.marqueeActive {
            // 正在圈选：只取消这次圈选
            model.cancelMarquee()
            return
        }
        if workerRunning && model.phase == .selecting {
            // 单击即关闭模式下还有排队的：取消排队中的（不再关闭），当前这个处理完后退出
            for q in clickQueue { setStatus(q, nil) }
            clickQueue.removeAll()
            model.activeCount = 1
            dismissWhenIdle = true
            return
        }
        guard !isBusy else { return }
        dismiss(hideApp: true, animated: true)
    }

    // MARK: 读取窗口和缩略图

    func reload(reason: String, t0: CFTimeInterval) {
        guard !isBusy else { return }
        cancelLoading()
        loadGeneration += 1
        let generation = loadGeneration
        model.axTrusted = Permissions.accessibility
        model.screenRecording = Permissions.screenRecording
        if !model.axTrusted {
            model.reset()
            model.phase = .needsPermission
            startPermissionPolling()
            TimingLog.append("show reason=\(reason) state=needsAccessibility")
            return
        }
        stopPermissionPolling()
        if model.phase != .selecting && model.phase != .finished { model.phase = .loading }
        let ownPID = getpid()
        Task.detached(priority: .userInitiated) {
            var result = WindowEnumerator.enumerate(backend: LiveBackend(), ownPID: ownPID)
            // 刚安装新版本后，系统可能有一小段时间仍拒绝辅助功能请求：权限明明在，就稍等再读一次
            for _ in 0..<2 where !result.axTrusted && AXIsProcessTrusted() {
                TimingLog.append("list retry: accessibility requests were refused although permission is granted")
                try? await Task.sleep(nanoseconds: 600_000_000)
                result = WindowEnumerator.enumerate(backend: LiveBackend(), ownPID: ownPID)
            }
            let finalResult = result
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.apply(finalResult, reason: reason, t0: t0, generation: generation)
            }
        }
    }

    private func apply(_ result: WindowEnumerator.Result, reason: String, t0: CFTimeInterval, generation: Int) {
        let listMs = (CACurrentMediaTime() - t0) * 1000
        model.reset()
        model.entries = result.entries
        DispatchQueue.main.async { [weak self] in self?.model.cardsRevealed = true }
        var counts: [pid_t: Int] = [:], order: [pid_t: Int] = [:]
        for (i, e) in result.entries.enumerated() {
            counts[e.pid, default: 0] += 1
            if order[e.pid] == nil { order[e.pid] = i }
        }
        model.apps = OverviewModel.runningApps(windowCounts: counts, order: order)
        model.hasTitles = result.hasTitles
        if model.page == .browserTabs { loadTabs() }
        model.phase = .selecting
        updateTimingText(listMs: listMs, thumbMs: nil, ok: 0, failed: 0)
        checkAutoDismiss()
        var blocked: [String: Int] = [:]
        for e in result.entries { if let r = e.closability.reasonText { blocked[r, default: 0] += 1 } }
        let blockedText = blocked.isEmpty ? "" : " blocked=" + blocked.map { "\($0.key)×\($0.value)" }.joined(separator: ";")
        TimingLog.append("show reason=\(reason) list=\(Int(listMs))ms windows=\(result.entries.count) closable=\(result.entries.filter(\.isClosable).count)\(blockedText) \(TimingLog.memoryText())")
        guard model.screenRecording, !result.entries.isEmpty else {
            model.thumbnailPhase = model.screenRecording ? .done : .unavailable("未授权屏幕录制")
            return
        }
        model.thumbnailPhase = .loading
        let ids = result.entries.map(\.id)
        let maxPx = thumbnailPixelSize(count: result.entries.count)
        thumbnailTask = Task { [weak self] in
            do {
                let (ok, failed) = try await ThumbnailLoader.load(ids: ids, maxPixelSize: maxPx) { id, image in
                    guard let self, generation == self.loadGeneration else { return }
                    if let image { self.model.thumbnails[id] = image } else { self.model.failedThumbnails.insert(id) }
                }
                guard let self, generation == self.loadGeneration else { return }
                let ms = (CACurrentMediaTime() - t0) * 1000
                self.model.thumbnailPhase = .done
                self.updateTimingText(listMs: listMs, thumbMs: ms, ok: ok, failed: failed)
                TimingLog.append("show reason=\(reason) thumbnails=\(Int(ms))ms ok=\(ok) failed=\(failed) \(TimingLog.memoryText())")
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.model.thumbnailPhase = .unavailable("系统拒绝了截图请求（屏幕锁定时也会这样）")
                self.model.failedThumbnails = Set(ids)
                TimingLog.append("show reason=\(reason) thumbnails=failed error=\(error)")
            }
        }
    }

    /// 按卡片实际显示的大小决定缩略图像素（与界面同样的排版规则估算）
    private func thumbnailPixelSize(count: Int) -> CGSize {
        let scale = overlay?.backingScaleFactor ?? 2
        let screen = overlay?.frame.size ?? CGSize(width: 1600, height: 1000)
        // 去掉左右边距、顶部标题和页签、下方应用栏和底部栏
        let grid = CGSize(width: screen.width - 72, height: max(screen.height - 340, 300))
        let w = CardGrid.layout(count: max(count, 1), in: grid).width
        let thumb = CGSize(width: w - 24, height: w * 0.62 - 8)
        return CGSize(width: thumb.width * scale, height: thumb.height * scale)
    }

    private func updateTimingText(listMs: Double, thumbMs: Double?, ok: Int, failed: Int) {
        var parts: [String] = []
        if let p = lastProcessMs { parts.append("启动 \(Int(p)) ms") } else if lastOverlayMs > 0 { parts.append("唤出 \(Int(lastOverlayMs)) ms") }
        parts.append("列表 \(Int(listMs)) ms")
        if let thumbMs { parts.append("缩略图 \(Int(thumbMs)) ms（\(ok)/\(ok + failed)）") }
        model.timingText = parts.joined(separator: " · ")
    }

    private func cancelLoading() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        loadGeneration += 1
        if model.thumbnailPhase == .loading { model.thumbnailPhase = .idle }
    }

    // MARK: 关闭 / 退出队列

    func startClosing() {
        guard model.phase == .selecting, !model.selection.isEmpty else { return }
        cancelLoading() // 停止仍在进行的截图
        Task { await runQueue() }
    }

    /// 先选再关模式：按选中顺序依次处理窗口和应用
    func runQueue() async {
        let queue = model.selection
        let windows = model.selectedEntries
        model.phase = .running
        model.runTotal = queue.count
        model.runIndex = 0
        model.stopRequested = false
        lastActionKind = queue.contains { if case .app = $0 { return true }; return false } ? .app : .window
        for item in queue { setStatus(item, .queued) }

        for (i, item) in queue.enumerated() {
            if model.stopRequested {
                setStatus(item, .skipped(SkipReason.stoppedByUser.text))
                continue
            }
            model.runIndex = i + 1
            model.remainingCount = queue.count - i - 1
            let decision = await process(item)
            if decision == .stop { model.stopRequested = true }
        }

        model.phase = .finished
        if let overlay, !overlay.isVisible {
            overlay.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        let s = model.summary, a = model.appSummary
        TimingLog.append("run done closed=\(s.closed) waiting=\(s.waiting) skipped=\(s.skipped) failed=\(s.failed) appsQuit=\(a.closed)")
        checkAutoDismiss()
        scheduleRecheck(windows)
    }

    private func setStatus(_ item: QueueItem, _ st: ItemStatus?) {
        switch item {
        case .window(let id): model.statuses[id] = st
        case .app(let pid): model.appStatuses[pid] = st
        case .tab(let k): model.tabStatuses[k] = st
        }
    }

    private func status(_ item: QueueItem) -> ItemStatus? {
        switch item {
        case .window(let id): return model.statuses[id]
        case .app(let pid): return model.appStatuses[pid]
        case .tab(let k): return model.tabStatuses[k]
        }
    }

    private func process(_ item: QueueItem) async -> PauseDecision {
        switch item {
        case .window(let id):
            guard let e = model.entry(id) else { return .proceed }
            // 所属应用已经退出了：窗口也随之关闭，不必再处理
            if model.vanishedApps.contains(e.pid) { return .proceed }
            processedInSession.append(e)
            return await processWindow(e)
        case .app(let pid):
            guard let a = model.app(pid) else { return .proceed }
            return await processApp(a)
        case .tab(let k):
            return await processTab(k)
        }
    }

    // MARK: 浏览器标签页

    let tabsBackend = LiveTabsBackend()
    /// 网站图标缓存放在这里（不随总览关闭清空），同一网站只读一次数据库
    let faviconStore = FaviconStore()
    lazy var tabCloser = TabCloser(tabs: tabsBackend, windows: backend)
    /// 关过标签页的浏览器窗口卡片：回到“窗口与应用”页时重新截取它们的缩略图
    private var cardsNeedingRefresh: Set<CGWindowID> = []

    /// 切换总览顶部的页签
    func switchPage(_ p: OverviewPage) {
        lastPointerAction = CACurrentMediaTime()
        guard model.page != p else { return }
        model.cancelMarquee()
        model.marqueeCancelled = false
        withAnimation(.easeInOut(duration: 0.18)) { model.page = p }
        if p == .browserTabs {
            loadTabs()
        } else {
            refreshCards(cardsNeedingRefresh)
            cardsNeedingRefresh = []
            checkAutoDismiss()
        }
    }

    private func supportedBrowsers() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { BrowserTabSupport.supports($0.bundleIdentifier) && !$0.isTerminated }
    }

    /// 读取所有支持的浏览器的标签页（不会弹出授权询问）
    func loadTabs() {
        let browsers = supportedBrowsers()
        guard !browsers.isEmpty else {
            model.browserGroups = []
            model.tabsPhase = .noBrowser
            return
        }
        if model.browserGroups.isEmpty { model.tabsPhase = .loading }
        let backend = tabsBackend
        let list = browsers.map { ($0.processIdentifier, $0.localizedName ?? "浏览器") }
        let cards = model.entries.filter { BrowserTabSupport.supports($0.bundleID) }
        Task.detached(priority: .userInitiated) {
            var groups: [BrowserGroup] = []
            var needAsk: [String] = [], denied: [String] = []
            var errorText: String?
            for (pid, name) in list {
                switch backend.permission(pid: pid, ask: false) {
                case .granted:
                    switch backend.windows(pid: pid) {
                    case .success(let wins):
                        for w in wins where !w.tabs.isEmpty {
                            let card = cards.filter { $0.pid == pid }.first { c in
                                BrowserTabSupport.matchWindow(cardBounds: c.bounds, cardTitle: c.title, in: wins)?.id == w.id
                            }
                            groups.append(BrowserGroup(pid: pid, appName: name, windowID: w.id, title: w.title, cardID: card?.id, tabs: w.tabs))
                        }
                    case .failure(.notPermitted): denied.append(name)
                    case .failure(let e): errorText = "读取“\(name)”的标签页失败（\(e)）"
                    }
                case .notDetermined: needAsk.append(name)
                case .denied: denied.append(name)
                case .appNotRunning: break
                case .failed(let c): errorText = "无法确认是否允许控制“\(name)”（错误 \(c)）"
                }
            }
            let fGroups = groups, fAsk = needAsk, fDenied = denied, fError = errorText
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.model.browserGroups = fGroups
                if !fAsk.isEmpty && fGroups.isEmpty { self.model.tabsPhase = .needsPermission(fAsk) }
                else if !fDenied.isEmpty && fGroups.isEmpty { self.model.tabsPhase = .denied(fDenied) }
                else if let fError, fGroups.isEmpty { self.model.tabsPhase = .error(fError) }
                else { self.model.tabsPhase = .ready }
                TimingLog.append("tabs groups=\(fGroups.count) tabs=\(fGroups.reduce(0) { $0 + $1.tabs.count }) ask=\(fAsk.count) denied=\(fDenied.count)")
                self.loadFavicons(fGroups)
            }
        }
    }

    /// 在后台读取网站图标（只读本机图标数据库，不联网），读到一个显示一个
    private func loadFavicons(_ groups: [BrowserGroup]) {
        var urlsByBundle: [String: [String]] = [:]
        for g in groups {
            guard let b = NSRunningApplication(processIdentifier: g.pid)?.bundleIdentifier else { continue }
            urlsByBundle[b, default: []] += g.tabs.map(\.url)
        }
        let store = faviconStore
        Task.detached(priority: .utility) {
            let t0 = CFAbsoluteTimeGetCurrent()
            var all: [String: NSImage] = [:]
            for (bundle, urls) in urlsByBundle {
                all.merge(store.load(urls: urls, bundleID: bundle)) { a, _ in a }
            }
            let found = all
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.model.favicons.merge(found) { _, b in b }
                TimingLog.append("favicons found=\(found.count) ms=\(ms)")
            }
        }
    }

    /// 请求控制浏览器的权限：先收起总览，让系统的询问框能显示出来
    func requestTabsPermission() {
        let pids = supportedBrowsers().map(\.processIdentifier)
        let backend = tabsBackend
        overlay?.orderOut(nil)
        removeKeyMonitor()
        Task.detached {
            for pid in pids { _ = backend.permission(pid: pid, ask: true) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.overlay?.makeKeyAndOrderFront(nil)
                NSApp.activate()
                self.installKeyMonitor()
                self.loadTabs()
            }
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// 用户单击了一个标签页
    func tabClicked(_ k: TabKey) {
        lastPointerAction = CACurrentMediaTime()
        guard model.phase == .selecting else { return }
        guard model.closeOnClick else {
            model.toggleTab(k)
            return
        }
        if model.tabStatuses[k] != nil {
            cancelIfQueued(.tab(k))
            return
        }
        lastActionKind = .tab
        enqueue(.tab(k))
    }

    /// 组头的“全部关闭”：把这一组里还没处理的标签页依次排队关闭（先选再关模式下全部选中）
    func closeTabGroup(_ keys: [TabKey]) {
        lastPointerAction = CACurrentMediaTime()
        tabMarqueeFinished(keys)
    }

    func tabMarqueeFinished(_ keys: [TabKey]) {
        lastPointerAction = CACurrentMediaTime()
        guard model.phase == .selecting else { return }
        if model.closeOnClick {
            for k in keys where model.tabStatuses[k] == nil { tabClicked(k) }
        } else {
            for k in keys where model.tabSelectionIndex(k) == nil { model.toggleTab(k) }
        }
    }

    func appMarqueeFinished(_ apps: [AppEntry]) {
        lastPointerAction = CACurrentMediaTime()
        guard model.phase == .selecting else { return }
        if model.closeOnClick {
            for a in apps where model.appStatuses[a.id] == nil { appClicked(a) }
        } else {
            for a in apps where model.appSelectionIndex(a.id) == nil { model.toggleApp(a) }
        }
    }

    private func processTab(_ k: TabKey) async -> PauseDecision {
        guard let g = model.group(k) else { return .proceed }
        let title = model.tab(k)?.title ?? ""
        tabCloser.allowedPIDs = allowedPIDs
        let exec = tabCloser
        model.tabStatuses[k] = .working
        let t0 = CACurrentMediaTime()
        let outcome = await Task.detached(priority: .userInitiated) { exec.attempt(k) }.value
        model.tabStatuses[k] = outcome.status
        ActionLog.append(app: g.appName, status: outcome.status, note: "关闭标签页 耗时 \(Int((CACurrentMediaTime() - t0) * 1000))ms")
        if case .closed(let windowClosed) = outcome { tabDidClose(k, windowClosed: windowClosed) }
        guard case .needsUser(let ctx) = outcome else { return .proceed }
        let decision = await pause(
            pid: k.pid, isApp: false,
            message: "“\(g.appName)”的标签页“\(title.isEmpty ? "无标题" : title)”弹出了确认框（例如“离开此网站？”）。",
            raise: nil,
            check: { exec.checkPending(ctx) },
            apply: { [weak self] st in
                guard let self else { return }
                switch st {
                case .closed:
                    self.model.tabStatuses[k] = .closed("你确认后，标签页已关闭")
                    self.tabDidClose(k, windowClosed: false)
                case .keptOpen: self.model.tabStatuses[k] = .skipped("你取消了关闭，标签页保留")
                case .stillWaiting: self.model.tabStatuses[k] = TabOutcome.needsUser(ctx).status
                }
            })
        return decision
    }

    /// 标签页关闭后：如果整个窗口随之关闭，同组标签页和对应的窗口卡片一起淡出；否则记下要刷新缩略图
    private func tabDidClose(_ k: TabKey, windowClosed: Bool) {
        guard let g = model.group(k) else { return }
        if windowClosed {
            for t in g.tabs where model.tabStatuses[g.key(t)] == nil || model.tabStatuses[g.key(t)] == .queued {
                model.tabStatuses[g.key(t)] = .closed("窗口已关闭")
            }
            clickQueue.removeAll { if case .tab(let q) = $0 { return q.pid == g.pid && q.windowID == g.windowID }; return false }
            if let card = g.cardID, model.statuses[card] == nil {
                model.statuses[card] = .closed("最后一个标签页关闭后，窗口随之关闭")
            }
        } else if let card = g.cardID {
            cardsNeedingRefresh.insert(card)
        }
    }

    /// 重新截取指定卡片的缩略图（关过标签页后，窗口画面和标题会变）
    private func refreshCards(_ ids: Set<CGWindowID>) {
        let live = ids.filter { model.entry($0) != nil && !model.vanished.contains($0) }
        guard !live.isEmpty, model.screenRecording else { return }
        let maxPx = thumbnailPixelSize(count: model.entries.count)
        Task { [weak self] in
            _ = try? await ThumbnailLoader.load(ids: Array(live), maxPixelSize: maxPx) { id, image in
                if let image { self?.model.thumbnails[id] = image }
            }
        }
    }

    /// 关闭一个窗口：核对 → 按关闭按钮 → 观察；出现确认框则暂停等用户决定。
    private func processWindow(_ e: WindowEntry) async -> PauseDecision {
        executor.allowedPIDs = allowedPIDs
        let exec = executor
        model.statuses[e.id] = .working
        let target = e.target
        let t0 = CACurrentMediaTime()
        let outcome = await Task.detached(priority: .userInitiated) { exec.attempt(target) }.value
        model.statuses[e.id] = outcome.status
        model.refreshAppWindowCounts()
        ActionLog.append(app: e.appName, status: outcome.status, note: "耗时 \(Int((CACurrentMediaTime() - t0) * 1000))ms")
        guard case .needsUser(let ctx) = outcome else { return .proceed }
        let title = e.title.isEmpty ? "无标题" : e.title
        let decision = await pause(
            pid: e.pid, isApp: false,
            message: "“\(e.appName)”的窗口“\(title)”弹出了确认框（例如“是否保存更改”）。",
            raise: { [backend] in backend.raise(ctx.windowRef) },
            check: { exec.checkPending(ctx) },
            apply: { [weak self] st in
                guard let self else { return }
                switch st {
                case .closed: self.model.statuses[e.id] = .closed(ClosedNote.afterUserChoice.text)
                case .keptOpen: self.model.statuses[e.id] = .skipped(SkipReason.userKeptOpen.text)
                case .stillWaiting: self.model.statuses[e.id] = CloseOutcome.needsUser(ctx).status
                }
            })
        model.refreshAppWindowCounts()
        ActionLog.append(app: e.appName, status: model.statuses[e.id] ?? .queued, note: "暂停结束")
        return decision
    }

    /// 退出一个应用（等同 ⌘Q）：应用可以询问是否保存或拒绝；绝不强制退出。
    private func processApp(_ a: AppEntry) async -> PauseDecision {
        if NSRunningApplication(processIdentifier: a.id) == nil {
            model.appStatuses[a.id] = .closed("应用已经退出了")
            appDidQuit(a)
            return .proceed
        }
        quitExecutor.allowedPIDs = allowedPIDs
        let exec = quitExecutor
        model.appStatuses[a.id] = .working
        let target = a.target
        let t0 = CACurrentMediaTime()
        let outcome = await Task.detached(priority: .userInitiated) { exec.attempt(target) }.value
        model.appStatuses[a.id] = outcome.status
        if case .quit = outcome { appDidQuit(a) }
        ActionLog.append(app: a.name, status: outcome.status, note: "退出应用 耗时 \(Int((CACurrentMediaTime() - t0) * 1000))ms")
        guard case .needsUser(let ctx) = outcome else { return .proceed }
        let decision = await pause(
            pid: a.id, isApp: true,
            message: "“\(a.name)”在退出前弹出了确认框（例如“是否保存更改”）。",
            raise: nil,
            check: { exec.checkPending(ctx) },
            apply: { [weak self] st in
                guard let self else { return }
                switch st {
                case .closed:
                    self.model.appStatuses[a.id] = .closed("你确认后，应用已退出")
                    self.appDidQuit(a)
                case .keptOpen: self.model.appStatuses[a.id] = .skipped("你取消了退出，应用继续运行")
                case .stillWaiting: self.model.appStatuses[a.id] = QuitOutcome.needsUser(ctx).status
                }
            })
        ActionLog.append(app: a.name, status: model.appStatuses[a.id] ?? .queued, note: "退出应用 暂停结束")
        return decision
    }

    /// 应用退出后：它在上方的窗口卡片也随之淡出；排队中的这些窗口不再处理
    private func appDidQuit(_ a: AppEntry) {
        for e in model.entries where e.pid == a.id {
            if let st = model.statuses[e.id], st.isFinal { continue }
            model.statuses[e.id] = .closed("随“\(a.name)”退出而关闭")
        }
        clickQueue.removeAll { if case .window(let id) = $0 { return model.entry(id)?.pid == a.id }; return false }
        model.refreshAppWindowCounts()
    }

    /// 稍后在后台复查（不阻塞界面）：判为失败或等待的窗口后来是否关闭了；关掉的是唯一窗口时应用是否自行退出了；
    /// 退出失败或等待中的应用后来是否退出了。
    private func scheduleRecheck(_ entries: [WindowEntry]) {
        let exec = executor
        Task { [weak self] in
            for delay in [0.8, 1.5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                for e in entries {
                    guard let st = self.model.statuses[e.id] else { continue }
                    switch st {
                    case .failed, .waitingUser:
                        if exec.isGoneNow(e.id) {
                            self.model.statuses[e.id] = .closed(st.category == "等待你处理" ? ClosedNote.afterUserChoice.text : ClosedNote.late.text)
                        }
                    case .closed(let d):
                        if !d.contains("自行退出"), !d.contains("退出而关闭"), NSRunningApplication(processIdentifier: e.pid) == nil {
                            self.model.statuses[e.id] = .closed(d + "；随后“\(e.appName)”自行退出了（这是该应用关闭最后一个窗口时的默认行为）")
                            // 应用栏里的图标也随之淡出
                            if self.model.app(e.pid) != nil, self.model.appStatuses[e.pid] == nil {
                                self.model.appStatuses[e.pid] = .closed("关闭最后一个窗口后，应用自行退出了")
                            }
                        }
                    default: break
                    }
                }
                for a in self.model.apps {
                    guard let st = self.model.appStatuses[a.id] else { continue }
                    switch st {
                    case .failed, .waitingUser:
                        if NSRunningApplication(processIdentifier: a.id) == nil {
                            self.model.appStatuses[a.id] = .closed("应用稍后已退出")
                            self.appDidQuit(a)
                        }
                    default: break
                    }
                }
                self.model.refreshAppWindowCounts()
            }
        }
    }

    // MARK: 单击即关闭 / 单击即退出

    private enum ActionKind { case window, app, tab }
    private var lastActionKind: ActionKind = .window
    private var clickQueue: [QueueItem] = []
    private var workerRunning = false
    private var dismissWhenIdle = false
    private var processedInSession: [WindowEntry] = []
    lazy var quitExecutor = QuitExecutor(backend: backend)

    var isWorking: Bool { workerRunning }

    /// 用户单击了一张窗口卡片
    func cardClicked(_ e: WindowEntry) {
        lastPointerAction = CACurrentMediaTime()
        guard model.phase == .selecting else { return }
        guard model.closeOnClick else {
            model.toggle(e)
            return
        }
        if model.statuses[e.id] != nil {
            cancelIfQueued(.window(e.id))
            return
        }
        guard e.isClosable else {
            NSSound.beep()
            return
        }
        lastActionKind = .window
        enqueue(.window(e.id))
    }

    /// 用户单击了下方应用栏里的一个应用
    func appClicked(_ a: AppEntry) {
        lastPointerAction = CACurrentMediaTime()
        guard model.phase == .selecting else { return }
        guard model.closeOnClick else {
            model.toggleApp(a)
            return
        }
        if model.appStatuses[a.id] != nil {
            cancelIfQueued(.app(a.id))
            return
        }
        lastActionKind = .app
        enqueue(.app(a.id))
    }

    private func enqueue(_ item: QueueItem) {
        setStatus(item, .queued)
        clickQueue.append(item)
        model.activeCount = clickQueue.count + (workerRunning ? 1 : 0)
        guard !workerRunning else { return }
        workerRunning = true
        Task { await runClickWorker() }
    }

    /// 还在排队、尚未开始的，再点一次就取消
    private func cancelIfQueued(_ item: QueueItem) {
        guard status(item) == .queued, let i = clickQueue.firstIndex(of: item) else { return }
        clickQueue.remove(at: i)
        setStatus(item, nil)
        model.activeCount = clickQueue.count + (workerRunning ? 1 : 0)
    }

    private var compactionTask: Task<Void, Never>?
    private var lastPointerAction = CACurrentMediaTime()

    /// 已关闭的卡片/已退出的应用先在原位淡出；等你停手约 1 秒（没有新的点击、没在圈选、鼠标没按着）再让其余补位
    func scheduleCompaction() {
        compactionTask?.cancel()
        compactionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                let idle = CACurrentMediaTime() - self.lastPointerAction > 1.0
                if idle && !self.model.marqueeActive && NSEvent.pressedMouseButtons == 0 && self.model.phase != .paused {
                    self.model.compactVanished()
                    return
                }
            }
        }
    }

    /// 圈选结束（只作用于上方窗口卡片）：单击即关闭模式下按顺序排队关闭；先选再关模式下加入选择
    func marqueeFinished(_ entries: [WindowEntry]) {
        lastPointerAction = CACurrentMediaTime()
        guard model.phase == .selecting else { return }
        if model.closeOnClick {
            for e in entries where model.statuses[e.id] == nil && e.isClosable { cardClicked(e) }
        } else {
            for e in entries where model.selectionIndex(e.id) == nil { model.toggle(e) }
        }
    }

    // MARK: 自检用：向总览窗口发送真实的鼠标事件，走与用户操作相同的路径

    var overlayContentSize: CGSize { overlay?.contentView?.bounds.size ?? .zero }

    /// 卡片在总览窗口中的位置（窗口内容坐标，左上角为原点）
    func cardWindowFrame(_ id: CGWindowID) -> CGRect? { model.cardFrames[id]?.window }
    func appWindowFrame(_ pid: pid_t) -> CGRect? { model.appFrames[pid]?.window }
    func tabWindowFrame(_ k: TabKey) -> CGRect? { model.tabFrames[k]?.window }

    func simulateClick(at p: CGPoint) async {
        await postMouse(.leftMouseDown, p)
        try? await Task.sleep(nanoseconds: 60_000_000)
        await postMouse(.leftMouseUp, p)
    }

    func simulateDrag(from a: CGPoint, to b: CGPoint, steps: Int = 12) async {
        await postMouse(.leftMouseDown, a)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            await postMouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        await postMouse(.leftMouseUp, b)
    }

    private func postMouse(_ type: NSEvent.EventType, _ p: CGPoint) async {
        guard let overlay, let content = overlay.contentView else { return }
        let loc = NSPoint(x: p.x, y: content.bounds.height - p.y)
        if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                      pressure: type == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
    }

    private func runClickWorker() async {
        while !clickQueue.isEmpty {
            let item = clickQueue.removeFirst()
            model.activeCount = clickQueue.count + 1
            model.remainingCount = clickQueue.count
            let decision = await process(item)
            if decision == .stop {
                for q in clickQueue { setStatus(q, .skipped(SkipReason.stoppedByUser.text)) }
                clickQueue.removeAll()
            }
        }
        workerRunning = false
        model.activeCount = 0
        scheduleRecheck(processedInSession)
        checkAutoDismiss()
        processedInSession = []
        if dismissWhenIdle {
            dismissWhenIdle = false
            dismiss(hideApp: true, animated: true)
        }
    }

    /// 出现需要用户处理的确认框：暂停队列，把原应用带到前面，显示小面板，等用户决定。
    private func pause(pid: pid_t, isApp: Bool, message: String, raise: (() -> Void)?,
                       check: @escaping () -> PendingState, apply: @escaping (PendingState) -> Void) async -> PauseDecision {
        let previousPhase = model.phase
        model.phase = .paused
        model.pauseMessage = message
        model.pauseIsApp = isApp
        model.pendingState = .stillWaiting
        startPendingPolling(check: check, apply: apply)

        let decision: PauseDecision
        if let pauseHandler {
            decision = await pauseHandler()
        } else {
            overlay?.orderOut(nil)
            showPanel(PausePanelView(model: model,
                                     onContinue: { [weak self] in self?.resumePause(.proceed) },
                                     onStop: { [weak self] in self?.resumePause(.stop) }))
            if let app = NSRunningApplication(processIdentifier: pid) {
                NSApp.yieldActivation(to: app)
                app.activate()
            }
            raise?()
            decision = await withCheckedContinuation { self.pauseContinuation = $0 }
        }

        pollTask?.cancel()
        pollTask = nil
        // 最后再确认一次状态
        let final = await Task.detached { check() }.value
        model.pendingState = final
        apply(final)
        closePanel()
        model.pauseMessage = ""
        model.phase = previousPhase
        // 批量模式：还有剩余才回到总览（全部结束时会自动回来）；单击即关闭模式：总是回到总览继续点
        let backToOverview = previousPhase == .selecting || (model.remainingCount > 0 && decision == .proceed)
        if pauseHandler == nil, backToOverview {
            overlay?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return decision
    }

    private func resumePause(_ d: PauseDecision) {
        pauseContinuation?.resume(returning: d)
        pauseContinuation = nil
    }

    private func startPendingPolling(check: @escaping () -> PendingState, apply: @escaping (PendingState) -> Void) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var keptCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let s = await Task.detached { check() }.value
                guard let self, !Task.isCancelled else { return }
                // “取消”需连续两次确认，避免对话框切换（例如点了“存储…”）的瞬间被误判
                if s == .keptOpen { keptCount += 1 } else { keptCount = 0 }
                if s == .keptOpen && keptCount < 2 { continue }
                self.model.pendingState = s
                apply(s)
            }
        }
    }

    // MARK: 浮动面板

    private func showPanel<V: View>(_ view: V) {
        closePanel()
        let p = HelperPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: view)
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let screen = screenWithMouse() {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width - 20, y: vf.maxY - p.frame.height - 20))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    // MARK: 权限

    private func openPermissionSettings(accessibility: Bool) {
        if accessibility {
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
        } else {
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
        }
        // 收起总览，让用户能操作系统设置；留一个小面板显示授权状态
        removeKeyMonitor()
        overlay?.orderOut(nil)
        if model.phase != .needsPermission { model.phase = .needsPermission }
        showPanel(PermissionWaitPanelView(model: model, onBack: { [weak self] in
            guard let self else { return }
            self.closePanel()
            self.show(reason: "授权后返回")
        }))
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.model.axTrusted = Permissions.accessibility
                self.model.screenRecording = Permissions.screenRecording
                if self.model.axTrusted && self.isOverlayVisible && self.model.phase == .needsPermission {
                    self.reload(reason: "授权完成", t0: CACurrentMediaTime())
                }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    /// 重新打开本应用（屏幕录制授权通常需要重启应用才生效）。只针对本应用自己。
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// 关闭结果日志：只记录应用名和结果，不记录窗口标题。
enum ActionLog {
    static func append(app: String, status: ItemStatus, note: String = "") {
        TimingLog.append("close app=\(app) result=\(status.category)\(status.detail.isEmpty ? "" : "（\(status.detail)）") \(note)")
    }
}
