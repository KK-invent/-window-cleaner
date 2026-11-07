// 玻璃效果预览（仅开发用）：在屏幕上临时显示演示数据的总览，换几种背景方案并截图对比。
import AppKit
import SwiftUI

@MainActor
func demoModel(page: OverviewPage) -> OverviewModel {
    let m = OverviewModel()
    m.axTrusted = true; m.screenRecording = true; m.closeOnClick = true
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(8)
    let sizes: [NSSize] = [NSSize(width: 640, height: 400), NSSize(width: 420, height: 560), NSSize(width: 720, height: 360),
                           NSSize(width: 520, height: 520), NSSize(width: 640, height: 420), NSSize(width: 600, height: 380)]
    let titles = ["产品需求文档 v3", "未命名", "下载", "2026 年度预算.numbers", "设计稿评审记录", "会议纪要 11-06"]
    let realApps = Array(apps)
    m.entries = titles.enumerated().map { i, t in
        let a = realApps[i % max(realApps.count, 1)]
        return WindowEntry(id: CGWindowID(1000 + i), pid: a.processIdentifier, appName: a.localizedName ?? "应用", bundleID: a.bundleIdentifier,
                    title: t, bounds: CGRect(origin: .zero, size: sizes[i]), closability: i == 4 ? .blocked("无法唯一确认：同应用有位置、大小和标题都相同的窗口") : .closable,
                    isBrowser: a.bundleIdentifier == "com.google.Chrome", isOnlyWindowOfApp: false, zIndex: i)
    }
    for i in 0..<6 {
        let sz = sizes[i]
        let img = NSImage(size: sz)
        img.lockFocus()
        NSColor(calibratedHue: CGFloat(i) / 6, saturation: 0.18, brightness: 0.97, alpha: 1).setFill()
        NSRect(origin: .zero, size: sz).fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: sz.height - 26, width: sz.width, height: 26).fill()
        for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() { c.setFill(); NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(j) * 18, y: sz.height - 19, width: 12, height: 12)).fill() }
        NSColor(calibratedHue: CGFloat(i) / 6, saturation: 0.45, brightness: 0.75, alpha: 1).setFill()
        for r in 0..<6 { NSRect(x: 30, y: sz.height - 70 - CGFloat(r) * 40, width: CGFloat(140 + (r % 3) * 70), height: 14).fill() }
        img.unlockFocus()
        m.thumbnails[CGWindowID(1000 + i)] = img
    }
    m.hoveredID = nil
    m.apps = apps.enumerated().map { i, a in
        AppEntry(id: a.processIdentifier, name: a.localizedName ?? "应用", bundleID: a.bundleIdentifier, icon: a.icon ?? NSImage(), windowCount: i < 3 ? 1 : 0, isHidden: false)
    }
    if m.apps.count > 3 { m.appMarqueeIDs = [m.apps[2].id, m.apps[3].id] }
    m.marqueeIDs = [1002, 1003]
    m.marqueeActive = true
    m.marquee.rect = CGRect(x: 430, y: 300, width: 400, height: 420)
    m.page = page
    m.tabsPhase = .ready
    let chrome = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.google.Chrome" }
    let sites = [("GitHub - apple/swift", "https://github.com/apple/swift"), ("Google 翻译", "https://translate.google.com/"),
                 ("哔哩哔哩", "https://www.bilibili.com/"), ("知乎", "https://www.zhihu.com/"), ("YouTube", "https://www.youtube.com/"),
                 ("百度一下", "https://www.baidu.com/"), ("微博", "https://weibo.com/"), ("新标签页", "chrome://newtab/"),
                 ("Gmail", "https://mail.google.com/mail/u/0/"), ("淘宝网", "https://www.taobao.com/")]
    let pid = chrome?.processIdentifier ?? 1
    m.browserGroups = [BrowserGroup(pid: pid, appName: "Google Chrome", windowID: "w1", title: "GitHub - apple/swift", cardID: 1000,
                                    tabs: sites.enumerated().map { BrowserTab(id: "\($0.offset)", title: $0.element.0, url: $0.element.1, isActive: $0.offset == 0) })]
    m.phase = .selecting
    m.timingText = "演示数据"
    return m
}

@main
enum GlassPreview {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let out = CommandLine.arguments[1]
        let screen = NSScreen.main!.frame
        let size = NSSize(width: 1280, height: 800)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        let variants: [(String, NSVisualEffectView.Material, Double, OverviewPage)] = [
            ("卡片-新样式", .hudWindow, 0.12, .windows),
        ]
        // 网站图标（与应用相同的读取方式）
        let store = FaviconStore()
        for (name, material, tint, page) in variants {
            OverlayStyle.material = material
            OverlayStyle.tint = tint
            let m = demoModel(page: page)
            m.favicons = store.load(urls: m.browserGroups.flatMap { $0.tabs.map(\.url) }, bundleID: "com.google.Chrome")
            let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = .floating; w.hasShadow = true
            let host = NSHostingView(rootView: OverviewRoot(model: m, actions: OverviewActions()))
            host.sizingOptions = []
            w.contentView = host
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // 按屏幕区域截图，才能看到背后桌面被模糊后的真实效果
            let primaryH = NSScreen.screens[0].frame.height
            let r = "\(Int(frame.minX)),\(Int(primaryH - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
            p.arguments = ["-x", "-R", r, "\(out)/\(name).png"]
            try? p.run(); p.waitUntilExit()
            w.orderOut(nil)
            print("→", name)
        }
    }
}
