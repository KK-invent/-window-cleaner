import Foundation

/// 只记住用户通过系统文件夹选择器授权的目录；不自动授予权限、不修改浏览器文件。
public final class FaviconFolderAccess {
    public static let shared = FaviconFolderAccess()
    private struct Folder { let url: URL; let scoped: Bool }
    private let lock = NSLock()
    private var active: [String: [Folder]] = [:]
    private let defaultsKey = "faviconFolderBookmarks.v1"

    public func folders(bundleID: String) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        if let folders = active[bundleID] { return folders.map(\.url) }
        let all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        let bookmarks = all[bundleID] as? [Data] ?? []
        let folders = bookmarks.compactMap { data -> Folder? in
            var stale = false
            let secured = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            let plain = secured ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))
            guard let url = plain else { return nil }
            return Folder(url: url, scoped: url.startAccessingSecurityScopedResource())
        }
        active[bundleID] = folders
        return folders.map(\.url)
    }

    /// 只能由 NSOpenPanel 返回用户选择的 URL 后调用。书签只放本应用偏好，不写日志。
    public func authorize(_ urls: [URL], bundleID: String) throws {
        let folders = urls.map { Folder(url: $0, scoped: $0.startAccessingSecurityScopedResource()) }
        do {
            let data = try urls.map { url -> Data in
                do { return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
                catch { return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) }
            }
            lock.lock(); defer { lock.unlock() }
            for old in active[bundleID] ?? [] where old.scoped { old.url.stopAccessingSecurityScopedResource() }
            active[bundleID] = folders
            var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
            all[bundleID] = data
            UserDefaults.standard.set(all, forKey: defaultsKey)
        } catch {
            for folder in folders where folder.scoped { folder.url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
}
