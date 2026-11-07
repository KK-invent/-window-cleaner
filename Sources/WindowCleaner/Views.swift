import AppKit
import SwiftUI

/// 界面上的按钮动作，由控制器提供。
struct OverviewActions {
    var cardClicked: (WindowEntry) -> Void = { _ in }
    var appClicked: (AppEntry) -> Void = { _ in }
    var tabClicked: (TabKey) -> Void = { _ in }
    var tabMarqueeFinished: ([TabKey]) -> Void = { _ in }
    var closeTabGroup: ([TabKey]) -> Void = { _ in }
    var appMarqueeFinished: ([AppEntry]) -> Void = { _ in }
    var switchPage: (OverviewPage) -> Void = { _ in }
    var requestTabsPermission: () -> Void = {}
    var openAutomationSettings: () -> Void = {}
    var reloadTabs: () -> Void = {}
    /// 点了空白处（不在任何卡片上）：和按 Esc 一样退出总览
    var backgroundClicked: () -> Void = {}
    var marqueeFinished: ([WindowEntry]) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var closeSelected: () -> Void = {}
    var stop: () -> Void = {}
    var refresh: () -> Void = {}
    var finish: () -> Void = {}
    var openAccessibility: () -> Void = {}
    var openScreenRecording: () -> Void = {}
    var recheckPermissions: () -> Void = {}
    var relaunch: () -> Void = {}
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = OverlayStyle.material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 外观参数：背景只用一层模糊（最省内存和显卡），遮罩浅一些让桌面透出来
enum OverlayStyle {
    static var material: NSVisualEffectView.Material = .hudWindow
    static var tint: Double = 0.12
    /// 是否使用系统“液态玻璃”（macOS 26+）；关闭时用超薄毛玻璃
    static var liquidGlass = true
    /// 是否使用背景模糊（关闭时只用半透明底色）
    static var blur = true
}

extension View {
    /// 玻璃面板：macOS 26 起用系统的“液态玻璃”（清透款），更早的系统用超薄毛玻璃
    @ViewBuilder func glassPanel(cornerRadius: CGFloat, clear: Bool = true) -> some View {
        if #available(macOS 26.0, *), OverlayStyle.liquidGlass {
            self.glassEffect(clear ? .clear : .regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *), OverlayStyle.liquidGlass {
            self.glassEffect(.clear, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// 不额外模糊的“玻璃感”：半透明底色 + 上亮下暗的细边高光（几十张卡片也不增加模糊层）
    func glassTile(cornerRadius: CGFloat, fill: Color) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct OverviewRoot: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions

    var body: some View {
        ZStack {
            if OverlayStyle.blur { VisualEffectBackground() }
            Color.black.opacity(OverlayStyle.blur ? OverlayStyle.tint : 0.55)
                .contentShape(Rectangle())
                .onTapGesture { actions.backgroundClicked() }
            VStack(spacing: 14) {
                HeaderBar(model: model, actions: actions)
                if unifiedSelection {
                    // 窗口区和应用栏共用一次框选：一个框可以同时选中窗口和应用
                    VStack(spacing: 14) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showsAppBar {
                            AppBar(model: model, actions: actions)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(windowsPageGesture)
                } else {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsAppBar {
                        AppBar(model: model, actions: actions)
                    }
                }
                BottomBar(model: model, actions: actions)
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 58)
            // 进入/退出的淡入淡出和缩放由窗口与合成层完成（见 OverviewController.animateContentScale），不重画界面
        }
        // 框选框画在整个画面上（与卡片、应用图标的位置同一套坐标）
        .overlay(MarqueeOverlay(marquee: model.marquee, closeMode: model.closeOnClick, count: 0, text: marqueeText))
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    /// “窗口与应用”页显示卡片时，使用统一框选
    var unifiedSelection: Bool {
        guard model.page == .windows, !(model.entries.isEmpty && model.apps.isEmpty) else { return false }
        return [.selecting, .running, .paused, .finished].contains(model.phase)
    }

    var marqueeText: String {
        let w = model.marqueeIDs.count, a = model.appMarqueeIDs.count
        var parts: [String] = []
        if model.closeOnClick {
            if w > 0 { parts.append("关闭 \(w) 个窗口") }
            if a > 0 { parts.append("退出 \(a) 个应用") }
            return parts.isEmpty ? "拖动框选窗口或应用 · Esc 取消" : "松开即" + parts.joined(separator: "、") + " · Esc 取消"
        }
        if w > 0 { parts.append("\(w) 个窗口") }
        if a > 0 { parts.append("\(a) 个应用") }
        return parts.isEmpty ? "拖动框选窗口或应用" : "框选 " + parts.joined(separator: "、")
    }

    /// 单击与框选共用一个手势（整个画面坐标）：移动不超过 6 点算单击，否则为框选
    var windowsPageGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                guard model.phase == .selecting, !model.marqueeCancelled else { return }
                if !model.marqueeActive {
                    if hypot(v.translation.width, v.translation.height) < 6 { return }
                    model.marqueeActive = true
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                model.marquee.rect = r
                let ws = Set(model.entries.filter { e in
                    e.isClosable && model.statuses[e.id] == nil && (model.cardFrames[e.id]?.window.intersects(r) ?? false)
                }.map(\.id))
                if ws != model.marqueeIDs { model.marqueeIDs = ws }
                let aps = Set(model.apps.filter { a in
                    model.appStatuses[a.id] == nil && !model.vanishedApps.contains(a.id) && (model.appFrames[a.id]?.window.intersects(r) ?? false)
                }.map(\.id))
                if aps != model.appMarqueeIDs { model.appMarqueeIDs = aps }
            }
            .onEnded { v in
                defer { model.endMarquee() }
                guard model.phase == .selecting, !model.marqueeCancelled else { return }
                let p = v.location
                if model.marqueeActive {
                    // 先关窗口，再退出应用（应用退出后它的窗口会随之关闭，不会重复处理）
                    let ws = model.entries.filter { model.marqueeIDs.contains($0.id) }
                    let aps = model.apps.filter { model.appMarqueeIDs.contains($0.id) }
                    if !ws.isEmpty { actions.marqueeFinished(ws) }
                    if !aps.isEmpty { actions.appMarqueeFinished(aps) }
                } else if let e = model.entries.first(where: { model.cardFrames[$0.id]?.window.contains(p) ?? false }) {
                    // 点在窗口上（包括刚关掉、还没补位的空位：那里点了不起作用）
                    actions.cardClicked(e)
                } else if let a = model.apps.first(where: { model.appFrames[$0.id]?.window.contains(p) ?? false }) {
                    actions.appClicked(a)
                } else if model.entries.contains(where: {
                    model.cardFrames[$0.id]?.window.insetBy(dx: -CardGrid.gutterGuard, dy: -CardGrid.gutterGuard).contains(p) ?? false
                }) {
                    // 窗口之间的窄缝：不算空白，避免连续点击时擦边误退出
                } else if model.appPanelFrame.contains(p) {
                    // 应用栏底板里的空白：不算空白
                } else {
                    actions.backgroundClicked()
                }
            }
    }

    var showsAppBar: Bool {
        model.page == .windows && !model.apps.isEmpty &&
            (model.phase == .selecting || model.phase == .running || model.phase == .paused || model.phase == .finished)
    }

    @ViewBuilder var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在读取窗口…")
                .controlSize(.large)
        case .needsPermission:
            PermissionView(model: model, actions: actions)
        default:
            if model.page == .browserTabs {
                BrowserTabsPage(model: model, actions: actions)
            } else if model.entries.isEmpty && model.summary.closed > 0 {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.green)
                    Text("窗口都关好了").font(.title3)
                    Text(model.apps.isEmpty ? "按 Esc 退出" : "可以在下方退出应用，或点空白处、按 Esc 退出").foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if model.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("当前桌面没有可显示的窗口")
                        .font(.title3)
                    Text(model.apps.isEmpty
                         ? "最小化、隐藏、全屏或在其他桌面空间里的窗口暂不显示。"
                         : "可以在下方退出正在运行的应用。最小化、隐藏、全屏或在其他桌面空间里的窗口暂不显示。")
                        .foregroundStyle(.secondary)
                }
            } else {
                CardGrid(model: model, actions: actions)
            }
        }
    }
}

// MARK: 顶部

struct HeaderBar: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("窗口清理")
                        .font(.system(size: 20, weight: .semibold))
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.timingText.isEmpty {
                    Text(model.timingText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if model.phase == .selecting || model.phase == .finished {
                    Text(model.page == .windows ? "共 \(model.entries.count) 个窗口" : "共 \(model.tabCount) 个标签页")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(action: model.page == .windows ? actions.refresh : actions.reloadTabs) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.activeCount > 0)
                    .help(model.page == .windows ? "重新读取窗口列表" : "重新读取标签页")
                    .accessibilityLabel("重新读取")
                }
            }
            if model.phase != .loading && model.phase != .needsPermission {
                PageTabs(model: model, actions: actions)
            }
            if model.page == .windows && model.phase == .selecting && !model.screenRecording {
                Banner(icon: "eye.slash",
                       text: "未授权“屏幕录制”：卡片只显示图标，无法读取窗口标题，位置重叠的同应用窗口可能无法区分。",
                       button: "去授权", action: actions.openScreenRecording)
            } else if model.page == .windows, model.phase == .selecting, case .unavailable(let why) = model.thumbnailPhase {
                Banner(icon: "photo.badge.exclamationmark", text: "缩略图暂时无法获取：\(why)", button: nil, action: {})
            }
        }
    }
}

