import AppKit
import SwiftUI

/// 下方应用栏里的一个正在运行的应用
struct AppEntry: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage
    /// 当前桌面上的窗口数（上方卡片里的数量）
    var windowCount: Int
    var isHidden: Bool

    var target: QuitTarget { QuitTarget(pid: id, appName: name) }

    static func == (a: AppEntry, b: AppEntry) -> Bool {
        a.id == b.id && a.windowCount == b.windowCount && a.isHidden == b.isHidden && a.name == b.name
    }
}

/// 排队/选中的一项：关闭一个窗口、退出一个应用，或关闭一个浏览器标签页
enum QueueItem: Hashable {
    case window(CGWindowID)
    case app(pid_t)
    case tab(TabKey)
}

/// 总览顶部的两个页签
enum OverviewPage: Equatable {
    case windows
    case browserTabs
}

/// 浏览器标签页页面里的一组：一个浏览器窗口及其标签页
struct BrowserGroup: Identifiable, Equatable {
    var id: String { "\(pid)-\(windowID)" }
    let pid: pid_t
    let appName: String
    let windowID: String
    let title: String
    /// 对应“窗口与应用”页里的哪张卡片（用于显示缩略图；对应不上时为空）
    let cardID: CGWindowID?
    var tabs: [BrowserTab]

    func key(_ t: BrowserTab) -> TabKey { TabKey(pid: pid, windowID: windowID, tabID: t.id) }
}

/// 浏览器标签页页面的分组方式
enum TabGrouping: String {
    case byWindow
    case bySite
}

/// 界面上显示的一组标签页（按窗口或按网站）
struct TabItem: Identifiable, Equatable {
    var id: TabKey { key }
    let key: TabKey
    let tab: BrowserTab
}

struct TabDisplayGroup: Identifiable, Equatable {
    enum Kind: Equatable {
        case window(cardID: CGWindowID?, appName: String, pid: pid_t)
        case site
    }
    let id: String
    let kind: Kind
    let title: String
    var items: [TabItem]
    /// 按网站分组时：这些标签页来自几个窗口
    var windowCount: Int
}

enum TabsPhase: Equatable {
    case idle
    case loading
    case noBrowser
    /// 还没问过你是否允许控制这些浏览器
    case needsPermission([String])
    /// 你拒绝过
    case denied([String])
    case ready
    case error(String)
}

