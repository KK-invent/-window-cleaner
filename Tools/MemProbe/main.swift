// 内存对照（仅开发用）：在屏幕上显示演示总览 3 秒，报告本进程的物理内存峰值。
import AppKit
import SwiftUI

func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

/// 把截图复制成普通位图（不再挂着截图接口的图形缓冲区）
func plainCopy(_ img: NSImage) -> NSImage {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return img }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let out = ctx.makeImage() else { return img }
    return NSImage(cgImage: out, size: img.size)
}

@main
enum MemProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        OverlayStyle.liquidGlass = CommandLine.arguments.contains("--glass")
        OverlayStyle.blur = !CommandLine.arguments.contains("--no-blur")
        if CommandLine.arguments.contains("--no-tint") { OverlayStyle.tint = 0.001 }
        let before = footprintMB()
        let screen = NSScreen.main!.frame
        let m = OverviewModel()
        m.axTrusted = true; m.screenRecording = true; m.phase = .selecting
        m.entries = (0..<12).map { i in WindowEntry(id: CGWindowID(1000 + i), pid: 1, appName: "演示", bundleID: nil, title: "演示窗口 \(i)", bounds: .zero, closability: .closable, isBrowser: false, isOnlyWindowOfApp: false, zIndex: i) }
        if CommandLine.arguments.contains("--thumbs") {
            let ids = LiveBackend().onScreenWindows().filter { $0.layer == 0 && $0.bounds.width > 200 && $0.pid != getpid() }.prefix(6).map(\.windowID)
            var imgs: [NSImage] = []
            _ = try? await ThumbnailLoader.load(ids: Array(ids), maxPixelSize: CGSize(width: 712, height: 455)) { _, img in if let img { imgs.append(img) } }
            let copy = CommandLine.arguments.contains("--copy")
            for (i, img) in imgs.enumerated() { m.thumbnails[CGWindowID(1000 + i)] = copy ? plainCopy(img) : img }
        }
        m.apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.prefix(10).map { AppEntry(id: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: nil, icon: $0.icon ?? NSImage(), windowCount: 0, isHidden: false) }
        var shown = (now: 0.0, peak: 0.0)
        autoreleasepool {
            let w = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false; w.backgroundColor = .clear; w.level = .floating
            let host = NSHostingView(rootView: OverviewRoot(model: m, actions: OverviewActions()))
            host.sizingOptions = []
            w.contentView = host
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            shown = footprintMB()
            w.orderOut(nil)
            w.contentView = nil
            if CommandLine.arguments.contains("--close") { w.close() }
        }
        m.entries = []; m.apps = []; m.thumbnails = [:]
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        malloc_zone_pressure_relief(nil, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = footprintMB()
        print(String(format: "%@：显示中 %.1f MB（峰值 %.1f MB）→ 关闭后 %.1f MB",
                     CommandLine.arguments.dropFirst().joined(separator: " "), shown.now, shown.peak, after.now))
    }
}