extension HeaderBar {
    var hint: String {
        switch (model.page, model.closeOnClick) {
        case (.windows, true):
            return "点上方窗口 = 关闭这个窗口（等同点它的红色按钮）；点下方应用图标 = 退出整个应用（等同 ⌘Q）。拖动可框选多个。点空白处或按 Esc 退出。"
        case (.windows, false):
            return "单击窗口或应用图标来选中，再点“关闭所选”。窗口是关闭，应用是退出（等同 ⌘Q）。点空白处或按 Esc 退出。"
        case (.browserTabs, true):
            return "点标签页 = 关闭这个标签页；拖动可框选多个。关闭的标签页可在浏览器里按 ⌘⇧T 找回。点空白处或按 Esc 退出。"
        case (.browserTabs, false):
            return "单击标签页来选中，再点“关闭所选”。关闭的标签页可在浏览器里按 ⌘⇧T 找回。点空白处或按 Esc 退出。"
        }
    }
}

/// 顶部的两个页签：窗口与应用 / 浏览器标签页（⌘1 / ⌘2 切换）
struct PageTabs: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                tab("窗口与应用", icon: "macwindow.on.rectangle", page: .windows,
                    badge: "\(model.entries.filter { !model.vanished.contains($0.id) }.count)", key: "1")
                tab("浏览器标签页", icon: "globe", page: .browserTabs,
                    badge: model.tabsPhase == .ready ? "\(model.tabCount)" : nil, key: "2")
            }
            .padding(3)
            .glassCapsule()
            Spacer()
        }
    }

    func tab(_ title: String, icon: String, page: OverviewPage, badge: String?, key: KeyEquivalent) -> some View {
        let selected = model.page == page
        return Button { actions.switchPage(page) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.white.opacity(selected ? 0.22 : 0.1), in: Capsule())
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(selected ? Color.white.opacity(0.16) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help("\(title)（⌘\(key.character)）")
    }
}

