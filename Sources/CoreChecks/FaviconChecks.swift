// 使用自建数据库和自绘图标，不读取用户的 Chrome 资料，不联网。
import AppKit
import SQLite3

private enum FixtureError: Error { case sqlite(Int32) }

private final class FaviconFixture {
    let file: URL
    var db: OpaquePointer?
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("Favicons")
        let rc = sqlite3_open(file.path, &db)
        guard rc == SQLITE_OK else { throw FixtureError.sqlite(rc) }
        try sql("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try sql("CREATE TABLE icon_mapping(page_url TEXT,icon_id INTEGER); CREATE TABLE favicon_bitmaps(icon_id INTEGER,width INTEGER,last_updated INTEGER,image_data BLOB);")
        try sql("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    deinit { sqlite3_close(db) }
    func sql(_ text: String) throws {
        let rc = sqlite3_exec(db, text, nil, nil, nil)
        if rc != SQLITE_OK { throw FixtureError.sqlite(rc) }
    }
    static func png(_ color: NSColor) -> Data {
        let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
        let rgb = color.usingColorSpace(.sRGB)!
        let rgba: [UInt8] = [UInt8((rgb.redComponent * 255).rounded()), UInt8((rgb.greenComponent * 255).rounded()), UInt8((rgb.blueComponent * 255).rounded()), 255]
        for y in 0..<64 { for x in 0..<64 {
            let i = y * r.bytesPerRow + x * 4
            for component in 0..<4 { r.bitmapData![i + component] = rgba[component] }
        } }
        return r.representation(using: .png, properties: [:])!
    }
    func add(_ page: String, id: Int, color: NSColor) throws {
        var stmt: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(db, "INSERT INTO icon_mapping VALUES(?1,?2)", -1, &stmt, nil) == SQLITE_OK else { throw FixtureError.sqlite(SQLITE_ERROR) }
        sqlite3_bind_text(stmt, 1, page, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(id))
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { throw FixtureError.sqlite(rc) }
        try sql("INSERT INTO favicon_bitmaps VALUES(\(id),64,1,NULL)")
        try update(id, color: color)
    }
    func update(_ id: Int, color: NSColor) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE favicon_bitmaps SET image_data=?1,last_updated=last_updated+1 WHERE icon_id=?2", -1, &stmt, nil) == SQLITE_OK else { throw FixtureError.sqlite(SQLITE_ERROR) }
        defer { sqlite3_finalize(stmt) }
        let data = Self.png(color)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_int(stmt, 2, Int32(id))
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE { throw FixtureError.sqlite(rc) }
    }
}

private func isColor(_ image: NSImage?, _ expected: NSColor) -> Bool {
    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let c = NSBitmapImageRep(cgImage: cg).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB),
          let e = expected.usingColorSpace(.sRGB) else { return false }
    // PNG 的设备色彩配置会经过色彩管理转换；校验主导颜色，以区分图标身份而非锁死某个 RGB 数值。
    if e.redComponent > 0.8 { return c.redComponent > c.greenComponent + 0.5 && c.redComponent > c.blueComponent + 0.5 }
    if e.greenComponent > 0.8 { return c.greenComponent > c.redComponent + 0.5 && c.greenComponent > c.blueComponent + 0.5 }
    return c.blueComponent > c.redComponent + 0.5 && c.blueComponent > c.greenComponent + 0.5
}

