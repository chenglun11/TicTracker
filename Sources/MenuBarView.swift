import SwiftUI

struct MenuBarView: View {
    @Bindable var store: DataStore
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false
    @State private var noteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日技术支持")
                    .font(.headline)
                Spacer()
                Text(store.todayKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            if store.departments.isEmpty {
                Text("暂无部门，请在设置中添加")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.departments, id: \.self) { dept in
                    HStack {
                        Text(dept)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(store.todayRecords[dept, default: 0])")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                        Button { store.decrement(dept) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.todayRecords[dept, default: 0] == 0)
                        Button { store.increment(dept) } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("今日小记")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if noteText.isEmpty {
                            Text("记录今天做了什么…")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .onChange(of: noteText) { _, newValue in
                        store.setTodayNote(newValue)
                    }
            }

            Divider()

            HStack {
                Button(copied ? "已复制 ✓" : "复制本周汇总") {
                    WeeklyReport.copyToClipboard(from: store)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                Spacer()
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "recent-notes")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("查看日报")
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("设置")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("退出")
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear { noteText = store.todayNote }
    }
}