struct Banner: View {
    let icon: String
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.yellow)
            Text(text).font(.system(size: 12))
            Spacer()
            if let button {
                Button(button, action: action).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: 卡片网格

struct CardGrid: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions
    static let spacing: CGFloat = 18

    /// extraLabel：有窗口要显示“无法关闭的原因”时，名称下方多出的两行字
    static func layout(count: Int, in size: CGSize, extraLabel: CGFloat = 0) -> (columns: Int, width: CGFloat) {
        // 窗口多时卡片可以缩到 100 点宽，一屏放下（像调度中心那样缩小，而不是滚动）
        let maxW: CGFloat = 380, minW: CGFloat = 100
        let n = max(count, 1)
        // 卡片高度 = 缩略图 + 上下内边距 16 + 间距 8 + 名称一行约 22 + 底部 2
        func cardHeight(_ w: CGFloat) -> CGFloat { w * 0.62 + 48 + extraLabel }
        // 网格上下各有 6 点留白
        let usable = size.height - 12
        var best: (Int, CGFloat)?
        for cols in 1...14 {
            let w = min(maxW, (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols))
            if w < minW { break }
            let rows = Int(ceil(Double(n) / Double(cols)))
            let h = CGFloat(rows) * cardHeight(w) + CGFloat(rows - 1) * spacing
            if h <= usable { return (cols, w) }
            best = (cols, w)
        }
        // 放不下：用尽量多的列，然后滚动
        return best ?? (1, max(minW, min(maxW, size.width)))
    }

    var body: some View {
        GeometryReader { geo in
            let (cols, w) = Self.layout(count: model.entries.count, in: geo.size,
                                        extraLabel: model.entries.contains { !$0.isClosable } ? 30 : 0)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: Self.spacing, alignment: .top), count: cols),
                      spacing: Self.spacing) {
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, e in
                        CardView(entry: e,
                                 icon: model.icon(for: e.pid),
                                 thumbnail: model.thumbnails[e.id],
                                 thumbnailFailed: model.failedThumbnails.contains(e.id) || !model.screenRecording || model.thumbnailPhase != .loading,
                                 selectionIndex: model.selectionIndex(e.id),
                                 status: model.statuses[e.id],
                                 selectable: model.phase == .selecting,
                                 closeOnClick: model.closeOnClick,
                                 width: w,
                                 hovering: model.hoveredID == e.id && !model.marqueeActive,
                                 inMarquee: model.marqueeIDs.contains(e.id),
                                 vanishing: model.vanished.contains(e.id),
                                 onHover: { h in
                                     if h { model.hoveredID = e.id } else if model.hoveredID == e.id { model.hoveredID = nil }
                                 })
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("card-\(e.id)")
                            .accessibilityLabel("\(e.appName)：\(e.title.isEmpty ? "无标题窗口" : e.title)")
                            .accessibilityValue(model.selectionIndex(e.id) != nil ? "已选中" : "未选中")
                            .accessibilityAction { actions.cardClicked(e) }
                            .opacity(model.cardsRevealed ? 1 : 0)
                            .scaleEffect(model.cardsRevealed || model.reduceMotion ? 1 : 0.9)
                            .offset(y: model.cardsRevealed || model.reduceMotion ? 0 : 14)
                            .animation(model.reduceMotion ? .easeOut(duration: 0.15)
                                       : .spring(response: 0.4, dampingFraction: 0.82).delay(min(Double(index) * 0.025, 0.3)),
                                       value: model.cardsRevealed)
                    }
            }
            .padding(.vertical, 6)
            // 像调度中心一样：窗口多时缩小，不滚动；在可用区域里居中
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(CardFramesKey.self) { frames in
                MainActor.assumeIsolated { model.cardFrames = frames }
            }
        }
    }

    static let space = "cardGrid"
    /// 卡片四周这么宽的范围内点击既不关闭也不退出（卡片间距的一半多一点）
    static let gutterGuard: CGFloat = spacing / 2 + 2

}

struct CardFrame: Equatable {
    var grid: CGRect
    /// 窗口内容坐标（左上角为原点），自检用来模拟真实鼠标操作
    var window: CGRect
}

