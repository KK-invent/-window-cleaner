import AppKit
import ScreenCaptureKit

// 定向原生检查：仅通过 --selftest --selftest-close-feedback-only 运行。
// 所有关闭目标均为本次创建的测试宿主，截图只含本工具的测试总览。
extension SelfTestRunner {
    func scenarioCloseFeedback() async {
        previousCloseOnClick = model.closeOnClick
        let previousBlur = OverlayStyle.blur
        OverlayStyle.blur = false
        defer { OverlayStyle.blur = previousBlur }
        model.closeOnClick = true
        controller.allowedPIDs = []
        guard Permissions.accessibility else {
            add("F0", "关闭动效专项", expected: "辅助功能已授权", actual: "权限不足，未操作任何窗口", .notRun)
            return
        }
        let appA = hostsDir.appendingPathComponent("WC测试应用A.app")
        let appB = hostsDir.appendingPathComponent("WC测试应用B.app")
        var slow = spec("A1", 0); slow.closeBehavior = "slow:1"
        var refused = spec("A3", 2); refused.closeBehavior = "refuse"
        hosts["A"] = TestHost(instance: "A", appURL: appA, workDir: workDir,
                              specs: [slow, spec("A2", 1), refused])
        hosts["E"] = TestHost(instance: "E", appURL: appB, workDir: workDir, specs: [spec("E1", 3)])
        do { for h in hosts.values { try h.launch() } }
        catch { add("F0", "启动测试宿主", expected: "仅新建测试窗口", actual: "\(error)", .fail); return }
        guard await waitUntil(10, { self.hosts.values.allSatisfy { h in h.specs.allSatisfy { h.number($0.label) != nil } } }) else {
            add("F0", "启动测试宿主", expected: "测试窗口就绪", actual: "超时", .fail); return
        }
        controller.allowedPIDs = Set(hosts.values.map(\.pid))
        await wait(1)
        guard await openOverview(), model.phase == .selecting else {
            add("F0", "打开测试总览", expected: "可选择测试窗口", actual: "未就绪", .fail); return
        }
        await wait(0.5)
        guard let surface = model.closeFeedback.surface, let entryA = entry("A1"),
              let geometry = model.closeFeedback.frames[.window(entryA.id)],
              let appGeometry = model.closeFeedback.frames[.app(host("E").pid)] else {
            let windowID = entry("A1")?.id.description ?? "缺失"
            let hasApp = model.app(host("E").pid) != nil
            let detail = "动效层=\(model.closeFeedback.surface != nil)，动效边界=\(model.closeFeedback.frames.count)，卡片=\(model.entries.count)，应用=\(model.apps.count)，A1=\(windowID)，E图标=\(hasApp)，原卡片边界=\(model.cardFrames.count)，原图标边界=\(model.appFrames.count)"
            add("F0", "关闭动效定位", expected: "获取窗口和应用图标边界", actual: detail, .fail); return
        }
        let overlay = NSApp.windows.first { $0.title == "扫把" && $0.isVisible }
        // 测试截图不透出用户的真实桌面内容。
        overlay?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1)
        let shareable = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let captureWindow = shareable?.windows.first { $0.windowID == CGWindowID(overlay?.windowNumber ?? 0) }
        let frame = surface.convert(surface.bounds, to: overlay?.contentView)
        add("F1", "效果裁切与点击穿透", expected: "动效区避开工具栏且不拦截鼠标",
            actual: "内容区 \(frame)，窗口/应用目标均在内容区，hitTest 返回空",
            geometry.rect.intersects(surface.bounds) && appGeometry.rect.intersects(surface.bounds) &&
                frame.minY > 20 && frame.maxY < (overlay?.contentView?.bounds.height ?? 0) - 40 &&
                surface.hitTest(CGPoint(x: geometry.rect.midX, y: geometry.rect.midY)) == nil ? .pass : .fail)

