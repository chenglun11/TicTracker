import SwiftUI

struct MenuBarView: View {
    @Bindable var store: DataStore
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日技术支持 — \(store.todayKey)")
                .font(.headline)
                .padding(.bottom, 4)

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

            HStack {
                Button(copied ? "已复制 ✓" : "复制本周汇总") {
                    WeeklyReport.copyToClipboard(from: store)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                Spacer()
                Button("设置") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("退出") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 280)
    }
}
