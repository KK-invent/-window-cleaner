import Foundation
import AppKit
import ImageIO
import SQLite3

/// 从本机浏览器图标库读取 favicon，不联网。
/// 连同 WAL 复制到短命的私有目录，再只读查询副本：既读到最新数据，也不在浏览器目录创建 shm 或修改其文件。
public final class FaviconStore {
    public struct Statistics {
        public var databases = 0
        public var opened = 0
        public var walSnapshots = 0
        public var cacheHits = 0
        public var requested = 0
        public var found = 0
        public var snapshotErrors = 0
        public var queryErrors = 0
        public var text: String {
            "requested=\(requested) found=\(found) cacheHits=\(cacheHits) databases=\(databases) opened=\(opened) wal=\(walSnapshots) snapshotErrors=\(snapshotErrors) queryErrors=\(queryErrors)"
        }
    }

    private struct CachedIcon {
        let image: NSImage
        let expires: Date
    }
    private struct Stamp: Equatable {
        let size: UInt64
        let inode: UInt64
        let modified: Date
    }
    private struct Snapshot {
        let file: URL
        let directory: URL
        let hasWAL: Bool
    }

    private let lock = NSLock()
    private var cache: [String: CachedIcon] = [:]
    private var order: [String] = []
    private let databaseProvider: (String) -> [URL]
    private let now: () -> Date
    private let temporaryRoot: URL
    private let lifetime: TimeInterval

    /// 测试可注入专用数据库，绝不需要读取真实 Chrome 资料。
    public init(databaseProvider: @escaping (String) -> [URL] = FaviconStore.databases,
                temporaryRoot: URL = FileManager.default.temporaryDirectory,
                lifetime: TimeInterval = 120, now: @escaping () -> Date = Date.init) {
        self.databaseProvider = databaseProvider
        self.temporaryRoot = temporaryRoot
        self.lifetime = lifetime
        self.now = now
    }

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

    public static func defaultRoot(bundleID: String) -> URL? {
        guard let sub = userDataDirs[bundleID] else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").appendingPathComponent(sub)
    }

