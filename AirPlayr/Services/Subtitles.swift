import Foundation
import Security

// MARK: - External SubRip (SRT)

/// One timed line of on-screen text for Mac overlay or burn-in compositing.
struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

/// Parsed SRT cues with strict size and encoding limits (UTF-8 or BOM-marked UTF-16).
struct SubtitleDocument: Sendable {
    let cues: [SubtitleCue]
    func text(at time: Double) -> String {
        cues.filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
    }
    func shifted(by offsetSeconds: Double) -> SubtitleDocument {
        guard offsetSeconds != 0, offsetSeconds.isFinite else { return self }
        let adjusted = cues.compactMap { cue -> SubtitleCue? in
            let newEnd = cue.end + offsetSeconds
            guard newEnd > 0 else { return nil }
            let newStart = max(0, cue.start + offsetSeconds)
            guard newEnd > newStart else { return nil }
            return SubtitleCue(start: newStart, end: newEnd, text: cue.text)
        }
        return SubtitleDocument(cues: adjusted)
    }
    static func companionURL(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("srt") }
    static func read(_ url: URL) throws -> SubtitleDocument {
        let scope = FileAccess(url)
        defer { withExtendedLifetime(scope) {} }
        guard url.pathExtension.lowercased() == "srt" else { throw MediaIssue.subtitles("Choose an SRT file.") }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 5_000_000 else { throw MediaIssue.subtitles("The file exceeds the 5 MB limit.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 5_000_001) ?? Data()
        guard data.count <= 5_000_000 else { throw MediaIssue.subtitles("The file exceeds the 5 MB limit.") }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw MediaIssue.subtitles("Save the file as UTF-8 or UTF-16 with a byte-order mark.") }
        return try parse(text)
    }
    static func parse(_ input: String) throws -> SubtitleDocument {
        let normalized = input.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var cues: [SubtitleCue] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }), timing <= 1 else { throw MediaIssue.subtitles("A cue has no valid timing line.") }
            let pair = lines[timing].components(separatedBy: "-->")
            let endToken = pair.count == 2 ? (pair[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? "") : ""
            guard pair.count == 2, let start = timestamp(pair[0]), let end = timestamp(endToken), end > start else { throw MediaIssue.subtitles("A cue has invalid timestamps or no text.") }
            guard timing + 1 < lines.count else { continue }
            let rawText = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let plain = rawText.trimmingCharacters(in: .newlines)
            guard !plain.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: plain))
        }
        guard !cues.isEmpty else { throw MediaIssue.subtitles("No subtitle cues were found.") }
        return SubtitleDocument(cues: cues.sorted { $0.start < $1.start })
    }
    private static func timestamp(_ input: String) -> Double? {
        let parts = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]), hours.isFinite, minutes.isFinite, seconds.isFinite, hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

// MARK: - Opt-In OpenSubtitles Search & Download

struct OpenSubtitlesResult: Identifiable, Equatable, Sendable {
    let id: String
    let fileID: Int
    let fileName: String
    let language: String
    let downloadCount: Int
    let release: String
    let hashMatch: Bool
}

