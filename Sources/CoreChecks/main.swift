// 逻辑检查：用模拟的窗口系统验证配对规则和关闭流程。不需要任何系统权限。
// 运行：scripts/build.sh checks
import Foundation
import CoreGraphics

final class MockAXWindow {
    var info: AXWindowInfo
    var cgID: CGWindowID
    var alive = true
    init(_ info: AXWindowInfo, cgID: CGWindowID) {
        self.info = info
        self.cgID = cgID
    }
}

final class MockBackend: WindowBackend {
    var windows: [CGWindowID: CGWindowInfo] = [:]
    var ax: [pid_t: [MockAXWindow]] = [:]
    var running: Set<pid_t> = []
    var trusted = true
    var unresponsive: Set<pid_t> = []
    var clock: Double = 0
    var pressed: [CGWindowID] = []
    var timeline: [(Double, () -> Void)] = []
    /// 按下关闭按钮时发生什么；默认：窗口立即销毁
    var onPress: ((MockAXWindow) -> AXActionResult)?

    func add(_ id: CGWindowID, pid: pid_t, title: String?, frame: CGRect, axTitle: String? = nil, layer: Int = 0,
             ax axInfo: AXWindowInfo? = nil, noAX: Bool = false) {
        windows[id] = CGWindowInfo(windowID: id, pid: pid, ownerName: "App\(pid)", title: title, bounds: frame, layer: layer)
        running.insert(pid)
        if !noAX {
            let info = axInfo ?? AXWindowInfo(title: axTitle ?? title, frame: frame)
            ax[pid, default: []].append(MockAXWindow(info, cgID: id))
        }
    }

    func remove(_ id: CGWindowID) {
        guard let w = windows.removeValue(forKey: id) else { return }
        for a in ax[w.pid] ?? [] where a.cgID == id { a.alive = false }
        ax[w.pid]?.removeAll { $0.cgID == id }
    }

    func onScreenWindows() -> [CGWindowInfo] { windows.values.filter(\.isOnScreen).sorted { $0.windowID < $1.windowID } }
    func allWindows() -> [CGWindowInfo] { windows.values.sorted { $0.windowID < $1.windowID } }
    func windowInfo(_ id: CGWindowID) -> CGWindowInfo? { windows[id] }
    func isAppRunning(_ pid: pid_t) -> Bool { running.contains(pid) }
    var hiddenPIDs: Set<pid_t> = []
    func isAppHidden(_ pid: pid_t) -> Bool { hiddenPIDs.contains(pid) }

    var quitRequests: [pid_t] = []
    /// 收到退出请求时发生什么；默认：应用立即退出
    var onTerminate: ((pid_t) -> Bool)?
    func terminateApp(_ pid: pid_t) -> Bool {
        quitRequests.append(pid)
        if let onTerminate { return onTerminate(pid) }
        running.remove(pid)
        for id in windows.values.filter({ $0.pid == pid }).map(\.windowID) { remove(id) }
        return true
    }

    var dialogReads = 0
    var fullAXReads = 0
    var onDialogRead: ((pid_t, Float) -> Result<Bool, AXAccessError>)?
    func appHasDialog(pid: pid_t, timeout: Float) -> Result<Bool, AXAccessError> {
        dialogReads += 1
        if let onDialogRead { return onDialogRead(pid, timeout) }
        if !trusted { return .failure(.notTrusted) }
        if unresponsive.contains(pid) { return .failure(.appUnresponsive) }
        return .success((ax[pid] ?? []).contains { $0.info.hasSheet })
    }

    func axWindows(pid: pid_t, timeout: Float, includeSheetCheck: Bool) -> Result<[AXWindowRef], AXAccessError> {
        fullAXReads += 1
        if !trusted { return .failure(.notTrusted) }
        if unresponsive.contains(pid) { return .failure(.appUnresponsive) }
        return .success((ax[pid] ?? []).map { AXWindowRef(info: $0.info, handle: $0) })
    }

    func pressCloseButton(of ref: AXWindowRef, timeout: Float) -> AXActionResult {
        let w = ref.handle as! MockAXWindow
        pressed.append(w.cgID)
        if let onPress { return onPress(w) }
        remove(w.cgID)
        return .success
    }

    func refreshAXInfo(_ ref: AXWindowRef, timeout: Float) -> AXWindowInfo? {
        let w = ref.handle as! MockAXWindow
        return w.alive ? w.info : nil
    }

    var goneChecks = 0
    func axWindowIsGone(_ ref: AXWindowRef, timeout: Float) -> Bool {
        goneChecks += 1
        return !(ref.handle as! MockAXWindow).alive
    }

    func sleep(_ seconds: Double) {
        clock += seconds
        let due = timeline.filter { $0.0 <= clock }
        timeline.removeAll { $0.0 <= clock }
        for (_, f) in due { f() }
    }

    func now() -> TimeInterval { clock }
}

var passed = 0
var failed = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name) \(detail())")
    }
}

