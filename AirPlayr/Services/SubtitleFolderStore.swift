import Foundation

/// Only explicitly selected directories are remembered; no recursive discovery.
@MainActor enum SubtitleFolderStore {
    private static let key = "subtitleFolderBookmarks"
    static func access(for video: URL) -> FileAccess? {
        let parent = video.deletingLastPathComponent().standardizedFileURL
        for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), url.standardizedFileURL == parent else { continue }
            let access = FileAccess(url)
            if stale { try? remember(url) }
            return access
        }
        return nil
    }
    static func remember(_ folder: URL) throws {
        let access = FileAccess(folder)
        defer { withExtendedLifetime(access) {} }
        let data = try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        var bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        bookmarks.removeAll { entry in
            var stale = false
            return (try? URL(resolvingBookmarkData: entry, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL == folder.standardizedFileURL
        }
        bookmarks.insert(data, at: 0)
        UserDefaults.standard.set(Array(bookmarks.prefix(20)), forKey: key)
    }
}
