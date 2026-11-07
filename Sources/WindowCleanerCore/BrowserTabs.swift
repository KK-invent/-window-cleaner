import Foundation
import CoreGraphics
import AppKit
import ScriptingBridge

// 浏览器标签页：读取 Chrome（及同样提供 Chrome 脚本接口的浏览器）窗口里的标签页，按标签页编号关闭指定标签页。
// 使用浏览器自带的公开脚本接口（Apple Events / ScriptingBridge），需要你允许“窗口清理”控制该浏览器（系统会询问一次）。
// 标签页以浏览器内部的唯一编号识别，不靠标题匹配；关闭前再次确认编号仍在，关闭后观察它是否真的消失。

public struct BrowserTab: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public var isActive: Bool

    public init(id: String, title: String, url: String, isActive: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
    }

    /// 只显示网址的主机部分
    public var host: String {
        URL(string: url)?.host ?? url
    }
}

public struct BrowserWindowInfo: Equatable, Sendable {
    public var id: String
    public var title: String
    /// 浏览器报告的窗口边界（为兼容不同的坐标表示，给出几种可能的解读）
    public var boundsCandidates: [CGRect]
    public var isMinimized: Bool
    public var tabs: [BrowserTab]

    public init(id: String, title: String, boundsCandidates: [CGRect], isMinimized: Bool, tabs: [BrowserTab]) {
        self.id = id
        self.title = title
        self.boundsCandidates = boundsCandidates
        self.isMinimized = isMinimized
        self.tabs = tabs
    }
}

public struct TabKey: Hashable, Sendable {
    public var pid: pid_t
    public var windowID: String
    public var tabID: String

    public init(pid: pid_t, windowID: String, tabID: String) {
        self.pid = pid
        self.windowID = windowID
        self.tabID = tabID
    }
}

public enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case appNotRunning
    case failed(Int32)
}

public enum TabsError: Error, Equatable, Sendable {
    case notPermitted
    case appNotRunning
    case windowGone
    case failed(Int)
}

public protocol TabsBackend: AnyObject {
    func permission(pid: pid_t, ask: Bool) -> AutomationPermission
    func windows(pid: pid_t) -> Result<[BrowserWindowInfo], TabsError>
    func tabIDs(pid: pid_t, windowID: String) -> Result<[String], TabsError>
    func closeTab(_ key: TabKey) -> Result<Void, TabsError>
}

public enum BrowserTabSupport {
    /// 提供 Chrome 脚本接口（窗口、标签页编号、关闭标签页）的浏览器
    public static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta",
    ]

    public static func supports(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return bundleIDs.contains(b)
    }

    public static let internalPagesName = "浏览器内部页面"
    public static let localFilesName = "本地文件"
    public static let otherName = "其他"

    /// 需要保留三段的国家/地区二级域名，例如 sina.com.cn、bbc.co.uk
    static let secondLevelSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn", "com.hk", "org.hk", "edu.hk", "gov.hk", "com.tw", "org.tw", "edu.tw",
        "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "com.au", "net.au", "org.au", "edu.au",
        "co.kr", "or.kr", "com.sg", "edu.sg", "com.br", "co.in", "co.nz", "com.mx", "com.my", "co.id", "co.th", "com.tr", "com.ar",
    ]

    /// 按网站分组用的网站名：去掉 www，子域名归到主网站（mail.google.com → google.com）
    public static func siteName(for url: String) -> String {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased() else { return otherName }
        switch scheme {
        case "http", "https": break
        case "file": return localFilesName
        case "chrome", "chrome-extension", "chrome-untrusted", "edge", "brave", "about", "devtools", "view-source":
            return internalPagesName
        default: return otherName
        }
        guard var host = u.host?.lowercased(), !host.isEmpty else { return otherName }
        if host.hasSuffix(".") { host.removeLast() }
        // IP 地址和 localhost 原样显示
        if host == "localhost" || host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) || host.contains(":") { return host }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return parts.first == "www" ? parts.dropFirst().joined(separator: ".") : host }
        let last2 = parts.suffix(2).joined(separator: ".")
        if secondLevelSuffixes.contains(last2) { return parts.suffix(3).joined(separator: ".") }
        return last2
    }

    /// 把浏览器窗口和总览里的窗口卡片对应起来：边界一致且唯一才算
    public static func matchWindow(cardBounds: CGRect, cardTitle: String, in windows: [BrowserWindowInfo]) -> BrowserWindowInfo? {
        let byBounds = windows.filter { w in !w.isMinimized && w.boundsCandidates.contains { WindowMatcher.framesMatch($0, cardBounds) } }
        if byBounds.count == 1 { return byBounds[0] }
        if byBounds.count > 1 {
            let byTitle = byBounds.filter { $0.title == cardTitle }
            if byTitle.count == 1 { return byTitle[0] }
        }
        return nil
    }
}

public struct TabPendingContext {
    public var key: TabKey
    public var baseline: Set<CGWindowID>
}

public enum TabOutcome {
    case closed(windowClosed: Bool)
    case needsUser(TabPendingContext)
    case skipped(String)
    case failed(String)