        var actualMouse = false
        if let card = controller.cardWindowFrame(entryA.id) {
            await controller.simulateClick(at: CGPoint(x: card.midX, y: card.midY))
            actualMouse = await waitUntil(0.4) { self.model.statuses[entryA.id] != nil }
        }
        if !actualMouse { controller.cardClicked(entryA) }
        _ = await waitUntil(0.5) { surface.activeEffectCount > 0 }
        let edgeVisible = surface.activeEffectCount > 0
        await wait(0.18)
        await captureFeedback(captureWindow, name: "01-窗口边缘扫光")
        _ = await waitUntil(6) { self.model.statuses[entryA.id]?.isFinal == true }
        let haloVisible = surface.activeEffectCount > 0
        await wait(0.18)
        await captureFeedback(captureWindow, name: "02-关闭成功光晕")
        _ = await waitUntil(2) { surface.activeEffectCount == 0 }
        add("F2", "真实关闭窗口与光晕回收", expected: "处理时扫光，成功后光晕，随后无残留图层；另一窗口保留",
            actual: "扫光=\(edgeVisible)，光晕=\(haloVisible)，剩余动效=\(surface.activeEffectCount)，A1已关=\(!host("A").isOpen("A1"))，A2保留=\(host("A").isOpen("A2"))；\(actualMouse ? "真实鼠标事件" : "鼠标注入未生效，直接调用点击处理")",
            edgeVisible && haloVisible && surface.activeEffectCount == 0 && isClosed(model.statuses[entryA.id]) &&
                !host("A").isOpen("A1") && host("A").isOpen("A2") ? .pass : .fail)
        _ = await waitUntil(3) { !self.controller.isBusy }
        let e = host("E")
        let realAppMouse = await clickApp(e)
        _ = await waitUntil(6) { self.model.appStatuses[e.pid]?.isFinal == true }
        let appHalo = surface.activeEffectCount > 0
        await wait(0.18)
        await captureFeedback(captureWindow, name: "03-退出应用光晕")
        _ = await waitUntil(2) { surface.activeEffectCount == 0 }
        add("F3", "真实退出应用与光晕", expected: "测试应用退出、光晕释放，其他测试应用保留",
            actual: "E退出=\(!e.isRunning)，光晕=\(appHalo)，剩余动效=\(surface.activeEffectCount)，A运行=\(host("A").isRunning)；\(realAppMouse ? "真实鼠标事件" : "鼠标注入未生效，直接调用点击处理")",
            !e.isRunning && appHalo && surface.activeEffectCount == 0 && host("A").isRunning ? .pass : .fail)
        _ = await waitUntil(3) { !self.controller.isBusy }
        if let refusedEntry = entry("A3") {
            controller.cardClicked(refusedEntry)
            _ = await waitUntil(8) { self.model.statuses[refusedEntry.id]?.isFinal == true }
            add("F4", "拒绝关闭不会播成功光晕", expected: "目标保留、动效立即清理",
                actual: "A3仍在=\(host("A").isOpen("A3"))，剩余动效=\(surface.activeEffectCount)",
                host("A").isOpen("A3") && isFailed(status("A3")) && surface.activeEffectCount == 0 ? .pass : .fail)
        }
        // 以下只向动效层输入演示事件，不发送任何窗口/应用关闭请求。
        for i in 0..<16 {
            let key = QueueItem.window(CGWindowID(900_000 + i))
            surface.begin(key, geometry: geometry)
            surface.finish(key, succeeded: true)
        }
        let capped = surface.activeEffectCount == CloseFeedbackSurface.maximumHalos
        await wait(0.85)
        add("F5", "快速连续触发与空闲回收", expected: "最多6个余光，结束后图层归零",
            actual: "数量上限正确=\(capped)，剩余动效=\(surface.activeEffectCount)，图层数=\(surface.layer?.sublayers?.count ?? 0)",
            capped && surface.activeEffectCount == 0 && (surface.layer?.sublayers?.isEmpty ?? true) ? .pass : .fail)
        func containsAnimation(_ key: String, in layer: CALayer?) -> Bool {
            guard let layer else { return false }
            return layer.animation(forKey: key) != nil || (layer.sublayers ?? []).contains { containsAnimation(key, in: $0) }
        }
        surface.reduceMotion = true
        surface.begin(.window(900_100), geometry: geometry)
        let noSweep = !containsAnimation("edgeSweep", in: surface.layer)
        surface.finish(.window(900_100), succeeded: true)
        let noSpread = !containsAnimation("haloSpread", in: surface.layer)
        await wait(0.18)
        await captureFeedback(captureWindow, name: "04-减弱动态效果")
        await wait(0.65)
        add("F6", "减弱动态效果", expected: "只有淡入淡出，没有旋转或扩散，结束后释放",
            actual: "无旋转=\(noSweep)，无扩散=\(noSpread)，剩余动效=\(surface.activeEffectCount)",
            noSweep && noSpread && surface.activeEffectCount == 0 ? .pass : .fail)
        surface.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        surface.begin(.window(900_200), geometry: geometry)
        surface.finish(.window(900_200), succeeded: true)
        closeOverview()
        add("F7", "收起界面立即停止动效", expected: "所有动画及延迟清理任务移除",
            actual: "剩余动效=\(surface.activeEffectCount)，图层数=\(surface.layer?.sublayers?.count ?? 0)",
            surface.activeEffectCount == 0 && (surface.layer?.sublayers?.isEmpty ?? true) ? .pass : .fail)
    }

    private func captureFeedback(_ window: SCWindow?, name: String) async {
        guard let window else { note("未截图：系统未提供测试总览的截图句柄"); return }
        do {
            let image = try await ThumbnailLoader.capture(window, maxPixelSize: CGSize(width: 1512, height: 1000))
            let rep = NSBitmapImageRep(cgImage: image)
            try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try data.write(to: reportDir.appendingPathComponent(name + ".png"))
            note("测试界面截图：\(name).png")
        } catch { note("测试界面截图失败：\(error)") }
    }
}
