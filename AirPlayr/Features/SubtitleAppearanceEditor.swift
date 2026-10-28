import SwiftUI

struct SubtitleOverlay: View {
    let text: String
    let style: SubtitleAppearance
    var body: some View {
        GeometryReader { geometry in
            VStack {
                if style.position != .top { Spacer(minLength: 0) }
                Text(text)
                    .font(.system(size: max(12, geometry.size.height * style.size.scale), weight: .semibold))
                    .multilineTextAlignment(.center).foregroundStyle(.white)
                    .shadow(color: style.background == .outline ? .black : .clear, radius: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(style.background == .box ? Color.black.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: geometry.size.width * style.width.fraction)
                if style.position == .top { Spacer(minLength: 0) }
            }.padding(.vertical, geometry.size.height * style.position.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.allowsHitTesting(false).accessibilityLabel("Subtitle: \(text)")
    }
}

struct SubtitleAppearanceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var style: SubtitleAppearance
    let streaming: Bool
    let apply: (SubtitleAppearance) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Subtitle Display").font(.title2.weight(.semibold))
            ZStack {
                Color(white: 0.15)
                SubtitleOverlay(text: "A small adventure.\nA much bigger screen.", style: style)
            }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
            Form {
                Picker("Text size", selection: $style.size) { ForEach(SubtitleAppearance.Size.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Maximum width", selection: $style.width) { ForEach(SubtitleAppearance.Width.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Background", selection: $style.background) { ForEach(SubtitleAppearance.Background.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Position", selection: $style.position) { ForEach(SubtitleAppearance.Position.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            }
            Text(streaming ? "Applies to external SRT captions. Applying briefly reloads the TV stream at your current position." : "Applies to external SRT captions on this Mac, automatic TV streaming, and exported copies. Embedded captions use the system or receiver style.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset") { style = SubtitleAppearance() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(style); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
    }
}
