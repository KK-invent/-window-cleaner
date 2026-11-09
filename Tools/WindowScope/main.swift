// 公开窗口接口范围检查。默认只输出数量；--selftest 创建自己的普通/全屏窗口，不操作用户窗口。
// 用法：WindowScope --selftest <报告目录> <扫把可执行文件>
import AppKit
import ScreenCaptureKit
import ApplicationServices

final class ScopeHost: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let stateURL: URL
    let fullscreen: Bool
    var window: NSWindow?
    var finishing = false
    init(stateURL: URL, fullscreen: Bool) { self.stateURL = stateURL; self.fullscreen = fullscreen }

    func save() {
        guard let w = window else { return }
        let info: [String: Any] = ["id": w.windowNumber, "pid": getpid(), "fullscreen": w.styleMask.contains(.fullScreen),
                                   "hidden": NSApp.isHidden, "minimized": w.isMiniaturized, "visible": w.isVisible]
        try? JSONSerialization.data(withJSONObject: info).write(to: stateURL, options: .atomic)
    }
    func applicationDidFinishLaunching(_ n: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 150, y: 190, width: 580, height: 380),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "WC窗口范围测试 — " + (fullscreen ? "全屏" : "普通")
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.fullScreenPrimary]
        w.delegate = self
        let label = NSTextField(labelWithString: "扫把的专用测试窗口\n没有真实工作内容")
        label.font = .systemFont(ofSize: 24)
        label.alignment = .center
        w.contentView = label
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        save()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(command(_:)),
            name: Notification.Name("local.windowcleaner.scope-test"), object: String(getpid()), suspensionBehavior: .deliverImmediately)
        if fullscreen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.toggleFullScreen(nil) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.finish() }
    }
    func windowDidEnterFullScreen(_ notification: Notification) { save() }
    func windowDidExitFullScreen(_ notification: Notification) {
        save()
        if finishing { window?.close(); NSApp.terminate(nil) }
    }
    func finish() {
        if finishing { return }
        finishing = true
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        else { window?.close(); NSApp.terminate(nil) }
    }
    @objc func command(_ notification: Notification) {
        switch notification.userInfo?["action"] as? String {
        case "activate": NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        case "hide": NSApp.hide(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.save() }
        case "minimize": window?.miniaturize(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.save() }
        case "retainClosed": window?.close(); save() // 保留窗口对象，验证不能把它重新列出来。
        case "finish": finish()
        default: break
        }
    }
}

