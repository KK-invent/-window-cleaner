// 缩略图内存对照（仅开发用）：截取当前屏幕上的普通窗口缩略图，报告内存变化；图片不保存。
import AppKit

func mb() -> (Double, Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

@main
enum ThumbProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let ids = LiveBackend().onScreenWindows().filter { $0.layer == 0 && $0.bounds.width > 200 && $0.pid != getpid() }.prefix(6).map(\.windowID)
        let px = CGSize(width: Double(CommandLine.arguments.dropFirst().first ?? "712") ?? 712, height: 455)
        let a = mb()
        var images: [NSImage] = []
        let r = try? await ThumbnailLoader.load(ids: Array(ids), maxPixelSize: px) { _, img in if let img { images.append(img) } }
        let b = mb()
        images.removeAll()
        try? await Task.sleep(nanoseconds: 500_000_000)
        malloc_zone_pressure_relief(nil, 0)
        let c = mb()
        print(String(format: "截 %d 张（宽≤%.0f 像素）：之前 %.1f MB → 之后 %.1f MB（峰值 %.1f）→ 丢掉图片后 %.1f MB", r?.ok ?? 0, px.width, a.0, b.0, b.1, c.0))
    }
}
