// 界面离屏渲染工具（仅用于开发检查排版）：用演示数据把各个界面状态画成 PNG。
// 这里的演示数据只存在于本工具中，主应用不会用到。
import AppKit
import SwiftUI

@MainActor
func fakeThumb(_ w: CGFloat, _ h: CGFloat, hue: CGFloat, title: String) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor(calibratedHue: hue, saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 10, yRadius: 10).fill()
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: h - 28, width: w, height: 28).fill()
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 18, y: h - 20, width: 12, height: 12)).fill()
    }
    (title as NSString).draw(at: NSPoint(x: 70, y: h - 22), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
    NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.7, alpha: 1).setFill()
    for i in 0..<5 { NSRect(x: 20, y: h - 60 - CGFloat(i) * 30, width: w * (0.4 + 0.1 * CGFloat(i % 3)), height: 12).fill() }
    img.unlockFocus()
    return img
}

@MainActor
func render<V: View>(_ view: V, size: NSSize, to path: String) {
    let host = NSHostingView(rootView: ZStack {
        LinearGradient(colors: [Color(red: 0.15, green: 0.25, blue: 0.45), Color(red: 0.45, green: 0.3, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        view
    })
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("→", path)
}

@main
enum UIRender {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let apps: [(String, String?)] = [("Google Chrome", "com.google.Chrome"), ("文本编辑", nil), ("访达", nil), ("备忘录", nil), ("预览", nil), ("Safari浏览器", "com.apple.Safari")]
        let titles = ["产品需求文档 v3 — 最终版（请勿外传）", "未命名", "下载", "2026 年度预算.numbers", "GitHub - apple/swift: The Swift Programming Language — 一个非常长的标题用来测试截断效果", "设计稿评审记录", "WC测试-文档1", "会议纪要 11-06", "照片 IMG_2048.HEIC", ""]

        func makeModel(count: Int, selected: Int, phase: OverviewModel.Phase) -> OverviewModel {
            let m = OverviewModel()
            m.closeOnClick = selected == 0 || phase != .selecting
            m.axTrusted = true; m.screenRecording = true
            var entries: [WindowEntry] = []
            for i in 0..<count {
                let (app, bid) = apps[i % apps.count]
                let blocked = i == 4 ? WindowEntry.Closability.blocked("无法唯一确认：同应用有位置、大小和标题都相同的窗口") : .closable
                entries.append(WindowEntry(id: CGWindowID(1000 + i), pid: pid_t(1 + i % apps.count), appName: app, bundleID: bid,
                                           title: titles[i % titles.count], bounds: .zero, closability: blocked,
                                           isBrowser: bid != nil, isOnlyWindowOfApp: i % apps.count == 3, zIndex: i))
                if i != 7 { m.thumbnails[CGWindowID(1000 + i)] = fakeThumb(i % 3 == 0 ? 900 : 700, i % 4 == 1 ? 700 : 480, hue: CGFloat(i) / CGFloat(count), title: titles[i % titles.count]) }
            }
            m.entries = entries
            // 演示用的应用栏：取本机正在运行的应用图标
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(9)
            m.apps = running.enumerated().map { i, a in
                AppEntry(id: a.processIdentifier, name: ["微信", "Google Chrome", "企业微信", "钉钉", "访达", "备忘录", "Safari浏览器", "音乐", "抖音"][i % 9],
                         bundleID: nil, icon: a.icon ?? NSImage(), windowCount: i < 3 ? 2 - i % 2 : 0, isHidden: i == 6)
            }
            m.phase = phase
            m.selection = entries.filter(\.isClosable).prefix(selected).map { QueueItem.window($0.id) }
            m.timingText = "唤出 21 ms · 列表 48 ms · 缩略图 380 ms（\(count)/\(count)）"
            return m
        }

        let size = NSSize(width: 1512, height: 945)
        render(OverviewRoot(model: makeModel(count: 8, selected: 3, phase: .selecting), actions: OverviewActions()), size: size, to: "\(out)/1-选择-8个窗口.png")
        render(OverviewRoot(model: makeModel(count: 32, selected: 0, phase: .selecting), actions: OverviewActions()), size: size, to: "\(out)/2-选择-32个窗口.png")
        let m3 = makeModel(count: 8, selected: 5, phase: .finished)
        let st: [ItemStatus] = [.closed(ClosedNote.destroyed.text), .closed(ClosedNote.afterUserChoice.text), .skipped(SkipReason.userKeptOpen.text), .failed(FailReason.stillOpen.text), .skipped(SkipReason.appUnresponsive.text)]
        for (i, e) in m3.selectedEntries.enumerated() { m3.statuses[e.id] = st[i] }
        render(OverviewRoot(model: m3, actions: OverviewActions()), size: size, to: "\(out)/3-完成-结果.png")
        let m4 = OverviewModel(); m4.phase = .needsPermission; m4.axTrusted = false; m4.screenRecording = true
        render(OverviewRoot(model: m4, actions: OverviewActions()), size: size, to: "\(out)/4-权限引导.png")
        let m5 = makeModel(count: 5, selected: 2, phase: .running)
        m5.runTotal = 2; m5.runIndex = 1; m5.statuses[m5.selectedEntries[0].id] = .working; m5.statuses[m5.selectedEntries[1].id] = .queued
        render(OverviewRoot(model: m5, actions: OverviewActions()), size: size, to: "\(out)/5-正在关闭.png")
        let m6 = makeModel(count: 3, selected: 2, phase: .paused)
        m6.pauseMessage = "“微信”在退出前弹出了确认框（例如“是否保存更改”）。"; m6.pauseIsApp = true; m6.remainingCount = 2
        render(PausePanelView(model: m6, onContinue: {}, onStop: {}).background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 380, height: 260), to: "\(out)/6-暂停面板.png")
        let m7 = makeModel(count: 6, selected: 0, phase: .selecting); m7.screenRecording = false; m7.thumbnails = [:]
        render(OverviewRoot(model: m7, actions: OverviewActions()), size: size, to: "\(out)/7-无屏幕录制.png")
        // 单击即关闭：圈选中
        let m9 = makeModel(count: 10, selected: 0, phase: .selecting)
        m9.closeOnClick = true
        m9.marqueeActive = true
        m9.marqueeIDs = [1001, 1002, 1006]
        m9.marquee.rect = CGRect(x: 380, y: 30, width: 520, height: 520)
        m9.statuses[1000] = .closed(ClosedNote.destroyed.text)
        m9.statuses[1003] = .skipped(SkipReason.notUniquelyIdentified.text)
        if m9.apps.count > 4 {
            m9.appStatuses[m9.apps[2].id] = .working
            m9.appStatuses[m9.apps[3].id] = .waitingUser("")
            m9.hoveredApp = m9.apps[4].id
        }
        render(OverviewRoot(model: m9, actions: OverviewActions()), size: size, to: "\(out)/9-单击即关闭-圈选中.png")
        let m10 = OverviewModel(); m10.phase = .selecting; m10.axTrusted = true; m10.screenRecording = true; m10.closeOnClick = true
        m10.statuses[1] = .closed("")
        render(OverviewRoot(model: m10, actions: OverviewActions()), size: size, to: "\(out)/10-全部关好.png")
        // 浏览器标签页页面
        let m11 = makeModel(count: 6, selected: 0, phase: .selecting)
        m11.closeOnClick = true
        m11.page = .browserTabs
        m11.tabsPhase = .ready
        let sites = [("GitHub - apple/swift: The Swift Programming Language", "https://github.com/apple/swift"),
                     ("Swift Forums - 讨论区", "https://forums.swift.org/latest"), ("ScreenCaptureKit | Apple Developer Documentation", "https://developer.apple.com/documentation/screencapturekit"),
                     ("哔哩哔哩 (゜-゜)つロ 干杯~-bilibili", "https://www.bilibili.com"), ("知乎 - 有问题，就会有答案", "https://www.zhihu.com"),
                     ("Google 翻译", "https://translate.google.com"), ("淘宝网 - 淘！我喜欢", "https://www.taobao.com"),
                     ("Gmail - 收件箱 (12)", "https://mail.google.com/mail/u/0/#inbox"), ("YouTube", "https://www.youtube.com"),
                     ("百度一下，你就知道", "https://www.baidu.com"), ("微博", "https://weibo.com"), ("新标签页", "chrome://newtab"),
                     ("Google 日历", "https://calendar.google.com"), ("swift/README.md at main · apple/swift", "https://github.com/apple/swift/blob/main/README.md"),
                     ("【4K】城市漫步 - 哔哩哔哩", "https://www.bilibili.com/video/BV1xx"), ("Pull requests · GitHub", "https://github.com/pulls")]
        func tabs(_ n: Int, _ off: Int) -> [BrowserTab] { (0..<n).map { i in let s = sites[(i + off) % sites.count]; return BrowserTab(id: "\(off)-\(i)", title: s.0, url: s.1, isActive: i == 0) } }
        m11.browserGroups = [BrowserGroup(pid: 1, appName: "Google Chrome", windowID: "w1", title: "GitHub - apple/swift: The Swift Programming Language", cardID: 1000, tabs: tabs(13, 0)),
                             BrowserGroup(pid: 1, appName: "Google Chrome", windowID: "w2", title: "Gmail - 收件箱 (12)", cardID: 1006, tabs: tabs(8, 9))]
        let g0 = m11.browserGroups[0]
        m11.tabStatuses[g0.key(g0.tabs[1])] = .closed("")
        m11.tabStatuses[g0.key(g0.tabs[2])] = .working
        m11.tabMarqueeKeys = [g0.key(g0.tabs[5]), g0.key(g0.tabs[6])]
        m11.tabMarquee.rect = CGRect(x: 380, y: 140, width: 560, height: 60)
        m11.marqueeActive = true
        render(OverviewRoot(model: m11, actions: OverviewActions()), size: size, to: "\(out)/11-浏览器标签页.png")
        m11.tabGrouping = .bySite
        m11.tabMarqueeKeys = []; m11.tabMarquee.rect = nil; m11.marqueeActive = false
        m11.hoveredTab = nil
        render(OverviewRoot(model: m11, actions: OverviewActions()), size: size, to: "\(out)/13-标签页按网站.png")
        m11.tabGrouping = .byWindow
        let m12 = makeModel(count: 2, selected: 0, phase: .selecting)
        m12.page = .browserTabs; m12.tabsPhase = .needsPermission(["Google Chrome"])
        render(OverviewRoot(model: m12, actions: OverviewActions()), size: size, to: "\(out)/12-标签页授权.png")
        let m8 = OverviewModel(); m8.phase = .selecting; m8.axTrusted = true; m8.screenRecording = true
        render(OverviewRoot(model: m8, actions: OverviewActions()), size: size, to: "\(out)/8-没有窗口.png")
    }
}
