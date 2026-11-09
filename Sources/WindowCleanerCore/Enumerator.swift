import Foundation
import CoreGraphics
import AppKit

public enum WindowScope: String {
    case currentDesktop
    case allDesktops
}

/// 总览里的一张卡片对应的窗口。id 就是窗口服务器的窗口编号，缩略图也按它截取。
public struct WindowEntry: Identifiable, Equatable {
    public enum Closability: Equatable {
        case closable
        case blocked(String)
    }

    public let id: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let bundleID: String?
    public let title: String
    public let bounds: CGRect
    public let closability: Closability
    public let isBrowser: Bool
    /// 该应用在当前桌面只有这一个窗口
    public let isOnlyWindowOfApp: Bool
    /// 在屏幕上的前后顺序（0 = 最前）
    public let zIndex: Int
    public let isOnScreen: Bool
    public let isMinimized: Bool
    public let isAppHidden: Bool
    public let scope: WindowScope

    /// 公开接口不提供可靠的桌面编号，因此不会编造“桌面 1/2”或把未显示一律叫作全屏。
    public var locationLabel: String? {
        if isMinimized { return "已最小化" }
        if isAppHidden { return "应用已隐藏" }
        return isOnScreen ? nil : "其他桌面"
    }

    public var isClosable: Bool { closability == .closable }

    public var target: CloseTarget {
        CloseTarget(windowID: id, pid: pid, appName: appName, title: title, allowOffscreen: scope == .allDesktops)
    }

    public init(id: CGWindowID, pid: pid_t, appName: String, bundleID: String?, title: String, bounds: CGRect,
                closability: Closability, isBrowser: Bool, isOnlyWindowOfApp: Bool, zIndex: Int,
                isOnScreen: Bool = true, isMinimized: Bool = false, isAppHidden: Bool = false,
                scope: WindowScope = .currentDesktop) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.bounds = bounds
        self.closability = closability
        self.isBrowser = isBrowser
        self.isOnlyWindowOfApp = isOnlyWindowOfApp
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.scope = scope
    }
}