func runFaviconChecks() {
    print("网站图标回归（专用数据库）")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/favicon-fixtures.noindex/" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    do {
        let first = try FaviconFixture(directory: root.appendingPathComponent("profile-a"))
        let second = try FaviconFixture(directory: root.appendingPathComponent("profile-b"))
        let snapshots = root.appendingPathComponent("snapshots")
        let page = "https://example.test/a"
        let other = "https://example.test/b"
        let bundle = "test.browser.chrome"
        try first.add(page, id: 1, color: .red)
        try first.add(other, id: 2, color: .blue)
        try second.add(page, id: 1, color: .green)
        let key = FaviconStore.cacheKey(url: page, bundleID: bundle)!
        let otherKey = FaviconStore.cacheKey(url: other, bundleID: bundle)!
        let store = FaviconStore(databaseProvider: { _ in [first.file] }, temporaryRoot: snapshots)

        // 主文件里只有 schema；新图标仍在 WAL 中。
        var old: OpaquePointer?
        sqlite3_open_v2(first.file.absoluteString + "?immutable=1", &old, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        var count: OpaquePointer?
        sqlite3_prepare_v2(old, "SELECT count(*) FROM icon_mapping", -1, &count, nil)
        let missingFromOld = sqlite3_step(count) == SQLITE_ROW && sqlite3_column_int(count, 0) == 0
        sqlite3_finalize(count); sqlite3_close(old)
        check("复现旧方式漏图：immutable 只读主文件时看不到 WAL 中的新图标", missingFromOld)

        let sourceFiles = ["Favicons", "Favicons-wal", "Favicons-shm"].map { first.file.deletingLastPathComponent().appendingPathComponent($0) }
        let before = sourceFiles.map { try? Data(contentsOf: $0) }
        var stats = FaviconStore.Statistics()
        let loaded = store.load(urls: [page, other], bundleID: bundle) { stats = $0 }
        check("连同 WAL 查询副本，读到最新写入的两个图标", loaded.count == 2 && stats.walSnapshots == 1 && stats.queryErrors == 0)
        check("同一网站不同页面使用各自图标，而不是共用主机缓存", isColor(loaded[key], .red) && isColor(loaded[otherKey], .blue))
        check("读取前后源 DB、WAL 和 SHM 的内容完全不变", before == sourceFiles.map { try? Data(contentsOf: $0) })
        let leftovers = (try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []
        check("查询后临时图标数据库副本全部删除", leftovers.isEmpty)
        let maxPixels = loaded[key]?.representations.map { max($0.pixelsWide,$0.pixelsHigh) }.max() ?? 0
        check("图标解码限制到 32 像素，避免按原图占内存", maxPixels > 0 && maxPixels <= 32)

        let normalized = store.load(urls: [page + "#section"], bundleID: bundle)
        check("带片段的网址仍匹配原页面图标", isColor(normalized[key], .red))
        let missingPage = "https://newly-added.test/page"
        let missingKey = FaviconStore.cacheKey(url: missingPage, bundleID: bundle)!
        check("尚未写入的图标保持未命中", store.load(urls: [missingPage], bundleID: bundle).isEmpty)
        try first.add(missingPage, id: 3, color: .green)
        check("先查不到、随后浏览器写入：下次刷新可以读到，不永久缓存失败", isColor(store.load(urls: [missingPage], bundleID: bundle)[missingKey], .green))

        try first.update(1, color: .blue)
        var cachedStats = FaviconStore.Statistics()
        let cached = store.load(urls: [page], bundleID: bundle) { cachedStats = $0 }
        check("成功图标短期缓存，避免反复复制数据库", cachedStats.cacheHits == 1 && cachedStats.opened == 0 && isColor(cached[key], .red))
        store.invalidate()
        check("手动刷新清除旧缓存，读取更新后的图标", isColor(store.load(urls: [page], bundleID: bundle)[key], .blue))

        var time = Date(timeIntervalSince1970: 100)
        let expiring = FaviconStore(databaseProvider: { _ in [first.file] }, temporaryRoot: snapshots, lifetime: 10, now: { time })
        _ = expiring.load(urls: [page], bundleID: bundle)
        try first.update(1, color: .red)
        time = time.addingTimeInterval(11)
        check("正缓存到期后读取新图标，缓存命中不会无限续期", isColor(expiring.load(urls: [page], bundleID: bundle)[key], .red))

        let differentBrowsers = FaviconStore(databaseProvider: { $0 == bundle ? [first.file] : [second.file] }, temporaryRoot: snapshots)
        let chrome = differentBrowsers.load(urls: [page], bundleID: bundle)
        let edgeBundle = "test.browser.edge"
        let edge = differentBrowsers.load(urls: [page], bundleID: edgeBundle)
        check("不同浏览器的同一网址缓存彼此独立", isColor(chrome[key], .red) && isColor(edge[FaviconStore.cacheKey(url: page, bundleID: edgeBundle)!], .green))

        let multipleProfiles = FaviconStore(databaseProvider: { _ in [second.file,first.file] }, temporaryRoot: snapshots)
        check("默认资料夹没有对应记录时继续查其他资料夹", isColor(multipleProfiles.load(urls: [other], bundleID: bundle)[otherKey], .blue))
        let absent = FaviconStore(databaseProvider: { _ in [] }, temporaryRoot: snapshots)
        var noDB = FaviconStore.Statistics()
        _ = absent.load(urls: [page], bundleID: bundle) { noDB = $0 }
        check("数据库不存在时有明确统计，不伪造网站图标", noDB.databases == 0 && noDB.found == 0)
        check("内部页面与本地文件不查询网站数据库", store.load(urls: ["chrome://newtab","file:///example.html"], bundleID: bundle).isEmpty)
    } catch {
        check("网站图标测试夹具", false, String(describing: error))
    }
}