    public var status: ItemStatus {
        switch self {
        case .closed(let w): return .closed(w ? "标签页已关闭；这是窗口里最后一个标签页，窗口也随之关闭" : "标签页已关闭")
        case .needsUser: return .waitingUser("网页弹出了确认框（例如“离开此网站？”），请你自己决定")
        case .skipped(let s): return .skipped(s)
        case .failed(let s): return .failed(s)
        }
    }
}

/// 关闭单个标签页：核对编号 → 发送关闭 → 观察结果
public final class TabCloser {
    public let tabs: TabsBackend
    public let windows: WindowBackend
    public var timeout: Double = 3.0
    public var pollInterval: Double = 0.1
    public var allowedPIDs: Set<pid_t>?

    public init(tabs: TabsBackend, windows: WindowBackend) {
        self.tabs = tabs
        self.windows = windows
    }

    public func attempt(_ key: TabKey) -> TabOutcome {
        if let allowed = allowedPIDs, !allowed.contains(key.pid) { return .skipped(SkipReason.notAllowed.text) }
        guard windows.isAppRunning(key.pid) else { return .skipped("浏览器已经退出") }
        switch tabs.tabIDs(pid: key.pid, windowID: key.windowID) {
        case .failure(.notPermitted): return .failed("没有控制该浏览器的权限")
        case .failure(.windowGone): return .skipped("所在窗口已经关闭")
        case .failure(.appNotRunning): return .skipped("浏览器已经退出")
        case .failure(.failed(let c)): return .failed("读取标签页失败（错误 \(c)）")
        case .success(let ids):
            guard ids.contains(key.tabID) else { return .skipped("标签页已经不存在，未做任何操作") }
        }
        let baseline = Set(windows.onScreenWindows().filter { $0.pid == key.pid }.map(\.windowID))
        switch tabs.closeTab(key) {
        case .success: break
        case .failure(.notPermitted): return .failed("没有控制该浏览器的权限")
        case .failure(.windowGone): return .skipped("所在窗口已经关闭")
        case .failure(let e): return .failed("发送关闭请求失败（\(e)）")
        }
        let ctx = TabPendingContext(key: key, baseline: baseline)
        let deadline = windows.now() + timeout
        var dialogTicks = 0
        while true {
            switch tabs.tabIDs(pid: key.pid, windowID: key.windowID) {
            case .failure(.windowGone): return .closed(windowClosed: true)
            case .failure(.appNotRunning): return .closed(windowClosed: true)
            case .success(let ids) where !ids.contains(key.tabID): return .closed(windowClosed: false)
            default: break
            }
            if hasDialog(ctx) {
                dialogTicks += 1
                if dialogTicks >= 2 { return .needsUser(ctx) }
            } else {
                dialogTicks = 0
            }
            if windows.now() >= deadline {
                return .failed("已发送关闭请求，但标签页仍在（网页可能弹出了“离开此网站？”确认）")
            }
            windows.sleep(pollInterval)
        }
    }

    public func checkPending(_ ctx: TabPendingContext) -> PendingState {
        switch tabs.tabIDs(pid: ctx.key.pid, windowID: ctx.key.windowID) {
        case .failure(.windowGone), .failure(.appNotRunning): return .closed
        case .success(let ids) where !ids.contains(ctx.key.tabID): return .closed
        case .failure: return .stillWaiting
        default: break
        }
        return hasDialog(ctx) ? .stillWaiting : .keptOpen
    }

    private func hasDialog(_ ctx: TabPendingContext) -> Bool {
        windows.onScreenWindows().contains {
            $0.pid == ctx.key.pid && !ctx.baseline.contains($0.windowID) && WindowMatcher.isDialogCandidate($0)
        }
    }
}

// MARK: - 真实实现（ScriptingBridge）

final class SBErrorCatcher: NSObject, SBApplicationDelegate {
    var code = 0
    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        code = (error as NSError).code
        return nil
    }
}

public final class LiveTabsBackend: TabsBackend {
    public init() {}

    public func permission(pid: pid_t, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let desc = target.aeDesc else { return .failed(-1) }
        let st = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch st {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .appNotRunning
        default: return .failed(st)
        }
    }

    private func app(_ pid: pid_t, _ catcher: SBErrorCatcher) -> SBApplication? {
        guard let a = SBApplication(processIdentifier: pid) else { return nil }
        a.delegate = catcher
        a.timeout = 5 * 60 // 5 秒（单位为 1/60 秒）
        return a
    }

