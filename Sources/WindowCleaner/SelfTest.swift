import AppKit
import SwiftUI

// 一键自检：只操作“WC测试应用”打开的测试窗口，不碰任何其他窗口（关闭队列带有进程白名单保护）。
// 通过真实界面流程运行：唤出总览 → 按卡片选择 → 关闭所选 → 观察结果；
// 再用测试窗口自己记录的真实状态（窗口编号、是否关闭、收到过哪些关闭请求）来核对。

struct HostWindowSpec: Codable {
    var label: String
    var title: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var color: String
    var dirty: Bool?
    var closeBehavior: String?
    var autoResponse: String?
    var autoResponseDelay: Double?
    var style: String?
    var noAnimation: Bool?
}

struct HostConfigFile: Codable {
    var instance: String
    var statePath: String
    var windows: [HostWindowSpec]
    var quitAfterLastWindow: Bool?
    var lifetimeSeconds: Double?
    var quitDelay: Double?
}

struct HostWindowState: Codable {
    var label: String
    var title: String
    var number: Int
    var frame: [Double]
    var color: String
    var open: Bool
    var dirty: Bool
    var nsFrame: [Double]?
    var axFrame: [Double]?
}

struct HostEventRecord: Codable {
    var t: Double
    var event: String
    var label: String?
}

struct HostStateFile: Codable {
    var pid: Int32
    var instance: String
    var windows: [HostWindowState]
    var events: [HostEventRecord]
}

@MainActor
final class TestHost {
    let instance: String
    let appURL: URL
    let statePath: URL
    let configPath: URL
    var specs: [HostWindowSpec]
    let quitAfterLast: Bool
    var quitDelay: Double?
    var process: Process?

    init(instance: String, appURL: URL, workDir: URL, specs: [HostWindowSpec], quitAfterLast: Bool = false) {
        self.instance = instance
        self.appURL = appURL
        self.statePath = workDir.appendingPathComponent("state-\(instance).json")
        self.configPath = workDir.appendingPathComponent("config-\(instance).json")
        self.specs = specs
        self.quitAfterLast = quitAfterLast
    }

    func launch() throws {
        let cfg = HostConfigFile(instance: instance, statePath: statePath.path, windows: specs,
                                 quitAfterLastWindow: quitAfterLast, lifetimeSeconds: 600, quitDelay: quitDelay)
        try JSONEncoder().encode(cfg).write(to: configPath)
        let p = Process()
        p.executableURL = appURL.appendingPathComponent("Contents/MacOS/WCTestHost")
        p.arguments = ["--config", configPath.path, "-ApplePersistenceIgnoreState", "YES"]
        try p.run()
        process = p
    }

    var pid: pid_t { process?.processIdentifier ?? -1 }

    func state() -> HostStateFile? {
        guard let d = try? Data(contentsOf: statePath) else { return nil }
        return try? JSONDecoder().decode(HostStateFile.self, from: d)
    }

    func window(_ label: String) -> HostWindowState? { state()?.windows.first { $0.label == label } }

    /// 测试窗口的编号一经出现就记住：新版系统在窗口关闭后，测试宿主报告的编号变为 -1
    private var knownNumbers: [String: CGWindowID] = [:]

    func number(_ label: String) -> CGWindowID? {
        if let n = window(label)?.number, n > 0 {
            knownNumbers[label] = CGWindowID(n)
            return CGWindowID(n)
        }
        return knownNumbers[label]
    }

    func isOpen(_ label: String) -> Bool { window(label)?.open ?? false }

    func events(_ label: String? = nil, since: Double = 0) -> [String] {
        (state()?.events ?? []).filter { $0.t >= since && (label == nil || $0.label == label) }.map(\.event)
    }

    var clock: Double { state()?.events.last?.t ?? 0 }

    func send(_ cmd: String, _ extra: [String: String] = [:]) {
        var info = extra
        info["cmd"] = cmd
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.windowcleaner.testhost.command"), object: instance, userInfo: info, deliverImmediately: true)
    }

    var isRunning: Bool { process?.isRunning ?? false }
}

@MainActor
final class SelfTestViewModel: ObservableObject {
    struct Row: Identifiable {
        enum Verdict: String {
            case pass = "通过"
            case fail = "未通过"
            case notRun = "未执行"
            case info = "记录"
        }
        let id = UUID()
        var code: String
        var name: String
        var expected: String
        var actual: String
        var verdict: Verdict
    }

    @Published var rows: [Row] = []
    @Published var log: [String] = []
    @Published var running = true
    @Published var reportPath: String?
}

@MainActor
final class SelfTestRunner {
    let controller: OverviewController
    let vm = SelfTestViewModel()
    let noAnimation: Bool
    let tabsOnly: Bool
    let closeFeedbackOnly: Bool
    let closeTimingOnly: Bool
    let hostsDir: URL
    let reportDir: URL
    let workDir: URL
    var hosts: [String: TestHost] = [:]
    var window: NSWindow?
    var onPause: (() async -> Void)?
    var onFinish: (() -> Void)?
    var previousCloseOnClick: Bool?
    var testChrome: Process?
    var testChromeProfile: URL?