struct CardFramesKey: PreferenceKey {
    static let defaultValue: [CGWindowID: CardFrame] = [:]
    static func reduce(value: inout [CGWindowID: CardFrame], nextValue: () -> [CGWindowID: CardFrame]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 圈选框的显示状态。单独发布，拖动时只重绘这一层。
@MainActor
final class MarqueeState: ObservableObject {
    @Published var rect: CGRect?
}

struct MarqueeOverlay: View {
    @ObservedObject var marquee: MarqueeState
    let closeMode: Bool
    let count: Int
    var verb = "关闭"
    var noun = "个窗口"
    /// 整句提示（给出时优先使用）
    var text: String? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let r = marquee.rect {
                let color: Color = closeMode ? .red : .accentColor
                Rectangle()
                    .fill(color.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])))
                    .frame(width: max(r.width, 1), height: max(r.height, 1))
                    .offset(x: r.minX, y: r.minY)
                Text(text ?? (closeMode ? "松开即\(verb) \(count) \(noun) · Esc 取消" : "框选 \(count) \(noun)"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(color.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: r.minX, y: max(0, r.minY - 30))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 一个窗口：像调度中心那样直接浮在背景上——按真实长宽比显示的缩略图（圆角 + 阴影），
/// 应用图标压在缩略图底边正中，名称在图标下方。没有外框和底色。
struct CardView: View {
    let entry: WindowEntry
    let icon: NSImage
    let thumbnail: NSImage?
    let thumbnailFailed: Bool
    let selectionIndex: Int?
    let status: ItemStatus?
    let selectable: Bool
    let closeOnClick: Bool
    let width: CGFloat
    let hovering: Bool
    let inMarquee: Bool
    let vanishing: Bool
    let onHover: (Bool) -> Void

    static let iconSize: CGFloat = 44
    var selected: Bool { selectionIndex != nil }
    /// 缩略图可占的最大区域
    var boxHeight: CGFloat { width * 0.62 }

    /// 按窗口真实长宽比放进区域里的尺寸（缩略图还没到时也按这个尺寸占位，避免跳动）
    var fitted: CGSize {
        let boxW = width - 8, boxH = boxHeight
        let b = entry.bounds
        var ar = b.height > 0 ? b.width / b.height : 1.6
        if let t = thumbnail, t.size.height > 0 { ar = t.size.width / t.size.height }
        ar = min(max(ar, 0.45), 3.2)
        return boxW / boxH > ar ? CGSize(width: boxH * ar, height: boxH) : CGSize(width: boxW, height: boxW / ar)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            hotContent
                .onHover(perform: onHover)
                // 只有“缩略图 + 图标 + 名称”这块算卡片；四周的空白算空白处
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardFramesKey.self,
                                           value: [entry.id: CardFrame(grid: g.frame(in: .named(CardGrid.space)), window: g.frame(in: .global))])
                })
        }
        .frame(width: width)
        .frame(minHeight: boxHeight + 48, alignment: .bottom)
        // 关闭成功：淡出并缩小
        .opacity(vanishing ? 0 : 1)
        .scaleEffect(vanishing ? 0.82 : 1)
        .blur(radius: vanishing ? 6 : 0)
        .animation(.easeOut(duration: 0.3), value: vanishing)
        .help(tooltip)
    }

    var hotContent: some View {
        VStack(spacing: 0) {
            windowView
            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if entry.isBrowser {
                        Text("浏览器窗口")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.45), in: Capsule())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .help("按窗口关闭：会同时关闭这个窗口里的所有标签页")
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                if let status, !status.detail.isEmpty {
                    Text(status.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusColor(status))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.55), radius: 2)
                } else if case .blocked(let reason) = entry.closability {
                    Text(reason)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.55), radius: 2)
                }
            }
            .frame(maxWidth: width)
            .padding(.top, Self.iconSize / 2 + 5)
        }
    }

    var windowView: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(Color.white.opacity(0.08))
                Group {
                    if thumbnailFailed {
                        Text("无预览").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .offset(y: -Self.iconSize / 3)
            }
            if let status {
                StatusOverlay(status: status)
            } else if inMarquee {
                ZStack {
                    (closeOnClick ? Color.red : Color.accentColor).opacity(0.32)
                    Label(closeOnClick ? "将关闭" : "将选中", systemImage: closeOnClick ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else if closeOnClick && hovering && selectable && entry.isClosable {
                ZStack {
                    Color.black.opacity(0.32)
                    VStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white, .red)
                        Text("点击关闭此窗口").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .clipShape(shape)
        // 窗口自身的细边（像真实窗口），以及悬停/选中/圈选时的高亮边
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .overlay(shape.strokeBorder(highlight ?? .clear, lineWidth: highlight == nil ? 0 : 3))
        .shadow(color: .black.opacity(0.38), radius: 14, y: 8)
        .opacity(entry.isClosable || status != nil ? 1 : 0.45)
        .overlay(alignment: .topTrailing) {
            if let i = selectionIndex, status == nil {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Circle().strokeBorder(.white, lineWidth: 2)
                    Text("\(i)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                .offset(x: 8, y: -8)
                .shadow(radius: 3)
            }
        }
        // 应用图标压在缩略图底边正中，一半盖在缩略图上
        .overlay(alignment: .bottom) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .offset(y: Self.iconSize / 2)
        }
    }

    var highlight: Color? {
        if inMarquee { return closeOnClick ? .red : .accentColor }
        if selected { return .accentColor }
        if hovering && selectable && entry.isClosable && status == nil { return closeOnClick ? .red : Color.white.opacity(0.7) }
        return nil
    }

    /// 鼠标悬停提示：完整的窗口标题
    var tooltip: String {
        let title = entry.title.isEmpty ? "（无标题窗口）" : entry.title
        if let reason = entry.closability.reasonText { return "\(entry.appName)：\(title)\n\(reason)" }
        return "\(entry.appName)：\(title)"
    }

    func statusColor(_ s: ItemStatus) -> Color {
        switch s {
        case .closed: return .green
        case .waitingUser: return .orange
        case .failed: return .red
        default: return .white.opacity(0.8)
        }
    }
}

extension WindowEntry.Closability {
    var reasonText: String? {
        if case .blocked(let r) = self { return r }
        return nil
    }
}

struct StatusOverlay: View {
    let status: ItemStatus

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(status == .queued ? 0.25 : 0.55))
            VStack(spacing: 6) {
                switch status {
                case .working:
                    ProgressView().controlSize(.regular)
                default:
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(status.category)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }

    var symbol: String {
        switch status {
        case .queued: return "clock"
        case .working: return "hourglass"
        case .closed: return "checkmark.circle.fill"
        case .waitingUser: return "pause.circle.fill"
        case .skipped: return "arrow.uturn.right.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch status {
        case .closed: return .green
        case .waitingUser: return .orange
        case .failed: return .red
        default: return .white.opacity(0.8)
        }
    }
}

// MARK: 底部

/// 底部：只放按钮（和处理结果），居中
struct BottomBar: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch model.phase {
            case .selecting:
                if model.closeOnClick { clickBar } else { selectingBar }
            case .running, .paused:
                ProgressView().controlSize(.small)
                Text("正在处理 \(model.runIndex) / \(model.runTotal)")
                    .font(.system(size: 13, weight: .medium))
                Button("停止剩余", action: actions.stop)
                    .disabled(model.stopRequested)
            case .finished:
                counts
                Button("重新整理列表", action: actions.refresh)
                Button("完成", action: actions.finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .loading, .needsPermission:
                Button("退出（Esc）", action: actions.dismiss)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 16)
        .frame(maxWidth: .infinity)
    }

    /// 处理结果（有结果时才显示）
    @ViewBuilder var counts: some View {
        let s = model.summary, a = model.appSummary, t = model.tabSummary
        if model.page == .windows {
            if s.closed + s.waiting + s.skipped + s.failed > 0 { ResultCounts(title: "窗口", done: "已关闭", s: s) }
            if a.closed + a.waiting + a.skipped + a.failed > 0 { ResultCounts(title: "应用", done: "已退出", s: a) }
        } else if t.closed + t.waiting + t.skipped + t.failed > 0 {
            ResultCounts(title: "标签页", done: "已关闭", s: t)
        }
    }

    @ViewBuilder var clickBar: some View {
        if model.activeCount > 0 {
            ProgressView().controlSize(.small)
            Text("还有 \(model.activeCount) 项").font(.system(size: 13, weight: .medium))
        }
        counts
        ModePicker(model: model)
        Button(model.activeCount > 0 ? "停止并退出（Esc）" : "完成（Esc）", action: actions.dismiss)
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder var selectingBar: some View {
        Text(selectionTitle)
            .font(.system(size: 13, weight: .semibold))
            .accessibilityIdentifier("selection-count")
        ModePicker(model: model)
        Button("取消全选", action: { model.clearSelection() })
            .disabled(model.selection.isEmpty)
        Button("退出（Esc）", action: actions.dismiss)
        Button(action: actions.closeSelected) {
            Label(closeButtonTitle, systemImage: "xmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(model.selection.isEmpty)
        .accessibilityIdentifier("close-selected")
    }

    var selectionTitle: String {
        var parts: [String] = []
        if !model.selectedEntries.isEmpty { parts.append("\(model.selectedEntries.count) 个窗口") }
        if !model.selectedApps.isEmpty { parts.append("\(model.selectedApps.count) 个应用") }
        if !model.selectedTabs.isEmpty { parts.append("\(model.selectedTabs.count) 个标签页") }
        return parts.isEmpty ? "未选择" : "已选 " + parts.joined(separator: "、")
    }

    var closeButtonTitle: String {
        let w = !model.selectedEntries.isEmpty, a = !model.selectedApps.isEmpty, t = !model.selectedTabs.isEmpty
        if a && !w && !t { return "退出所选应用" }
        if t && !w && !a { return "关闭所选标签页" }
        if w && !a && !t { return "关闭所选窗口" }
        return a ? "关闭 / 退出所选" : "关闭所选"
    }
}

// MARK: 浏览器标签页页面

struct TabFramesKey: PreferenceKey {
    static let defaultValue: [TabKey: CardFrame] = [:]
    static func reduce(value: inout [TabKey: CardFrame], nextValue: () -> [TabKey: CardFrame]) {
        value.merge(nextValue()) { $1 }
    }
}

struct GroupFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 第二个页签：专门管理浏览器标签页。按窗口分组，点一下关闭，拖动框选多个。
struct BrowserTabsPage: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions
    static let space = "tabGrid"
    static let spacing: CGFloat = 10

    var body: some View {
        switch model.tabsPhase {
        case .idle, .loading:
            ProgressView("正在读取浏览器标签页…").controlSize(.large)
        case .noBrowser:
            message(icon: "globe", title: "没有正在运行的 Chrome",
                    detail: "目前支持 Google Chrome，以及同样提供 Chrome 脚本接口的 Microsoft Edge、Brave、Chromium。")
        case .needsPermission(let names):
            permission(names, denied: false)
        case .denied(let names):
            permission(names, denied: true)
        case .error(let text):
            VStack(spacing: 12) {
                message(icon: "exclamationmark.triangle", title: "无法读取标签页", detail: text)
                Button("重试", action: actions.reloadTabs)
            }
        case .ready:
            content
        }
    }

    func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
        }
    }

    func permission(_ names: [String], denied: Bool) -> some View {
        let list = names.joined(separator: "、")
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                Text(denied ? "你没有允许“窗口清理”控制 \(list)" : "需要你允许“窗口清理”控制 \(list)")
                    .font(.system(size: 18, weight: .semibold))
            }
            Text("只用来读取每个窗口里的标签页标题和网址，并在你点击时关闭对应的标签页。不读取网页内容，不上传、不保存。标签页按浏览器内部的唯一编号关闭，不会因为同名而关错。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if denied {
                Text("请到 系统设置 › 隐私与安全性 › 自动化，在“窗口清理”下面打开 \(list) 的开关，然后回到这里点“重试”。")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("打开系统设置", action: actions.openAutomationSettings)
                    Button("重试", action: actions.reloadTabs)
                }
            } else {
                Text("点下面的按钮后，系统会弹出询问，请点“好”或“允许”。")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Button("允许读取标签页", action: actions.requestTabsPermission)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(maxWidth: 620)
        .glassPanel(cornerRadius: 20, clear: false)
    }

    @ViewBuilder var content: some View {
        let groups = model.displayGroups
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索标签页标题或网址", text: $model.tabFilter)
                        .textFieldStyle(.plain)
                        .frame(width: 300)
                    if !model.tabFilter.isEmpty {
                        Button { model.tabFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Picker("", selection: $model.tabGrouping) {
                    Text("按窗口").tag(TabGrouping.byWindow)
                    Text("按网站").tag(TabGrouping.bySite)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("标签页的分组方式")
                Text("\(model.browserGroups.count) 个窗口 · \(model.tabCount) 个标签页" + (model.tabFilter.isEmpty ? "" : " · 匹配 \(groups.reduce(0) { $0 + $1.items.count }) 个"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            if groups.isEmpty {
                message(icon: model.tabFilter.isEmpty ? "checkmark.circle" : "magnifyingglass",
                        title: model.tabFilter.isEmpty ? "标签页都关好了" : "没有匹配的标签页",
                        detail: model.tabFilter.isEmpty ? "点空白处或按 Esc 退出。" : "换个关键词试试。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(groups) { g in
                                groupView(g)
                                    .background(GeometryReader { gg in
                                        Color.clear.preference(key: GroupFramesKey.self, value: [g.id: gg.frame(in: .named(Self.space))])
                                    })
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .overlay(MarqueeOverlay(marquee: model.tabMarquee, closeMode: model.closeOnClick,
                                                count: model.tabMarqueeKeys.count, verb: "关闭", noun: "个标签页"))
                        .coordinateSpace(name: Self.space)
                        .gesture(pointerGesture)
                        .onPreferenceChange(TabFramesKey.self) { f in MainActor.assumeIsolated { model.tabFrames = f } }
                        .onPreferenceChange(GroupFramesKey.self) { f in MainActor.assumeIsolated { model.groupFrames = f } }
                    }
                }
            }
        }
    }

    @ViewBuilder func groupHeader(_ g: TabDisplayGroup) -> some View {
        let open = g.items.filter { !model.vanishedTabs.contains($0.key) }
        HStack(spacing: 10) {
            switch g.kind {
            case .window(let cardID, let appName, let pid):
                if let card = cardID, let thumb = model.thumbnails[card] {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(nsImage: model.icon(for: pid)).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title.isEmpty ? "（无标题窗口）" : g.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(appName) 的窗口 · \(open.count) 个标签页" + (cardID == nil ? "（不在当前桌面，或已最小化）" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .site:
                if let icon = g.items.lazy.compactMap({ tileIcon($0.tab, pid: $0.key.pid) }).first {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: 22, height: 22)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: siteIcon(g.title))
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(open.count) 个标签页" + (g.windowCount > 1 ? " · 分布在 \(g.windowCount) 个窗口" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .site = g.kind, model.phase == .selecting {
                let pending = open.filter { model.tabStatuses[$0.key] == nil }.map(\.key)
                if pending.count > 1 {
                    Button {
                        actions.closeTabGroup(pending)
                    } label: {
                        Label(model.closeOnClick ? "全部关闭（\(pending.count)）" : "全部选中（\(pending.count)）",
                              systemImage: model.closeOnClick ? "xmark.circle" : "checkmark.circle")
                    }
                    .controlSize(.small)
                    .help(model.closeOnClick ? "依次关闭“\(g.title)”的全部 \(pending.count) 个标签页" : "选中“\(g.title)”的全部标签页")
                }
            }
        }
    }

    /// 标签页图标：网站图标 → 浏览器自己的页面用浏览器图标 → 本地文件用文档图标 → 地球
    func tileIcon(_ t: BrowserTab, pid: pid_t) -> NSImage? {
        if let f = model.favicon(for: t.url) { return f }
        switch BrowserTabSupport.siteName(for: t.url) {
        case BrowserTabSupport.internalPagesName: return model.icon(for: pid)
        default: return nil
        }
    }

    func siteIcon(_ site: String) -> String {
        switch site {
        case BrowserTabSupport.internalPagesName: return "gearshape"
        case BrowserTabSupport.localFilesName: return "doc"
        case BrowserTabSupport.otherName: return "questionmark.circle"
        default: return "globe"
        }
    }

    func groupView(_ g: TabDisplayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groupHeader(g)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: Self.spacing, alignment: .top)],
                      alignment: .leading, spacing: Self.spacing) {
                ForEach(g.items) { item in
                    let k = item.key
                    let t = item.tab
                    TabTile(tab: t,
                            icon: tileIcon(t, pid: k.pid),
                            status: model.tabStatuses[k],
                            selectionIndex: model.tabSelectionIndex(k),
                            closeOnClick: model.closeOnClick,
                            selectable: model.phase == .selecting,
                            hovering: model.hoveredTab == k && !model.marqueeActive,
                            inMarquee: model.tabMarqueeKeys.contains(k),
                            vanishing: model.vanishedTabs.contains(k))
                        .onHover { h in
                            if h { model.hoveredTab = k } else if model.hoveredTab == k { model.hoveredTab = nil }
                        }
                        .background(GeometryReader { gg in
                            Color.clear.preference(key: TabFramesKey.self,
                                                   value: [k: CardFrame(grid: gg.frame(in: .named(Self.space)), window: gg.frame(in: .global))])
                        })
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("标签页：\(t.title)")
                        .accessibilityAction { actions.tabClicked(k) }
                }
            }
        }
        .padding(12)
        .glassTile(cornerRadius: 14, fill: Color.white.opacity(0.05))
    }

    /// 单击与圈选共用一个手势：移动不超过 6 点算单击，否则为圈选
    var pointerGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                guard model.phase == .selecting, !model.marqueeCancelled else { return }
                if !model.marqueeActive {
                    if hypot(v.translation.width, v.translation.height) < 6 { return }
                    model.marqueeActive = true
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                model.tabMarquee.rect = r
                var keys = Set<TabKey>()
                for g in model.displayGroups {
                    for item in g.items where model.tabStatuses[item.key] == nil && model.tabFrames[item.key]?.grid.intersects(r) == true {
                        keys.insert(item.key)
                    }
                }
                if keys != model.tabMarqueeKeys { model.tabMarqueeKeys = keys }
            }
            .onEnded { v in
                defer { model.endMarquee() }
                guard model.phase == .selecting, !model.marqueeCancelled else { return }
                if model.marqueeActive {
                    let ordered = model.displayGroups.flatMap { $0.items.map(\.key) }.filter { model.tabMarqueeKeys.contains($0) }
                    if !ordered.isEmpty { actions.tabMarqueeFinished(ordered) }
                } else if let k = model.tabFrames.first(where: { $0.value.grid.contains(v.location) })?.key {
                    actions.tabClicked(k)
                } else if !model.groupFrames.values.contains(where: { $0.contains(v.location) }) {
                    // 不在任何窗口分组里的空白处：退出总览（分组里标签页之间的缝隙不算）
                    actions.backgroundClicked()
                }
            }
    }
}

