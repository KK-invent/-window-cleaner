import Foundation
import CoreGraphics
import AppKit

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

    public var isClosable: Bool { closability == .closable }

    public var target: CloseTarget {
        CloseTarget(windowID: id, pid: pid, appName: appName, title: title)
    }

    public init(id: CGWindowID, pid: pid_t, appName: String, bundleID: String?, title: String, bounds: CGRect,
                closability: Closability, isBrowser: Bool, isOnlyWindowOfApp: Bool, zIndex: Int) {
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

    /// 枚举当前桌面空间里的普通窗口，并与辅助功能窗口配对。
    public static func enumerate(backend: WindowBackend, ownPID: pid_t, axTimeout: Float = 0.6) -> Result {
        let onScreen = backend.onScreenWindows()
        let candidates = onScreen.enumerated().filter { _, w in
            w.layer == 0 && w.pid != ownPID && w.alpha > 0.01 &&
                w.bounds.width >= 60 && w.bounds.height >= 40 && !excludedOwners.contains(w.ownerName)
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
            let peers = onScreen.filter { $0.pid == w.pid }
            var closability: WindowEntry.Closability = .closable
            var title = w.title ?? ""
            var axCount = 0

            switch axByPID[w.pid] ?? .success([]) {
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
                axCount = axList.filter { !$0.info.isMinimized && $0.info.role == "AXWindow" }.count
                switch WindowMatcher.match(target: w, peers: peers, axWindows: axList.map(\.info)) {
                case .unique(let idx, _):
                    let ax = axList[idx].info
                    if let t = ax.title, !t.isEmpty { title = t }
                    if !ax.hasCloseButton {
                        closability = .blocked("这个窗口没有关闭按钮")
                    } else if !ax.closeButtonEnabled {
                        closability = .blocked("关闭按钮当前不可用（可能正在显示对话框）")
                    }
                case .ambiguous:
                    closability = .blocked(hasTitles
                        ? "无法唯一确认：同应用有位置、大小和标题都相同的窗口"
                        : "无法唯一确认：同应用有位置、大小相同的窗口（授权屏幕录制后可借助标题区分）")
                case .notFound:
                    // 辅助功能里找不到、也没有标题的，多半是应用内部的辅助窗口，不展示
                    if title.isEmpty { continue }
                    closability = .blocked("无法通过辅助功能找到这个窗口的关闭按钮")
                }
            }

            entries.append(WindowEntry(
                id: w.windowID, pid: w.pid, appName: appName, bundleID: bundleID, title: title, bounds: w.bounds,
                closability: closability, isBrowser: BrowserDetector.isBrowser(bundleID: bundleID),
                isOnlyWindowOfApp: axCount <= 1, zIndex: z))
        }

        // 同一应用的窗口排在一起；应用按其最前面窗口的顺序排列
        var firstZ: [pid_t: Int] = [:]
        for e in entries where firstZ[e.pid] == nil { firstZ[e.pid] = e.zIndex }
        entries.sort { a, b in
            let za = firstZ[a.pid] ?? 0, zb = firstZ[b.pid] ?? 0
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
