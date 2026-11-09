import AppKit
import SwiftUI
import QuartzCore

/// 只记录缩略图/应用图标的实际边界，坐标相对于中间内容区，工具栏不在其中。
struct CloseFeedbackGeometry: Equatable {
    let rect: CGRect
    let cornerRadius: CGFloat
}

struct CloseFeedbackFramesKey: PreferenceKey {
    static let defaultValue: [QueueItem: CloseFeedbackGeometry] = [:]
    static func reduce(value: inout [QueueItem: CloseFeedbackGeometry], nextValue: () -> [QueueItem: CloseFeedbackGeometry]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 动效与关闭队列独立：不会等待动画，也不会凭动画结果判断是否关闭成功。
@MainActor
final class CloseFeedbackCoordinator {
    static let space = "closeFeedbackContent"
    weak var surface: CloseFeedbackSurface?
    var frames: [QueueItem: CloseFeedbackGeometry] = [:] {
        didSet { surface?.updateFrames(frames) }
    }

    func begin(_ item: QueueItem) {
        guard let geometry = frames[item] else { return }
        surface?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        surface?.begin(item, geometry: geometry)
    }

    func finish(_ item: QueueItem, status: ItemStatus) {
        if case .closed = status { surface?.finish(item, succeeded: true) }
        else { surface?.finish(item, succeeded: false) }
    }

    func reset() {
        surface?.clear()
        frames = [:]
    }
}

struct CloseFeedbackOverlay: NSViewRepresentable {
    let feedback: CloseFeedbackCoordinator

    func makeCoordinator() -> CloseFeedbackCoordinator { feedback }
    func makeNSView(context: Context) -> CloseFeedbackSurface {
        let view = CloseFeedbackSurface()
        feedback.surface = view
        return view
    }
    func updateNSView(_ view: CloseFeedbackSurface, context: Context) {
        // 切换布局时旧视图可能在新视图创建后再收到一次更新，不能把引用重新指回旧视图。
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    static func dismantleNSView(_ view: CloseFeedbackSurface, coordinator: CloseFeedbackCoordinator) {
        view.clear()
        if coordinator.surface === view { coordinator.surface = nil }
    }
}

/// 一个透明的原生合成层。扫光只动画渐变图层，光晕共用一张 256×256 的生成纹理；
/// 不截屏、不重绘 SwiftUI 内容、不启动逐帧计时器，结束后移除全部动画图层。
@MainActor
final class CloseFeedbackSurface: NSView {
    private struct Running {
        let container: CALayer
        let edge: CALayer
        let geometry: CloseFeedbackGeometry
    }
    private struct Fading {
        let container: CALayer
        let cleanup: DispatchWorkItem
    }

    private var running: [QueueItem: Running] = [:]
    private var fading: [UUID: Fading] = [:]
    private var fadingOrder: [UUID] = []
    private var visibilityObserver: NSObjectProtocol?
    var reduceMotion = false
    var activeEffectCount: Int { running.count + fading.count }
    static let maximumHalos = 6
    static let haloDuration = 0.5

    // Spark：紫、浅紫、暖金、浅金，适配目前的深色毛玻璃界面。
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 140 / 255, green: 100 / 255, blue: 1, alpha: 1),
        NSColor(srgbRed: 200 / 255, green: 130 / 255, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 200 / 255, blue: 110 / 255, alpha: 1),
        NSColor(srgbRed: 1, green: 235 / 255, blue: 170 / 255, alpha: 1)
    ]
    private static let haloImage: CGImage? = makeHaloImage()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        guard let window else { clear(); return }
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window?.occlusionState.contains(.visible) != true { self.clear() }
            }
        }
    }

    deinit {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        for effect in fading.values { effect.cleanup.cancel() }
    }

    func begin(_ item: QueueItem, geometry: CloseFeedbackGeometry) {
        guard let layer, window?.isVisible == true, valid(geometry.rect),
              bounds.intersects(geometry.rect), running[item] == nil else { return }
        let container = CALayer()
        container.frame = geometry.rect
        let edge = makeEdge(size: geometry.rect.size, radius: geometry.cornerRadius)
        container.addSublayer(edge)
        withoutImplicitAnimations { layer.addSublayer(container) }
        running[item] = Running(container: container, edge: edge, geometry: geometry)
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = reduceMotion ? 0.45 : 1
        appear.duration = reduceMotion ? 0.18 : 0.08
        edge.opacity = reduceMotion ? 0.45 : 1
        edge.add(appear, forKey: "appear")
    }

    func updateFrames(_ frames: [QueueItem: CloseFeedbackGeometry]) {
        // 页面补位时跟随目标；成功后的光晕留在原位置，不跳到下一个目标身上。
        for item in Array(running.keys) {
            guard let effect = running[item] else { continue }
            guard let geometry = frames[item], valid(geometry.rect), bounds.intersects(geometry.rect) else {
                finish(item, succeeded: false)
                continue
            }
            guard geometry != effect.geometry else { continue }
            withoutImplicitAnimations {
                effect.container.frame = geometry.rect
                if geometry.rect.size != effect.geometry.rect.size {
                    effect.edge.removeFromSuperlayer()
                    let edge = makeEdge(size: geometry.rect.size, radius: geometry.cornerRadius)
                    effect.container.addSublayer(edge)
                    running[item] = Running(container: effect.container, edge: edge, geometry: geometry)
                } else {
                    running[item] = Running(container: effect.container, edge: effect.edge, geometry: geometry)
                }
            }
        }
    }

    func finish(_ item: QueueItem, succeeded: Bool) {
        guard let effect = running.removeValue(forKey: item) else { return }
        guard succeeded, window?.isVisible == true else {
            effect.container.removeFromSuperlayer()
            return
        }
        // 快速连关时限制同时存在的余光；仅回收最旧动效，关闭队列不受影响。
        while fadingOrder.count >= Self.maximumHalos, let oldest = fadingOrder.first { removeFading(oldest) }
        let edgeFade = CABasicAnimation(keyPath: "opacity")
        edgeFade.fromValue = effect.edge.presentation()?.opacity ?? effect.edge.opacity
        edgeFade.toValue = 0
        edgeFade.duration = reduceMotion ? 0.18 : 0.3
        withoutImplicitAnimations { effect.edge.opacity = 0 }
        effect.edge.add(edgeFade, forKey: "finish")

        let halo = CALayer()
        let size = effect.geometry.rect.size
        let diameter = max(size.width, size.height) + (size.width < 100 ? 110 : 180)
        halo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        halo.position = CGPoint(x: size.width / 2, y: size.height / 2)
        halo.contents = Self.haloImage
        halo.opacity = 0
        effect.container.insertSublayer(halo, at: 0)
        let duration = reduceMotion ? 0.6 : Self.haloDuration
        let times = (0...30).map { Double($0) / 30 }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = times.map { NSNumber(value: $0) }
        fade.values = times.map { t in
            NSNumber(value: reduceMotion ? sin(.pi * t) * 0.5 : min(1, t / 0.04) * (1 - pow(t, 2.2)))
        }
        fade.duration = duration
        halo.add(fade, forKey: "haloFade")
        if !reduceMotion {
            let spread = CAKeyframeAnimation(keyPath: "transform.scale")
            spread.keyTimes = fade.keyTimes
            spread.values = times.map { t in NSNumber(value: 0.46 + 0.54 * (1 - pow(1 - t, 3))) }
            spread.duration = duration
            halo.add(spread, forKey: "haloSpread")
        }
        let id = UUID()
        let cleanup = DispatchWorkItem { [weak self] in self?.removeFading(id) }
        fading[id] = Fading(container: effect.container, cleanup: cleanup)
        fadingOrder.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: cleanup)
    }

    func clear() {
        for effect in running.values { effect.container.removeFromSuperlayer() }
        running.removeAll()
        for id in Array(fadingOrder) { removeFading(id) }
    }

    private func removeFading(_ id: UUID) {
        guard let effect = fading.removeValue(forKey: id) else { return }
        effect.cleanup.cancel()
        effect.container.removeFromSuperlayer()
        fadingOrder.removeAll { $0 == id }
    }

    private func makeEdge(size: CGSize, radius: CGFloat) -> CALayer {
        let edge = CALayer()
        edge.frame = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: edge.bounds.insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        // 两条共用色带的细描边形成柔光，不模糊文字、图标或整个窗口。
        for (width, opacity) in [(CGFloat(6), Float(0.18)), (CGFloat(1.8), Float(1))] {
            let band = CALayer()
            band.frame = edge.bounds
            band.opacity = opacity
            let mask = CAShapeLayer()
            mask.frame = band.bounds
            mask.path = path
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            band.mask = mask
            let gradient = CAGradientLayer()
            let side = hypot(size.width, size.height) + 12
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: size.width / 2, y: size.height / 2)
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor] +
                Self.palette.map(\.cgColor) + [NSColor.white.withAlphaComponent(0.95).cgColor, NSColor.clear.cgColor]
            gradient.locations = [0, 0.48, 0.60, 0.72, 0.82, 0.90, 0.95, 1]
            band.addSublayer(gradient)
            edge.addSublayer(band)
            if !reduceMotion {
                let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
                sweep.fromValue = -Double.pi / 3
                sweep.toValue = 5 * Double.pi / 3
                sweep.duration = 0.95
                sweep.repeatCount = .infinity
                gradient.add(sweep, forKey: "edgeSweep")
            }
        }
        return edge
    }

    private func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 2 && rect.height > 2
    }

    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func makeHaloImage() -> CGImage? {
        let pixels = 256
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        for step in 0...64 {
            let location = Double(step) / 64
            let x = (location - 0.64) / 0.09
            let weights = (0..<4).map { exp(-pow((x - (Double($0) - 1.5)) / 0.8, 2)) }
            let sum = max(weights.reduce(0, +), 0.00000001)
            var red = 0.0, green = 0.0, blue = 0.0
            for (index, color) in palette.enumerated() {
                red += color.redComponent * weights[index] / sum
                green += color.greenComponent * weights[index] / sum
                blue += color.blueComponent * weights[index] / sum
            }
            let alpha = step == 0 || step == 64 ? 0 : exp(-1.1 * pow(x / 2, 2)) * 0.28
            components.append(contentsOf: [red, green, blue, alpha])
            locations.append(location)
        }
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: components,
                                        locations: locations, count: locations.count) else { return nil }
        let center = CGPoint(x: pixels / 2, y: pixels / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: CGFloat(pixels) / 2, options: [])
        return context.makeImage()
    }
}
