import AppKit

func runTabPreviewChecks() {
    print("标签页预览身份与内存")
    let key = TabKey(pid: 10, windowID: "w1", tabID: "t1")
    let page = "https://example.test/a"
    let tab = BrowserTab(id: "t1", title: "A", url: page, isActive: true)
    check("截图前后编号和网址相同，才接受这张预览", TabPreviewIdentity.matches(key: key, expectedURL: page, before: tab, after: tab))
    let switched = BrowserTab(id: "t2", title: "B", url: page, isActive: true)
    check("截图期间切换到同网址的另一个标签，也会丢弃预览", !TabPreviewIdentity.matches(key: key, expectedURL: page, before: tab, after: switched))
    let navigated = BrowserTab(id: "t1", title: "B", url: "https://example.test/b", isActive: true)
    check("同一标签页跳转后，不能沿用原页面预览", !TabPreviewIdentity.matches(key: key, expectedURL: page, before: tab, after: navigated))
    let loading = BrowserTab(id: "t1", title: "A", url: page, isActive: true, isLoading: true)
    check("加载中的页面不捕获，避免缓存空白过渡画面", !TabPreviewIdentity.matches(key: key, expectedURL: page, before: loading, after: tab))
    var inactive = tab; inactive.isActive = false
    check("后台标签页不能借用当前页画面", !TabPreviewIdentity.matches(key: key, expectedURL: page, before: inactive, after: tab))

    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
    let image = NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 16, height: 16))
    let imageCost = image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max()!
    let cache = TabPreviewCache(maxBytes: imageCost * 2, maxCount: 2)
    check("已核对的预览可以存入内存", cache.store(key: key, expectedURL: page, before: tab, after: tab, image: image),
          image.representations.map { "\(type(of: $0)) \($0.pixelsWide)×\($0.pixelsHigh)" }.joined(separator: ";"))
    check("同编号但网址不同，不会返回旧预览", cache.preview(for: key, url: navigated.url) == nil)
    check("另一个窗口中相同标签编号，不会共享预览", cache.preview(for: TabKey(pid: 10, windowID: "w2", tabID: "t1"), url: page) == nil)
    check("错误截图不能覆盖已经验证的缓存", !cache.store(key: key, expectedURL: page, before: tab, after: switched, image: image) && cache.preview(for: key, url: page) != nil)
    for id in ["t2", "t3"] {
        let t = BrowserTab(id: id, title: id, url: page, isActive: true)
        _ = cache.store(key: TabKey(pid: 10, windowID: "w1", tabID: id), expectedURL: page, before: t, after: t, image: image)
    }
    check("预览缓存超出数量或字节预算时，释放最旧图片", cache.byteCount <= imageCost * 2 && cache.preview(for: key, url: page) == nil)
    let tooSmall = TabPreviewCache(maxBytes: 1, maxCount: 1)
    check("单张图片超过预算时不保留", !tooSmall.store(key: key, expectedURL: page, before: tab, after: tab, image: image) && tooSmall.byteCount == 0)
    cache.removeAll()
    check("收起总览后的清理能释放全部缓存", cache.byteCount == 0)
}