enum OpenSubtitlesService {
    private static let keychainService = "com.sarthak7gupta.AirPlayr.opensubtitles"
    private static let keychainAccount = "api-key"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Computes the standard 64-bit OpenSubtitles movie hash (file size + first 64 KB + last 64 KB).
    static func computeMovieHash(for url: URL) throws -> String {
        let scope = FileAccess(url)
        defer { withExtendedLifetime(scope) {} }
        let chunkSize = 65_536
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= chunkSize else {
            throw MediaIssue.subtitles("Video file must be at least 64 KB to compute an OpenSubtitles hash.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: chunkSize) ?? Data()
        try handle.seek(toOffset: UInt64(fileSize - chunkSize))
        let tail = try handle.read(upToCount: chunkSize) ?? Data()
        guard head.count == chunkSize, tail.count == chunkSize else {
            throw MediaIssue.subtitles("Could not read 64 KB chunks for OpenSubtitles hash.")
        }
        var hash = UInt64(fileSize)
        func accumulate(_ chunk: Data) {
            chunk.withUnsafeBytes { raw in
                let words = raw.bindMemory(to: UInt64.self)
                for word in words {
                    hash = hash &+ UInt64(littleEndian: word)
                }
            }
        }
        accumulate(head)
        accumulate(tail)
        return String(format: "%016llx", hash)
    }

    static func search(videoURL: URL?, query: String, language: String, apiKey: String) async throws -> [OpenSubtitlesResult] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw MediaIssue.subtitles("Enter your OpenSubtitles API key first.")
        }
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        var items: [URLQueryItem] = []
        let cleanLang = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleanLang.isEmpty {
            items.append(URLQueryItem(name: "languages", value: cleanLang))
        }
        if let videoURL, let movieHash = try? computeMovieHash(for: videoURL) {
            items.append(URLQueryItem(name: "moviehash", value: movieHash))
        }
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanQuery.isEmpty {
            items.append(URLQueryItem(name: "query", value: cleanQuery))
        }
        components.queryItems = items
        guard let url = components.url else { throw MediaIssue.subtitles("Invalid search query.") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue(trimmedKey, forHTTPHeaderField: "Api-Key")
        request.setValue("AirPlayr v1.7.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MediaIssue.subtitles("OpenSubtitles search failed. Verify your API key and network connection.")
        }
        return parseSearchResponse(data)
    }

    static func parseSearchResponse(_ data: Data) -> [OpenSubtitlesResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { return [] }
        var results: [OpenSubtitlesResult] = []
        for entry in entries {
            let id = (entry["id"] as? String) ?? UUID().uuidString
            guard let attributes = entry["attributes"] as? [String: Any],
                  let files = attributes["files"] as? [[String: Any]],
                  let firstFile = files.first,
                  let fileID = firstFile["file_id"] as? Int else { continue }
            let fileName = (firstFile["file_name"] as? String) ?? (attributes["release"] as? String) ?? "Subtitle.srt"
            let language = (attributes["language"] as? String) ?? "en"
            let downloads = (attributes["download_count"] as? Int) ?? 0
            let release = (attributes["release"] as? String) ?? fileName
            let hashMatch = (attributes["moviehash_match"] as? Bool) ?? false
            results.append(OpenSubtitlesResult(id: id, fileID: fileID, fileName: fileName, language: language, downloadCount: downloads, release: release, hashMatch: hashMatch))
        }
        return results
    }

    static func download(fileID: Int, apiKey: String, near videoURL: URL?) async throws -> (URL, SubtitleDocument) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw MediaIssue.subtitles("Enter your OpenSubtitles API key first.") }
        let endpoint = URL(string: "https://api.opensubtitles.com/api/v1/download")!
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue(trimmedKey, forHTTPHeaderField: "Api-Key")
        request.setValue("AirPlayr v1.7.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileID])
        let (metaData, metaResponse) = try await URLSession.shared.data(for: request)
        guard let http = metaResponse as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let linkString = json["link"] as? String,
              let downloadURL = URL(string: linkString) else {
            throw MediaIssue.subtitles("Could not obtain download link from OpenSubtitles.")
        }
        let (srtData, srtResponse) = try await URLSession.shared.data(from: downloadURL)
        guard let srtHTTP = srtResponse as? HTTPURLResponse, (200...299).contains(srtHTTP.statusCode),
              srtData.count <= 5_000_000,
              let text = String(data: srtData, encoding: .utf8) ?? String(data: srtData, encoding: .utf16) else {
            throw MediaIssue.subtitles("Downloaded subtitle file is invalid or exceeds 5 MB.")
        }
        let document = try SubtitleDocument.parse(text)
        let targetURL: URL
        if let videoURL {
            let companion = SubtitleDocument.companionURL(for: videoURL)
            if (try? srtData.write(to: companion, options: .atomic)) != nil {
                targetURL = companion
            } else {
                let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + ".srt")
                try srtData.write(to: fallback, options: .atomic)
                targetURL = fallback
            }
        } else {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("OpenSubtitles-\(fileID).srt")
            try srtData.write(to: fallback, options: .atomic)
            targetURL = fallback
        }
        return (targetURL, document)
    }
}
