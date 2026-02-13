import SwiftUI

private struct NoteContentView: View {
    let text: String
    let inlineMarkdown: (String) -> AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                        Text(inlineMarkdown(String(line.dropFirst(2))))
                    }
                } else if line.isEmpty {
                    Spacer().frame(height: 4)
                } else {
                    Text(inlineMarkdown(line))
                }
            }
        }
    }
}

struct RecentNotesView: View {
    @Bindable var store: DataStore

    private var recentNotes: [(date: String, display: String, note: String)] {
        let calendar = Calendar.current
        let today = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "M/d (EEE)"
        displayFmt.locale = Locale(identifier: "zh_CN")

        return (0..<14).compactMap { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = fmt.string(from: date)
            guard let note = store.dailyNotes[key], !note.isEmpty else { return nil }
            return (key, displayFmt.string(from: date), note)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recentNotes.isEmpty {
                Text("暂无日报记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(recentNotes, id: \.date) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.display)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NoteContentView(text: item.note, inlineMarkdown: inlineMarkdown)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("最近日报")
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