struct TabTile: View {
    let tab: BrowserTab
    var icon: NSImage?
    let status: ItemStatus?
    let selectionIndex: Int?
    let closeOnClick: Bool
    let selectable: Bool
    let hovering: Bool
    let inMarquee: Bool
    let vanishing: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                switch status {
                case .working?: ProgressView().controlSize(.small)
                case .queued?: Image(systemName: "clock.fill").foregroundStyle(.secondary)
                case .waitingUser?: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                case .skipped?, .failed?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .closed?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case nil:
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: tab.url.hasPrefix("file:") ? "doc" : "globe").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 15))
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? "（无标题）" : tab.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(tab.host).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    if tab.isActive {
                        Text("当前").font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                }
                if let status, case .skipped = status { detail(status) }
                if let status, case .failed = status { detail(status) }
                if let status, case .waitingUser = status { detail(status) }
            }
            Spacer(minLength: 0)
            if let i = selectionIndex {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Text("\(i)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)
            } else if status == nil && closeOnClick && (hovering || inMarquee) && selectable {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, .red)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minHeight: 50)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(borderStyle, lineWidth: inMarquee || selectionIndex != nil ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(vanishing ? 0 : 1)
        .scaleEffect(vanishing ? 0.9 : 1)
        .animation(.easeOut(duration: 0.25), value: vanishing)
        .help(tab.title + "\n" + tab.url)
    }

    func detail(_ s: ItemStatus) -> some View {
        Text(s.detail).font(.system(size: 10)).foregroundStyle(s.category == "等待你处理" ? .orange : .red).lineLimit(2)
    }

    var fill: Color {
        if inMarquee { return (closeOnClick ? Color.red : Color.accentColor).opacity(0.25) }
        if selectionIndex != nil { return Color.accentColor.opacity(0.22) }
        if hovering && selectable && status == nil { return closeOnClick ? Color.red.opacity(0.16) : Color.white.opacity(0.1) }
        return Color.white.opacity(0.05)
    }

    var borderStyle: AnyShapeStyle {
        if inMarquee { return AnyShapeStyle(closeOnClick ? Color.red : Color.accentColor) }
        if selectionIndex != nil { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: 应用栏

struct AppFramesKey: PreferenceKey {
    static let defaultValue: [pid_t: CardFrame] = [:]
    static func reduce(value: inout [pid_t: CardFrame], nextValue: () -> [pid_t: CardFrame]) {
        value.merge(nextValue()) { $1 }
    }
}

extension AppBar {
    static let space = "appBar"
}

struct AppBar: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions
    static let rowHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            // 一行放下所有图标；应用很多时每个图标位自动变窄（不横向滚动）
            let n = CGFloat(max(model.apps.count, 1))
            let item = min(84, max(48, (geo.size.width - 40) / n))
            HStack(spacing: 0) {
                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, a in
                    AppIconView(app: a,
                                status: model.appStatuses[a.id],
                                selectionIndex: model.appSelectionIndex(a.id),
                                closeOnClick: model.closeOnClick,
                                selectable: model.phase == .selecting,
                                hovering: model.hoveredApp == a.id && !model.marqueeActive,
                                inMarquee: model.appMarqueeIDs.contains(a.id),
                                vanishing: model.vanishedApps.contains(a.id),
                                width: item - 6)
                        .frame(width: item)
                        .onHover { h in
                            if h { model.hoveredApp = a.id } else if model.hoveredApp == a.id { model.hoveredApp = nil }
                        }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AppFramesKey.self,
                                                   value: [a.id: CardFrame(grid: g.frame(in: .named(Self.space)), window: g.frame(in: .global))])
                        })
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("退出 \(a.name)")
                        .accessibilityAction { actions.appClicked(a) }
                        .opacity(model.cardsRevealed ? 1 : 0)
                        .offset(y: model.cardsRevealed || model.reduceMotion ? 0 : 10)
                        .animation(model.reduceMotion ? .easeOut(duration: 0.15)
                                   : .spring(response: 0.4, dampingFraction: 0.85).delay(0.08 + min(Double(index) * 0.02, 0.25)),
                                   value: model.cardsRevealed)
                }
            }
            .frame(height: Self.rowHeight)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassPanel(cornerRadius: 18)
            .background(GeometryReader { g in
                Color.clear.preference(key: AppPanelFrameKey.self, value: g.frame(in: .global))
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(AppFramesKey.self) { frames in
                MainActor.assumeIsolated { model.appFrames = frames }
            }
            .onPreferenceChange(AppPanelFrameKey.self) { f in
                MainActor.assumeIsolated { model.appPanelFrame = f }
            }
        }
        .frame(height: Self.rowHeight + 12 + 22)
    }
}

