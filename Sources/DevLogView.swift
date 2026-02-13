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
            HStack(spacing: 8) {
                Picker("模块", selection: $filterModule) {
                    ForEach(modules, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                TextField("搜索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Text("\(filtered.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button("清除") { DevLog.shared.clear() }
                    .controlSize(.small)
            }
            .padding(8)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: 0) {
                                Text(DevLog.shared.formatted(entry))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(colorFor(entry.level))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
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

    private func colorFor(_ level: DevLog.Level) -> Color {
        switch level {
        case .info: .primary
        case .warn: .orange
        case .error: .red
        }
    }
}
