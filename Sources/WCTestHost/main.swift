// WC 测试宿主：只用于“扫把”的自检。
// 它按配置打开一批带编号、标题和底色的测试窗口，并把自己窗口的真实状态（窗口编号、是否已关闭、
// 收到过哪些关闭请求）写进状态文件，自检程序据此核对“选中的窗口确实就是被关掉的那个”。
//
// 用法：WCTestHost --config /path/config.json
import AppKit

struct WindowSpec: Codable {
    var label: String
    var title: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var color: String
    /// 未保存文档：关闭时由 AppKit 弹出标准的“是否保存更改”表单
    var dirty: Bool?
    /// normal | modal（弹出独立确认对话框）| refuse（拒绝关闭）| slow:N（关闭前卡 N 秒）
    var closeBehavior: String?
    /// 模拟“用户”在确认框里的选择：cancel | dontsave；为空则一直等待
    var autoResponse: String?
    var autoResponseDelay: Double?
    /// standard | fullsize | panel | toolbar | borderless
    var style: String?
    /// 关闭窗口出现动画（用于排查动画对窗口边界的影响）
    var noAnimation: Bool?
}

struct HostConfig: Codable {
    var instance: String
    var statePath: String
    var windows: [WindowSpec]
    var quitAfterLastWindow: Bool?
    var lifetimeSeconds: Double?
    /// 收到退出请求后先“收尾” N 秒再退出（模拟飞书等退出较慢的应用）
    var quitDelay: Double?
}

struct WindowState: Codable {
    var label: String
    var title: String
    var number: Int
    var frame: [Double]
    var color: String
    var open: Bool
    var dirty: Bool
    /// 本进程内 NSWindow.frame（全局左上角坐标）
    var nsFrame: [Double]?
    /// 本进程内 AppKit 提供给辅助功能客户端的位置/尺寸（accessibilityFrame）
    var axFrame: [Double]?
}

struct HostEvent: Codable {
    var t: Double
    var event: String
    var label: String?
}

struct HostState: Codable {
    var pid: Int32
    var instance: String
    var windows: [WindowState]
    var events: [HostEvent]
}

func color(hex: String) -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0x808080
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// 全局坐标（原点在主显示器左上角）→ AppKit 坐标（原点在左下角）
func cocoaFrame(_ s: WindowSpec) -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
    return NSRect(x: s.x, y: primaryHeight - s.y - s.h, width: s.w, height: s.h)
}

func makeWindow(_ s: WindowSpec) -> NSWindow {
    let rect = NSRect(x: 0, y: 0, width: s.w, height: s.h)
    let std: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    switch s.style ?? "standard" {
    case "fullsize":
        let w = NSWindow(contentRect: rect, styleMask: std.union(.fullSizeContentView), backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        return w
    case "panel":
        return NSPanel(contentRect: rect, styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
    case "toolbar":
        let w = NSWindow(contentRect: rect, styleMask: std.union(.fullSizeContentView), backing: .buffered, defer: false)
        let tb = NSToolbar(identifier: "wc")
        w.toolbar = tb
        w.toolbarStyle = .unified
        return w
    case "borderless":
        return NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    default:
        return NSWindow(contentRect: rect, styleMask: std, backing: .buffered, defer: false)
    }
}

func makeContentView(_ s: WindowSpec) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = color(hex: s.color).cgColor
    let label = NSTextField(labelWithString: "\(s.label)\n\(s.title)")
    label.font = .boldSystemFont(ofSize: 28)
    label.textColor = .white
    label.alignment = .center
    label.maximumNumberOfLines = 3
    label.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(label)
    NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
        label.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
    ])
    return v
}