struct AppPanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

struct AppIconView: View {
    let app: AppEntry
    let status: ItemStatus?
    let selectionIndex: Int?
    let closeOnClick: Bool
    let selectable: Bool
    let hovering: Bool
    var inMarquee = false
    let vanishing: Bool
    var width: CGFloat = 78

    var iconSize: CGFloat { width >= 66 ? 46 : 36 }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                        .opacity(status == nil || status == .queued ? 1 : 0.55)
                    if let status {
                        switch status {
                        case .queued:
                            Image(systemName: "clock.fill").font(.system(size: 16)).foregroundStyle(.white).shadow(radius: 2)
                        case .working:
                            ProgressView().controlSize(.small)
                        case .waitingUser:
                            Image(systemName: "pause.circle.fill").font(.system(size: 22)).foregroundStyle(.orange)
                        case .skipped, .failed:
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                        case .closed:
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
                        }
                    }
                }
                if let i = selectionIndex {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Text("\(i)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                    .offset(x: 6, y: -4)
                }
            }
            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        }
        .frame(width: width)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(borderColor, lineWidth: borderColor == .clear ? 0 : 2))
        .opacity(vanishing ? 0 : 1)
        .scaleEffect(vanishing ? 0.7 : 1)
        .animation(.easeOut(duration: 0.3), value: vanishing)
        .help(helpText)
    }

    var subtitle: String {
        if let status {
            switch status {
            case .queued: return "排队中"
            case .working: return "正在退出…"
            case .closed: return "已退出"
            case .waitingUser: return "等待你处理"
            case .skipped, .failed: return "未退出"
            }
        }
        if inMarquee { return closeOnClick ? "将退出" : "将选中" }
        if hovering && selectable && closeOnClick { return "点击退出" }
        if app.windowCount > 0 { return "\(app.windowCount) 个窗口" }
        return app.isHidden ? "已隐藏" : "后台运行"
    }

    var subtitleColor: Color {
        switch status {
        case .closed?: return .green
        case .waitingUser?: return .orange
        case .skipped?, .failed?: return .red
        default: return (inMarquee || hovering && selectable) && closeOnClick && status == nil ? .red : .secondary
        }
    }

    /// 红色包裹：单击即关闭模式下悬停或被框选时；先选再关模式下选中时为蓝色
    var borderColor: Color {
        if inMarquee { return closeOnClick ? .red : .accentColor }
        if selectionIndex != nil { return .accentColor }
        if hovering && selectable && closeOnClick && status == nil { return .red }
        return .clear
    }

    var background: Color {
        if inMarquee { return (closeOnClick ? Color.red : Color.accentColor).opacity(0.25) }
        if selectionIndex != nil { return Color.accentColor.opacity(0.22) }
        if hovering && selectable && status == nil { return closeOnClick ? Color.red.opacity(0.22) : Color.white.opacity(0.1) }
        return .clear
    }

    var helpText: String {
        if let status, !status.detail.isEmpty { return status.detail }
        return closeOnClick ? "点击退出“\(app.name)”（等同 ⌘Q；有未保存内容时应用会询问你）" : "点击选中“\(app.name)”"
    }
}

