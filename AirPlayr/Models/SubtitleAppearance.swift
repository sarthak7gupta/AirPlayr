import Foundation

/// User preferences for burned-in subtitles (TV stream and offline export).
struct SubtitleAppearance: Codable, Equatable, Sendable {
    enum Size: String, Codable, CaseIterable { case small, medium, large; var scale: Double { switch self { case .small: 0.035; case .medium: 0.045; case .large: 0.06 } } }
    enum Width: String, Codable, CaseIterable { case compact, standard, wide; var fraction: Double { switch self { case .compact: 0.55; case .standard: 0.72; case .wide: 0.9 } } }
    enum Background: String, Codable, CaseIterable { case box, outline, none }
    enum Position: String, Codable, CaseIterable { case bottom, raised, top; var margin: Double { self == .raised ? 0.16 : 0.06 } }
    var size: Size = .medium
    var width: Width = .standard
    var background: Background = .box
    var position: Position = .bottom
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "subtitleAppearance"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "subtitleAppearance") } }
}