public enum WindowEnumerator {
    /// 不是普通应用窗口的系统进程
    static let excludedOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center", "控制中心", "通知中心",
        "Spotlight", "WindowManager", "screencaptureui", "loginwindow", "TextInputMenuAgent",
    ]

    public struct Result {
        public var entries: [WindowEntry]
        public var axTrusted: Bool
        public var hasTitles: Bool
    }

    /// 先按窗口服务器枚举，再用辅助功能过滤应用内部缓冲窗口，并核对可关闭窗口。
    public static func enumerate(backend: WindowBackend, ownPID: pid_t, axTimeout: Float = 0.6,
                                 scope: WindowScope = .currentDesktop) -> Result {
        let all = backend.allWindows()
        let onScreen = scope == .allDesktops ? all : backend.onScreenWindows()
        let candidates = onScreen.enumerated().filter { _, w in
            w.layer == 0 && w.pid != ownPID && w.alpha > 0.01 &&
                w.bounds.width >= 60 && w.bounds.height >= 40 && !excludedOwners.contains(w.ownerName) && !backend.isAppHidden(w.pid)
        }
        let pids = Array(Set(candidates.map { $0.element.pid }))

        // 各应用并发读取，避免一个卡住的应用拖慢整体
        var axByPID: [pid_t: Swift.Result<[AXWindowRef], AXAccessError>] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let r = backend.axWindows(pid: pids[i], timeout: axTimeout, includeSheetCheck: false)
            lock.lock(); axByPID[pids[i]] = r; lock.unlock()
        }

        var trusted = true
        var entries: [WindowEntry] = []
        let hasTitles = onScreen.contains { ($0.title ?? "").isEmpty == false }

        for (z, w) in candidates {
            let app = NSRunningApplication(processIdentifier: w.pid)
            let appName = app?.localizedName ?? w.ownerName
            let bundleID = app?.bundleIdentifier
            if let app, app.activationPolicy != .regular || app.bundleIdentifier == "local.windowcleaner.app" { continue }
            let peers = all.filter { $0.pid == w.pid }
            var minimized = false
            var closability: WindowEntry.Closability = .closable
            var title = w.title ?? ""
            var axCount = 0

            let axResult = axByPID[w.pid] ?? .success([])
            // 屏幕外窗口必须由应用自己的辅助功能属性确认，不能把服务器保留记录当作真实窗口。
            if !w.isOnScreen, case .failure = axResult { continue }
            switch axResult {
            case .failure(.notTrusted):
                trusted = false
                closability = .blocked("需要辅助功能权限")
            case .failure(.appUnresponsive):
                closability = .blocked("应用暂时无响应，或不支持辅助功能")
            case .failure(.appGone):
                continue
            case .failure(.other(let code)):
                closability = .blocked("无法读取该应用的窗口（错误 \(code)）")
            case .success(let axList):
                axCount = axList.filter { $0.info.role == "AXWindow" }.count
                switch WindowMatcher.match(target: w, peers: peers, axWindows: axList.map(\.info)) {
                case .unique(let idx, _):
                    let ax = axList[idx].info
                    // 不在屏幕上的菜单、表单和面板不作为普通窗口展示。
                    if !w.isOnScreen && ax.subrole != "AXStandardWindow" { continue }
                    minimized = ax.isMinimized
                    if minimized { continue }
                    if let t = ax.title, !t.isEmpty { title = t }
                    if !ax.hasCloseButton {
                        closability = .blocked("这个窗口没有关闭按钮")
                    } else if !ax.closeButtonEnabled {
                        closability = .blocked("关闭按钮当前不可用（可能正在显示对话框）")
                    }
                case .ambiguous:
                    let candidates = axList.filter { $0.info.frame.map { WindowMatcher.framesMatch($0, w.bounds) } ?? false }
                    // 不把全部已最小化或仅含面板的候选窗口放进主列表。
                    if !candidates.isEmpty && candidates.allSatisfy({ $0.info.isMinimized || $0.info.subrole != "AXStandardWindow" }) { continue }
                    closability = .blocked(hasTitles
                        ? "无法唯一确认：同应用有位置、大小和标题都相同的窗口"
                        : "无法唯一确认：同应用有位置、大小相同的窗口（授权屏幕录制后可借助标题区分）")
                case .notFound:
                    // 不再按标题兜底收录屏幕外窗口：其中会混有已关闭、隐藏后仍保留的后台记录。
                    if title.isEmpty || !w.isOnScreen { continue }
                    closability = .blocked("无法通过辅助功能找到这个窗口的关闭按钮")
                }
            }

            if backend.isAppHidden(w.pid) { continue }
            entries.append(WindowEntry(
                id: w.windowID, pid: w.pid, appName: appName, bundleID: bundleID, title: title, bounds: w.bounds,
                closability: closability, isBrowser: BrowserDetector.isBrowser(bundleID: bundleID),
                isOnlyWindowOfApp: axCount <= 1, zIndex: z,
                isOnScreen: w.isOnScreen, isMinimized: minimized, isAppHidden: backend.isAppHidden(w.pid), scope: scope))
        }

        // 同一应用的窗口排在一起；应用按其最前面窗口的顺序排列
        var firstZ: [pid_t: Int] = [:]
        for e in entries where firstZ[e.pid] == nil { firstZ[e.pid] = e.zIndex }
        entries.sort { a, b in
            let za = firstZ[a.pid] ?? 0, zb = firstZ[b.pid] ?? 0
            if a.isOnScreen != b.isOnScreen { return a.isOnScreen }
            return za != zb ? za < zb : a.zIndex < b.zIndex
        }
        return Result(entries: entries, axTrusted: trusted, hasTitles: hasTitles)
    }
}

public enum BrowserDetector {
    static let known: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "company.thebrowser.Browser", "com.brave.Browser", "com.brave.Browser.beta", "com.operasoftware.Opera",
        "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS",
        "ru.yandex.desktop.yandex-browser", "com.duckduckgo.macos.browser", "org.chromium.Chromium",
        "com.openai.atlas", "ai.perplexity.comet", "com.sogou.SogouExplorer", "com.360.360chrome",
    ]

    nonisolated(unsafe) static var cache: [String: Bool] = [:]
    static let lock = NSLock()

    /// 已知浏览器名单，或应用自己声明的类别是“网页浏览器”。
    public static func isBrowser(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        if known.contains(id) { return true }
        lock.lock(); defer { lock.unlock() }
        if let v = cache[id] { return v }
        var v = false
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String {
            v = category == "public.app-category.web-browser"
        }
        cache[id] = v
        return v
    }
}