final class Host: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var config: HostConfig
    var specs: [String: WindowSpec] = [:]
    var windows: [String: NSWindow] = [:]
    var documents: [String: TestDocument] = [:]
    var closedLabels: Set<String> = []
    var order: [String] = []
    var events: [HostEvent] = []
    let start = Date()

    init(config: HostConfig) {
        self.config = config
    }

    func log(_ e: String, _ label: String? = nil) {
        events.append(HostEvent(t: Date().timeIntervalSince(start), event: e, label: label))
        writeState()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        for s in config.windows { open(s) }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: Notification.Name("local.windowcleaner.testhost.command"),
            object: config.instance, suspensionBehavior: .deliverImmediately)
        let life = config.lifetimeSeconds ?? 900
        DispatchQueue.main.asyncAfter(deadline: .now() + life) { exit(0) }
        log("ready")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let delay = config.quitDelay, delay > 0 else { return .terminateNow }
        log("quitDelay")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        config.quitAfterLastWindow ?? false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ n: Notification) { log("terminating") }

    func open(_ s: WindowSpec) {
        specs[s.label] = s
        if !order.contains(s.label) { order.append(s.label) }
        closedLabels.remove(s.label)
        let window: NSWindow
        if s.dirty == true {
            let doc = TestDocument(spec: s, host: self)
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.updateChangeCount(.changeDone)
            documents[s.label] = doc
            window = doc.windowControllers[0].window!
        } else {
            window = makeWindow(s)
            window.isReleasedWhenClosed = false
            window.title = s.title
            window.contentView = makeContentView(s)
            window.delegate = self
        }
        window.isRestorable = false
        if s.noAnimation == true { window.animationBehavior = .none }
        window.setFrame(cocoaFrame(s), display: true)
        window.identifier = NSUserInterfaceItemIdentifier(s.label)
        windows[s.label] = window
        window.orderFront(nil)
        if s.dirty == true {
            NotificationCenter.default.addObserver(self, selector: #selector(sheetWillBegin(_:)),
                                                   name: NSWindow.willBeginSheetNotification, object: window)
        }
        log("opened", s.label)
    }

    func label(of w: NSWindow) -> String? { w.identifier?.rawValue }

    // MARK: 关闭行为

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let l = label(of: sender), let s = specs[l] else { return true }
        log("shouldClose", l)
        let behavior = s.closeBehavior ?? "normal"
        if behavior == "refuse" {
            log("refused", l)
            return false
        }
        if behavior.hasPrefix("slow:") {
            let secs = Double(behavior.dropFirst(5)) ?? 3
            Thread.sleep(forTimeInterval: secs)
            return true
        }
        if behavior == "modal" {
            let alert = NSAlert()
            alert.messageText = "关闭“\(s.title)”之前确认（测试对话框）"
            alert.informativeText = "这是 WC 测试宿主模拟的应用确认框。"
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            log("modalShown", l)
            if let resp = s.autoResponse {
                let timer = Timer(timeInterval: s.autoResponseDelay ?? 2, repeats: false) { [weak self] _ in
                    self?.log("autoResponse:\(resp)", l)
                    alert.buttons[resp == "cancel" ? 1 : 0].performClick(nil)
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .modalPanel)
            }
            let r = alert.runModal()
            let ok = r == .alertFirstButtonReturn
            log(ok ? "modalConfirmed" : "modalCancelled", l)
            return ok
        }
        return true
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let l = label(of: w) else { return }
        markClosed(l)
    }

    func markClosed(_ l: String) {
        closedLabels.insert(l)
        log("closed", l)
        // 释放窗口，让窗口服务器真正销毁它
        DispatchQueue.main.async { [weak self] in
            self?.windows[l] = nil
            self?.documents[l] = nil
            self?.writeState()
        }
    }

    // 模拟用户在“是否保存”表单里的选择（只作用于本测试宿主自己的表单）
    @objc func sheetWillBegin(_ n: Notification) {
        guard let w = n.object as? NSWindow, let l = label(of: w), let s = specs[l] else { return }
        log("sheetShown", l)
        guard let resp = s.autoResponse else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (s.autoResponseDelay ?? 1.5)) { [weak self] in
            guard let sheet = w.attachedSheet else {
                self?.log("autoResponseFailed:\(resp) sheet=false", l)
                return
            }
            self?.respond(to: w, sheet: sheet, resp: resp, label: l)
        }
    }

    func respond(to w: NSWindow, sheet: NSWindow, resp: String, label l: String) {
        do { // 先找普通按钮；新版系统的提示框改用辅助功能按钮或结束表单
            guard let button = Self.findButton(in: sheet.contentView, response: resp) else {
                // 新版系统的提示框按钮可能不是 NSButton 视图：改从本应用自己的辅助功能树里找按钮按下
                let followUp = {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        self.log(w.attachedSheet == nil ? "sheetGone" : "sheetStillOpen", l)
                    }
                }
                if let element = Self.findAXButton(in: sheet, response: resp, depth: 0), element.accessibilityPerformPress() {
                    self.log("autoResponse:\(resp)", l)
                    self.log("via:ax", l)
                    followUp()
                    return
                }
                // 新版系统的保存提示按钮不在本进程视图树里：由测试应用结束自己的表单，
                // 返回值与用户点按钮相同（存储=第一个，取消=第二个，不存储=第三个）
                w.endSheet(sheet, returnCode: resp == "cancel" ? .alertSecondButtonReturn : .alertThirdButtonReturn)
                self.log("autoResponse:\(resp)", l)
                self.log("via:endSheet", l)
                followUp()
                return
            }
            self.log("autoResponse:\(resp)", l)
            button.performClick(nil)
        }
    }

    static func findAXButton(in element: Any, response: String, depth: Int) -> NSAccessibilityProtocol? {
        guard depth < 12, let e = element as? NSAccessibilityProtocol else { return nil }
        let roleFn: (() -> NSAccessibility.Role?)? = e.accessibilityRole
        let role = roleFn?() ?? nil
        if role == .button {
            let titleFn: (() -> String?)? = e.accessibilityTitle
            let labelFn: (() -> String?)? = e.accessibilityLabel
            let title = titleFn?() ?? nil
            let label = labelFn?() ?? nil
            let t = ((title ?? "") + " " + (label ?? "")).lowercased()
            let hit = response == "cancel" ? (t.contains("cancel") || t.contains("取消"))
                : (t.contains("don") || t.contains("不存储") || t.contains("不保存") || t.contains("delete") || t.contains("删除"))
            if hit { return e }
        }
        let childrenFn: (() -> [Any]?)? = e.accessibilityChildren
        let children = childrenFn?() ?? nil
        for child in children ?? [] {
            if let found = findAXButton(in: child, response: response, depth: depth + 1) { return found }
        }
        return nil
    }

    static func buttonTitles(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var out: [String] = []
        if let b = view as? NSButton { out.append("\(b.title)[\(b.keyEquivalent == "\u{1b}" ? "esc" : b.keyEquivalent)]") }
        for sub in view.subviews { out += buttonTitles(in: sub) }
        return out
    }

    static func findButton(in view: NSView?, response: String) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton {
            let t = b.title.lowercased()
            if response == "cancel" && (b.keyEquivalent == "\u{1b}" || t == "cancel" || t == "取消") { return b }
            if response == "dontsave" && (t.contains("don") || t.contains("不存储") || t.contains("不保存") || t.contains("delete") || t.contains("删除")) { return b }
        }
        for sub in view.subviews {
            if let b = findButton(in: sub, response: response) { return b }
        }
        return nil
    }

    // MARK: 自检程序发来的指令

    @objc func command(_ n: Notification) {
        let info = n.userInfo ?? [:]
        let cmd = info["cmd"] as? String ?? ""
        let l = info["label"] as? String
        switch cmd {
        case "closeWindow":
            if let l, let w = windows[l] {
                log("hostClosesItself", l)
                if let doc = documents[l] { doc.updateChangeCount(.changeCleared); doc.close() } else { w.close() }
            }
        case "openWindow":
            if let json = info["spec"] as? String, let s = try? JSONDecoder().decode(WindowSpec.self, from: Data(json.utf8)) {
                open(s)
            }
        case "hang":
            let secs = Double(info["seconds"] as? String ?? "5") ?? 5
            DispatchQueue.main.async { [weak self] in
                self?.log("hangStart")
                Thread.sleep(forTimeInterval: secs)
                self?.log("hangEnd")
            }
        case "setFrame":
            if let l, let w = windows[l], let f = info["frame"] as? String {
                let v = f.split(separator: ",").compactMap { Double($0) }
                if v.count == 4 {
                    var sp = specs[l]!; sp.x = v[0]; sp.y = v[1]; sp.w = v[2]; sp.h = v[3]; specs[l] = sp
                    w.setFrame(cocoaFrame(sp), display: true, animate: false)
                    log("setFrame", l)
                }
            }
        case "minimize":
            if let l, let w = windows[l] { w.miniaturize(nil); log("minimized", l) }
        case "deminimize":
            if let l, let w = windows[l] { w.deminiaturize(nil); log("deminimized", l) }
        case "hideApp":
            NSApp.hide(nil); log("hidden")
        case "unhideApp":
            NSApp.unhide(nil); log("unhidden")
        case "shutdown":
            // 测试宿主自行退出（不经过保存提示，测试窗口没有真实内容）
            log("shutdown")
            exit(0)
        default:
            break
        }
    }

    func writeState() {
        var list: [WindowState] = []
        for l in order {
            guard let s = specs[l] else { continue }
            let w = windows[l]
            let open = !closedLabels.contains(l) && w != nil
            var frame = [s.x, s.y, s.w, s.h]
            var axFrame: [Double]?
            let ph = NSScreen.screens.first?.frame.height ?? 1080
            if let w, open {
                frame = [w.frame.minX, ph - w.frame.maxY, w.frame.width, w.frame.height]
                let a = w.accessibilityFrame()
                axFrame = [a.minX, ph - a.maxY, a.width, a.height]
            }
            list.append(WindowState(label: l, title: s.title, number: w?.windowNumber ?? -1, frame: frame,
                                    color: s.color, open: open, dirty: documents[l]?.isDocumentEdited ?? false,
                                    nsFrame: frame, axFrame: axFrame))
        }
        let state = HostState(pid: getpid(), instance: config.instance, windows: list, events: events)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: URL(fileURLWithPath: config.statePath), options: .atomic)
        }
    }
}