    /// 用户可选择整个 Chrome 目录，或某个包含 Favicons 的资料目录；只找图标文件，不读取其他资料。
    public static func databases(in root: URL) -> [URL] {
        let own = root.appendingPathComponent("Favicons")
        if FileManager.default.fileExists(atPath: own.path) { return [own] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { a, b in
                if a == b { return false }
                if a == "Default" { return true }
                if b == "Default" { return false }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { root.appendingPathComponent($0).appendingPathComponent("Favicons") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func databases(bundleID: String) -> [URL] {
        let authorized = FaviconFolderAccess.shared.folders(bundleID: bundleID)
        if !authorized.isEmpty { return authorized.flatMap { databases(in: $0) } }
        guard let root = defaultRoot(bundleID: bundleID) else { return [] }
        return databases(in: root)
    }

    /// favicon 与网址有关，不只与主机名有关；同一网站的不同页面也可能有不同图标。
    public static func normalizedPage(_ url: String) -> String? {
        guard var c = URLComponents(string: url), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        c.scheme = scheme
        c.host = host
        c.fragment = nil
        if c.path.isEmpty { c.path = "/" }
        return c.string
    }

    public static func cacheKey(url: String, bundleID: String) -> String? {
        normalizedPage(url).map { bundleID + "|" + $0 }
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        order = []
    }

    /// 只缓存成功读取的图标；未命中、文件繁忙、权限不足或损坏时，下次刷新仍会重试。
    public func load(urls: [String], bundleID: String, report: ((Statistics) -> Void)? = nil) -> [String: NSImage] {
        let pages = Array(Set(urls.compactMap(Self.normalizedPage))).sorted()
        var stats = Statistics()
        stats.requested = pages.count
        var result: [String: NSImage] = [:]
        var missing: [String] = []
        let date = now()
        lock.lock()
        for page in pages {
            let key = bundleID + "|" + page
            if let hit = cache[key], hit.expires > date {
                result[key] = hit.image
                stats.cacheHits += 1
            } else { missing.append(page) }
        }
        lock.unlock()

        if !missing.isEmpty {
            let databases = databaseProvider(bundleID)
            stats.databases = databases.count
            var snapshots: [Snapshot] = []
            // 先跨所有资料夹查找精确页面，最后才按网站兜底，避免另一个资料夹的同站图标抢先命中。
            defer { for snapshot in snapshots { try? FileManager.default.removeItem(at: snapshot.directory) } }
            for file in databases {
                guard !missing.isEmpty else { break }
                guard let snapshot = makeSnapshot(file) else { stats.snapshotErrors += 1; continue }
                snapshots.append(snapshot)
                guard let db = Self.openReadOnly(snapshot.file) else { stats.snapshotErrors += 1; continue }
                defer { sqlite3_close(db) }
                stats.opened += 1
                if snapshot.hasWAL { stats.walSnapshots += 1 }
                var found: Set<String> = []
                for page in missing {
                    guard let host = URL(string: page)?.host,
                          let data = Self.lookup(db, host: host, page: page, allowHostFallback: false, errors: &stats.queryErrors),
                          let image = Self.decode(data) else { continue }
                    result[bundleID + "|" + page] = image
                    found.insert(page)
                }
                missing.removeAll { found.contains($0) }
            }
            for snapshot in snapshots {
                guard !missing.isEmpty else { break }
                guard let db = Self.openReadOnly(snapshot.file) else { continue }
                defer { sqlite3_close(db) }
                stats.opened += 1
                var found: Set<String> = []
                for page in missing {
                    guard let host = URL(string: page)?.host,
                          let data = Self.lookup(db, host: host, page: page, allowHostFallback: true, errors: &stats.queryErrors),
                          let image = Self.decode(data) else { continue }
                    result[bundleID + "|" + page] = image
                    found.insert(page)
                }
                missing.removeAll { found.contains($0) }
            }
        }
        lock.lock()
        for (key, image) in result {
            if cache[key] == nil { order.append(key) }
            // 缓存命中不续期，否则反复打开总览会让旧图标永不过期。
            if cache[key] == nil || cache[key]!.expires <= date {
                cache[key] = CachedIcon(image: image, expires: date.addingTimeInterval(lifetime))
            }
        }
        while order.count > 600 { cache[order.removeFirst()] = nil }
        lock.unlock()
        stats.found = result.count
        report?(stats)
        return result
    }

    private static func stamp(_ file: URL) throws -> Stamp {
        let a = try FileManager.default.attributesOfItem(atPath: file.path)
        return Stamp(size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                     inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                     modified: (a[.modificationDate] as? Date) ?? .distantPast)
    }

    private func makeSnapshot(_ file: URL) -> Snapshot? {
        let fm = FileManager.default
        let wal = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "-wal")
        // 复制期间如果浏览器正在写入或 checkpoint，就重试，避免把不同时刻的 DB/WAL 拼在一起。
        for _ in 0..<3 {
            let dir = temporaryRoot.appendingPathComponent("SaobaFavicons-" + UUID().uuidString, isDirectory: true)
            do {
                let before = try Self.stamp(file)
                let beforeWAL = try? Self.stamp(wal)
                guard before.size <= 256 * 1024 * 1024, (beforeWAL?.size ?? 0) <= 256 * 1024 * 1024 else { return nil }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let copy = dir.appendingPathComponent("Favicons")
                try fm.copyItem(at: file, to: copy)
                if beforeWAL != nil { try fm.copyItem(at: wal, to: dir.appendingPathComponent("Favicons-wal")) }
                let after = try Self.stamp(file)
                let afterWAL = try? Self.stamp(wal)
                if before == after && beforeWAL == afterWAL {
                    return Snapshot(file: copy, directory: dir, hasWAL: (beforeWAL?.size ?? 0) > 0)
                }
            } catch { /* 只返回计数，不把包含个人路径或网址的错误写入日志。 */ }
            try? fm.removeItem(at: dir)
        }
        return nil
    }

    static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        var db: OpaquePointer?
        // 不用 immutable=1：它会忽略 WAL 中尚未 checkpoint 的最新图标。
        guard sqlite3_open_v2(parts.string!, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 100)
        sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
        return db
    }

    static let bitmapOrder = "ORDER BY abs(b.width - 32), b.last_updated DESC LIMIT 1"

    static func lookup(_ db: OpaquePointer, host: String, page: String, allowHostFallback: Bool, errors: inout Int) -> Data? {
        let exact = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ?1 AND length(b.image_data) BETWEEN 1 AND 4194304 \(bitmapOrder)
            """
        if let data = queryBlob(db, exact, [page], errors: &errors) { return data }
        guard allowHostFallback else { return nil }
        let range = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url >= ?1 AND m.page_url < ?2 AND length(b.image_data) BETWEEN 1 AND 4194304 \(bitmapOrder)
            """
        for scheme in ["https://", "http://"] {
            if let data = queryBlob(db, range, [scheme + host + "/", scheme + host + "0"], errors: &errors) { return data }
        }
        return nil
    }

    static func queryBlob(_ db: OpaquePointer, _ sql: String, _ args: [String], errors: inout Int) -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { errors += 1; return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in args.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
        let step = sqlite3_step(statement)
        if step != SQLITE_ROW { if step != SQLITE_DONE { errors += 1 }; return nil }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return count > 0 ? Data(bytes: bytes, count: count) : nil
    }

    /// 限制解码尺寸，避免大 favicon 在几十个标签页中占用多余内存。
    static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
    }
}