/// 底部的结果计数，例如“窗口：已关闭 3 · 已跳过 1”
struct ResultCounts: View {
    let title: String
    let done: String
    let s: OverviewModel.Summary

    var body: some View {
        HStack(spacing: 8) {
            Text(title + "：").foregroundStyle(.secondary)
            Label("\(done) \(s.closed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if s.waiting > 0 { Label("等待你处理 \(s.waiting)", systemImage: "pause.circle.fill").foregroundStyle(.orange) }
            if s.skipped > 0 { Label("已跳过 \(s.skipped)", systemImage: "arrow.uturn.right.circle.fill").foregroundStyle(.secondary) }
            if s.failed > 0 { Label("失败 \(s.failed)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

struct ModePicker: View {
    @ObservedObject var model: OverviewModel

    var body: some View {
        Picker("", selection: $model.closeOnClick) {
            Text("单击即关闭").tag(true)
            Text("先选再关").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .disabled(model.activeCount > 0)
        .help("单击即关闭：点一下卡片就关闭那个窗口。先选再关：先点选多个，再点“关闭所选窗口”。")
    }
}

// MARK: 权限

struct PermissionView: View {
    @ObservedObject var model: OverviewModel
    let actions: OverviewActions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("需要你授权后才能使用").font(.system(size: 22, weight: .semibold))
                    Text("窗口清理只在本机运行，不联网；截图只用于显示缩略图，不上传、不保存。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            PermissionRow(title: "辅助功能（必需）",
                          detail: "用来按下你选中窗口左上角的红色关闭按钮，并在关闭前核对窗口身份。没有这项权限就无法关闭任何窗口，也不会显示窗口列表。",
                          granted: model.axTrusted, button: "打开设置", action: actions.openAccessibility)
            PermissionRow(title: "屏幕录制（建议）",
                          detail: "只用来在本机截取窗口缩略图、读取窗口标题。只截静态画面，不录视频、不采集声音；总览关闭后即停止。不授权也能用，但卡片只显示图标。",
                          granted: model.screenRecording, button: "授权", action: actions.openScreenRecording)
            VStack(alignment: .leading, spacing: 4) {
                Text("操作步骤").font(.system(size: 13, weight: .semibold))
                Text("1. 点“打开设置”，系统设置会打开“隐私与安全性 › 辅助功能”。")
                Text("2. 在列表里找到“窗口清理”，打开右侧开关（可能需要输入开机密码）。")
                Text("3. 回到这里点“重新检测”。屏幕录制同理；授权后系统可能要求重新打开本应用，点“重新打开窗口清理”即可。")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            HStack {
                Button("重新检测", action: actions.recheckPermissions)
                Button("重新打开窗口清理", action: actions.relaunch)
                Spacer()
            }
        }
        .padding(28)
        .frame(maxWidth: 660)
        .glassPanel(cornerRadius: 20, clear: false)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(granted ? "已授权" : "未授权")
                        .font(.system(size: 11))
                        .foregroundStyle(granted ? .green : .red)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(button, action: action)
            }
        }
    }
}

// MARK: 浮动小面板（暂停等待用户处理 / 等待授权）

struct PausePanelView: View {
    @ObservedObject var model: OverviewModel
    let onContinue: () -> Void
    let onStop: () -> Void

    var body: some View {
        let remaining = model.remainingCount
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.system(size: 20))
                Text("已暂停：需要你处理确认框").font(.system(size: 14, weight: .semibold))
            }
            if !model.pauseMessage.isEmpty {
                Text(model.pauseMessage)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("请直接在那个对话框里做选择。窗口清理不会替你点任何按钮。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                switch model.pendingState {
                case .stillWaiting:
                    ProgressView().controlSize(.small)
                    Text("等待你处理…").foregroundStyle(.orange)
                case .closed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(model.pauseIsApp ? "应用已退出" : "该窗口已关闭").foregroundStyle(.green)
                case .keptOpen:
                    Image(systemName: "arrow.uturn.right.circle.fill")
                    Text(model.pauseIsApp ? "你取消了退出，应用继续运行" : "你取消了关闭，窗口已保留")
                }
            }
            .font(.system(size: 12, weight: .medium))
            Text(remaining > 0 ? "还有 \(remaining) 项尚未处理。" : "这是最后一项。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                if remaining > 0 {
                    Button("停止，不再处理剩余的", action: onStop)
                }
                Spacer()
                Button(remaining > 0 ? (model.pendingState == .stillWaiting ? "先跳过它，继续下一个" : "继续下一个") : "完成",
                       action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

struct PermissionWaitPanelView: View {
    @ObservedObject var model: OverviewModel
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("请在系统设置中为“窗口清理”授权").font(.system(size: 14, weight: .semibold))
            HStack {
                Image(systemName: model.axTrusted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.axTrusted ? .green : .secondary)
                Text("辅助功能（必需）")
            }
            HStack {
                Image(systemName: model.screenRecording ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.screenRecording ? .green : .secondary)
                Text("屏幕录制（建议）")
            }
            Text("授权屏幕录制后，系统可能要求重新打开本应用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("返回窗口清理", action: onBack).buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 320)
    }
}