@main enum WindowScopeProbe {
    static func state(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
    static func send(_ pid: pid_t, _ action: String) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.windowcleaner.scope-test"),
            object: String(pid), userInfo: ["action": action], deliverImmediately: true)
    }
    static func counts() async {
        for (label, options): (String, CGWindowListOption) in [("当前屏幕", [.optionOnScreenOnly, .excludeDesktopElements]), ("全部", [.optionAll, .excludeDesktopElements])] {
            let normal = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            print("CG \(label)：普通层窗口 \(normal.count)，不在当前屏幕 \(normal.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) != true }.count)")
        }
        for visible in [true, false] {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: visible)
                let normal = content.windows.filter { $0.windowLayer == 0 }
                print("ScreenCaptureKit onlyVisible=\(visible)：普通层窗口 \(normal.count)，不在当前屏幕 \(normal.filter { !$0.isOnScreen }.count)")
            } catch { print("ScreenCaptureKit：\(error.localizedDescription)") }
        }
    }

    @MainActor static func main() async throws {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--host" {
            let delegate = ScopeHost(stateURL: URL(fileURLWithPath: args[3]), fullscreen: args[2] == "fullscreen")
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        app.setActivationPolicy(.accessory)
        guard args.count == 4, args[1] == "--selftest" else { await counts(); return }
        let out = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var hosts: [(Process, URL)] = []
        for kind in ["normal", "fullscreen", "hidden", "minimized", "retained"] {
            let file = out.appendingPathComponent(kind + ".json")
            try? FileManager.default.removeItem(at: file)
            let p = Process()
            p.executableURL = Bundle.main.executableURL!
            p.arguments = ["--host", kind, file.path]
            try p.run()
            hosts.append((p, file))
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let s = state(file)
                if s["id"] != nil && (kind == "normal" || s["fullscreen"] as? Bool == true) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { for (host, _) in hosts where host.isRunning { send(host.processIdentifier, "finish") } }
        var lines: [String] = []
        let fullscreenReady = state(hosts[1].1)["fullscreen"] as? Bool == true
        lines.append("测试宿主已进入全屏：\(fullscreenReady)")
        // 让普通测试宿主回到前面；不激活或移动用户应用，也不依赖桌面编号。
        send(hosts[0].0.processIdentifier, "activate")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        send(hosts[2].0.processIdentifier, "hide")
        send(hosts[3].0.processIdentifier, "minimize")
        send(hosts[4].0.processIdentifier, "retainClosed")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let ids = Set(hosts.prefix(2).compactMap { (state($0.1)["id"] as? NSNumber)?.uint32Value })
        let normalID = (state(hosts[0].1)["id"] as? NSNumber)?.uint32Value
        let fullID = (state(hosts[1].1)["id"] as? NSNumber)?.uint32Value
        let cg = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for (name, id) in [("普通", normalID), ("全屏", fullID)] {
            let w = cg.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
            lines.append("\(name)测试窗口：CG全部列表中=\(w != nil)，当前屏幕上=\((w?[kCGWindowIsOnscreen as String] as? Bool) ?? false)")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            for window in content.windows where ids.contains(window.windowID) {
                lines.append("测试窗口 \(window.windowID)：ScreenCaptureKit active=\(window.isActive)，onScreen=\(window.isOnScreen)")
                let config = SCStreamConfiguration()
                config.width = 320; config.height = 200; config.capturesAudio = false
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                do {
                    _ = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    lines.append("测试窗口 \(window.windowID)：预览成功（仅在内存，没有保存图片）")
                } catch { lines.append("测试窗口 \(window.windowID)：预览失败 \(error.localizedDescription)") }
            }
        } catch { lines.append("ScreenCaptureKit读取失败：\(error.localizedDescription)") }
        let reportFile = out.appendingPathComponent("app-scope.json")
        let diagnosis = Process()
        diagnosis.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let candidateBundle = URL(fileURLWithPath: args[3]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        diagnosis.arguments = ["-n", "-W", candidateBundle.path, "--args", "--window-scope-report", reportFile.path]
        try diagnosis.run()
        while diagnosis.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        let report = state(reportFile)
        lines.append("扫把诊断辅助功能权限：\(report["accessibility"] ?? "未知")")
        let entries = report["entries"] as? [[String: Any]] ?? []
        for id in ids.sorted() {
            let e = entries.first { ($0["id"] as? NSNumber)?.uint32Value == id }
            lines.append("测试窗口 \(id)：应用全部桌面列表中=\(e != nil)，可唯一关闭=\(e?["closable"] ?? false)")
        }
        for (index, name) in [(2, "已隐藏"), (3, "已最小化"), (4, "已关闭但对象保留")] {
            let host = hosts[index]
            let s = state(host.1)
            let listed = entries.contains { ($0["pid"] as? NSNumber)?.int32Value == host.0.processIdentifier }
            lines.append("\(name)测试宿主：hidden=\(s["hidden"] ?? false) minimized=\(s["minimized"] ?? false) visible=\(s["visible"] ?? false)；出现在扫把列表中=\(listed)")
        }
        let text = lines.joined(separator: "\n")
        print(text)
        try text.write(to: out.appendingPathComponent("范围检查.txt"), atomically: true, encoding: .utf8)
        for (host, _) in hosts where host.isRunning { send(host.processIdentifier, "finish") }
        for _ in 0..<40 {
            if hosts.allSatisfy({ !$0.0.isRunning }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("测试进程已退出：\(hosts.allSatisfy { !$0.0.isRunning })")
    }
}