    init(controller: OverviewController, arguments: [String]) {
        self.controller = controller
        noAnimation = arguments.contains("--no-window-animation")
        tabsOnly = arguments.contains("--selftest-tabs-only")
        closeFeedbackOnly = arguments.contains("--selftest-close-feedback-only")
        closeTimingOnly = arguments.contains("--selftest-close-timing")
        let fm = FileManager.default
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        // 构建时写入的项目位置：应用装在“应用程序”里时，靠它找到测试工具和报告文件夹
        let projectDir = (Bundle.main.object(forInfoDictionaryKey: "WCProjectDir") as? String)
            .map { URL(fileURLWithPath: $0) }
            .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        if let i = arguments.firstIndex(of: "--hosts-dir"), i + 1 < arguments.count {
            hostsDir = URL(fileURLWithPath: arguments[i + 1])
        } else {
            let candidates = [appDir.appendingPathComponent("测试工具"),
                              projectDir?.appendingPathComponent("dist/测试工具")].compactMap { $0 }
            hostsDir = candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("WC测试应用A.app").path) } ?? candidates[0]
        }
        if let i = arguments.firstIndex(of: "--report-dir"), i + 1 < arguments.count {
            reportDir = URL(fileURLWithPath: arguments[i + 1])
        } else if let projectDir {
            reportDir = projectDir.appendingPathComponent("验证报告")
        } else {
            reportDir = TimingLog.url.deletingLastPathComponent()
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("WindowCleanerSelfTest-\(f.string(from: Date()))")
    }

    func start() {
        showWindow()
        Task { await run() }
    }

    // MARK: 工具

    func note(_ s: String) {
        vm.log.append(s)
        NSLog("[自检] %@", s)
    }

    func add(_ code: String, _ name: String, expected: String, actual: String, _ v: SelfTestViewModel.Row.Verdict) {
        vm.rows.append(.init(code: code, name: name, expected: expected, actual: actual, verdict: v))
        note("\(code) \(name)：\(v.rawValue) —— \(actual)")
    }

    func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            await wait(0.1)
        }
        return cond()
    }

    var model: OverviewModel { controller.model }

    func openOverview() async -> Bool {
        controller.show(reason: "自检")
        let ok = await waitUntil(10) { self.model.phase == .selecting || self.model.phase == .needsPermission }
        if model.screenRecording && model.phase == .selecting {
            _ = await waitUntil(8) { self.model.thumbnailPhase != .loading }
        }
        return ok
    }

    func closeOverview() {
        controller.dismiss(hideApp: false)
    }

    func host(_ label: String) -> TestHost {
        hosts[String(label.prefix(1))]!
    }

    func entry(_ label: String) -> WindowEntry? {
        guard let n = host(label).number(label) else { return nil }
        return model.entry(n)
    }

    /// 像用户一样单击卡片
    @discardableResult
    func select(_ labels: [String]) -> Bool {
        var ok = true
        for l in labels {
            guard let e = entry(l) else { note("找不到 \(l) 的卡片"); ok = false; continue }
            model.toggle(e)
            if model.selectionIndex(e.id) == nil { note("\(l) 无法选中：\(e.closability.reasonText ?? "")"); ok = false }
        }
        return ok
    }

    func status(_ label: String) -> ItemStatus? {
        guard let n = host(label).number(label) else { return nil }
        return model.statuses[n]
    }

    func describe(_ label: String) -> String {
        let s = status(label)
        return "\(label)：\(s?.category ?? "无状态")\((s?.detail ?? "").isEmpty ? "" : "（\(s!.detail)）")，测试窗口\(host(label).isOpen(label) ? "仍在" : "已关闭")"
    }

    func isClosed(_ s: ItemStatus?) -> Bool { if case .closed = s { return true }; return false }
    func isSkipped(_ s: ItemStatus?) -> Bool { if case .skipped = s { return true }; return false }
    func isFailed(_ s: ItemStatus?) -> Bool { if case .failed = s { return true }; return false }

    // MARK: 测试窗口布局

    static func colorHex(_ k: Int) -> String {
        let c = NSColor(calibratedHue: CGFloat(k % 18) / 18.0, saturation: 0.75, brightness: k >= 18 ? 0.5 : 0.8, alpha: 1)
            .usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    func spec(_ label: String, _ k: Int, title: String? = nil, frameOf: Int? = nil, color: Int? = nil) -> HostWindowSpec {
        let primary = NSScreen.screens.first!
        let ph = primary.frame.height
        let vf = primary.visibleFrame
        let top = ph - vf.maxY
        let slot = frameOf ?? k
        return HostWindowSpec(label: label, title: title ?? "WC自检-\(label)",
                              x: vf.minX + 30 + Double(slot % 5) * 160, y: top + 30 + Double(slot / 5) * 110,
                              w: 420, h: 300, color: Self.colorHex(color ?? k), noAnimation: noAnimation ? true : nil)
    }

    // MARK: 主流程

    func run() async {
        let ax = Permissions.accessibility
        let sr = Permissions.screenRecording
        note("开始自检。辅助功能：\(ax ? "已授权" : "未授权")；屏幕录制：\(sr ? "已授权" : "未授权")")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        if closeTimingOnly {
            await scenarioCloseTiming()
            await cleanup()
            finish()
            if CommandLine.arguments.contains("--selftest-exit") { NSApp.terminate(nil) }
            return
        }
        if closeFeedbackOnly {
            await scenarioCloseFeedback()
            await cleanup()
            finish()
            if CommandLine.arguments.contains("--selftest-exit") { NSApp.terminate(nil) }
            return
        }
        if tabsOnly {
            previousCloseOnClick = model.closeOnClick
            controller.allowedPIDs = []
            await scenarioBrowserTabs()
            await cleanup()
            finish()
            return
        }

        guard FileManager.default.fileExists(atPath: hostsDir.appendingPathComponent("WC测试应用A.app").path) else {
            add("E0", "测试工具", expected: "找到 WC测试应用A/B", actual: "在 \(hostsDir.path) 找不到测试工具", .fail)
            finish()
            return
        }
        let appA = hostsDir.appendingPathComponent("WC测试应用A.app")
        let appB = hostsDir.appendingPathComponent("WC测试应用B.app")

        var a = [spec("A1", 0), spec("A2", 1), spec("A3", 2)]
        var a5 = spec("A5", 3); a5.dirty = true; a5.autoResponse = "cancel"; a5.autoResponseDelay = 1.5
        var a6 = spec("A6", 4); a6.dirty = true; a6.autoResponse = "dontsave"; a6.autoResponseDelay = 1.5
        var a7 = spec("A7", 5); a7.dirty = true; a7.autoResponse = "cancel"; a7.autoResponseDelay = 2.5
        var a11 = spec("A11", 8); a11.closeBehavior = "modal"; a11.autoResponse = "cancel"; a11.autoResponseDelay = 3.5
        a += [a5, a6, a7, spec("A8", 6), spec("A9", 7), a11, spec("A12", 18), spec("A13", 19), spec("A14", 20)]
        let b = [spec("B1", 9), spec("B2", 10), spec("B7", 21),
                 spec("B3", 11, title: "WC自检-同名重叠窗口"), spec("B4", 11, title: "WC自检-同名重叠窗口", frameOf: 11, color: 18),
                 spec("B5", 12, title: "WC自检-同名不同位置"), spec("B6", 13, title: "WC自检-同名不同位置")]
        let c = [spec("C1", 14)]
        var d2 = spec("D2", 16); d2.closeBehavior = "refuse"
        var d3 = spec("D3", 17); d3.closeBehavior = "slow:1"
        let d = [spec("D1", 15), d2, d3]
        var f1 = spec("F1", 23); f1.dirty = true; f1.autoResponse = "cancel"; f1.autoResponseDelay = 1.5

        hosts["A"] = TestHost(instance: "A", appURL: appA, workDir: workDir, specs: a)
        hosts["B"] = TestHost(instance: "B", appURL: appB, workDir: workDir, specs: b)
        hosts["C"] = TestHost(instance: "C", appURL: appA, workDir: workDir, specs: c, quitAfterLast: true)
        hosts["D"] = TestHost(instance: "D", appURL: appB, workDir: workDir, specs: d)
        hosts["E"] = TestHost(instance: "E", appURL: appB, workDir: workDir, specs: [spec("E1", 22)])
        hosts["F"] = TestHost(instance: "F", appURL: appA, workDir: workDir, specs: [f1])
        hosts["G"] = TestHost(instance: "G", appURL: appB, workDir: workDir, specs: [])
        hosts["H"] = TestHost(instance: "H", appURL: appA, workDir: workDir, specs: [])
        hosts["I"] = TestHost(instance: "I", appURL: appB, workDir: workDir, specs: [])
        for (_, h) in hosts.sorted(by: { $0.key < $1.key }) {
            do { try h.launch() } catch { note("启动测试应用 \(h.instance) 失败：\(error)") }
        }
        let ready = await waitUntil(15) { self.hosts.values.allSatisfy { h in h.specs.allSatisfy { h.number($0.label) != nil } } }
        guard ready else {
            add("E0", "启动测试窗口", expected: "4 个测试应用、\(hosts.values.map(\.specs.count).reduce(0, +)) 个测试窗口就绪", actual: "超时未就绪", .fail)
            await cleanup()
            finish()
            return
        }
        controller.allowedPIDs = Set(hosts.values.map(\.pid))
        // 原有场景按“先选再关”模式验证；单击即关闭和圈选另有专门场景
        previousCloseOnClick = model.closeOnClick
        model.closeOnClick = false
        controller.pauseHandler = { [weak self] in await self?.handlePause() ?? .proceed }
        note("测试窗口已就绪；关闭队列已限定只能操作测试应用的进程：\(hosts.values.map { String($0.pid) }.sorted().joined(separator: ", "))")
        await wait(1.2) // 等窗口打开动画结束

        await scenarioWindowServerMapping(sr: sr)
        await scenarioMapping(ax: ax, sr: sr)
        if ax {
            await scenarioSameApp()
            await scenarioCrossApp()
            await scenarioCancelAndEsc()
            await scenarioUnsavedCancel()
            await scenarioUnsavedDontSave()
            await scenarioQueuePauses()
            await scenarioSameTitleSameFrame()
            await scenarioSameTitleDifferentFrame()
            await scenarioVanished()
            await scenarioUnresponsive()
            await scenarioRefuse()
            await scenarioModalDialog()
            await scenarioSlow()
            await scenarioLastWindowQuits()
            await scenarioClickToClose()
            await scenarioMarquee()
            await scenarioBlankClick()
            await scenarioQuitApp()
            await scenarioQuitAppUnsaved()
            await scenarioQuitBackgroundApp()
            await scenarioAppMarquee()
            await scenarioBrowserTabs()
        } else {
            for (code, name) in [("S1", "同一应用多个窗口，只关闭选中的"), ("S2", "跨应用多选"), ("S3", "取消全选 / Esc 不关闭"),
                                 ("S4", "未保存文档：取消后文档仍在"), ("S5", "未保存文档：选“不保存”"), ("S6", "确认框出现时暂停队列"),
                                 ("S7", "同名且位置相同的窗口不误关"), ("S8", "同名不同位置只关所选"), ("S9", "窗口已消失 / 被同名新窗口替换"),
                                 ("S10", "目标应用无响应"), ("S11", "应用拒绝关闭（请求成功≠已关闭）"), ("S12", "应用弹出独立对话框"),
                                 ("S13", "应用响应慢"), ("S14", "关闭最后一个窗口后应用自行退出"),
                                 ("S16", "单击即关闭（真实鼠标点击）"), ("S17", "圈选关闭（真实鼠标拖动）"),
                                 ("S18", "点击空白处退出，点卡片间窄缝不退出"),
                                 ("S19", "点应用图标退出应用"), ("S20", "退出前有未保存文档：保留原生提示"),
                                 ("S21", "没有窗口的后台应用也能退出"), ("S22", "应用栏圈选退出多个应用"),
                                 ("S23", "浏览器标签页：点击关闭、圈选关闭")] {
                add(code, name, expected: "—", actual: "需要先在系统设置中给“扫把”授权辅助功能", .notRun)
            }
            await scenarioPermissionMissing()
        }
        await cleanup()
        finish()
    }

    // MARK: 场景

    func scenarioMapping(ax: Bool, sr: Bool) async {
        guard await openOverview() else {
            add("S0", "总览能打开", expected: "进入选择界面", actual: "超时，当前阶段 \(model.phase)", .fail)
            return
        }
        if model.phase == .needsPermission {
            add("S0", "未授权时的界面", expected: "显示权限引导，不显示伪造列表", actual: "显示了权限引导页，窗口列表为空（\(model.entries.count) 张卡片）",
                model.entries.isEmpty ? .pass : .fail)
            closeOverview()
            return
        }
        var found = 0, titleOK = 0, frameOK = 0, total = 0
        var axFrameOK = 0, axFrameTotal = 0
        var colorOK = 0, colorTotal = 0
        var mismatches: [String] = []
        let allSpecs = hosts.values.flatMap { h in h.specs.map { (h, $0) } }
        let palette = allSpecs.map { ($0.1.label, $0.1.color) }
        for (h, s) in allSpecs {
            total += 1
            guard let st = h.window(s.label), st.number > 0 else { continue }
            guard let e = model.entry(CGWindowID(st.number)) else { mismatches.append("\(s.label) 没有卡片"); continue }
            found += 1
            if e.title == s.title { titleOK += 1 } else { mismatches.append("\(s.label) 标题“\(e.title)”") }
            let hf = CGRect(x: st.frame[0], y: st.frame[1], width: st.frame[2], height: st.frame[3])
            if WindowMatcher.framesMatch(hf, e.bounds) { frameOK += 1 } else { mismatches.append("\(s.label) 边界 \(e.bounds) ≠ \(hf)") }
            if sr, let img = model.thumbnails[e.id] {
                colorTotal += 1
                if let nearest = Self.nearestLabel(img, palette: palette), nearest == s.label { colorOK += 1 } else {
                    mismatches.append("\(s.label) 缩略图颜色不符")
                }
            }
        }
        if ax {
            // 直接比较辅助功能接口报告的窗口位置尺寸与窗口服务器的边界
            for h in hosts.values {
                guard case .success(let list) = controller.backend.axWindows(pid: h.pid, timeout: 1, includeSheetCheck: false) else { continue }
                let cg = controller.backend.onScreenWindows().filter { $0.pid == h.pid && $0.layer == 0 }
                for axw in list where axw.info.role == "AXWindow" {
                    axFrameTotal += 1
                    if let f = axw.info.frame, cg.contains(where: { WindowMatcher.framesMatch($0.bounds, f) }) { axFrameOK += 1 }
                }
            }
        }
        let pass = found == total && titleOK == total && frameOK == total && (!sr || colorOK == colorTotal) && (!ax || axFrameOK == axFrameTotal)
        var actual = "\(total) 个测试窗口：找到卡片 \(found)，卡片编号=测试窗口真实编号；标题一致 \(titleOK)，窗口服务器边界与窗口真实边界一致 \(frameOK)"
        if ax { actual += "；辅助功能坐标与窗口服务器边界一致 \(axFrameOK)/\(axFrameTotal)" } else { actual += "；辅助功能坐标未核对（未授权）" }
        if sr { actual += "；缩略图颜色与对应窗口一致 \(colorOK)/\(colorTotal)" } else { actual += "；缩略图未核对（未授权屏幕录制）" }
        if !mismatches.isEmpty { actual += "。不一致：" + mismatches.prefix(6).joined(separator: "；") }
        add("S0", "缩略图 / 卡片 / 可关闭窗口三者对应", expected: "每张卡片的编号、标题、边界、缩略图都对应同一个测试窗口", actual: actual, pass ? .pass : .fail)

        if ax {
            let b3 = entry("B3"), b4 = entry("B4")
            let closableAll = ["A1", "A2", "B1", "B5", "B6", "D1"].allSatisfy { entry($0)?.isClosable == true }
            add("S0b", "可关闭判定", expected: "普通测试窗口可选；同名且重叠的 B3/B4 不可选",
                actual: "普通窗口\(closableAll ? "均可选" : "有不可选的")；B3 \(b3?.isClosable == true ? "可选" : "不可选")，B4 \(b4?.isClosable == true ? "可选" : "不可选")",
                closableAll && b3?.isClosable == false && b4?.isClosable == false ? .pass : .fail)
        }
        add("T0", "耗时记录", expected: "如实记录", actual: model.timingText.isEmpty ? "无" : model.timingText, .info)
        closeOverview()
    }

    /// 不依赖辅助功能的基础核对：窗口服务器的编号/标题/边界，以及按编号截取的缩略图，是否对应同一个测试窗口
    func scenarioWindowServerMapping(sr: Bool) async {
        let backend = controller.backend
        let onScreen = backend.onScreenWindows()
        let allSpecs = hosts.values.flatMap { h in h.specs.map { (h, $0) } }
        var idOK = 0, titleOK = 0, frameOK = 0
        var problems: [String] = []
        var ids: [CGWindowID] = []
        var labelByID: [CGWindowID: String] = [:]
        for (h, s) in allSpecs {
            guard let st = h.window(s.label), st.number > 0 else { problems.append("\(s.label) 无编号"); continue }
            let id = CGWindowID(st.number)
            guard let cg = onScreen.first(where: { $0.windowID == id }) else { problems.append("\(s.label) 不在窗口列表"); continue }
            if cg.pid == h.pid { idOK += 1 } else { problems.append("\(s.label) 进程不符") }
            if !sr || cg.title == s.title { titleOK += 1 } else { problems.append("\(s.label) 标题“\(cg.title ?? "")”") }
            let hf = CGRect(x: st.frame[0], y: st.frame[1], width: st.frame[2], height: st.frame[3])
            if WindowMatcher.framesMatch(cg.bounds, hf) { frameOK += 1 } else { problems.append("\(s.label) 边界 \(cg.bounds) ≠ 实际 \(hf)") }
            ids.append(id)
            labelByID[id] = s.label
        }
        let total = allSpecs.count
        var thumbText = "未核对（未授权屏幕录制）"
        var thumbPass = true
        if sr {
            let palette = allSpecs.map { ($0.1.label, $0.1.color) }
            var ok = 0, captured = 0
            do {
                _ = try await ThumbnailLoader.load(ids: ids, maxPixelSize: CGSize(width: 400, height: 400)) { id, img in
                    guard let img else { return }
                    captured += 1
                    if Self.nearestLabel(img, palette: palette) == labelByID[id] { ok += 1 } else { problems.append("\(labelByID[id] ?? "?") 缩略图颜色不符") }
                }
                if captured < ids.count && Self.screenLocked {
                    thumbText = "未核对：屏幕处于锁定状态，系统不允许截图（截到 \(captured)/\(ids.count) 张）"
                } else {
                    thumbText = "按编号截取 \(captured)/\(ids.count) 张，颜色与对应窗口一致 \(ok) 张"
                    thumbPass = captured == ids.count && ok == captured
                }
            } catch {
                if Self.screenLocked {
                    thumbText = "未核对：屏幕处于锁定状态，系统不允许截图"
                } else {
                    thumbText = "截图失败：\(error)"
                    thumbPass = false
                }
            }
        }
        let pass = idOK == total && titleOK == total && frameOK == total && thumbPass
        var actual = "\(total) 个测试窗口：编号与进程一致 \(idOK)，标题一致 \(sr ? "\(titleOK)" : "未核对（无屏幕录制读不到标题）")，边界一致 \(frameOK)；缩略图：\(thumbText)"
        if !problems.isEmpty { actual += "。问题：" + problems.prefix(6).joined(separator: "；") }
        add("S0a", "窗口编号 / 标题 / 边界 / 缩略图对应（不需辅助功能）", expected: "全部对应同一个测试窗口", actual: actual, pass ? .pass : .fail)
    }

    static var screenLocked: Bool {
        let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static func nearestLabel(_ img: NSImage, palette: [(String, String)]) -> String? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let c = rep.colorAt(x: cg.width / 2, y: Int(Double(cg.height) * 0.75))?.usingColorSpace(.sRGB) else { return nil }
        func rgb(_ hex: String) -> (Double, Double, Double) {
            let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
        var best: (String, Double)?
        for (label, hex) in palette {
            let (r, g, b) = rgb(hex)
            let dist = abs(r - c.redComponent) + abs(g - c.greenComponent) + abs(b - c.blueComponent)
            if best == nil || dist < best!.1 { best = (label, dist) }
        }
        return best?.0
    }

    func runSelection(_ labels: [String]) async -> Bool {
        guard await openOverview(), model.phase == .selecting else { note("总览未进入选择状态"); return false }
        let ok = select(labels)
        if !ok { closeOverview(); return false }
        await controller.runQueue()
        return true
    }

    func scenarioSameApp() async {
        let t = host("A").clock
        guard await runSelection(["A1", "A3"]) else {
            add("S1", "同一应用多个窗口，只关闭选中的", expected: "A1、A3 关闭，A2 保留", actual: "无法选中测试窗口", .fail); return
        }
        let pass = isClosed(status("A1")) && isClosed(status("A3")) && !host("A").isOpen("A1") && !host("A").isOpen("A3") &&
            host("A").isOpen("A2") && !host("A").events("A2", since: t).contains("shouldClose")
        add("S1", "同一应用多个窗口，只关闭选中的", expected: "WC测试应用A 的 A1、A3 关闭，A2 不受影响",
            actual: [describe("A1"), describe("A3"), "A2 \(host("A").isOpen("A2") ? "仍在，且未收到任何关闭请求" : "被关闭了！")"].joined(separator: "；"),
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioCrossApp() async {
        let tA = host("A").clock, tB = host("B").clock
        guard await runSelection(["A2", "B2"]) else {
            add("S2", "跨应用多选", expected: "A2、B2 关闭", actual: "无法选中", .fail); return
        }
        let untouched = host("B").isOpen("B1") && host("A").isOpen("A8") &&
            !host("B").events("B1", since: tB).contains("shouldClose") && !host("A").events("A8", since: tA).contains("shouldClose")
        let pass = isClosed(status("A2")) && isClosed(status("B2")) && !host("A").isOpen("A2") && !host("B").isOpen("B2") && untouched
        add("S2", "跨应用多选，未选中的保持原样", expected: "A2（应用A）、B2（应用B）关闭；B1、A8 等未选窗口不受影响",
            actual: [describe("A2"), describe("B2"), untouched ? "B1、A8 仍在且未收到关闭请求" : "有未选窗口受到影响！"].joined(separator: "；"),
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioCancelAndEsc() async {
        let tA = host("A").clock, tB = host("B").clock
        guard await openOverview(), model.phase == .selecting else { add("S3", "取消全选 / Esc", expected: "", actual: "总览未打开", .fail); return }
        select(["B1", "A8"])
        let selectedBefore = model.selection.count
        model.clearSelection()
        let cleared = model.selection.isEmpty
        select(["B1", "A8"])
        controller.simulateEscapeKey()
        let hidden = await waitUntil(3) { !self.controller.isOverlayVisible }
        await wait(1.5)
        let untouched = host("B").isOpen("B1") && host("A").isOpen("A8") &&
            !host("B").events("B1", since: tB).contains("shouldClose") && !host("A").events("A8", since: tA).contains("shouldClose")
        add("S3", "取消全选 / 按 Esc 不关闭任何窗口", expected: "取消全选后计数归零、关闭按钮禁用；Esc 收起总览；B1、A8 不受影响",
            actual: "选中 \(selectedBefore) 个后取消全选 → 剩 \(model.selection.count == 0 && cleared ? 0 : -1) 个；再选中后按 Esc → 总览\(hidden ? "已收起" : "未收起")；B1、A8 \(untouched ? "仍在且未收到关闭请求" : "受到了影响！")",
            cleared && hidden && untouched && selectedBefore == 2 ? .pass : .fail)
    }

    func handlePause() async -> PauseDecision {
        note("队列已暂停，等待“用户”在确认框中做选择（测试应用会模拟用户点击）")
        if let onPause { await onPause() }
        _ = await waitUntil(15) { self.model.pendingState != .stillWaiting }
        return .proceed
    }

    func scenarioUnsavedCancel() async {
        var sawWaiting = false
        onPause = { sawWaiting = self.status("A5").map { if case .waitingUser = $0 { return true }; return false } ?? false }
        guard await runSelection(["A5"]) else { add("S4", "未保存文档：取消", expected: "", actual: "无法选中", .fail); onPause = nil; return }
        onPause = nil
        let ev = host("A").events("A5")
        let pass = sawWaiting && ev.contains("sheetShown") && ev.contains("autoResponse:cancel") && host("A").isOpen("A5") &&
            host("A").window("A5")?.dirty == true && isSkipped(status("A5"))
        add("S4", "未保存文档的确认提示保留，取消后文档仍在",
            expected: "出现原生“是否保存”表单；队列暂停并标为“等待你处理”；用户选“取消”后文档仍在、未保存内容仍在",
            actual: "表单\(ev.contains("sheetShown") ? "出现了" : "没出现")；暂停时状态\(sawWaiting ? "为“等待你处理”" : "不对")；\(describe("A5"))；文档\(host("A").window("A5")?.dirty == true ? "仍有未保存内容" : "已无未保存内容")",
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioUnsavedDontSave() async {
        guard await runSelection(["A6"]) else { add("S5", "未保存文档：不保存", expected: "", actual: "无法选中", .fail); return }
        let ev = host("A").events("A6")
        let pass = ev.contains("sheetShown") && ev.contains("autoResponse:dontsave") && !host("A").isOpen("A6") && isClosed(status("A6"))
        add("S5", "未保存文档：由用户选择“不保存”",
            expected: "扫把只按关闭按钮，不替用户选择；用户选“不保存”后才关闭，并标为已关闭",
            actual: "“不保存”由测试应用模拟的用户点击（扫把未点击任何对话框按钮）；\(describe("A6"))", pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioQueuePauses() async {
        var a8UntouchedDuringPause = false
        let t = host("A").clock
        onPause = {
            await self.wait(0.8)
            a8UntouchedDuringPause = self.host("A").isOpen("A8") && !self.host("A").events("A8", since: t).contains("shouldClose")
        }
        guard await runSelection(["A7", "A8"]) else { add("S6", "暂停队列", expected: "", actual: "无法选中", .fail); onPause = nil; return }
        onPause = nil
        let pass = a8UntouchedDuringPause && host("A").isOpen("A7") && isSkipped(status("A7")) && isClosed(status("A8")) && !host("A").isOpen("A8")
        add("S6", "出现确认框时暂停队列，不连续弹出多个确认框",
            expected: "A7（未保存）弹出表单时暂停，A8 在暂停期间不被处理；用户处理后继续，A8 关闭",
            actual: "暂停期间 A8 \(a8UntouchedDuringPause ? "未被处理" : "被处理了！")；\(describe("A7"))；\(describe("A8"))", pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioSameTitleSameFrame() async {
        let t = host("B").clock
        guard await openOverview(), model.phase == .selecting else { add("S7", "同名重叠", expected: "", actual: "总览未打开", .fail); return }
        let b3 = entry("B3"), b4 = entry("B4")
        if let b3 { model.toggle(b3) }
        if let b4 { model.toggle(b4) }
        let notSelectable = model.selection.isEmpty
        // 即使绕过界面直接请求关闭，执行前的复核也必须拒绝
        var direct = "未执行"
        var directSkipped = false
        if let b3 {
            let exec = controller.executor
            exec.allowedPIDs = controller.allowedPIDs
            let target = b3.target
            let outcome = await Task.detached { exec.attempt(target) }.value
            direct = outcome.status.category + "（" + outcome.status.detail + "）"
            if case .skipped(.notUniquelyIdentified) = outcome { directSkipped = true }
        }
        await wait(0.5)
        let untouched = host("B").isOpen("B3") && host("B").isOpen("B4") && !host("B").events("B3", since: t).contains("shouldClose") &&
            !host("B").events("B4", since: t).contains("shouldClose")
        add("S7", "同名且位置大小相同的窗口：宁可跳过，不误关",
            expected: "两张卡片都标为“无法唯一确认”且不能选；直接请求关闭也会在执行前被跳过；两个窗口都不受影响",
            actual: "卡片\(notSelectable ? "不能选中" : "可以选中！")（\(b3?.closability.reasonText ?? "")）；直接请求结果：\(direct)；B3、B4 \(untouched ? "都仍在且未收到关闭请求" : "受到了影响！")",
            notSelectable && directSkipped && untouched ? .pass : .fail)
        closeOverview()
    }

    func scenarioSameTitleDifferentFrame() async {
        guard await runSelection(["B5"]) else { add("S8", "同名不同位置", expected: "", actual: "无法选中", .fail); return }
        let pass = isClosed(status("B5")) && !host("B").isOpen("B5") && host("B").isOpen("B6")
        add("S8", "同名但位置不同的窗口：只关选中的那个", expected: "B5 关闭，同名的 B6 保留",
            actual: "\(describe("B5"))；B6 \(host("B").isOpen("B6") ? "仍在" : "被关闭了！")", pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioVanished() async {
        guard await openOverview(), model.phase == .selecting, select(["A9"]) else {
            add("S9", "窗口已消失", expected: "", actual: "无法选中", .fail); closeOverview(); return
        }
        let oldNumber = host("A").number("A9")
        // 选中之后、执行之前：A9 被应用自己关掉，并在同一位置打开一个同名新窗口 A10
        host("A").send("closeWindow", ["label": "A9"])
        _ = await waitUntil(3) { !self.host("A").isOpen("A9") }
        var a10 = spec("A10", 7, title: "WC自检-A9", frameOf: 7, color: 19)
        a10.noAnimation = true
        host("A").specs.append(a10)
        host("A").send("openWindow", ["spec": String(data: try! JSONEncoder().encode(a10), encoding: .utf8)!])
        _ = await waitUntil(3) { self.host("A").number("A10") != nil }
        await wait(0.6)
        let t = host("A").clock
        await controller.runQueue()
        let st = oldNumber.flatMap { model.statuses[$0] }
        let pass = isSkipped(st) && host("A").isOpen("A10") && !host("A").events("A10", since: t).contains("shouldClose")
        add("S9", "执行前窗口已消失，且原位置出现同名新窗口",
            expected: "A9 标为“已跳过（窗口已不存在）”；同名同位置的新窗口 A10 不受影响（不靠标题匹配）",
            actual: "A9：\(st?.category ?? "无状态")（\(st?.detail ?? "")）；A10 \(host("A").isOpen("A10") ? "仍在且未收到关闭请求" : "被关闭了！")",
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioUnresponsive() async {
        guard await openOverview(), model.phase == .selecting, select(["D1"]) else {
            add("S10", "应用无响应", expected: "", actual: "无法选中", .fail); closeOverview(); return
        }
        let t = host("D").clock
        host("D").send("hang", ["seconds": "6"])
        await wait(0.5)
        await controller.runQueue()
        let st = status("D1")
        _ = await waitUntil(10) { self.host("D").events(since: t).contains("hangEnd") }
        await wait(1.5)
        let untouched = host("D").isOpen("D1") && !host("D").events("D1", since: t).contains("shouldClose")
        let notFakeSuccess = !isClosed(st)
        add("S10", "目标应用无响应时不误关、不假报成功",
            expected: "不发送关闭请求，标为“已跳过（应用无响应）”；应用恢复后窗口仍在",
            actual: "D1：\(st?.category ?? "无状态")（\(st?.detail ?? "")）；应用恢复后 D1 \(untouched ? "仍在，且从未收到关闭请求" : "被关闭了或收到了关闭请求")",
            untouched && notFakeSuccess && isSkipped(st) ? .pass : .fail)
        closeOverview()
    }

    func scenarioRefuse() async {
        guard await runSelection(["D2"]) else { add("S11", "拒绝关闭", expected: "", actual: "无法选中", .fail); return }
        let st = status("D2")
        let ev = host("D").events("D2")
        let pass = isFailed(st) && host("D").isOpen("D2") && ev.contains("refused")
        add("S11", "发送关闭请求成功 ≠ 窗口已关闭",
            expected: "应用收到请求但没有关闭窗口：标为“关闭失败（窗口仍然存在）”，不报成功",
            actual: "测试应用\(ev.contains("refused") ? "收到并拒绝了关闭请求" : "没有收到请求")；D2：\(st?.category ?? "")（\(st?.detail ?? "")）",
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioModalDialog() async {
        guard await runSelection(["A11"]) else { add("S12", "独立对话框", expected: "", actual: "无法选中", .fail); return }
        let ev = host("A").events("A11")
        let pass = ev.contains("modalShown") && ev.contains("modalCancelled") && host("A").isOpen("A11") && isSkipped(status("A11"))
        add("S12", "应用弹出独立的确认对话框（非表单）",
            expected: "识别为需要用户处理并暂停；用户取消后窗口保留",
            actual: "对话框\(ev.contains("modalShown") ? "出现了" : "没出现")；\(describe("A11"))", pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioSlow() async {
        guard await runSelection(["D3"]) else { add("S13", "响应慢", expected: "", actual: "无法选中", .fail); return }
        let pass = isClosed(status("D3")) && !host("D").isOpen("D3")
        add("S13", "应用关闭前卡顿 1 秒", expected: "等待并观察到窗口真正消失后标为已关闭", actual: describe("D3"), pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioLastWindowQuits() async {
        guard await runSelection(["C1"]) else { add("S14", "最后一个窗口", expected: "", actual: "无法选中", .fail); return }
        let exited = await waitUntil(3) { !self.host("C").isRunning }
        // “随后自行退出”由关闭后的复查补充（约 0.8 秒后），等它出现
        _ = await waitUntil(3) { self.status("C1")?.detail.contains("自行退出") == true }
        let st = status("C1")
        add("S14", "关闭最后一个窗口后应用自行退出（兼容性边界）",
            expected: "如实标注“应用随后自行退出”；不重新启动应用来伪装",
            actual: "C1：\(st?.category ?? "")（\(st?.detail ?? "")）；测试应用C \(exited ? "已自行退出" : "仍在运行")",
            isClosed(st) && exited && (st?.detail.contains("自行退出") ?? false) ? .pass : .fail)
        closeOverview()
    }

    func scenarioPermissionMissing() async {
        // 未授权辅助功能时：执行器必须拒绝，且不伪造窗口列表
        let exec = controller.executor
        exec.allowedPIDs = controller.allowedPIDs
        guard let n = host("B").number("B1") else { return }
        let target = CloseTarget(windowID: n, pid: host("B").pid, appName: "WC测试应用B", title: "WC自检-B1")
        let outcome = await Task.detached { exec.attempt(target) }.value
        var ok = false
        if case .failed(.notTrusted) = outcome { ok = true }
        add("S15", "权限不足时不误关、不假报成功", expected: "直接请求关闭也返回“关闭失败（缺少辅助功能权限）”，窗口仍在",
            actual: "\(outcome.status.category)（\(outcome.status.detail)）；B1 \(host("B").isOpen("B1") ? "仍在" : "被关闭了！")",
            ok && host("B").isOpen("B1") ? .pass : .fail)
    }

    /// 等界面上报卡片位置；只有在总览可见区域内的卡片才能用模拟鼠标操作
    func visibleCardFrame(_ label: String) -> CGRect? {
        guard let e = entry(label), let f = controller.cardWindowFrame(e.id) else { return nil }
        let size = controller.overlayContentSize
        guard f.minX >= 0, f.minY >= 0, f.maxX <= size.width, f.maxY <= size.height - 90 else { return nil }
        return f
    }

    func scenarioClickToClose() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else {
            add("S16", "单击即关闭", expected: "", actual: "总览未打开", .fail); return
        }
        await wait(0.6)
        let tA = host("A").clock, tB = host("B").clock
        var notes: [String] = []
        var realMouse = true
        for l in ["A12", "B7"] {
            guard let e = entry(l) else { notes.append("\(l) 没有卡片"); continue }
            let t0 = Date()
            if let f = visibleCardFrame(l) {
                await controller.simulateClick(at: CGPoint(x: f.midX, y: f.midY))
                if !(await waitUntil(1.5) { self.model.statuses[e.id] != nil }) {
                    realMouse = false
                    controller.cardClicked(e)
                }
            } else {
                realMouse = false
                controller.cardClicked(e)
            }
            _ = await waitUntil(6) { self.model.statuses[e.id]?.isFinal == true }
            notes.append("\(l) 从点击到确认关闭 \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
        let gone = await waitUntil(5) { self.entry("A12") == nil && self.entry("B7") == nil }
        let untouched = host("A").isOpen("A11") && host("B").isOpen("B6") &&
            !host("A").events("A11", since: tA).contains("shouldClose") && !host("B").events("B6", since: tB).contains("shouldClose")
        let pass = isClosed(status("A12")) && isClosed(status("B7")) && !host("A").isOpen("A12") && !host("B").isOpen("B7") && untouched && gone
        add("S16", "单击即关闭：单击卡片立即关闭该窗口，关闭后卡片淡出消失",
            expected: "A12、B7 各点一下即关闭，卡片随后从总览消失；其他窗口不受影响",
            actual: notes.joined(separator: "；") + "；\(describe("A12"))；\(describe("B7"))；卡片\(gone ? "已从总览消失" : "仍在总览里")；其他窗口\(untouched ? "不受影响" : "受到了影响！")" +
                (realMouse ? "（使用真实鼠标事件）" : "（模拟鼠标点击未生效，改为直接调用点击处理）"),
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioMarquee() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else {
            add("S17", "圈选关闭", expected: "", actual: "总览未打开", .fail); return
        }
        await wait(0.6)
        let t = host("A").clock
        guard let f13 = visibleCardFrame("A13"), let f14 = visibleCardFrame("A14") else {
            add("S17", "圈选关闭（真实鼠标拖动）", expected: "框住的窗口被关闭", actual: "A13/A14 的卡片不在可见区域，无法模拟拖动", .notRun)
            closeOverview(); return
        }
        // 从一张卡片内侧的角拖到另一张卡片内侧的对角；先确认这个框只会碰到这两张卡片
        var targets = ["A13", "A14"]
        var rect = f13.union(f14).insetBy(dx: 12, dy: 12)
        let hits = model.entries.filter { e in model.cardFrames[e.id]?.window.intersects(rect) ?? false }.map(\.id)
        let wanted = Set(targets.compactMap { host("A").number($0) })
        if Set(hits) != wanted {
            note("A13、A14 之间夹着其他卡片，改为只框选 A13")
            targets = ["A13"]
            rect = f13.insetBy(dx: 12, dy: 12)
        }
        await controller.simulateDrag(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        let started = await waitUntil(2) { targets.allSatisfy { self.status($0) != nil } }
        _ = await waitUntil(8) { targets.allSatisfy { self.status($0)?.isFinal == true } }
        let othersUntouched = ["A5", "A7", "A10", "A11"].filter { host("A").specs.map(\.label).contains($0) }.allSatisfy {
            !host("A").events($0, since: t).contains("shouldClose")
        }
        let closedAll = targets.allSatisfy { isClosed(status($0)) && !host("A").isOpen($0) }
        let notTargetStillOpen = targets.count == 1 ? host("A").isOpen("A14") : true
        add("S17", "圈选关闭（真实鼠标拖动）",
            expected: "拖出的框碰到的卡片（\(targets.joined(separator: "、"))）被依次关闭；框外的窗口不受影响",
            actual: started ? targets.map { describe($0) }.joined(separator: "；") + "；框外窗口\(othersUntouched && notTargetStillOpen ? "不受影响" : "受到了影响！")"
                            : "模拟拖动没有触发圈选（可能是系统没有把模拟的鼠标事件交给界面）",
            started && closedAll && othersUntouched && notTargetStillOpen ? .pass : .fail)
        closeOverview()
    }

    func scenarioBlankClick() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else {
            add("S18", "点击空白处退出", expected: "", actual: "总览未打开", .fail); return
        }
        await wait(0.6)
        let clocks = hosts.mapValues { $0.clock }
        func anyCloseRequest() -> Bool {
            hosts.contains { key, h in h.isRunning && h.events(since: clocks[key] ?? 0).contains { $0 == "shouldClose" || $0 == "closed" } }
        }
        // 1. 找两张同一行、左右相邻的卡片，点它们之间的窄缝
        let size = controller.overlayContentSize
        let frames = model.entries.compactMap { controller.cardWindowFrame($0.id) }
            .filter { $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= size.width && $0.maxY <= size.height - 90 }
        var gutter: CGPoint?
        for a in frames {
            if let b = frames.first(where: { abs($0.minY - a.minY) < 1 && $0.minX > a.maxX && $0.minX - a.maxX < 40 }) {
                gutter = CGPoint(x: (a.maxX + b.minX) / 2, y: a.midY)
                break
            }
        }
        var gutterText = "没有找到同一行相邻的两张卡片，未测试窄缝"
        var gutterOK = true
        if let g = gutter {
            await controller.simulateClick(at: g)
            await wait(0.8)
            gutterOK = controller.isOverlayVisible && !anyCloseRequest()
            gutterText = "点卡片之间的窄缝后，总览\(controller.isOverlayVisible ? "仍在" : "退出了！")"
        }
        // 2. 点顶部空白处（标题栏上方的边距）
        await controller.simulateClick(at: CGPoint(x: size.width / 2, y: 12))
        let exited = await waitUntil(2) { !self.controller.isOverlayVisible }
        await wait(0.8)
        let untouched = !anyCloseRequest()
        let realMouse = gutter != nil ? gutterOK || exited : exited
        add("S18", "点击空白处退出总览；卡片之间的窄缝不算空白",
            expected: "点窄缝不退出；点空白处退出；都不关闭任何窗口",
            actual: gutterText + "；点空白处后总览\(exited ? "已退出" : "没有退出")；测试窗口\(untouched ? "都没有收到关闭请求" : "收到了关闭请求！")" +
                (realMouse ? "（使用真实鼠标事件）" : "（模拟鼠标事件可能未生效）"),
            gutterOK && exited && untouched ? .pass : .fail)
        closeOverview()
    }

    /// 点应用栏里的图标：优先用真实鼠标事件，取不到位置时直接调用点击处理
    func clickApp(_ h: TestHost) async -> Bool {
        guard let a = model.app(h.pid) else { return false }
        let size = controller.overlayContentSize
        if let f = controller.appWindowFrame(h.pid), f.minX >= 0, f.maxX <= size.width, f.minY >= 0, f.maxY <= size.height {
            await controller.simulateClick(at: CGPoint(x: f.midX, y: f.midY))
            if await waitUntil(1.5, { self.model.appStatuses[h.pid] != nil }) { return true }
        }
        controller.appClicked(a)
        return false
    }

    func appStatusText(_ h: TestHost) -> String {
        let st = model.appStatuses[h.pid]
        return "\(st.map { $0.category == "已关闭" ? "已退出" : $0.category } ?? "无状态")\((st?.detail ?? "").isEmpty ? "" : "（\(st!.detail)）")"
    }

    func scenarioQuitApp() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else { add("S19", "退出应用", expected: "", actual: "总览未打开", .fail); return }
        await wait(0.6)
        let e = host("E")
        let others = ["A", "B", "D"].map { host($0) }
        let t0 = Date()
        let real = await clickApp(e)
        let exited = await waitUntil(8) { !e.isRunning }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let cardGone = await waitUntil(4) { self.entry("E1") == nil }
        let othersRunning = others.allSatisfy(\.isRunning)
        add("S19", "点应用图标退出应用；它的窗口卡片随之消失",
            expected: "WC测试应用B（实例 E）退出，窗口 E1 的卡片消失；其他测试应用继续运行",
            actual: "实例 E \(exited ? "已退出（约 \(ms) ms）" : "没有退出")；状态：\(appStatusText(e))；E1 卡片\(cardGone ? "已消失" : "仍在")；其他测试应用\(othersRunning ? "都在运行" : "有被退出的！")" +
                (real ? "（使用真实鼠标事件）" : "（模拟点击未生效，改为直接调用点击处理）"),
            exited && cardGone && othersRunning && isClosed(model.appStatuses[e.pid]) ? .pass : .fail)
        closeOverview()
    }

    func scenarioQuitAppUnsaved() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else { add("S20", "退出前保存提示", expected: "", actual: "总览未打开", .fail); return }
        await wait(0.6)
        let f = host("F")
        var sawWaiting = false
        onPause = { sawWaiting = { if case .waitingUser = self.model.appStatuses[f.pid] { return true }; return false }() }
        _ = await clickApp(f)
        _ = await waitUntil(15) { self.model.appStatuses[f.pid]?.isFinal == true }
        onPause = nil
        await wait(1)
        let ev = f.events("F1")
        let stillRunning = f.isRunning
        let pass = sawWaiting && ev.contains("sheetShown") && ev.contains("autoResponse:cancel") && stillRunning &&
            f.isOpen("F1") && f.window("F1")?.dirty == true && isSkipped(model.appStatuses[f.pid])
        add("S20", "退出应用时有未保存文档：保留原生提示，由你决定",
            expected: "出现原生“是否保存”表单；队列暂停并标为“等待你处理”；“用户”点取消后应用继续运行、文档和未保存内容都在",
            actual: "表单\(ev.contains("sheetShown") ? "出现了" : "没出现")；暂停时状态\(sawWaiting ? "为“等待你处理”" : "不对")；应用\(stillRunning ? "仍在运行" : "已退出！")；状态：\(appStatusText(f))；文档\(f.window("F1")?.dirty == true ? "仍有未保存内容" : "已无未保存内容")",
            pass ? .pass : .fail)
        closeOverview()
    }

    func scenarioQuitBackgroundApp() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else { add("S21", "后台应用", expected: "", actual: "总览未打开", .fail); return }
        await wait(0.6)
        let g = host("G")
        let listed = model.app(g.pid)
        let label = listed.map { $0.windowCount == 0 ? "显示为“\($0.isHidden ? "已隐藏" : "后台运行")”" : "显示有 \($0.windowCount) 个窗口" } ?? "没有出现在应用栏"
        if listed != nil { _ = await clickApp(g) }
        let exited = await waitUntil(8) { !g.isRunning }
        add("S21", "没有窗口、在后台运行的应用也能在应用栏里退出",
            expected: "实例 G（没有任何窗口）出现在应用栏并能被退出",
            actual: "实例 G \(label)；\(exited ? "已退出" : "没有退出")；状态：\(appStatusText(g))",
            listed != nil && exited ? .pass : .fail)
        closeOverview()
    }

    func scenarioAppMarquee() async {
        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else { add("S22", "应用栏圈选", expected: "", actual: "总览未打开", .fail); return }
        await wait(0.6)
        let h = host("H"), i = host("I")
        let size = controller.overlayContentSize
        guard let fh = controller.appWindowFrame(h.pid), let fi = controller.appWindowFrame(i.pid),
              [fh, fi].allSatisfy({ $0.minX >= 0 && $0.maxX <= size.width && $0.maxY <= size.height }) else {
            add("S22", "应用栏圈选退出多个应用", expected: "", actual: "测试应用的图标不在可见区域，无法模拟拖动", .notRun)
            closeOverview(); return
        }
        var targets = [h, i]
        var rect = fh.union(fi).insetBy(dx: 10, dy: 10)
        let hits = model.apps.filter { a in model.appFrames[a.id]?.window.intersects(rect) ?? false }.map(\.id)
        if Set(hits) != Set([h.pid, i.pid]) {
            note("两个测试应用的图标之间夹着别的应用，改为只框选实例 H")
            targets = [h]
            rect = fh.insetBy(dx: 10, dy: 10)
        }
        await controller.simulateDrag(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        let started = await waitUntil(2) { targets.allSatisfy { self.model.appStatuses[$0.pid] != nil } }
        let exited = await waitUntil(10) { targets.allSatisfy { !$0.isRunning } }
        let othersRunning = ["A", "B", "D", "F"].map { host($0) }.allSatisfy(\.isRunning) && (targets.count == 2 || i.isRunning)
        let untouchedUserApps = model.appStatuses.keys.allSatisfy { controller.allowedPIDs?.contains($0) ?? false }
        add("S22", "应用栏圈选：框住的应用依次退出，框外的不受影响",
            expected: "拖出的框碰到的测试应用（\(targets.map(\.instance).joined(separator: "、"))）退出；其他应用不受影响",
            actual: started ? "\(exited ? "已全部退出" : "没有全部退出")；其他测试应用\(othersRunning ? "都在运行" : "有被退出的！")；你的应用\(untouchedUserApps ? "都没有收到退出请求" : "收到了退出请求！")"
                            : "模拟拖动没有触发圈选（可能是系统没有把模拟的鼠标事件交给界面）",
            started && exited && othersRunning && untouchedUserApps ? .pass : .fail)
        closeOverview()
    }

    func scenarioBrowserTabs() async {
        let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        guard FileManager.default.fileExists(atPath: chromeApp.path) else {
            add("S23", "浏览器标签页", expected: "", actual: "本机没有安装 Google Chrome", .notRun); return
        }
        // 1. 另开一个测试用 Chrome：独立的临时资料夹，和你自己的 Chrome 完全分开
        let profile = workDir.appendingPathComponent("chrome-profile")
        let pages = workDir.appendingPathComponent("tabs")
        try? FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        var urls: [String] = []
        for n in 1...5 {
            let f = pages.appendingPathComponent("t\(n).html")
            try? "<html><head><meta charset=utf-8><title>WC标签测试\(n)</title></head><body style='background:#\(["c0392b","27ae60","2980b9","8e44ad","d35400"][n - 1])'><h1>WC标签测试\(n)</h1></body></html>"
                .write(to: f, atomically: true, encoding: .utf8)
            urls.append(f.absoluteString)
        }
        let p = Process()
        p.executableURL = chromeApp.appendingPathComponent("Contents/MacOS/Google Chrome")
        p.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--new-window"] + urls
        do { try p.run() } catch { add("S23", "浏览器标签页", expected: "", actual: "无法启动测试用 Chrome：\(error.localizedDescription)", .notRun); return }
        testChrome = p
        testChromeProfile = profile
        let pid = p.processIdentifier
        controller.allowedPIDs?.insert(pid)
        let up = await waitUntil(20) { self.controller.backend.onScreenWindows().contains { $0.pid == pid && $0.layer == 0 } }
        guard up else { add("S23", "浏览器标签页", expected: "", actual: "测试用 Chrome 的窗口没有出现", .fail); return }
        await wait(2.5) // 等网页加载出标题

        model.closeOnClick = true
        defer { model.closeOnClick = false }
        guard await openOverview(), model.phase == .selecting else { add("S23", "浏览器标签页", expected: "", actual: "总览未打开", .fail); return }
        controller.switchPage(.browserTabs)
        _ = await waitUntil(10) { self.model.tabsPhase != .loading && self.model.tabsPhase != .idle }
        if case .needsPermission = model.tabsPhase {
            note("请在系统弹出的询问中点“好”，允许“扫把”控制 Google Chrome（最多等 60 秒）")
            controller.requestTabsPermission()
            _ = await waitUntil(60) { self.model.tabsPhase == .ready && self.model.browserGroups.contains { $0.pid == pid } }
        }
        await wait(0.8)
        guard model.tabsPhase == .ready, let g = model.browserGroups.first(where: { $0.pid == pid }) else {
            add("S23", "浏览器标签页：点击关闭、圈选关闭", expected: "列出测试 Chrome 的 5 个标签页",
                actual: "没有读到测试 Chrome 的标签页（当前状态：\(model.tabsPhase)）。如果系统询问时没有点“好”，可在 系统设置 › 隐私与安全性 › 自动化 里打开后重试",
                .notRun)
            closeOverview(); return
        }
        let listed = g.tabs.map(\.title)
        if let active = g.tabs.first(where: \.isActive) {
            let previewKey = g.key(active)
            let gotPreview = await waitUntil(8) { self.model.tabPreviews[previewKey]?.url == active.url }
            let otherTabsHaveFakePreview = g.tabs.filter { !$0.isActive }.contains { self.model.tabPreviews[g.key($0)] != nil }
            add("S24", "当前标签页小预览；后台标签不冒用当前画面",
                expected: "测试 Chrome 当前标签有真实静态预览，其他新建后台标签没有伪造的预览；缓存不超过 3 MB",
                actual: "当前标签\(gotPreview ? "已捕获预览" : "没有捕获预览")；后台标签\(otherTabsHaveFakePreview ? "错误出现了预览" : "没有冒用画面")；缓存 \(controller.tabPreviewCache.byteCount) 字节",
                gotPreview && !otherTabsHaveFakePreview && controller.tabPreviewCache.byteCount <= 3 * 1024 * 1024 ? .pass : .fail)
        }
        func key(_ n: Int) -> TabKey? { g.tabs.first { $0.title == "WC标签测试\(n)" }.map { g.key($0) } }
        let userTabsBefore = model.browserGroups.filter { $0.pid != pid }.reduce(0) { $0 + $1.tabs.count }
        var notes = ["列出 \(listed.count) 个标签页"]
        var realMouse = true

        // 2. 点一下关闭第 2 个
        if let k2 = key(2) {
            if let f = controller.tabWindowFrame(k2) {
                await controller.simulateClick(at: CGPoint(x: f.midX, y: f.midY))
                if !(await waitUntil(1.5) { self.model.tabStatuses[k2] != nil }) { realMouse = false; controller.tabClicked(k2) }
            } else { realMouse = false; controller.tabClicked(k2) }
            _ = await waitUntil(5) { self.model.tabStatuses[k2]?.isFinal == true }
        }
        // 3. 框选第 3、4 个（等补位结束后再取位置）
        await wait(1.6)
        var marqueeTargets = [3, 4]
        if let k3 = key(3), let k4 = key(4), let f3 = controller.tabWindowFrame(k3), let f4 = controller.tabWindowFrame(k4) {
            var rect = f3.union(f4).insetBy(dx: 8, dy: 8)
            let hits = model.tabFrames.filter { $0.value.window.intersects(rect) }.map(\.key)
            if Set(hits) != Set([k3, k4]) { marqueeTargets = [3]; rect = f3.insetBy(dx: 8, dy: 8); notes.append("3、4 之间夹着别的标签页，改为只框选 3") }
            await controller.simulateDrag(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
            if !(await waitUntil(1.5) { self.model.tabStatuses[k3] != nil }) {
                realMouse = false
                controller.tabMarqueeFinished(marqueeTargets.compactMap { key($0) })
            }
            _ = await waitUntil(6) { marqueeTargets.compactMap { key($0) }.allSatisfy { self.model.tabStatuses[$0]?.isFinal == true } }
        }
        // 4. 用浏览器自己报告的标签页核对
        await wait(0.5)
        var remaining: [String] = []
        if case .success(let wins) = controller.tabsBackend.windows(pid: pid), let w = wins.first(where: { $0.id == g.windowID }) {
            remaining = w.tabs.map(\.title)
        }
        let closedSet = [2] + marqueeTargets
        let expectedRemaining = (1...5).filter { !closedSet.contains($0) }.map { "WC标签测试\($0)" }
        let userTabsUntouched = model.tabStatuses.keys.allSatisfy { $0.pid == pid }
        notes.append("关闭后浏览器里剩下：\(remaining.joined(separator: "、"))")
        // 5. 按网站分组：测试页面都是本地文件，应归到“本地文件”一组
        let previousGrouping = model.tabGrouping
        await wait(1.5)
        model.tabGrouping = .bySite
        let localGroup = model.displayGroups.first { $0.title == BrowserTabSupport.localFilesName }
        let localTitles = Set((localGroup?.items ?? []).filter { $0.key.pid == pid && !model.vanishedTabs.contains($0.key) }.map(\.tab.title))
        let siteOK = localTitles == Set(expectedRemaining)
        notes.append("按网站分组：“本地文件”组里有 \(localTitles.count) 个测试标签页\(siteOK ? "，与实际一致" : "，与实际不符！")")
        model.tabGrouping = previousGrouping
        let pass = Set(remaining) == Set(expectedRemaining) && userTabsUntouched && listed.count == 5 && siteOK
        add("S23", "浏览器标签页：点击关闭、圈选关闭（独立的测试用 Chrome）",
            expected: "点一下关掉“WC标签测试2”，框选关掉 \(marqueeTargets.map { "“WC标签测试\($0)”" }.joined(separator: "、"))；其余标签页还在；你自己 Chrome 的 \(userTabsBefore) 个标签页不受影响",
            actual: notes.joined(separator: "；") + "；你自己的标签页\(userTabsUntouched ? "没有收到任何关闭请求" : "收到了关闭请求！")" +
                (realMouse ? "（使用真实鼠标事件）" : "（模拟鼠标未生效，改为直接调用点击处理）"),
            pass ? .pass : .fail)
        closeOverview()
    }

    // MARK: 收尾

    func cleanup() async {
        if let p = previousCloseOnClick { model.closeOnClick = p }
        if let c = testChrome, c.isRunning {
            // 只结束自检自己启动的那个测试用 Chrome（独立的临时资料夹），不会碰你的 Chrome
            NSRunningApplication(processIdentifier: c.processIdentifier)?.terminate()
            _ = await waitUntil(5) { !c.isRunning }
            if c.isRunning { c.terminate() }
        }
        if let dir = testChromeProfile { try? FileManager.default.removeItem(at: dir) }
        controller.pauseHandler = nil
        controller.allowedPIDs = nil
        closeOverview()
        for h in hosts.values where h.isRunning { h.send("shutdown") }
        _ = await waitUntil(3) { self.hosts.values.allSatisfy { !$0.isRunning } }
        try? FileManager.default.removeItem(at: workDir)
        note("测试应用已全部自行退出，临时文件已删除。")
    }

    func finish() {
        vm.running = false
        onFinish?()
        writeReport()
        NSApp.unhide(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func writeReport() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let f2 = DateFormatter()
        f2.locale = Locale(identifier: "en_US_POSIX")
        f2.dateFormat = "yyyyMMdd-HHmmss"
        var md = "# 扫把 自检报告\n\n"
        md += "- 时间：\(f.string(from: Date()))\n"
        md += "- 系统：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        md += "- 应用：\(Bundle.main.bundlePath)\n"
        md += "- 辅助功能：\(Permissions.accessibility ? "已授权" : "未授权")；屏幕录制：\(Permissions.screenRecording ? "已授权" : "未授权")\n"
        md += "- 显示器：\(NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: "，"))\n\n"
        let pass = vm.rows.filter { $0.verdict == .pass }.count
        let fail = vm.rows.filter { $0.verdict == .fail }.count
        let notRun = vm.rows.filter { $0.verdict == .notRun }.count
        md += "**结果：通过 \(pass) 项，未通过 \(fail) 项，未执行 \(notRun) 项。**\n\n"
        md += "| 编号 | 场景 | 预期 | 实际 | 结论 |\n|---|---|---|---|---|\n"
        for r in vm.rows {
            let esc = { (s: String) in s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            md += "| \(r.code) | \(esc(r.name)) | \(esc(r.expected)) | \(esc(r.actual)) | \(r.verdict.rawValue) |\n"
        }
        md += "\n## 过程记录\n\n" + vm.log.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
        let url = reportDir.appendingPathComponent("自检报告-\(f2.string(from: Date())).md")
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            vm.reportPath = url.path
            note("报告已保存：\(url.path)")
        } catch {
            note("报告保存失败：\(error.localizedDescription)")
        }
    }

    func showWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "扫把 · 自检"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SelfTestView(vm: vm))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }
}

struct SelfTestView: View {
    @ObservedObject var vm: SelfTestViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("扫把 · 自检").font(.title2.bold())
                if vm.running { ProgressView().controlSize(.small); Text("进行中，请不要操作鼠标键盘…").foregroundStyle(.secondary) }
                Spacer()
            }
            Text("自检只操作“WC测试应用”打开的测试窗口，不会碰你自己的窗口。")
                .font(.caption).foregroundStyle(.secondary)
            List(vm.rows) { r in
                HStack(alignment: .top) {
                    Text(r.verdict.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(r.verdict == .pass ? .green : r.verdict == .fail ? .red : .secondary)
                        .frame(width: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.code) \(r.name)").font(.system(size: 13, weight: .semibold))
                        Text(r.actual).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if let p = vm.reportPath {
                HStack {
                    Text("报告：\(p)").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    Button("关闭自检窗口") { NSApp.keyWindow?.close() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 480)
    }
}
