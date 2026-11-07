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

    public func windowInfo(_ id: CGWindowID) -> CGWindowInfo? {
        // 快速路径：只对在屏幕上的窗口有效
        if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow, .optionOnScreenBelowWindow], id) as? [[String: Any]],
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
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    public func terminateApp(_ pid: pid_t) -> Bool {
        // 正常退出（不是强制退出）：应用会照常询问是否保存，也可以拒绝
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    // MARK: 辅助功能

    public func axWindows(pid: pid_t, timeout: Float, includeSheetCheck: Bool) -> Result<[AXWindowRef], AXAccessError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        switch err {
        case .success: break
        case .noValue, .attributeUnsupported: return .success([])
        case .cannotComplete: return .failure(isAppRunning(pid) ? .appUnresponsive : .appGone)
        case .apiDisabled: return .failure(.notTrusted)
        case .invalidUIElement: return .failure(.appGone)
        default: return .failure(.other(err.rawValue))
        }
        guard let elements = value as? [AXUIElement] else { return .success([]) }
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
