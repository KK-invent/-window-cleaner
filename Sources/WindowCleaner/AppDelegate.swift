import AppKit

@main
enum WindowCleanerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = OverviewController()
    var selfTest: SelfTestRunner?
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let ms = TimingLog.msSinceProcessStart() { TimingLog.append("launch didFinishLaunching=\(Int(ms))ms(从进程启动算起)") }
        buildMenu()
        launched = true
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            startSelfTest(arguments: args)
            return
        }
        controller.show(reason: "启动")
    }

    func startSelfTest(arguments: [String]) {
        guard selfTest == nil, !controller.isBusy else { return }
        controller.dismiss(hideApp: false)
        let runner = SelfTestRunner(controller: controller, arguments: arguments)
        runner.onFinish = { [weak self] in self?.selfTest = nil }
        selfTest = runner
        runner.start()
    }

    /// 右键 Dock 图标的菜单
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let show = NSMenuItem(title: "显示窗口总览", action: #selector(showOverview), keyEquivalent: "")
        show.target = self
        m.addItem(show)
        let test = NSMenuItem(title: "运行自检（只操作测试窗口）", action: #selector(runSelfTest), keyEquivalent: "")
        test.target = self
        test.isEnabled = selfTest == nil
        m.addItem(test)
        return m
    }

    @objc func runSelfTest() {
        startSelfTest(arguments: CommandLine.arguments)
    }

    /// 应用已在运行时再次点击 Dock 图标（或在访达里再次双击）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard selfTest == nil else { return false }
        controller.show(reason: "再次点击图标")
        return false
    }

    /// 通过 Cmd-Tab 等方式切换到本应用时，也唤出总览
    func applicationDidBecomeActive(_ notification: Notification) {
        guard launched, selfTest == nil else { return }
        // 自检报告窗口开着时，切回本应用是为了看报告，不自动弹出总览
        if NSApp.windows.contains(where: { $0.isVisible && $0.title == "窗口清理 · 自检" }) { return }
        if !controller.isOverlayVisible && !controller.isBusy && !controller.isWaitingForPermission {
            controller.show(reason: "切换到本应用")
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard selfTest == nil else { return }
        controller.didResignActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu(title: "窗口清理")
        m.addItem(withTitle: "关于窗口清理", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let show = NSMenuItem(title: "显示窗口总览", action: #selector(showOverview), keyEquivalent: "o")
        show.target = self
        m.addItem(show)
        m.addItem(.separator())
        m.addItem(withTitle: "隐藏窗口清理", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "退出窗口清理", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    @objc func showOverview() {
        controller.show(reason: "菜单")
    }
}
