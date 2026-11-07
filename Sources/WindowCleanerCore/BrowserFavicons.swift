import Foundation
import AppKit
import SQLite3

/// 网站图标（favicon）：从浏览器保存在本机的图标数据库里只读地取出，不联网、不修改浏览器的任何文件。
///
/// Chrome 系浏览器把访问过的网站图标存在 资料夹/Favicons（SQLite 数据库）里。
/// 这里以“不可变”方式只读打开（不加锁、不写日志），不会影响正在运行的浏览器；
/// 读不到最新写入的图标时，界面退回显示地球图标。
public final class FaviconStore {
    public init() {}

    private let lock = NSLock()
    /// 按主机名缓存（nil 表示查过但没有）。条目很小，最多保留 600 个
    private var cache: [String: NSImage?] = [:]
    private var order: [String] = []

    /// 各浏览器在“应用程序支持”目录下的资料夹位置
    static let userDataDirs: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.brave.Browser.beta": "BraveSoftware/Brave-Browser-Beta",
    ]

    /// 该浏览器所有资料（Default、Profile 1……）里的图标数据库
    public static func databases(bundleID: String) -> [URL] {
        guard let sub = userDataDirs[bundleID] else { return [] }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").appendingPathComponent(sub)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let profiles = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted { a, b in
            a == "Default" ? true : (b == "Default" ? false : a.localizedStandardCompare(b) == .orderedAscending)
        }
        return profiles.map { root.appendingPathComponent($0).appendingPathComponent("Favicons") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func cached(host: String) -> NSImage?? {
        lock.lock(); defer { lock.unlock() }
        return cache[host]
    }

    /// 为这些网址取图标，返回 [主机名: 图标]。只查询还没缓存过的主机。
    public func load(urls: [String], bundleID: String) -> [String: NSImage] {
        var byHost: [String: [String]] = [:]
        for u in urls {
            guard let comps = URL(string: u), let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = comps.host?.lowercased() else { continue }
            byHost[host, default: []].append(u)
        }
        var result: [String: NSImage] = [:]
        var missing: [String: [String]] = [:]
        lock.lock()
        for (host, list) in byHost {
            if let hit = cache[host] {
                if let img = hit { result[host] = img }
            } else {
                missing[host] = list
            }
        }
        lock.unlock()
        guard !missing.isEmpty else { return result }

        var found: [String: NSImage] = [:]
        for dbURL in Self.databases(bundleID: bundleID) {
            let pending = missing.filter { found[$0.key] == nil }
            if pending.isEmpty { break }
            guard let db = Self.openReadOnly(dbURL) else { continue }
            defer { sqlite3_close(db) }
            for (host, list) in pending {
                if let data = Self.lookup(db, host: host, urls: list), let img = NSImage(data: data) {
                    img.size = NSSize(width: 16, height: 16)
                    found[host] = img
                }
            }
        }

        lock.lock()
        for host in missing.keys {
            if cache[host] == nil { order.append(host) }
            cache[host] = .some(found[host])
        }
        while order.count > 600 { cache[order.removeFirst()] = nil }
        lock.unlock()
        return result.merging(found) { a, _ in a }
    }

    static func openReadOnly(_ url: URL) -> OpaquePointer? {
        guard let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2("file:\(path)?immutable=1", &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 200)
        return db
    }

    static let bitmapOrder = "ORDER BY abs(b.width - 32), b.last_updated DESC LIMIT 1"

    /// 先按标签页网址精确查找，再按同一主机下任意页面查找
    static func lookup(_ db: OpaquePointer, host: String, urls: [String]) -> Data? {
        let exact = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ?1 AND length(b.image_data) > 0 \(bitmapOrder)
            """
        for u in urls.prefix(3) {
            if let d = queryBlob(db, exact, [u]) { return d }
        }
        let range = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url >= ?1 AND m.page_url < ?2 AND length(b.image_data) > 0 \(bitmapOrder)
            """
        for scheme in ["https://", "http://"] {
            // “/” 的下一个字符是 “0”，所以 [host/, host0) 正好覆盖该主机下的所有网址
            if let d = queryBlob(db, range, [scheme + host + "/", scheme + host + "0"]) { return d }
        }
        return nil
    }

    static func queryBlob(_ db: OpaquePointer, _ sql: String, _ args: [String]) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_blob(stmt, 0) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        return n > 0 ? Data(bytes: p, count: n) : nil
    }
}
