import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// 使用 Apple 公开接口的真实实现：CGWindowList（窗口列表）+ AXUIElement（辅助功能）。
public final class LiveBackend: WindowBackend {
    public init() {}

    // MARK: 窗口服务器

    public func onScreenWindows() -> [CGWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap(Self.parse)
    }

    public func allWindows() -> [CGWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap(Self.parse)
    }

    public func windowInfo(_ id: CGWindowID) -> CGWindowInfo? {
        // 快速路径：只查这一个窗口（约 0.1 毫秒），在屏和不在屏的窗口都能查到
        var raw: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(id))
        if let ids = CFArrayCreate(kCFAllocatorDefault, &raw, 1, nil),
           let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
           let w = list.compactMap(Self.parse).first(where: { $0.windowID == id }) {
            return w
        }
        // 实测：窗口被最小化或所属应用被隐藏后，上面的查询会查不到，但窗口其实还在。
        // 用全部窗口列表确认，避免把“最小化/隐藏”误判成“已关闭”。
        guard let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for d in all where (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id {
            return Self.parse(d)
        }
        return nil
    }

    static func parse(_ d: [String: Any]) -> CGWindowInfo? {
        guard let number = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        return CGWindowInfo(
            windowID: number,
            pid: pid,
            ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
            title: d[kCGWindowName as String] as? String,
            bounds: bounds,
            layer: (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
            isOnScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
    }

    public func isAppRunning(_ pid: pid_t) -> Bool {
        // 直接问系统进程是否还在（信号 0 只做检查，不发送任何信号）。
        // 实测：几个应用并行退出时，在后台线程同时创建 NSRunningApplication 偶尔会对仍在运行的应用返回空，
        // 会把“正在显示保存提示”的应用误判为已退出；系统调用没有这个问题。
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func isAppHidden(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
    }

    public func terminateApp(_ pid: pid_t) -> Bool {
        // 正常退出（不是强制退出）：应用会照常询问是否保存，也可以拒绝
        // 并行退出时偶尔取不到应用对象：稍等重试，不把“没取到”当成拒绝
        for attempt in 0..<5 {
            if let app = NSRunningApplication(processIdentifier: pid) { return app.terminate() }
            if !isAppRunning(pid) { return false }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.01) }
        }
        return false
    }

    // MARK: 辅助功能

    public func appHasDialog(pid: pid_t, timeout: Float) -> Result<Bool, AXAccessError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let deadline = now() + Double(timeout)
        // 每次系统调用都使用剩余预算，避免多窗口 × 多属性 × 超时不断累加。
        func read(_ element: AXUIElement, _ attribute: String) -> Result<CFTypeRef?, AXAccessError> {
            guard isAppRunning(pid) else { return .failure(.appGone) }
            let remaining = deadline - now()
            guard remaining > 0 else { return .failure(.appUnresponsive) }
            AXUIElementSetMessagingTimeout(element, Float(remaining))
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            switch error {
            case .success: return .success(value)
            case .noValue, .attributeUnsupported: return .success(nil)
            case .cannotComplete: return .failure(.appUnresponsive)
            case .apiDisabled: return .failure(.notTrusted)
            case .invalidUIElement: return .failure(.appGone)
            default: return .failure(.other(error.rawValue))
            }
        }
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement]
        switch read(app, kAXWindowsAttribute) {
        case .success(let value): windows = (value as? [AXUIElement]) ?? []
        case .failure(let error): return .failure(error)
        }
        for window in windows {
            switch read(window, kAXModalAttribute) {
            case .success(let value):
                if (value as? NSNumber)?.boolValue == true { return .success(true) }
            case .failure(let error): return .failure(error)
            }
            let children: [AXUIElement]
            switch read(window, kAXChildrenAttribute) {
            case .success(let value): children = (value as? [AXUIElement]) ?? []
            case .failure(let error): return .failure(error)
            }
            for child in children {
                switch read(child, kAXRoleAttribute) {
                case .success(let value):
                    if (value as? String) == (kAXSheetRole as String) { return .success(true) }
                case .failure(let error): return .failure(error)
                }
            }
        }
        return .success(false)
    }

    public func axWindows(pid: pid_t, timeout: Float, includeSheetCheck: Bool) -> Result<[AXWindowRef], AXAccessError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        switch err {
        case .success, .noValue, .attributeUnsupported: break
        case .cannotComplete: return .failure(isAppRunning(pid) ? .appUnresponsive : .appGone)
        case .apiDisabled: return .failure(.notTrusted)
        case .invalidUIElement: return .failure(.appGone)
        default: return .failure(.other(err.rawValue))
        }
        var elements = (value as? [AXUIElement]) ?? []
        // 部分应用在其他桌面把 AXWindows 报为空，但仍提供主窗口或焦点窗口。
        // 这两个同样是公开属性；用元素身份去重，不靠标题推测窗口是否还在。
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let extra = Self.element(app, attribute), !elements.contains(where: { CFEqual($0, extra) }) {
                elements.append(extra)
            }
        }
        var result: [AXWindowRef] = []
        for element in elements {
            AXUIElementSetMessagingTimeout(element, timeout)
            guard let info = Self.readInfo(element, timeout: timeout, includeSheetCheck: includeSheetCheck) else { continue }
            result.append(AXWindowRef(info: info, handle: element))
        }
        return .success(result)
    }

    public func refreshAXInfo(_ ref: AXWindowRef, timeout: Float) -> AXWindowInfo? {
        let element = ref.handle as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return Self.readInfo(element, timeout: timeout, includeSheetCheck: true)
    }

    public func axWindowIsGone(_ ref: AXWindowRef, timeout: Float) -> Bool {
        let element = ref.handle as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    public func pressCloseButton(of ref: AXWindowRef, timeout: Float) -> AXActionResult {
        let window = ref.handle as! AXUIElement
        AXUIElementSetMessagingTimeout(window, timeout)
        // 重新取一次关闭按钮，确保它属于这个窗口且仍然有效
        guard let button = Self.element(window, kAXCloseButtonAttribute) else { return .elementGone }
        AXUIElementSetMessagingTimeout(button, timeout)
        let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
        switch err {
        case .success: return .success
        case .cannotComplete: return .timedOut
        case .invalidUIElement: return .elementGone
        default: return .failed(err.rawValue)
        }
    }

    /// 把窗口提到前面（仅用于暂停时让用户看到原应用的确认框）
    public func raise(_ ref: AXWindowRef) {
        let window = ref.handle as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    public func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: 读取属性

    static func readInfo(_ w: AXUIElement, timeout: Float, includeSheetCheck: Bool) -> AXWindowInfo? {
        // 先读角色：读不到说明元素已失效或应用无响应
        var roleValue: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &roleValue)
        guard roleErr == .success else { return nil }
        let role = roleValue as? String
        let subrole = string(w, kAXSubroleAttribute)
        let title = string(w, kAXTitleAttribute)
        var frame: CGRect?
        if let p = point(w, kAXPositionAttribute), let s = size(w, kAXSizeAttribute) {
            frame = CGRect(origin: p, size: s)
        }
        let minimized = bool(w, kAXMinimizedAttribute) ?? false
        let closeButton = element(w, kAXCloseButtonAttribute)
        var enabled = false
        if let b = closeButton {
            AXUIElementSetMessagingTimeout(b, timeout)
            enabled = bool(b, kAXEnabledAttribute) ?? true
        }
        var hasSheet = false
        if includeSheetCheck {
            hasSheet = children(w).contains { child in
                AXUIElementSetMessagingTimeout(child, timeout)
                return string(child, kAXRoleAttribute) == (kAXSheetRole as String)
            }
        }
        return AXWindowInfo(title: title, frame: frame, role: role, subrole: subrole, isMinimized: minimized,
                            hasCloseButton: closeButton != nil, closeButtonEnabled: enabled, hasSheet: hasSheet)
    }

    static func copy(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ e: AXUIElement, _ attr: String) -> String? {
        copy(e, attr) as? String
    }

    static func bool(_ e: AXUIElement, _ attr: String) -> Bool? {
        guard let v = copy(e, attr) else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) }
        return (v as? NSNumber)?.boolValue
    }

    static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (copy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func point(_ e: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ e: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