func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 400, _ h: CGFloat = 300) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

func executor(_ b: MockBackend) -> CloseExecutor {
    let e = CloseExecutor(backend: b)
    return e
}

func outcomeName(_ o: CloseOutcome) -> String { "\(o.status.category)：\(o.status.detail)" }

@main
enum CoreChecks {
    static func main() {
        print("配对规则")
        do {
            let t = CGWindowInfo(windowID: 1, pid: 10, ownerName: "A", title: "文档", bounds: r(100, 100))
            check("位置尺寸一致且唯一 → 唯一配对",
                  WindowMatcher.match(target: t, peers: [t], axWindows: [AXWindowInfo(title: "文档", frame: r(100, 100))]) == .unique(axIndex: 0, usedTitle: false))
            check("误差 0.5 点仍可配对",
                  WindowMatcher.match(target: t, peers: [t], axWindows: [AXWindowInfo(title: "x", frame: r(100.5, 99.5))]) == .unique(axIndex: 0, usedTitle: false))
            check("偏差 3 点 → 找不到（不放宽）",
                  WindowMatcher.match(target: t, peers: [t], axWindows: [AXWindowInfo(title: "文档", frame: r(103, 100))]) == .notFound)
            let scaled = CGWindowInfo(windowID: 1, pid: 10, ownerName: "A", title: "文档", bounds: CGRect(x: 105, y: 103, width: 392, height: 294))
            check("打开动画中的 98% 缩放边界 → 找不到（宁可不配对）",
                  WindowMatcher.match(target: scaled, peers: [scaled], axWindows: [AXWindowInfo(title: "文档", frame: r(100, 100))]) == .notFound)

            let p2 = CGWindowInfo(windowID: 2, pid: 10, ownerName: "A", title: "另一个", bounds: r(100, 100))
            let axs = [AXWindowInfo(title: "另一个", frame: r(100, 100)), AXWindowInfo(title: "文档", frame: r(100, 100))]
            check("两个窗口完全重叠但标题不同 → 借助标题唯一配对到正确的那个",
                  WindowMatcher.match(target: t, peers: [t, p2], axWindows: axs) == .unique(axIndex: 1, usedTitle: true))
            let p2same = CGWindowInfo(windowID: 2, pid: 10, ownerName: "A", title: "文档", bounds: r(100, 100))
            let axSame = [AXWindowInfo(title: "文档", frame: r(100, 100)), AXWindowInfo(title: "文档", frame: r(100, 100))]
            if case .ambiguous = WindowMatcher.match(target: t, peers: [t, p2same], axWindows: axSame) { check("完全重叠且同名 → 无法唯一确认", true) } else { check("完全重叠且同名 → 无法唯一确认", false) }
            let tNoTitle = CGWindowInfo(windowID: 1, pid: 10, ownerName: "A", title: nil, bounds: r(100, 100))
            let p2NoTitle = CGWindowInfo(windowID: 2, pid: 10, ownerName: "A", title: nil, bounds: r(100, 100))
            if case .ambiguous = WindowMatcher.match(target: tNoTitle, peers: [tNoTitle, p2NoTitle], axWindows: axs) { check("重叠且读不到标题（无屏幕录制）→ 无法唯一确认", true) } else { check("重叠且读不到标题 → 无法唯一确认", false) }
            let axMin = [AXWindowInfo(title: "文档", frame: r(100, 100), isMinimized: true), AXWindowInfo(title: "文档", frame: r(100, 100))]
            check("同位置的最小化窗口不参与配对",
                  WindowMatcher.match(target: t, peers: [t], axWindows: axMin) == .unique(axIndex: 1, usedTitle: false))
            if case .ambiguous = WindowMatcher.match(target: t, peers: [t, p2NoTitle], axWindows: [AXWindowInfo(title: "文档", frame: r(100, 100))]) {
                check("辅助功能只列出一个，但屏幕上有两个同位置窗口且其中一个无标题 → 无法唯一确认", true)
            } else { check("屏幕上有两个同位置窗口且其中一个无标题 → 无法唯一确认", false) }
            let otherPID = CGWindowInfo(windowID: 3, pid: 11, ownerName: "B", title: "文档", bounds: r(100, 100))
            check("其他应用的同位置同名窗口不影响配对",
                  WindowMatcher.match(target: t, peers: [t, otherPID], axWindows: [AXWindowInfo(title: "文档", frame: r(100, 100))]) == .unique(axIndex: 0, usedTitle: false))
        }

        print("关闭流程")
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            b.add(2, pid: 10, title: "A2", frame: r(50, 50))
            b.add(3, pid: 11, title: "B1", frame: r(0, 0))
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .closed(.destroyed) = o { check("正常关闭 → 已关闭", true) } else { check("正常关闭 → 已关闭", false, outcomeName(o)) }
            check("只按了目标窗口的关闭按钮", b.pressed == [1], "\(b.pressed)")
            check("同应用的其他窗口和其他应用的窗口都还在", b.windows[2] != nil && b.windows[3] != nil)
        }
        do {
            let b = MockBackend()
            b.add(2, pid: 10, title: "A2", frame: r(50, 50))
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .skipped(.windowGone) = o { check("执行前窗口已消失 → 已跳过，不按任何按钮", b.pressed.isEmpty) } else { check("窗口已消失 → 已跳过", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(5, pid: 10, title: "旧", frame: r(0, 0))
            b.remove(5)
            b.add(6, pid: 10, title: "旧", frame: r(0, 0)) // 原位置出现同名新窗口（新编号）
            let o = executor(b).attempt(CloseTarget(windowID: 5, pid: 10, appName: "A", title: "旧"))
            if case .skipped(.windowGone) = o { check("窗口被同名同位置的新窗口替换 → 跳过，不碰新窗口", b.pressed.isEmpty && b.windows[6] != nil) } else { check("窗口被替换 → 跳过", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 99, title: "别的应用", frame: r(0, 0))
            b.running.insert(10)
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .skipped(.ownerChanged) = o { check("窗口编号归属变了 → 跳过", b.pressed.isEmpty) } else { check("归属变化 → 跳过", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            b.unresponsive.insert(10)
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .skipped(.appUnresponsive) = o { check("应用无响应 → 跳过，不发送关闭请求", b.pressed.isEmpty) } else { check("应用无响应 → 跳过", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            b.trusted = false
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .failed(.notTrusted) = o { check("没有辅助功能权限 → 关闭失败（不假报成功）", b.pressed.isEmpty) } else { check("无权限 → 失败", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "同名", frame: r(0, 0))
            b.add(2, pid: 10, title: "同名", frame: r(0, 0))
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "同名"))
            if case .skipped(.notUniquelyIdentified) = o { check("同名且重叠 → 跳过，一个都不按", b.pressed.isEmpty) } else { check("同名重叠 → 跳过", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "同名", frame: r(0, 0))
            b.add(2, pid: 10, title: "同名", frame: r(300, 0))
            let o = executor(b).attempt(CloseTarget(windowID: 2, pid: 10, appName: "A", title: "同名"))
            if case .closed = o { check("同名不同位置 → 只关闭选中的那个", b.pressed == [2] && b.windows[1] != nil) } else { check("同名不同位置", false, outcomeName(o)) }
        }
        do {
            // 用户在总览打开后移动了窗口：重新配对使用最新位置
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            b.windows[1]!.bounds = r(200, 200)
            b.ax[10]![0].info.frame = r(200, 200)
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .closed = o { check("总览打开后窗口被移动 → 按最新位置重新核对后关闭", b.pressed == [1]) } else { check("窗口被移动", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0), ax: AXWindowInfo(title: "A1", frame: r(0, 0), closeButtonEnabled: false))
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .skipped(.closeButtonDisabled) = o { check("关闭按钮不可用 → 跳过", b.pressed.isEmpty) } else { check("按钮不可用", false, outcomeName(o)) }
            let b2 = MockBackend()
            b2.add(1, pid: 10, title: "A1", frame: r(0, 0), ax: AXWindowInfo(title: "A1", frame: r(0, 0), hasCloseButton: false))
            let o2 = executor(b2).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .skipped(.noCloseButton) = o2 { check("没有关闭按钮 → 跳过", b2.pressed.isEmpty) } else { check("无关闭按钮", false, outcomeName(o2)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            let e = executor(b)
            e.allowedPIDs = [99]
            let o = e.attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            if case .skipped(.notAllowed) = o { check("自检白名单外的窗口 → 不处理", b.pressed.isEmpty) } else { check("白名单", false, outcomeName(o)) }
        }

        print("关闭后的观察")
        do {
            // 弹出表单（新窗口）
            let b = MockBackend()
            b.add(1, pid: 10, title: "未保存", frame: r(0, 0))
            b.onPress = { _ in
                b.windows[50] = CGWindowInfo(windowID: 50, pid: 10, ownerName: "A", title: "", bounds: r(20, 30, 360, 160))
                return .success
            }
            let e = executor(b)
            let o = e.attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "未保存"))
            guard case .needsUser(let ctx) = o else { check("弹出确认框 → 等待你处理", false, outcomeName(o)); return }
            check("弹出确认框 → 等待你处理（不自动点任何按钮）", ctx.kind == .dialogWindow && b.windows[1] != nil)
            check("确认框仍在 → 继续等待", e.checkPending(ctx) == .stillWaiting)
            b.windows[50] = nil
            check("用户点“取消”，确认框消失、窗口仍在 → 判为保留", e.checkPending(ctx) == .keptOpen)
            b.remove(1)
            check("用户点“不保存”，窗口消失 → 判为已关闭", e.checkPending(ctx) == .closed)
        }
        do {
            // 辅助功能报告表单（没有新窗口）
            let b = MockBackend()
            b.add(1, pid: 10, title: "未保存", frame: r(0, 0))
            b.onPress = { w in w.info.hasSheet = true; return .success }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "未保存"))
            if case .needsUser(let ctx) = o { check("窗口挂上表单 → 等待你处理", ctx.kind == .sheet) } else { check("表单", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "拒绝", frame: r(0, 0))
            b.onPress = { _ in .success }
            let e = executor(b)
            let o = e.attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "拒绝"))
            if case .failed(.stillOpen) = o { check("请求发送成功但窗口没关 → 关闭失败（不报成功）", b.clock >= e.observeTimeout) } else { check("请求成功≠关闭", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "卡住", frame: r(0, 0))
            b.onPress = { _ in .timedOut }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "卡住"))
            if case .failed(.unresponsiveAfterPress) = o { check("按下时应用卡住且窗口仍在 → 关闭失败（应用无响应）", true) } else { check("按下时卡住", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "慢", frame: r(0, 0))
            b.onPress = { _ in
                b.timeline.append((b.clock + 1.0, { b.remove(1) }))
                return .success
            }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "慢"))
            if case .closed(.destroyed) = o { check("应用 1 秒后才关闭 → 等到真正消失后标为已关闭", b.clock >= 1.0) } else { check("慢关闭", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "收起", frame: r(0, 0))
            b.onPress = { _ in b.windows[1]!.isOnScreen = false; return .success }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "收起"))
            if case .closed(.removedFromScreen) = o { check("应用关闭时只把窗口收起（窗口对象保留）→ 已关闭，并注明", true) } else { check("收起", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "最后", frame: r(0, 0))
            b.onPress = { _ in .timedOut }
            b.timeline.append((2.5, { b.remove(1) }))
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "最后"))
            if case .closed = o { check("请求超时但窗口随后消失 → 已关闭（以观察结果为准）", true) } else { check("超时后关闭", false, outcomeName(o)) }
        }

