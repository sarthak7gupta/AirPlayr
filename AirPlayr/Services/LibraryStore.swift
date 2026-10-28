import Foundation
import Observation

/// Bounded JSON library of recent media (bookmarks, titles, resume position). No filesystem scan.
@MainActor @Observable final class LibraryStore {
    private(set) var entries: [MediaEntry] = []
    var issue: String?
    var isPrivateMode: Bool = UserDefaults.standard.bool(forKey: "libraryPrivateMode") {
        didSet { UserDefaults.standard.set(isPrivateMode, forKey: "libraryPrivateMode") }
    }
    var maxRecentItems: Int = {
        let saved = UserDefaults.standard.integer(forKey: "libraryMaxRecentItems")
        return saved > 0 ? saved : 100
    }() {
        didSet {
            let clamped = max(10, min(maxRecentItems, 200))
            UserDefaults.standard.set(clamped, forKey: "libraryMaxRecentItems")
            if entries.count > clamped {
                entries = Array(entries.prefix(clamped))
                save()
            }
        }
    }
    private let file: URL
    @ObservationIgnored private var resolvedURLs: [UUID: URL] = [:]
    init(file: URL? = nil) {
        if let file {
            self.file = file
        } else if let envPath = ProcessInfo.processInfo.environment["AIRPLAYR_LIBRARY_JSON"], !envPath.isEmpty {
            self.file = URL(fileURLWithPath: envPath)
        } else {
            self.file = URL.applicationSupportDirectory.appending(path: "AirPlayr/library.json")
        }
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                entries = try JSONDecoder().decode([MediaEntry].self, from: Data(contentsOf: self.file))
            }
        } catch { issue = "The saved library could not be read. Open your media again; the original files are untouched." }
    }
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = [.minimalBookmark]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif
    func remember(_ url: URL) throws -> MediaEntry {
        try MediaPolicy.validate(url)
        let standardized = url.standardizedFileURL
        let bookmark: Data
        if let scoped = try? url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmark = scoped
        } else {
            bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let existing = entries.firstIndex { entry in
            if let cached = resolvedURLs[entry.id] { return cached == standardized }
            var stale = false
            guard let resolved = (try? URL(resolvingBookmarkData: entry.bookmark, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL else { return false }
            resolvedURLs[entry.id] = resolved
            return resolved == standardized
        }
        var entry = existing.map { entries.remove(at: $0) } ?? MediaEntry(title: url.deletingPathExtension().lastPathComponent, bookmark: bookmark)
        entry.bookmark = bookmark
        entry.lastOpened = Date()
        resolvedURLs[entry.id] = standardized
        guard !isPrivateMode else { return entry }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(max(10, maxRecentItems)))
        save()
        return entry
    }
    func resolve(_ entry: MediaEntry) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: entry.bookmark, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        resolvedURLs[entry.id] = url.standardizedFileURL
        if stale, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            let access = FileAccess(url)
            defer { withExtendedLifetime(access) {} }
            if let refreshed = try? url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                entries[index].bookmark = refreshed
                save()
            }
        }
        return url
    }
    func update(_ id: UUID, position: Double, duration: Double?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].position = position.isFinite ? max(0, position) : 0
        entries[index].duration = duration
        save()
    }
    func resetProgress(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].position = 0
        save()
    }
    func remove(_ id: UUID) { resolvedURLs[id] = nil; entries.removeAll { $0.id == id }; save() }
    func clear() { resolvedURLs.removeAll(); entries.removeAll(); save() }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch { issue = MediaIssue.persistence.localizedDescription }
    }
}

/// Balanced scope ownership. A false start can also mean the URL already needs no extension.
final class FileAccess {
    let url: URL
    private let started: Bool
    init(_ url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
