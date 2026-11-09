import AppKit

// 定向计时检查：仅通过 --selftest --selftest-close-timing 运行。
// 只启动并操作本次新建的测试宿主（进程白名单保护），用于比较优化前后的关闭和退出耗时。
extension SelfTestRunner {
    func scenarioCloseTiming() async {
        previousCloseOnClick = model.closeOnClick
        model.closeOnClick = true
        controller.allowedPIDs = []
        guard Permissions.accessibility else {
            add("T0", "关闭计时", expected: "辅助功能已授权", actual: "权限不足，未操作任何窗口", .notRun)
            return
        }
        let appA = hostsDir.appendingPathComponent("WC测试应用A.app")
        let appB = hostsDir.appendingPathComponent("WC测试应用B.app")
        // 一个应用开 8 个窗口：辅助功能核对的开销会随窗口数增长
        hosts["A"] = TestHost(instance: "A", appURL: appA, workDir: workDir, specs: (0..<9).map { spec("A\($0 + 1)", $0) })
        hosts["Q"] = TestHost(instance: "Q", appURL: appB, workDir: workDir, specs: [spec("Q1", 9)])
        hosts["R"] = TestHost(instance: "R", appURL: appB, workDir: workDir, specs: [])
        // 两个“收尾慢”的应用：收到退出请求后 1.5 秒才退出
        let s1 = TestHost(instance: "S", appURL: appB, workDir: workDir, specs: [])
        s1.quitDelay = 1.5
        let s2 = TestHost(instance: "U", appURL: appA, workDir: workDir, specs: [])
        s2.quitDelay = 1.5
        hosts["S"] = s1
        hosts["U"] = s2
        // 两个都有未保存文档的应用：同时退出时两个保存提示依次交给“用户”（自动点取消）
        var v1 = spec("V1", 11); v1.dirty = true; v1.autoResponse = "cancel"; v1.autoResponseDelay = 1.2
        var w1 = spec("W1", 12); w1.dirty = true; w1.autoResponse = "cancel"; w1.autoResponseDelay = 2.0
        hosts["V"] = TestHost(instance: "V", appURL: appA, workDir: workDir, specs: [v1])
        hosts["W"] = TestHost(instance: "W", appURL: appB, workDir: workDir, specs: [w1])
        do { for h in hosts.values { try h.launch() } }
        catch { add("T0", "启动测试宿主", expected: "仅新建测试窗口", actual: "\(error)", .fail); return }
        guard await waitUntil(12, { self.hosts.values.allSatisfy { h in h.specs.allSatisfy { h.number($0.label) != nil } } }) else {
            add("T0", "启动测试宿主", expected: "测试窗口就绪", actual: "超时", .fail); return
        }
        controller.allowedPIDs = Set(hosts.values.map(\.pid))
        await wait(1.2)
        guard await openOverview(), model.phase == .selecting else {
            add("T0", "打开测试总览", expected: "可选择测试窗口", actual: "未就绪", .fail); return
        }
        await wait(0.5)

        // 1. 逐个单击关闭：每次等上一个确认后再点，测单个窗口从点击到确认关闭的时间
        var singles: [Int] = []
        for label in ["A1", "A3", "A5"] {
            guard let e = entry(label) else { continue }
            let t0 = CACurrentMediaTime()
            controller.cardClicked(e)
            var trace: [String] = []
            var last = ""
            _ = await pollUntil(6) {
                var raw: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(e.id))
                let arr = CFArrayCreate(kCFAllocatorDefault, &raw, 1, nil)!
                let d = (CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]])?.first
                let state = d == nil ? "已销毁" :
                    "在屏=\((d?[kCGWindowIsOnscreen as String] as? Bool) ?? false) 透明度=\((d?[kCGWindowAlpha as String] as? Double) ?? -1)"
                if state != last { trace.append("\(Int((CACurrentMediaTime() - t0) * 1000))ms \(state)"); last = state }
                return self.model.statuses[e.id]?.isFinal == true
            }
            note("\(label) 窗口状态变化：" + trace.joined(separator: " → "))
            singles.append(Int((CACurrentMediaTime() - t0) * 1000))
            note("\(label)：\(model.statuses[e.id]?.category ?? "无状态")；\(controller.executor.lastTiming.text)")
            await wait(0.3)
        }
        // 2. 快速连点两个：测第二个要排队多久
        var burst = 0
        if let e1 = entry("A2"), let e2 = entry("A4") {
            let t0 = CACurrentMediaTime()
            controller.cardClicked(e1)
            controller.cardClicked(e2)
            _ = await pollUntil(8) { self.model.statuses[e2.id]?.isFinal == true }
            burst = Int((CACurrentMediaTime() - t0) * 1000)
        }
        let closedOK = ["A1", "A3", "A5", "A2", "A4"].allSatisfy { !host("A").isOpen($0) } &&
            ["A6", "A7", "A8"].allSatisfy { host("A").isOpen($0) }
        add("T1", "单击关闭窗口耗时", expected: "选中的 5 个窗口关闭，其余 3 个保留",
            actual: "逐个：\(singles.map { "\($0)ms" }.joined(separator: "、"))；连点两个到第二个确认：\(burst)ms；其余窗口\(closedOK ? "保留" : "受到影响！")",
            closedOK ? .info : .fail)

        // 6. 关掉一个窗口后，其余卡片多久开始补位；补位动画期间界面单击暂不响应
        _ = await pollUntil(3) { !self.controller.isBusy }
        if let e = entry("A9") {
            let t0 = CACurrentMediaTime()
            controller.cardClicked(e)
            _ = await pollUntil(6) { self.model.statuses[e.id]?.isFinal == true }
            let closedMs = Int((CACurrentMediaTime() - t0) * 1000)
            _ = await pollUntil(4) { self.model.entry(e.id) == nil }
            let reflowMs = Int((CACurrentMediaTime() - t0) * 1000)
            let guarded = controller.isReflowing
            _ = await pollUntil(1) { !self.controller.isReflowing }
            let settledMs = Int((CACurrentMediaTime() - t0) * 1000)
            add("T5", "关闭后其余卡片补位", expected: "约 0.5 秒内开始补位（原先 1～1.3 秒），约 0.3 秒到位；补位途中单击暂不响应",
                actual: "确认关闭 \(closedMs)ms；开始补位 \(reflowMs)ms；到位 \(settledMs)ms；补位途中单击保护=\(guarded)",
                !host("A").isOpen("A9") && reflowMs < 800 && guarded ? .pass : .fail)
        } else {
            add("T5", "关闭后其余卡片补位", expected: "—", actual: "找不到 A9 的卡片（共 \(model.entries.count) 张）", .fail)
        }

        // 3. 先退出一个应用，紧接着点一个窗口：测窗口是否被退出应用挡住
        _ = await pollUntil(3) { !self.controller.isBusy }
        if let q = model.app(host("Q").pid), let r = model.app(host("R").pid), let e = entry("A6") {
            let t0 = CACurrentMediaTime()
            controller.appClicked(q)
            controller.appClicked(r)
            controller.cardClicked(e)
            _ = await pollUntil(8) { self.model.statuses[e.id]?.isFinal == true }
            let windowMs = Int((CACurrentMediaTime() - t0) * 1000)
            _ = await pollUntil(8) { !self.host("Q").isRunning && !self.host("R").isRunning }
            let allMs = Int((CACurrentMediaTime() - t0) * 1000)
            add("T2", "退出应用与关窗混合", expected: "两个测试应用退出，A6 关闭",
                actual: "点击后 A6 确认关闭 \(windowMs)ms；两个应用全部退出 \(allMs)ms；Q 退出=\(!host("Q").isRunning)，R 退出=\(!host("R").isRunning)，A6 已关=\(!host("A").isOpen("A6"))",
                !host("Q").isRunning && !host("R").isRunning && !host("A").isOpen("A6") ? .info : .fail)
        }

        // 4. 两个收尾慢的应用同时退出，同时点一个窗口：窗口不用等应用收尾，两个应用并行退出
        _ = await pollUntil(3) { !self.controller.isBusy }
        if let a1 = model.app(host("S").pid), let a2 = model.app(host("U").pid), let e = entry("A7") {
            let t0 = CACurrentMediaTime()
            controller.appClicked(a1)
            controller.appClicked(a2)
            controller.cardClicked(e)
            _ = await pollUntil(8) { self.model.statuses[e.id]?.isFinal == true }
            let windowMs = Int((CACurrentMediaTime() - t0) * 1000)
            _ = await pollUntil(10) { !self.host("S").isRunning && !self.host("U").isRunning }
            let allMs = Int((CACurrentMediaTime() - t0) * 1000)
            let pass = !host("S").isRunning && !host("U").isRunning && !host("A").isOpen("A7") && windowMs < 800 && allMs < 2600
            add("T3", "两个收尾慢的应用同时退出，关窗不被挡住",
                expected: "窗口不等应用收尾（< 0.8 秒）；两个各需 1.5 秒收尾的应用并行退出（总计 < 2.6 秒，逐个则需 3 秒以上）",
                actual: "A7 确认关闭 \(windowMs)ms；两个应用全部退出 \(allMs)ms；A8 保留=\(host("A").isOpen("A8"))",
                pass && host("A").isOpen("A8") ? .pass : .fail)
        }

        // 5. 两个有未保存文档的应用同时退出：保存提示逐个暂停，不替用户选择，文档都还在
        _ = await pollUntil(10) { !self.controller.isBusy }
        if let a1 = model.app(host("V").pid), let a2 = model.app(host("W").pid) {
            var concurrentPauses = 0, maxConcurrent = 0, pauses = 0
            controller.pauseHandler = { [weak self] in
                concurrentPauses += 1
                pauses += 1
                maxConcurrent = max(maxConcurrent, concurrentPauses)
                let d = await self?.handlePause() ?? .proceed
                concurrentPauses -= 1
                return d
            }
            let tStart = CACurrentMediaTime()
            let clockV = host("V").clock, clockW = host("W").clock
            controller.appClicked(a1)
            controller.appClicked(a2)
            _ = await pollUntil(15) {
                self.model.appStatuses[a1.id]?.isFinal == true && self.model.appStatuses[a2.id]?.isFinal == true && !self.controller.isBusy
            }
            controller.pauseHandler = nil
            let v = host("V"), w = host("W")
            note("T4 用时 \(Int((CACurrentMediaTime() - tStart) * 1000))ms；V 事件：\((v.state()?.events ?? []).filter { $0.t >= clockV }.map { "\(Int(($0.t - clockV) * 1000))ms \($0.event)" }.joined(separator: "，"))；W 事件：\((w.state()?.events ?? []).filter { $0.t >= clockW }.map { "\(Int(($0.t - clockW) * 1000))ms \($0.event)" }.joined(separator: "，"))")
            let kept = v.isRunning && w.isRunning && v.isOpen("V1") && w.isOpen("W1") &&
                v.window("V1")?.dirty == true && w.window("W1")?.dirty == true
            let sheets = v.events("V1").contains("sheetShown") && w.events("W1").contains("sheetShown")
            let skipped = isSkipped(model.appStatuses[a1.id]) && isSkipped(model.appStatuses[a2.id])
            add("T4", "两个应用同时弹出保存提示",
                expected: "两个原生保存提示都出现；扫把逐个暂停、不替用户选择；“用户”都点取消后两个应用继续运行，未保存内容都在",
                actual: "保存提示\(sheets ? "都出现了" : "缺失")；暂停 \(pauses) 次，同一时刻最多 \(maxConcurrent) 个；状态：\(appStatusText(v))、\(appStatusText(w))；应用与未保存内容\(kept ? "都在" : "有丢失！")",
                sheets && kept && skipped && maxConcurrent <= 1 ? .pass : .fail)
        }
        closeOverview()
    }

    /// 10 毫秒精度的等待，计时更准
    func pollUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }
}
