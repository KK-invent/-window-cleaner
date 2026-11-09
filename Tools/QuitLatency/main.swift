// 退出耗时检查：只启动、退出本工具自己的测试进程，绝不选择已有应用。
// 编译时加 -D LEGACY 可与旧 QuitExecutor 对照。
import AppKit
import ApplicationServices

final class LatencyHost: NSObject, NSApplicationDelegate {
    let delay: Double
    let state: URL
    var window: NSWindow?

    init(delay: Double, state: URL) { self.delay = delay; self.state = state }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 140, width: 380, height: 220),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "WC 退出耗时测试（没有工作内容）"
        w.isReleasedWhenClosed = false
        w.orderFront(nil)
        window = w
        try? "ready".write(to: state, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(2) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let request = Date().timeIntervalSince1970
        try? "request=\(request)".write(to: state, atomically: true, encoding: .utf8)
        if delay == 0 { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

final class Measurement: @unchecked Sendable {
    let lock = NSLock()
    private var value: (String, Double, String)?
    func store(_ item: (String, Double, String)) { lock.lock(); value = item; lock.unlock() }
    func read() -> (String, Double, String)? { lock.lock(); defer { lock.unlock() }; return value }
}

@main enum QuitLatency {
    static func main() throws {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        if args.count == 4, args[1] == "--host" {
            let host = LatencyHost(delay: Double(args[2])!, state: URL(fileURLWithPath: args[3]))
            app.setActivationPolicy(.regular)
            app.delegate = host
            withExtendedLifetime(host) { app.run() }
            return
        }
        guard args.count == 2 else { fatalError("用法：QuitLatency <报告目录>") }
        app.setActivationPolicy(.accessory)
        let out = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #if LEGACY
        let version = "旧版"
        #else
        let version = "新版"
        #endif
        print("\(version) / 辅助功能权限：\(AXIsProcessTrusted())")
        var report: [String] = []
        for (index, delay) in [0.0, 0.08, 0.65, 1.5].enumerated() {
            let state = out.appendingPathComponent("\(version)-\(index).txt")
            try? FileManager.default.removeItem(at: state)
            let host = Process()
            host.executableURL = Bundle.main.executableURL!
            host.arguments = ["--host", String(delay), state.path]
            try host.run()
            let readyDeadline = Date().addingTimeInterval(8)
            while !FileManager.default.fileExists(atPath: state.path), host.isRunning, Date() < readyDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            guard FileManager.default.fileExists(atPath: state.path), host.isRunning else {
                throw NSError(domain: "QuitLatency", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试宿主未就绪"])
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let pid = host.processIdentifier
            let measurement = Measurement()
            DispatchQueue.global(qos: .userInitiated).async {
                let e = QuitExecutor(backend: LiveBackend())
                e.allowedPIDs = [pid]
                let t0 = ProcessInfo.processInfo.systemUptime
                let result = e.attempt(QuitTarget(pid: pid, appName: "WC退出耗时测试"))
                let elapsed = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                #if LEGACY
                let detail = ""
                #else
                let detail = e.lastTiming.text
                #endif
                measurement.store((result.status.detail, elapsed, detail))
            }
            let end = Date().addingTimeInterval(12)
            while measurement.read() == nil, Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            guard let (result, ms, detail) = measurement.read() else {
                throw NSError(domain: "QuitLatency", code: 2, userInfo: [NSLocalizedDescriptionKey: "测量超时"])
            }
            let line = String(format: "宿主延时 %.0fms；退出观察 %.0fms；%@；%@", delay * 1000, ms, result, detail)
            print(line)
            report.append(line)
            let exitDeadline = Date().addingTimeInterval(2)
            while host.isRunning, Date() < exitDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            guard !host.isRunning else { throw NSError(domain: "QuitLatency", code: 3) }
        }
        try report.joined(separator: "\n").write(to: out.appendingPathComponent("退出耗时-\(version).txt"), atomically: true, encoding: .utf8)
    }
}
