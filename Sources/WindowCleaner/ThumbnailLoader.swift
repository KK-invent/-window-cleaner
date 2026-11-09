import AppKit
import ScreenCaptureKit

/// 用 ScreenCaptureKit 按窗口编号单独截取窗口画面（被遮挡的窗口也能截到）。
/// 只截一张静态图，不开启持续录制，不采集声音；图片只保存在内存里，总览关闭即释放。
enum ThumbnailLoader {
    enum LoadError: Error {
        case contentUnavailable(String)
    }

    /// 逐个回调结果；返回成功数和失败数。
    @MainActor
    static func load(ids: [CGWindowID], maxPixelSize: CGSize, includeOffscreen: Bool = false,
                     onImage: @escaping @MainActor (CGWindowID, NSImage?) -> Void) async throws -> (ok: Int, failed: Int) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: !includeOffscreen)
        } catch {
            throw LoadError.contentUnavailable(error.localizedDescription)
        }
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }

        var ok = 0, failed = 0
        let maxConcurrent = 6
        try await withThrowingTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            var pending = ids[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                let scw = byID[id]
                group.addTask {
                    guard let scw else { return (id, nil) }
                    return (id, try? await capture(scw, maxPixelSize: maxPixelSize))
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let (id, image) = try await group.next() {
                try Task.checkCancellation()
                if let image {
                    ok += 1
                    onImage(id, NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                } else {
                    failed += 1
                    onImage(id, nil)
                }
                addNext()
            }
        }
        return (ok, failed)
    }

    /// 只截到卡片缩略图框所需的像素（宽、高都不超过框），多一个像素都是内存浪费
    static func capture(_ window: SCWindow, maxPixelSize: CGSize) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var w = window.frame.width * scale
        var h = window.frame.height * scale
        let maxW = max(maxPixelSize.width, 160), maxH = max(maxPixelSize.height, 100)
        let fit = min(1, maxW / max(w, 1), maxH / max(h, 1))
        w *= fit
        h *= fit
        config.width = max(Int(w.rounded()), 16)
        config.height = max(Int(h.rounded()), 16)
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