final class TestDocument: NSDocument {
    let spec: WindowSpec
    weak var host: Host?

    init(spec: WindowSpec, host: Host) {
        self.spec = spec
        self.host = host
        super.init()
        fileType = "public.plain-text"
    }

    override class var autosavesInPlace: Bool { false }
    override var displayName: String! {
        get { spec.title }
        set {}
    }

    override func makeWindowControllers() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: spec.w, height: spec.h),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = makeContentView(spec)
        let wc = TestWindowController(window: window)
        wc.shouldCascadeWindows = false
        addWindowController(wc)
        NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    @objc func willClose(_ n: Notification) {
        host?.markClosed(spec.label)
    }

    override func data(ofType typeName: String) throws -> Data { Data("WC 测试文档".utf8) }
    override func read(from data: Data, ofType typeName: String) throws {}
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        host?.log("shouldClose", spec.label)
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
}

final class TestWindowController: NSWindowController {
    override func windowTitle(forDocumentDisplayName displayName: String) -> String { displayName }
}

// MARK: 启动

let args = CommandLine.arguments
guard let i = args.firstIndex(of: "--config"), i + 1 < args.count,
      let data = FileManager.default.contents(atPath: args[i + 1]),
      let config = try? JSONDecoder().decode(HostConfig.self, from: data) else {
    FileHandle.standardError.write("用法：WCTestHost --config config.json\n".data(using: .utf8)!)
    exit(2)
}
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
let app = NSApplication.shared
let host = Host(config: config)
app.delegate = host
app.setActivationPolicy(.regular)
app.run()
