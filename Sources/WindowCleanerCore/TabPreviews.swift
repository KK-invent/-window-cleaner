import AppKit

/// 静态标签页预览，只放内存；完整网址用于防止同一标签页导航后沿用旧画面，不写日志。
public struct TabPreview {
    public let key: TabKey
    public let url: String
    public let image: NSImage
    public let capturedAt: Date
}

/// 每次截图前后都要核对同一窗口中当前标签的编号和网址，避免切换/导航期间错配。
public enum TabPreviewIdentity {
    public static func matches(key: TabKey, expectedURL: String, before: BrowserTab, after: BrowserTab) -> Bool {
        before.id == key.tabID && after.id == key.tabID && before.url == expectedURL && after.url == expectedURL &&
            before.isActive && after.isActive && !before.isLoading && !after.isLoading
    }
}

public final class TabPreviewCache {
    private let lock = NSLock()
    private var values: [TabKey: TabPreview] = [:]
    private var order: [TabKey] = []
    private var costs: [TabKey: Int] = [:]
    private var bytes = 0
    public let maxBytes: Int
    public let maxCount: Int

    public init(maxBytes: Int = 3 * 1024 * 1024, maxCount: Int = 24) {
        self.maxBytes = maxBytes
        self.maxCount = maxCount
    }

    @discardableResult public func store(key: TabKey, expectedURL: String, before: BrowserTab, after: BrowserTab,
                                         image: NSImage, capturedAt: Date = Date()) -> Bool {
        guard TabPreviewIdentity.matches(key: key, expectedURL: expectedURL, before: before, after: after) else { return false }
        let pixelCost = image.representations.map { max($0.pixelsWide, 0) * max($0.pixelsHigh, 0) * 4 }.max() ?? 0
        guard pixelCost > 0, pixelCost <= maxBytes else { return false }
        lock.lock(); defer { lock.unlock() }
        if let old = costs[key] { bytes -= old }
        order.removeAll { $0 == key }
        order.append(key)
        values[key] = TabPreview(key: key, url: expectedURL, image: image, capturedAt: capturedAt)
        costs[key] = pixelCost
        bytes += pixelCost
        while order.count > maxCount || bytes > maxBytes {
            let k = order.removeFirst()
            values[k] = nil
            bytes -= costs.removeValue(forKey: k) ?? 0
        }
        return true
    }

    public func preview(for key: TabKey, url: String) -> TabPreview? {
        lock.lock(); defer { lock.unlock() }
        guard let p = values[key], p.url == url else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return p
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        values = [:]; order = []; costs = [:]; bytes = 0
    }

    public var byteCount: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}
