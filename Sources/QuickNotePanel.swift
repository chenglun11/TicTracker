import Cocoa
import SwiftUI

@MainActor
final class QuickNotePanel {
    static let shared = QuickNotePanel()
    private var panel: NSPanel?

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        p.title = "快速日报"
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.center()
        return p
    }

    func toggle(store: DataStore) {
        if let panel, panel.isVisible {
            panel.close()
            return
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hostingView = NSHostingView(rootView: QuickNoteView(store: store, onClose: { [weak panel] in
            panel?.close()
        }))
        panel.contentView = hostingView
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct QuickNoteView: View {
    @Bindable var store: DataStore
    let onClose: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(store.noteTitle)
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存") {
                    store.setTodayNote(text)
                    onClose()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 320, height: 200)
        .onAppear { text = store.todayNote }
    }
}