/// 总览界面的全部状态。只在主线程使用。
@MainActor
final class OverviewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case needsPermission
        case selecting
        case running
        case paused
        case finished
    }

    enum ThumbnailPhase: Equatable {
        case idle
        case loading
        case done
        case unavailable(String)
    }

    @Published var phase: Phase = .loading
    /// 进入/退出动画：整个界面是否已显示、是否正在退出、卡片是否已依次浮现
    @Published var shown = true
    @Published var exiting = false
    @Published var cardsRevealed = true
    /// 系统设置里开了“减弱动态效果”时只做淡入淡出
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @Published var windowScope: WindowScope = WindowScope(rawValue: UserDefaults.standard.string(forKey: "windowScope") ?? "") ?? .allDesktops {
        didSet { UserDefaults.standard.set(windowScope.rawValue, forKey: "windowScope") }
    }
    @Published var entries: [WindowEntry] = []
    @Published var apps: [AppEntry] = []
    /// 按选中的先后顺序排列，也是执行顺序（先选再关模式）
    @Published var selection: [QueueItem] = []
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var failedThumbnails: Set<CGWindowID> = []
    @Published var thumbnailPhase: ThumbnailPhase = .idle
    @Published var statuses: [CGWindowID: ItemStatus] = [:] {
        didSet {
            // 关闭成功的卡片：原位淡出，稍后再整理位置
            let newlyClosed = statuses.compactMap { id, st -> CGWindowID? in
                if case .closed = st, !vanished.contains(id) { return id }
                return nil
            }
            if !newlyClosed.isEmpty {
                vanished.formUnion(newlyClosed)
                onCardsVanished?()
            }
        }
    }
    /// 已关闭、正在淡出或已淡出的卡片（位置先保留，避免连续点击时卡片挪动导致点错）
    @Published var vanished: Set<CGWindowID> = []
    /// 应用栏里每个应用的处理结果（“已关闭”表示已退出）
    @Published var appStatuses: [pid_t: ItemStatus] = [:] {
        didSet {
            let newlyQuit = appStatuses.compactMap { pid, st -> pid_t? in
                if case .closed = st, !vanishedApps.contains(pid) { return pid }
                return nil
            }
            if !newlyQuit.isEmpty {
                vanishedApps.formUnion(newlyQuit)
                onCardsVanished?()
            }
        }
    }
    @Published var vanishedApps: Set<pid_t> = []

    // 浏览器标签页页面
    @Published var page: OverviewPage = .windows
    @Published var tabsPhase: TabsPhase = .idle
    @Published var browserGroups: [BrowserGroup] = []
    @Published var tabFilter = ""
    @Published var tabGrouping: TabGrouping = TabGrouping(rawValue: UserDefaults.standard.string(forKey: "tabGrouping") ?? "") ?? .byWindow {
        didSet { UserDefaults.standard.set(tabGrouping.rawValue, forKey: "tabGrouping") }
    }
    @Published var tabStatuses: [TabKey: ItemStatus] = [:] {
        didSet {
            let newlyClosed = tabStatuses.compactMap { k, st -> TabKey? in
                if case .closed = st, !vanishedTabs.contains(k) { return k }
                return nil
            }
            if !newlyClosed.isEmpty {
                vanishedTabs.formUnion(newlyClosed)
                onCardsVanished?()
            }
        }
    }
    @Published var vanishedTabs: Set<TabKey> = []
    /// 网站图标按“浏览器 + 页面网址”区分，同一网站的不同页面也可有不同图标。
    @Published var favicons: [String: NSImage] = [:]
    @Published var tabPreviews: [TabKey: TabPreview] = [:]
    @Published var faviconAccessBundleID: String?
    @Published var faviconFolderMessage = ""

    func favicon(for url: String, bundleID: String) -> NSImage? {
        guard let key = FaviconStore.cacheKey(url: url, bundleID: bundleID) else { return nil }
        return favicons[key]
    }
    @Published var hoveredTab: TabKey?
    @Published var tabMarqueeKeys: Set<TabKey> = []
    @Published var appMarqueeIDs: Set<pid_t> = []
    let tabMarquee = MarqueeState()
    let appMarquee = MarqueeState()
    var tabFrames: [TabKey: CardFrame] = [:]

    /// 按搜索词筛选后的窗口分组
    var visibleGroups: [BrowserGroup] {
        let q = tabFilter.trimmingCharacters(in: .whitespaces).lowercased()
        return browserGroups.compactMap { g in
            var g = g
            if !q.isEmpty {
                g.tabs = g.tabs.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
            }
            return g.tabs.isEmpty ? nil : g
        }
    }

    /// 界面上显示的分组：按窗口，或按网站（标签页多的网站排前面）
    var displayGroups: [TabDisplayGroup] {
        let groups = visibleGroups
        switch tabGrouping {
        case .byWindow:
            return groups.map { g in
                TabDisplayGroup(id: "w-" + g.id, kind: .window(cardID: g.cardID, appName: g.appName, pid: g.pid), title: g.title,
                                items: g.tabs.map { TabItem(key: g.key($0), tab: $0) }, windowCount: 1)
            }
        case .bySite:
            var order: [String] = []
            var items: [String: [TabItem]] = [:]
            var windows: [String: Set<String>] = [:]
            for g in groups {
                for t in g.tabs {
                    let site = BrowserTabSupport.siteName(for: t.url)
                    if items[site] == nil { order.append(site) }
                    items[site, default: []].append(TabItem(key: g.key(t), tab: t))
                    windows[site, default: []].insert(g.id)
                }
            }
            let special: Set<String> = [BrowserTabSupport.internalPagesName, BrowserTabSupport.localFilesName, BrowserTabSupport.otherName]
            let sorted = order.sorted { a, b in
                // 内部页面、本地文件、其他放最后；其余按标签页数量从多到少
                let sa = special.contains(a), sb = special.contains(b)
                if sa != sb { return !sa }
                let na = items[a]?.count ?? 0, nb = items[b]?.count ?? 0
                if na != nb { return na > nb }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            return sorted.map { site in
                TabDisplayGroup(id: "s-" + site, kind: .site, title: site, items: items[site] ?? [], windowCount: windows[site]?.count ?? 1)
            }
        }
    }

    var tabCount: Int {
        browserGroups.reduce(0) { n, g in n + g.tabs.filter { !vanishedTabs.contains(g.key($0)) }.count }
    }
    var tabSummary: Summary { Self.summarize(tabStatuses.values) }
    var selectedTabs: [TabKey] {
        selection.compactMap { if case .tab(let k) = $0 { return k }; return nil }
    }

    func tabSelectionIndex(_ k: TabKey) -> Int? {
        selection.firstIndex(of: .tab(k)).map { $0 + 1 }
    }

    func toggleTab(_ k: TabKey) {
        guard phase == .selecting, tabStatuses[k] == nil else { return }
        if let i = selection.firstIndex(of: .tab(k)) { selection.remove(at: i) } else { selection.append(.tab(k)) }
    }

    func tab(_ k: TabKey) -> BrowserTab? {
        browserGroups.first { $0.pid == k.pid && $0.windowID == k.windowID }?.tabs.first { $0.id == k.tabID }
    }

    func group(_ k: TabKey) -> BrowserGroup? {
        browserGroups.first { $0.pid == k.pid && $0.windowID == k.windowID }
    }
    var onCardsVanished: (() -> Void)?
    @Published var axTrusted = false
    @Published var screenRecording = false
    @Published var timingText = ""
    @Published var runIndex = 0
    @Published var runTotal = 0
    /// 暂停面板上的说明文字
    @Published var pauseMessage = ""
    @Published var pauseIsApp = false
    @Published var pendingState: PendingState = .stillWaiting
    @Published var stopRequested = false
    @Published var hasTitles = true
    @Published var hoveredID: CGWindowID?
    @Published var hoveredApp: pid_t?
    /// 暂停面板里显示的“还有几个没处理”
    @Published var remainingCount = 0
    /// 单击卡片立即关闭（默认）；关掉则为“先选择，再点关闭所选”
    @Published var closeOnClick: Bool = UserDefaults.standard.object(forKey: "closeOnClick") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(closeOnClick, forKey: "closeOnClick")
            selection = []
        }
    }
    /// 单击即关闭模式下，正在排队或正在处理的数量
    @Published var activeCount = 0

    // 关闭动效只使用独立合成层，不逐帧发布整个界面的状态。
    let closeFeedback = CloseFeedbackCoordinator()

    // 圈选
    let marquee = MarqueeState()
    @Published var marqueeIDs: Set<CGWindowID> = []
    @Published var marqueeActive = false
    /// 拖动途中按了 Esc：本次拖动作废
    var marqueeCancelled = false
    /// 各卡片、各应用图标当前位置（由界面上报）
    var cardFrames: [CGWindowID: CardFrame] = [:]
    var appFrames: [pid_t: CardFrame] = [:]
    /// 应用栏玻璃底板的位置（底板以外的空白算“空白处”）
    var appPanelFrame: CGRect = .zero
    var groupFrames: [String: CGRect] = [:]

    func endMarquee() {
        marquee.rect = nil
        tabMarquee.rect = nil
        appMarquee.rect = nil
        if !marqueeIDs.isEmpty { marqueeIDs = [] }
        if !tabMarqueeKeys.isEmpty { tabMarqueeKeys = [] }
        if !appMarqueeIDs.isEmpty { appMarqueeIDs = [] }
        if marqueeActive { marqueeActive = false }
        marqueeCancelled = false
    }

    func cancelMarquee() {
        endMarquee()
        marqueeCancelled = true
    }

    private var iconCache: [pid_t: NSImage] = [:]

    func reset() {
        closeFeedback.reset()
        entries = []
        apps = []
        cardsRevealed = false
        selection = []
        thumbnails = [:]
        failedThumbnails = []
        thumbnailPhase = .idle
        statuses = [:]
        appStatuses = [:]
        runIndex = 0
        runTotal = 0
        pauseMessage = ""
        pendingState = .stillWaiting
        stopRequested = false
        vanished = []
        vanishedApps = []
        endMarquee()
        cardFrames = [:]
        appFrames = [:]
        tabStatuses = [:]
        tabPreviews = [:]
        vanishedTabs = []
        tabMarqueeKeys = []
        appMarqueeIDs = []
        tabFrames = [:]
        browserGroups = []
        tabsPhase = .idle
        tabFilter = ""
    }

    func icon(for pid: pid_t) -> NSImage {
        if let i = iconCache[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
        iconCache[pid] = i
        return i
    }

    func entry(_ id: CGWindowID) -> WindowEntry? { entries.first { $0.id == id } }
    func app(_ pid: pid_t) -> AppEntry? { apps.first { $0.id == pid } }

    func selectionIndex(_ id: CGWindowID) -> Int? {
        selection.firstIndex(of: .window(id)).map { $0 + 1 }
    }

    func appSelectionIndex(_ pid: pid_t) -> Int? {
        selection.firstIndex(of: .app(pid)).map { $0 + 1 }
    }

    func toggle(_ e: WindowEntry) {
        guard phase == .selecting, statuses[e.id] == nil else { return }
        guard e.isClosable else {
            NSSound.beep() // 灰色卡片不能选，给一点提示
            return
        }
        if let i = selection.firstIndex(of: .window(e.id)) {
            selection.remove(at: i)
        } else {
            selection.append(.window(e.id))
        }
    }

    func toggleApp(_ a: AppEntry) {
        guard phase == .selecting, appStatuses[a.id] == nil else { return }
        if let i = selection.firstIndex(of: .app(a.id)) {
            selection.remove(at: i)
        } else {
            selection.append(.app(a.id))
        }
    }

    func clearSelection() {
        guard phase == .selecting else { return }
        selection = []
    }

    var selectedEntries: [WindowEntry] {
        selection.compactMap { if case .window(let id) = $0 { return entry(id) }; return nil }
    }
    var selectedApps: [AppEntry] {
        selection.compactMap { if case .app(let pid) = $0 { return app(pid) }; return nil }
    }
    var selectedBrowserCount: Int { selectedEntries.filter(\.isBrowser).count }
    var selectedOnlyWindowCount: Int { selectedEntries.filter(\.isOnlyWindowOfApp).count }
    var closableCount: Int { entries.filter(\.isClosable).count }

    /// 把已淡出的卡片和应用图标移除，其余平滑补位
    /// 补位动画约多长（用于补位途中暂不响应单击）
    static let reflowDuration: CFTimeInterval = 0.3

    @discardableResult
    func compactVanished() -> Bool {
        let hasCards = entries.contains { vanished.contains($0.id) }
        let hasApps = apps.contains { vanishedApps.contains($0.id) }
        let hasTabs = browserGroups.contains { g in g.tabs.contains { vanishedTabs.contains(g.key($0)) } }
        guard hasCards || hasApps || hasTabs else { return false }
        // 利落、几乎不回弹的弹簧：约 0.3 秒到位
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.92)) {
            entries.removeAll { vanished.contains($0.id) }
            apps.removeAll { vanishedApps.contains($0.id) }
            for i in browserGroups.indices {
                let g = browserGroups[i]
                browserGroups[i].tabs.removeAll { vanishedTabs.contains(g.key($0)) }
            }
            browserGroups.removeAll { $0.tabs.isEmpty }
            selection.removeAll {
                switch $0 {
                case .window(let id): return vanished.contains(id)
                case .app(let pid): return vanishedApps.contains(pid)
                case .tab(let k): return vanishedTabs.contains(k)
                }
            }
        }
        return true
    }

    /// 窗口卡片数变化后，更新应用栏里的窗口数
    func refreshAppWindowCounts() {
        var counts: [pid_t: Int] = [:]
        for e in entries where !vanished.contains(e.id) { counts[e.pid, default: 0] += 1 }
        for i in apps.indices {
            let n = counts[apps[i].id] ?? 0
            if apps[i].windowCount != n { apps[i].windowCount = n }
        }
    }

    struct Summary {
        var closed = 0, waiting = 0, skipped = 0, failed = 0
    }

    /// 窗口的处理结果
    var summary: Summary { Self.summarize(statuses.values) }
    /// 应用的处理结果（closed = 已退出）
    var appSummary: Summary { Self.summarize(appStatuses.values) }

    static func summarize<S: Sequence>(_ values: S) -> Summary where S.Element == ItemStatus {
        var s = Summary()
        for st in values {
            switch st {
            case .closed: s.closed += 1
            case .waitingUser: s.waiting += 1
            case .skipped: s.skipped += 1
            case .failed: s.failed += 1
            default: break
            }
        }
        return s
    }

    /// 应用栏：在 Dock 上有图标的正在运行的应用（不含访达和本工具自己）
    static func runningApps(windowCounts: [pid_t: Int], order: [pid_t: Int]) -> [AppEntry] {
        let own = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own &&
                $0.bundleIdentifier != "com.apple.finder"
        }
        let list = apps.map { a in
            AppEntry(id: a.processIdentifier, name: a.localizedName ?? a.bundleIdentifier ?? "未知应用",
                     bundleID: a.bundleIdentifier, icon: a.icon ?? NSWorkspace.shared.icon(for: .application),
                     windowCount: windowCounts[a.processIdentifier] ?? 0, isHidden: a.isHidden)
        }
        // 有窗口的在前，顺序与上方卡片一致；其余按名称
        return list.sorted { x, y in
            switch (order[x.id], order[y.id]) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x.name.localizedStandardCompare(y.name) == .orderedAscending
            }
        }
    }
}