    private func mapError(_ code: Int) -> TabsError {
        switch code {
        case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent): return .notPermitted
        case Int(procNotFound), -609 /* connectionInvalid */: return .appNotRunning
        case Int(errAENoSuchObject): return .windowGone
        default: return .failed(code)
        }
    }

    private static func strings(_ arr: [Any]?) -> [String] {
        (arr ?? []).map { "\($0)" }
    }

    public func windows(pid: pid_t) -> Result<[BrowserWindowInfo], TabsError> {
        let catcher = SBErrorCatcher()
        guard let app = app(pid, catcher) else { return .failure(.appNotRunning) }
        guard let wins = app.value(forKey: "windows") as? SBElementArray else { return .failure(mapError(catcher.code)) }
        let ids = Self.strings(wins.array(byApplying: NSSelectorFromString("id")))
        if catcher.code != 0 { return .failure(mapError(catcher.code)) }
        let names = Self.strings(wins.array(byApplying: NSSelectorFromString("name")))
        let bounds = wins.array(byApplying: NSSelectorFromString("bounds"))
        let minimized = wins.array(byApplying: NSSelectorFromString("minimized"))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var result: [BrowserWindowInfo] = []
        for (i, wid) in ids.enumerated() {
            catcher.code = 0
            guard let w = wins.object(withID: wid) as? SBObject,
                  let tabs = w.value(forKey: "tabs") as? SBElementArray else { continue }
            let tabIDs = Self.strings(tabs.array(byApplying: NSSelectorFromString("id")))
            if catcher.code != 0 { continue }
            let titles = Self.strings(tabs.array(byApplying: NSSelectorFromString("title")))
            let urls = Self.strings(tabs.array(byApplying: NSSelectorFromString("URL")))
            let activeIndex = (w.value(forKey: "activeTabIndex") as? NSNumber)?.intValue ?? 0
            var candidates: [CGRect] = []
            if let b = bounds[safe: i] {
                var r = CGRect.zero
                if let v = b as? NSValue { r = v.rectValue }
                else if let a = b as? [NSNumber], a.count == 4 {
                    r = CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: a[2].doubleValue - a[0].doubleValue, height: a[3].doubleValue - a[1].doubleValue)
                }
                if r != .zero {
                    candidates.append(r)
                    // 有的接口把 {左, 上, 右, 下} 放进矩形的“宽、高”里
                    candidates.append(CGRect(x: r.minX, y: r.minY, width: r.width - r.minX, height: r.height - r.minY))
                    // 左下角原点的坐标
                    candidates.append(CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height))
                }
            }
            let tabsList = tabIDs.enumerated().map { j, tid in
                BrowserTab(id: tid, title: titles[safe: j] ?? "", url: urls[safe: j] ?? "", isActive: j + 1 == activeIndex)
            }
            result.append(BrowserWindowInfo(id: wid, title: names[safe: i] ?? "", boundsCandidates: candidates,
                                            isMinimized: (minimized[safe: i] as? NSNumber)?.boolValue ?? false, tabs: tabsList))
        }
        return .success(result)
    }

    /// 编号在浏览器里是文字，也可能是数字；两种写法都试一次（第一次失败时什么都不会发生）
    private func idVariants(_ s: String) -> [Any] {
        if let n = Int(s) { return [s as NSString, NSNumber(value: n)] }
        return [s as NSString]
    }

    private func window(_ app: SBApplication, _ catcher: SBErrorCatcher, id: String) -> SBObject? {
        guard let wins = app.value(forKey: "windows") as? SBElementArray else { return nil }
        for v in idVariants(id) {
            catcher.code = 0
            guard let w = wins.object(withID: v) as? SBObject else { continue }
            // 读取一次属性来确认这个窗口确实存在
            _ = w.value(forKey: "name")
            if catcher.code == 0 { return w }
        }
        return nil
    }

    public func tabIDs(pid: pid_t, windowID: String) -> Result<[String], TabsError> {
        let catcher = SBErrorCatcher()
        guard let app = app(pid, catcher) else { return .failure(.appNotRunning) }
        guard let w = window(app, catcher, id: windowID) else {
            return .failure(catcher.code == 0 ? .windowGone : mapError(catcher.code))
        }
        catcher.code = 0
        guard let tabs = w.value(forKey: "tabs") as? SBElementArray else { return .failure(mapError(catcher.code)) }
        let ids = Self.strings(tabs.array(byApplying: NSSelectorFromString("id")))
        if catcher.code != 0 { return .failure(mapError(catcher.code)) }
        return .success(ids)
    }

    public func closeTab(_ key: TabKey) -> Result<Void, TabsError> {
        let catcher = SBErrorCatcher()
        guard let app = app(key.pid, catcher) else { return .failure(.appNotRunning) }
        guard let w = window(app, catcher, id: key.windowID) else {
            return .failure(catcher.code == 0 ? .windowGone : mapError(catcher.code))
        }
        guard let tabs = w.value(forKey: "tabs") as? SBElementArray else { return .failure(mapError(catcher.code)) }
        let close = NSSelectorFromString("close")
        for v in idVariants(key.tabID) {
            catcher.code = 0
            guard let t = tabs.object(withID: v) as? SBObject else { continue }
            // 先读一次标题，确认编号对应的标签页确实存在，再发送关闭
            _ = t.value(forKey: "title")
            guard catcher.code == 0 else { continue }
            guard t.responds(to: close) else { return .failure(.failed(-1708)) }
            t.perform(close)
            return catcher.code == 0 ? .success(()) : .failure(mapError(catcher.code))
        }
        return .failure(catcher.code == 0 ? .failed(Int(errAENoSuchObject)) : mapError(catcher.code))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