        print("关窗淡出期间提前确认")
        do {
            // 模拟系统关窗动画：应用立刻销毁窗口对象，窗口记录淡出 0.3 秒后才被系统删除
            let b = MockBackend()
            b.add(1, pid: 10, title: "淡出", frame: r(0, 0))
            b.add(2, pid: 10, title: "其他", frame: r(500, 0))
            b.onPress = { w in
                w.alive = false
                b.windows[1]!.alpha = 0.6
                b.timeline.append((b.clock + 0.3, { b.remove(1) }))
                return .success
            }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "淡出"))
            if case .closed(.destroyed) = o {
                check("淡出已开始且应用报告窗口不存在 → 立即确认关闭，不等 0.3 秒动画", b.clock < 0.05, "clock=\(b.clock)")
            } else { check("淡出提前确认", false, outcomeName(o)) }
            check("提前确认时只按了目标窗口", b.pressed == [1] && b.windows[2] != nil)
        }
        do {
            // 应用自己把窗口变透明，但窗口对象仍然有效 → 不能提前判定
            let b = MockBackend()
            b.add(1, pid: 10, title: "半透明", frame: r(0, 0))
            b.onPress = { _ in b.windows[1]!.alpha = 0.5; return .success }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "半透明"))
            if case .failed(.stillOpen) = o { check("窗口变透明但应用仍有这个窗口 → 不提前判定（关闭失败）", true) } else { check("透明但仍在", false, outcomeName(o)) }
        }
        do {
            // 窗口对象无效，但没有关窗淡出 → 仍等系统删除窗口记录
            let b = MockBackend()
            b.add(1, pid: 10, title: "无淡出", frame: r(0, 0))
            b.onPress = { w in
                w.alive = false
                b.timeline.append((b.clock + 0.3, { b.remove(1) }))
                return .success
            }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "无淡出"))
            if case .closed(.destroyed) = o { check("没有关窗淡出时不提前判定，等窗口真正消失", b.clock >= 0.3) } else { check("无淡出", false, outcomeName(o)) }
        }
        do {
            // 淡出期间出现了新的确认窗口 → 暂停交给用户，不判成功
            let b = MockBackend()
            b.add(1, pid: 10, title: "带确认", frame: r(0, 0))
            b.onPress = { w in
                w.alive = false
                b.windows[1]!.alpha = 0.6
                b.windows[9] = CGWindowInfo(windowID: 9, pid: 10, ownerName: "App10", title: "是否保存", bounds: r(100, 100, 260, 120))
                return .success
            }
            let o = executor(b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "带确认"))
            if case .needsUser = o { check("淡出时出现新确认窗口 → 等待你处理，不判为已关闭", true) } else { check("淡出+确认窗口", false, outcomeName(o)) }
        }

        print("退出应用")
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            b.add(2, pid: 11, title: "B1", frame: r(0, 0))
            let o = QuitExecutor(backend: b).attempt(QuitTarget(pid: 10, appName: "A"))
            if case .quit = o { check("正常退出 → 已退出，只向目标应用发了退出请求", b.quitRequests == [10] && b.running.contains(11)) } else { check("正常退出", false, "\(o.status)") }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "未保存", frame: r(0, 0))
            b.onTerminate = { _ in
                b.windows[60] = CGWindowInfo(windowID: 60, pid: 10, ownerName: "A", title: "", bounds: r(20, 30, 360, 160))
                return true
            }
            let e = QuitExecutor(backend: b)
            let o = e.attempt(QuitTarget(pid: 10, appName: "A"))
            guard case .needsUser(let ctx) = o else { check("退出前弹出确认框 → 等待你处理", false, "\(o.status)"); return }
            check("退出前弹出确认框 → 等待你处理（不替你点按钮）", b.running.contains(10))
            check("确认框还在 → 继续等待", e.checkPending(ctx) == .stillWaiting)
            b.windows[60] = nil
            check("你点了“取消”，应用继续运行 → 判为取消退出", e.checkPending(ctx) == .keptOpen)
            b.running.remove(10)
            check("你确认后应用退出 → 判为已退出", e.checkPending(ctx) == .closed)
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "闪一下", frame: r(0, 0))
            b.onTerminate = { _ in
                b.windows[61] = CGWindowInfo(windowID: 61, pid: 10, ownerName: "A", title: "", bounds: r(20, 30, 360, 160))
                b.timeline.append((b.clock + 0.15, { b.windows[61] = nil; b.running.remove(10) }))
                return true
            }
            let o = QuitExecutor(backend: b).attempt(QuitTarget(pid: 10, appName: "A"))
            if case .quit = o { check("退出时一闪而过的窗口不误判为确认框", true) } else { check("一闪而过的窗口", false, "\(o.status)") }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "卡住", frame: r(0, 0))
            b.onTerminate = { _ in true }
            let e = QuitExecutor(backend: b)
            let o = e.attempt(QuitTarget(pid: 10, appName: "A"))
            if case .failed = o { check("应用一直不退出 → 未退出（不强制退出、不报成功）", b.running.contains(10) && b.clock >= e.timeout) } else { check("不退出", false, "\(o.status)") }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            let e = QuitExecutor(backend: b)
            e.allowedPIDs = [99]
            let o = e.attempt(QuitTarget(pid: 10, appName: "A"))
            if case .skipped = o { check("自检白名单外的应用 → 不发退出请求", b.quitRequests.isEmpty) } else { check("白名单", false, "\(o.status)") }
            let o2 = QuitExecutor(backend: b).attempt(QuitTarget(pid: 77, appName: "已退出"))
            if case .skipped = o2 { check("应用已经不在运行 → 跳过", b.quitRequests.isEmpty) } else { check("已不在运行", false, "\(o2.status)") }
        }
        do {
            // 关闭窗口的流程里绝不会发出退出请求
            let b = MockBackend()
            b.add(1, pid: 10, title: "A1", frame: r(0, 0))
            b.onPress = { _ in .success }
            _ = CloseExecutor(backend: b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "A1"))
            check("关闭窗口（即使关不掉）也不会退出应用", b.quitRequests.isEmpty)
        }

        print("退出应用耗时回归")
        do {
            let b = MockBackend()
            b.running.insert(10)
            b.onTerminate = { pid in
                b.timeline.append((b.clock + 0.08, { b.running.remove(pid) }))
                return true
            }
            let e = QuitExecutor(backend: b)
            let o = e.attempt(QuitTarget(pid: 10, appName: "快速退出"))
            if case .quit = o {
                check("快速退出：100 毫秒内发现结束，不做辅助功能读取", b.clock <= 0.101 && b.dialogReads == 0 && b.fullAXReads == 0)
            } else { check("快速退出", false, "\(o.status)") }
        }
        do {
            let b = MockBackend()
            b.running.insert(10)
            b.onTerminate = { pid in
                b.timeline.append((b.clock + 0.65, { b.running.remove(pid) }))
                return true
            }
            b.onDialogRead = { _, budget in
                b.sleep(Double(budget))
                return .failure(.appUnresponsive)
            }
            let e = QuitExecutor(backend: b)
            let o = e.attempt(QuitTarget(pid: 10, appName: "检查中退出"))
            if case .quit = o {
                check("弹窗检查期间进程结束：检查返回后立即认定退出，不额外等待", b.clock <= 0.771 && b.fullAXReads == 0)
                check("日志记录弹窗检查实际开销", e.lastTiming.dialogChecks > 0 && e.lastTiming.dialogTime > 0)
            } else { check("检查中退出", false, "\(o.status)") }
        }
        do {
            let b = MockBackend()
            b.running.insert(10)
            b.onTerminate = { _ in true }
            b.onDialogRead = { _, budget in
                b.sleep(Double(budget))
                return .failure(.appUnresponsive)
            }
            let e = QuitExecutor(backend: b)
            let o = e.attempt(QuitTarget(pid: 10, appName: "无响应"))
            if case .failed = o {
                check("持续无响应：辅助功能超时不会叠加成多秒额外等待", b.clock <= e.timeout + 0.001 && b.fullAXReads == 0 && b.running.contains(10))
            } else { check("持续无响应", false, "\(o.status)") }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "未保存", frame: r(0, 0))
            b.onTerminate = { _ in b.ax[10]![0].info.hasSheet = true; return true }
            let e = QuitExecutor(backend: b)
            let o = e.attempt(QuitTarget(pid: 10, appName: "保存表单"))
            if case .needsUser(let ctx) = o {
                check("没有新增窗口的保存表单仍能识别并暂停", b.clock < 1 && b.fullAXReads == 0 && e.checkPending(ctx) == .stillWaiting)
                b.ax[10]![0].info.hasSheet = false
                b.unresponsive.insert(10)
                check("暂停中读不到弹窗状态：继续等待，不假报用户取消", e.checkPending(ctx) == .stillWaiting)
                b.unresponsive.remove(10)
                check("用户取消保存后：应用仍在，退出请求只发一次", e.checkPending(ctx) == .keptOpen && b.running.contains(10) && b.quitRequests == [10])
            } else { check("保存表单", false, "\(o.status)") }
        }

        print("浏览器标签页")
        do {
            final class MockTabs: TabsBackend {
                var tabs: [String: [String]] = ["W1": ["t1", "t2", "t3"], "W2": ["t9"]]
                var permitted = true
                var closed: [String] = []
                var onClose: ((TabKey) -> Void)?
                func permission(pid: pid_t, ask: Bool) -> AutomationPermission { permitted ? .granted : .denied }
                func windows(pid: pid_t) -> Result<[BrowserWindowInfo], TabsError> { .success([]) }
                func tabIDs(pid: pid_t, windowID: String) -> Result<[String], TabsError> {
                    guard permitted else { return .failure(.notPermitted) }
                    guard let t = tabs[windowID] else { return .failure(.windowGone) }
                    return .success(t)
                }
                func closeTab(_ key: TabKey) -> Result<Void, TabsError> {
                    closed.append(key.tabID)
                    if let onClose { onClose(key) } else {
                        tabs[key.windowID]?.removeAll { $0 == key.tabID }
                        if tabs[key.windowID]?.isEmpty == true { tabs[key.windowID] = nil }
                    }
                    return .success(())
                }
            }
            let b = MockBackend(); b.running.insert(10)
            let m = MockTabs()
            let c = TabCloser(tabs: m, windows: b)
            let o = c.attempt(TabKey(pid: 10, windowID: "W1", tabID: "t2"))
            if case .closed(let wc) = o { check("按编号关闭标签页 → 只关掉这一个", !wc && m.closed == ["t2"] && m.tabs["W1"] == ["t1", "t3"]) } else { check("关闭标签页", false, "\(o.status)") }
            let o2 = c.attempt(TabKey(pid: 10, windowID: "W1", tabID: "t2"))
            if case .skipped = o2 { check("标签页已经不存在 → 跳过，不发送关闭", m.closed == ["t2"]) } else { check("已不存在", false, "\(o2.status)") }
            let o3 = c.attempt(TabKey(pid: 10, windowID: "W2", tabID: "t9"))
            if case .closed(let wc) = o3 { check("关掉窗口里最后一个标签页 → 标明窗口也随之关闭", wc) } else { check("最后一个标签页", false, "\(o3.status)") }
            let o4 = c.attempt(TabKey(pid: 10, windowID: "W2", tabID: "t9"))
            if case .skipped = o4 { check("所在窗口已经关闭 → 跳过", true) } else { check("窗口已关闭", false, "\(o4.status)") }
            m.permitted = false
            let o5 = c.attempt(TabKey(pid: 10, windowID: "W1", tabID: "t1"))
            if case .failed = o5 { check("没有控制浏览器的权限 → 关闭失败（不假报成功）", !m.closed.contains("t1")) } else { check("无权限", false, "\(o5.status)") }
            m.permitted = true
            m.onClose = { _ in } // 网页拒绝关闭（例如弹出“离开此网站？”但没有新窗口）
            let o6 = c.attempt(TabKey(pid: 10, windowID: "W1", tabID: "t1"))
            if case .failed = o6 { check("发送了关闭但标签页还在 → 关闭失败（不报成功）", m.tabs["W1"]?.contains("t1") == true) } else { check("标签页仍在", false, "\(o6.status)") }
            m.onClose = { _ in b.windows[70] = CGWindowInfo(windowID: 70, pid: 10, ownerName: "Chrome", title: "", bounds: r(100, 100, 400, 200)) }
            let o7 = c.attempt(TabKey(pid: 10, windowID: "W1", tabID: "t3"))
            if case .needsUser(let ctx) = o7 {
                check("网页弹出离开确认 → 等待你处理", true)
                b.windows[70] = nil
                check("你点了“留下” → 判为保留", c.checkPending(ctx) == .keptOpen)
            } else { check("离开确认", false, "\(o7.status)") }
            let c2 = TabCloser(tabs: m, windows: b); c2.allowedPIDs = [99]
            let o8 = c2.attempt(TabKey(pid: 10, windowID: "W1", tabID: "t1"))
            if case .skipped = o8 { check("自检白名单外的浏览器 → 不处理", true) } else { check("白名单", false, "\(o8.status)") }
            // 浏览器窗口与卡片的对应
            let wins = [BrowserWindowInfo(id: "A", title: "x", boundsCandidates: [r(0, 0)], isMinimized: false, tabs: []),
                        BrowserWindowInfo(id: "B", title: "y", boundsCandidates: [r(300, 0)], isMinimized: false, tabs: [])]
            check("浏览器窗口按边界对应到卡片", BrowserTabSupport.matchWindow(cardBounds: r(300, 0), cardTitle: "y", in: wins)?.id == "B")
            let same = [BrowserWindowInfo(id: "A", title: "x", boundsCandidates: [r(0, 0)], isMinimized: false, tabs: []),
                        BrowserWindowInfo(id: "B", title: "x", boundsCandidates: [r(0, 0)], isMinimized: false, tabs: [])]
            check("两个浏览器窗口位置和标题都相同 → 不强行对应", BrowserTabSupport.matchWindow(cardBounds: r(0, 0), cardTitle: "x", in: same) == nil)
            let cases: [(String, String)] = [
                ("https://mail.google.com/mail/u/0/", "google.com"), ("https://translate.google.com", "google.com"),
                ("https://www.bilibili.com/video/x", "bilibili.com"), ("https://github.com/apple/swift", "github.com"),
                ("https://news.sina.com.cn/a.html", "sina.com.cn"), ("https://www.bbc.co.uk/news", "bbc.co.uk"),
                ("chrome://newtab/", BrowserTabSupport.internalPagesName), ("file:///Users/x/a.html", BrowserTabSupport.localFilesName),
                ("http://localhost:3000/", "localhost"), ("http://192.168.1.10/admin", "192.168.1.10"), ("", BrowserTabSupport.otherName),
            ]
            let wrong = cases.filter { BrowserTabSupport.siteName(for: $0.0) != $0.1 }
            check("按网站归类：子域名归到主网站、国家二级域名、内部页面、本地文件、IP", wrong.isEmpty,
                  wrong.map { "\($0.0) → \(BrowserTabSupport.siteName(for: $0.0))" }.joined(separator: "；"))
        }

        print("全部桌面与全屏窗口")
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "当前窗口", frame: r(0, 0))
            b.add(2, pid: 10, title: "其他桌面窗口", frame: r(200, 100))
            b.windows[2]!.isOnScreen = false
            let current = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .currentDesktop)
            let all = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .allDesktops)
            check("当前桌面模式只显示当前窗口，全部桌面模式同时显示其他桌面", current.entries.map(\.id) == [1] && Set(all.entries.map(\.id)) == Set([1, 2]))
            check("跨桌面窗口标明范围，并且关闭目标允许重新核对其他桌面", all.entries.first { $0.id == 2 }?.locationLabel != nil && all.entries.first { $0.id == 2 }?.target.allowOffscreen == true)
            let e = CloseExecutor(backend: b)
            let o = e.attempt(CloseTarget(windowID: 2, pid: 10, appName: "A", title: "其他桌面窗口", allowOffscreen: true))
            if case .closed(.destroyed) = o {
                check("唯一匹配的跨桌面窗口可关闭，同应用未选窗口保持原样", b.pressed == [2] && b.windows[1] != nil)
            } else { check("跨桌面窗口关闭", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "其他桌面", frame: r(0, 0))
            b.windows[1]!.isOnScreen = false
            b.onPress = { _ in .success }
            let o = CloseExecutor(backend: b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "其他桌面", allowOffscreen: true))
            if case .failed(.stillOpen) = o {
                check("本来就在其他桌面的窗口仍存在，不能凭“不在屏幕上”假报关闭", b.windows[1] != nil)
            } else { check("跨桌面不假报成功", false, outcomeName(o)) }
            b.pressed = []
            let oldScope = CloseExecutor(backend: b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "其他桌面"))
            if case .skipped(.notOnScreen) = oldScope { check("当前桌面目标移到其他桌面后仍应跳过", b.pressed.isEmpty) }
            else { check("当前桌面范围", false, outcomeName(oldScope)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "未保存文档", frame: r(0, 0))
            b.windows[1]!.isOnScreen = false
            b.onPress = { w in w.info.hasSheet = true; return .success }
            let e = CloseExecutor(backend: b)
            let o = e.attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "未保存文档", allowOffscreen: true))
            if case .needsUser(let ctx) = o {
                check("其他桌面的保存表单照样暂停，不能误报窗口已关闭", !ctx.wasOnScreen && e.checkPending(ctx) == .stillWaiting)
                b.ax[10]![0].info.hasSheet = false
                check("其他桌面上取消保存后，文档仍在", e.checkPending(ctx) == .keptOpen && b.windows[1] != nil)
            } else { check("其他桌面保存提示", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "全屏测试", frame: r(0, 0, 1920, 1080), noAX: true)
            b.windows[1]!.isOnScreen = false
            let all = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .allDesktops)
            check("仅有服务器标题但无 AX 确认的屏幕外窗口不展示", all.entries.isEmpty)
            let o = CloseExecutor(backend: b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "全屏测试", allowOffscreen: true))
            if case .skipped(.notUniquelyIdentified) = o { check("即使绕过界面也不能关闭无法确认的全屏窗口", b.pressed.isEmpty) }
            else { check("全屏关闭安全复核", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "同名全屏", frame: r(0, 0, 1920, 1080))
            b.add(2, pid: 10, title: "同名全屏", frame: r(0, 0, 1920, 1080))
            b.windows[1]!.isOnScreen = false
            b.windows[2]!.isOnScreen = false
            let all = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .allDesktops)
            check("不同桌面但同名同位置的全屏窗口无法区分时全部阻止关闭", all.entries.count == 2 && all.entries.allSatisfy { !$0.isClosable })
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "最小化", frame: r(0, 0), ax: AXWindowInfo(title: "最小化", frame: r(0, 0), isMinimized: true))
            b.windows[1]!.isOnScreen = false
            b.add(2, pid: 10, title: "", frame: r(100, 100), noAX: true)
            b.windows[2]!.isOnScreen = false
            let all = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .allDesktops)
            check("最小化窗口和无 AX 的后台缓冲窗口都不展示", all.entries.isEmpty)
            let o = CloseExecutor(backend: b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "最小化", allowOffscreen: true))
            if case .skipped(.notOnScreen) = o { check("窗口在执行前变成最小化时不发送关闭请求", b.pressed.isEmpty) }
            else { check("最小化执行前复核", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "已隐藏", frame: r(0, 0))
            b.windows[1]!.isOnScreen = false
            b.hiddenPIDs.insert(10)
            let all = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .allDesktops)
            check("已隐藏的应用即使仍报告 AX 窗口，也不出现在总览", all.entries.isEmpty)
            let o = CloseExecutor(backend: b).attempt(CloseTarget(windowID: 1, pid: 10, appName: "A", title: "已隐藏", allowOffscreen: true))
            if case .skipped(.notOnScreen) = o { check("窗口在执行前被隐藏时不发送关闭请求", b.pressed.isEmpty) }
            else { check("隐藏执行前复核", false, outcomeName(o)) }
        }
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "已关闭但服务器还留着", frame: r(0, 0), noAX: true)
            b.windows[1]!.isOnScreen = false
            b.add(2, pid: 10, title: "真正的其他桌面窗口", frame: r(100, 80))
            b.windows[2]!.isOnScreen = false
            let all = WindowEnumerator.enumerate(backend: b, ownPID: getpid(), scope: .allDesktops)
            check("不按标题收录后台保留记录，仍保留真正可确认的其他桌面窗口", all.entries.map(\.id) == [2])
        }

        print("窗口列表")
        do {
            let b = MockBackend()
            b.add(1, pid: 10, title: "普通", frame: r(0, 0))
            b.add(2, pid: 10, title: "菜单", frame: r(0, 0, 200, 300), layer: 101)
            b.add(3, pid: 10, title: "小", frame: r(0, 0, 20, 20))
            b.add(4, pid: getpid(), title: "自己", frame: r(500, 0))
            b.add(5, pid: 11, title: "同名", frame: r(0, 0))
            b.add(6, pid: 11, title: "同名", frame: r(0, 0))
            b.add(7, pid: 11, title: "", frame: r(700, 0), noAX: true)
            b.add(8, pid: 12, title: "无辅助功能", frame: r(700, 300), noAX: true)
            let res = WindowEnumerator.enumerate(backend: b, ownPID: getpid())
            let ids = Set(res.entries.map(\.id))
            check("排除非普通层级窗口、过小窗口和本工具自身", !ids.contains(2) && !ids.contains(3) && !ids.contains(4))
            check("普通窗口可选", res.entries.first { $0.id == 1 }?.isClosable == true)
            check("同名重叠窗口显示但不可选", res.entries.filter { $0.id == 5 || $0.id == 6 }.allSatisfy { !$0.isClosable } && ids.contains(5))
            check("没有标题、也找不到的辅助窗口不显示", !ids.contains(7))
            check("有标题但辅助功能找不到的窗口显示为不可选", res.entries.first { $0.id == 8 }?.isClosable == false)
            b.trusted = false
            let res2 = WindowEnumerator.enumerate(backend: b, ownPID: getpid())
            check("无辅助功能权限时标记为未授权，不可选", !res2.axTrusted && res2.entries.allSatisfy { !$0.isClosable })
        }

        runFaviconChecks()
        runTabPreviewChecks()
        print("\n结果：通过 \(passed) 项，未通过 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }
}
