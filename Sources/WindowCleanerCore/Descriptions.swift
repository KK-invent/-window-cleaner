import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

/// 卡片和报告里显示的四类结果（另有“排队中/处理中”两个过程状态）。
public enum ItemStatus: Equatable {
    case queued
    case working
    case closed(String)
    case waitingUser(String)
    case skipped(String)
    case failed(String)

    public var category: String {
        switch self {
        case .queued: return "排队中"
        case .working: return "正在关闭"
        case .closed: return "已关闭"
        case .waitingUser: return "等待你处理"
        case .skipped: return "已跳过"
        case .failed: return "关闭失败"
        }
    }

    public var detail: String {
        switch self {
        case .queued, .working: return ""
        case .closed(let d), .waitingUser(let d), .skipped(let d), .failed(let d): return d
        }
    }

    public var isFinal: Bool {
        switch self {
        case .queued, .working, .waitingUser: return false
        default: return true
        }
    }
}

public extension ClosedNote {
    var text: String {
        switch self {
        case .destroyed: return "窗口已关闭"
        case .removedFromScreen: return "窗口已从屏幕关闭（该应用在后台保留了它，与手动点红色按钮效果相同）"
        case .afterUserChoice: return "你在确认框中确认后，窗口已关闭"
        case .late: return "应用响应较慢，窗口稍后已关闭"
        }
    }
}

public extension SkipReason {
    var text: String {
        switch self {
        case .windowGone: return "执行前窗口已经不存在，未做任何操作"
        case .ownerChanged: return "窗口归属发生变化，为安全起见未关闭"
        case .notOnScreen: return "窗口已不在当前屏幕（可能被最小化、隐藏或移到其他桌面），未关闭"
        case .appNotRunning: return "所属应用已退出"
        case .appUnresponsive: return "应用无响应，没有发送关闭请求"
        case .notUniquelyIdentified: return "无法唯一确认是这个窗口（可能有位置和标题都相同的窗口），为避免误关已跳过"
        case .noCloseButton: return "这个窗口没有关闭按钮"
        case .closeButtonDisabled: return "关闭按钮当前不可用（窗口可能正在显示对话框）"
        case .alreadyHasDialog: return "窗口上已有对话框，未发送关闭请求"
        case .userKeptOpen: return "你在确认框中取消了关闭，窗口已保留"
        case .stoppedByUser: return "你停止了队列，这个窗口没有处理"
        case .notAllowed: return "自检保护：不是测试窗口，不处理"
        }
    }
}

public extension FailReason {
    var text: String {
        switch self {
        case .notTrusted: return "缺少辅助功能权限"
        case .pressFailed(let c): return "无法按下关闭按钮（错误 \(c)）"
        case .stillOpen: return "已发送关闭请求，但窗口仍然存在"
        case .unresponsiveAfterPress: return "应用没有及时回应关闭请求，窗口仍在；请求可能会在应用恢复后才生效"
        case .axError(let c): return "辅助功能接口出错（错误 \(c)）"
        }
    }
}

public extension CloseOutcome {
    var status: ItemStatus {
        switch self {
        case .closed(let n): return .closed(n.text)
        case .needsUser(let ctx):
            return .waitingUser(ctx.kind == .sheet
                ? "应用在窗口上弹出了确认框，请你自己决定"
                : "应用弹出了对话框，请你自己决定")
        case .skipped(let r): return .skipped(r.text)
        case .failed(let r): return .failed(r.text)
        }
    }
}

public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹出系统的辅助功能授权提示（只有用户本人能在系统设置里打开开关）
    public static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    public static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

/// 运行记录：写入 ~/Library/Logs/窗口清理/window-cleaner.log（只记录耗时、数量、应用名和关闭结果，不记录窗口标题）。
public enum TimingLog {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/窗口清理", isDirectory: true)
            .appendingPathComponent("window-cleaner.log")
    }

    public static func append(_ line: String) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let text = "\(f.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(text.data(using: .utf8)!)
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 本进程当前和峰值的物理内存占用（与“活动监视器”里的“内存”一致），用于日志
    public static func memoryText() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return "mem=?" }
        return String(format: "mem=%.1fMB peak=%.1fMB", Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// 本进程启动以来经过的毫秒数
    public static func msSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startDate = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        return Date().timeIntervalSince(startDate) * 1000
    }
}
