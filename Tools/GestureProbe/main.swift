// 手势排查（仅开发用）：显示演示总览，向它发送真实的鼠标拖动事件，检查窗口区和应用栏能否识别框选。
import AppKit
import SwiftUI

@MainActor var log: [String] = []

@MainActor
func post(_ w: NSWindow, _ type: NSEvent.EventType, _ p: CGPoint) {
    let h = w.contentView!.bounds.height
    if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: h - p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
        NSApp.postEvent(e, atStart: false)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
}

@MainActor
func drag(_ w: NSWindow, _ a: CGPoint, _ b: CGPoint) {
    post(w, .leftMouseDown, a)
    for i in 1...10 { let t = CGFloat(i) / 10; post(w, .leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
    post(w, .leftMouseUp, b)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@main
enum GestureProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let m = OverviewModel()
        m.axTrusted = true; m.screenRecording = true; m.phase = .selecting; m.closeOnClick = true
        m.entries = (0..<4).map { i in WindowEntry(id: CGWindowID(1000 + i), pid: 1, appName: "演示\(i)", bundleID: nil, title: "演示", bounds: CGRect(x: 0, y: 0, width: 600, height: 400), closability: .closable, isBrowser: false, isOnlyWindowOfApp: false, zIndex: i) }
        m.apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(6).map { AppEntry(id: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: nil, icon: $0.icon ?? NSImage(), windowCount: 0, isHidden: false) }
        var actions = OverviewActions()
        actions.appClicked = { a in log.append("单击应用 \(a.name)") }
        actions.appMarqueeFinished = { list in log.append("应用栏框选 \(list.count) 个") }
        actions.cardClicked = { e in log.append("单击窗口 \(e.appName)") }
        actions.marqueeFinished = { list in log.append("窗口区框选 \(list.count) 个") }
        actions.backgroundClicked = { log.append("点了空白处") }
        let screen = NSScreen.main!.frame
        let w = OverlayWindow(contentRect: NSRect(x: screen.minX + 60, y: screen.minY + 60, width: 1200, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.level = .floating
        let host = FirstMouseHostingView(rootView: OverviewRoot(model: m, actions: actions))
        host.sizingOptions = []
        w.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let cards = m.cardFrames.values.map(\.window).sorted { $0.minX < $1.minX }
        let icons = m.appFrames.values.map(\.window).sorted { $0.minX < $1.minX }
        print("窗口卡片位置 \(cards.count) 个，应用图标位置 \(icons.count) 个；本应用在前台：\(NSApp.isActive)")
        log.append("— 窗口区：框选前两个窗口（对照）")
        if cards.count >= 2 { drag(w, CGPoint(x: cards[0].minX + 10, y: cards[0].minY + 10), CGPoint(x: cards[1].maxX - 10, y: cards[1].maxY - 10)) }
        if icons.count >= 3 {
            log.append("— 单击第 1 个应用图标")
            post(w, .leftMouseDown, CGPoint(x: icons[0].midX, y: icons[0].midY)); post(w, .leftMouseUp, CGPoint(x: icons[0].midX, y: icons[0].midY))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            log.append("— 从第 1 个图标上开始，拖到第 3 个")
            drag(w, CGPoint(x: icons[0].minX + 6, y: icons[0].minY + 6), CGPoint(x: icons[2].maxX - 6, y: icons[2].maxY - 6))
            log.append("— 从底板左侧外面的空白开始，拖到第 3 个")
            drag(w, CGPoint(x: icons[0].minX - 50, y: icons[0].minY - 10), CGPoint(x: icons[2].maxX - 6, y: icons[2].maxY - 6))
        }
        print("窗口是焦点窗口：\(w.isKeyWindow)")
        w.orderOut(nil)
        let text = "本应用在前台：\(NSApp.isActive)\n" + log.joined(separator: "\n")
        print(text)
        if CommandLine.arguments.count > 1 { try? text.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8) }
        exit(0)
    }
}
