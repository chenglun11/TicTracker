import SwiftUI

struct DevLogView: View {
    @State private var filterModule = "全部"
    @State private var searchText = ""

    private var modules: [String] {
        let all = Set(DevLog.shared.entries.map(\.module))
        return ["全部"] + all.sorted()
    }

    private var filtered: [DevLog.Entry] {
        DevLog.shared.entries.filter { entry in
            (filterModule == "全部" || entry.module == filterModule) &&
            (searchText.isEmpty ||
             entry.message.localizedCaseInsensitiveContains(searchText) ||
             entry.module.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Picker("模块", selection: $filterModule) {
                    ForEach(modules, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                TextField("搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)

                Spacer()

                Text("\(filtered.count) 条")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    DevLog.shared.clear()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("清除")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                // Level badge
                                levelBadge(entry.level)
                                    .frame(width: 40)

                                // Log content
                                Text(DevLog.shared.formatted(entry))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(entry.level == .error ? Color.red.opacity(0.05) :
                                       entry.level == .warn ? Color.orange.opacity(0.05) :
                                       Color.clear)
                            .id(entry.id)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: DevLog.shared.entries.count) { _, _ in
                    if let last = filtered.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private func levelBadge(_ level: DevLog.Level) -> some View {
        let (text, color) = switch level {
        case .info: ("INFO", Color.blue)
        case .warn: ("WARN", Color.orange)
        case .error: ("ERR", Color.red)
        }
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }

    private func colorFor(_ level: DevLog.Level) -> Color {
        switch level {
        case .info: .primary
        case .warn: .orange
        case .error: .red
        }
    }
}
