import Foundation
import CoreGraphics

/// 窗口服务器（CGWindowList）报告的一个窗口。坐标为全局坐标，原点在主显示器左上角。
public struct CGWindowInfo: Equatable, Sendable {
    public var windowID: CGWindowID
    public var pid: pid_t
    public var ownerName: String
    /// 需要屏幕录制权限才能读到；没有权限时为 nil。
    public var title: String?
    public var bounds: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool

    public init(windowID: CGWindowID, pid: pid_t, ownerName: String, title: String?, bounds: CGRect,
                layer: Int = 0, alpha: Double = 1, isOnScreen: Bool = true) {
        self.windowID = windowID
        self.pid = pid
        self.ownerName = ownerName
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
    }
}

/// 辅助功能接口（AXUIElement）读到的一个窗口的信息。坐标系与 CGWindowInfo 相同。
public struct AXWindowInfo: Equatable, Sendable {
    public var title: String?
    public var frame: CGRect?
    public var role: String?
    public var subrole: String?
    public var isMinimized: Bool
    public var hasCloseButton: Bool
    public var closeButtonEnabled: Bool
    /// 窗口上是否挂着表单式对话框（sheet）。只在需要时读取，未读取时为 false。
    public var hasSheet: Bool

    public init(title: String?, frame: CGRect?, role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
                isMinimized: Bool = false, hasCloseButton: Bool = true, closeButtonEnabled: Bool = true,
                hasSheet: Bool = false) {
        self.title = title
        self.frame = frame
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.hasCloseButton = hasCloseButton
        self.closeButtonEnabled = closeButtonEnabled
        self.hasSheet = hasSheet
    }
}

/// 一个辅助功能窗口及其句柄。真实环境中 handle 是 AXUIElement，测试中可以是任意对象。
public struct AXWindowRef {
    public let info: AXWindowInfo
    public let handle: AnyObject

    public init(info: AXWindowInfo, handle: AnyObject) {
        self.info = info
        self.handle = handle
    }
}

public enum AXAccessError: Error, Equatable, Sendable {
    /// 本应用没有辅助功能权限
    case notTrusted
    /// 目标应用在限定时间内没有回应（卡住，或不支持辅助功能）
    case appUnresponsive
    /// 目标应用已经退出
    case appGone
    case other(Int32)
}

public enum AXActionResult: Equatable, Sendable {
    case success
    /// 发送了请求，但应用没有在限定时间内回应（可能卡住，也可能正停在一个模态对话框里）
    case timedOut
    /// 关闭按钮或窗口元素已经失效
    case elementGone
    case failed(Int32)
}

/// 要关闭的目标：以窗口服务器的窗口编号为准（缩略图也是按这个编号截取的）。
public struct CloseTarget: Equatable, Sendable {
    public var windowID: CGWindowID
    public var pid: pid_t
    public var appName: String
    public var title: String

    public init(windowID: CGWindowID, pid: pid_t, appName: String, title: String) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.title = title
    }
}

/// 关闭请求发出后出现了需要用户处理的对话框。
public struct PendingContext {
    public enum Kind: Equatable, Sendable {
        /// 挂在窗口上的表单（例如“是否保存更改”）
        case sheet
        /// 应用新弹出的独立对话框窗口
        case dialogWindow
    }
    public var target: CloseTarget
    public var kind: Kind
    /// 按下关闭按钮之前，该应用已在屏幕上的窗口编号；之后多出来的就是对话框。
    public var baseline: Set<CGWindowID>
    public var windowRef: AXWindowRef

    public init(target: CloseTarget, kind: Kind, baseline: Set<CGWindowID>, windowRef: AXWindowRef) {
        self.target = target
        self.kind = kind
        self.baseline = baseline
        self.windowRef = windowRef
    }
}

public enum ClosedNote: Equatable, Sendable {
    /// 窗口已被销毁
    case destroyed
    /// 窗口已从屏幕消失，但应用仍保留了它（例如部分聊天软件“关闭”时只是收起窗口）。这与手动点红色按钮效果一致。
    case removedFromScreen
    /// 用户在原应用的确认框中做出选择后，窗口关闭了
    case afterUserChoice
    /// 应用响应较慢，在之前判定失败或等待后才关闭
    case late
}

public enum SkipReason: Equatable, Sendable {
    case windowGone
    case ownerChanged
    case notOnScreen
    case appNotRunning
    case appUnresponsive
    case notUniquelyIdentified
    case noCloseButton
    case closeButtonDisabled
    case alreadyHasDialog
    /// 用户在确认框中选择了“取消”，窗口保留
    case userKeptOpen
    /// 用户停止了队列，这个窗口没有被处理
    case stoppedByUser
    /// 自检保护：不在允许名单中的窗口一律不碰
    case notAllowed
}

public enum FailReason: Equatable, Sendable {
    case notTrusted
    case pressFailed(Int32)
    /// 关闭请求已发送，但窗口仍然在
    case stillOpen
    /// 应用对关闭请求没有及时回应，窗口仍在
    case unresponsiveAfterPress
    case axError(Int32)
}

public enum CloseOutcome {
    case closed(ClosedNote)
    case needsUser(PendingContext)
    case skipped(SkipReason)
    case failed(FailReason)
}

public enum PendingState: Equatable, Sendable {
    case stillWaiting
    case closed
    case keptOpen
}
