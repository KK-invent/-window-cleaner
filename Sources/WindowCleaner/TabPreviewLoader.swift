import AppKit
import ScreenCaptureKit

/// 只截取每个浏览器窗口当前标签页的真实画面，不激活窗口、不切标签、不重新访问网址。
/// 后台标签只显示之前确实截到过的缓存，绝不拿当前标签画面冒充。
@MainActor enum TabPreviewLoader {
    static func cached(groups: [BrowserGroup], cache: TabPreviewCache) -> [TabKey: TabPreview] {
        var result: [TabKey: TabPreview] = [:]
        for g in groups {
            for t in g.tabs {
                let key = g.key(t)
                if let p = cache.preview(for: key, url: t.url) { result[key] = p }
            }
        }
        return result
    }

    static func load(groups: [BrowserGroup], tabs: TabsBackend, cache: TabPreviewCache,
                     onCaptured: @escaping (TabKey, TabPreview) -> Void) async {
        guard !Task.isCancelled,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        var windowsByPID: [pid_t: [BrowserWindowInfo]] = [:]
        for pid in Set(groups.map(\.pid)) {
            let response = await Task.detached(priority: .utility) { tabs.windows(pid: pid) }.value
            if case .success(let windows) = response { windowsByPID[pid] = windows }
        }
        // 预览只需要 120×75 点的两倍像素；每个窗口最多截一张。
        for g in groups.prefix(24) {
            guard !Task.isCancelled else { return }
            guard let cardID = g.cardID,
                  let window = windowsByPID[g.pid]?.first(where: { $0.id == g.windowID }), !window.isMinimized,
                  let active = window.tabs.first(where: \.isActive), !active.isLoading,
                  let known = g.tabs.first(where: { $0.id == active.id && $0.url == active.url }),
                  let scWindow = content.windows.first(where: { $0.windowID == cardID && $0.owningApplication?.processID == g.pid }),
                  window.boundsCandidates.contains(where: { WindowMatcher.framesMatch($0, scWindow.frame) }) else { continue }
            let key = g.key(known)
            // 在真正截图前再核对一次；读取整个窗口列表和截图之间用户可能已切换标签。
            let beforeResult = await Task.detached(priority: .utility) { tabs.activeTab(pid: g.pid, windowID: g.windowID) }.value
            guard case .success(let before) = beforeResult,
                  TabPreviewIdentity.matches(key: key, expectedURL: known.url, before: before, after: before),
                  !Task.isCancelled,
                  let cg = try? await ThumbnailLoader.capture(scWindow, maxPixelSize: CGSize(width: 240, height: 150)) else { continue }
            let afterResult = await Task.detached(priority: .utility) { tabs.activeTab(pid: g.pid, windowID: g.windowID) }.value
            guard case .success(let after) = afterResult, !Task.isCancelled else { continue }
            let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
            if cache.store(key: key, expectedURL: known.url, before: before, after: after, image: image),
               let p = cache.preview(for: key, url: known.url) {
                onCaptured(key, p)
            }
        }
    }
}
