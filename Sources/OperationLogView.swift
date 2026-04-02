import SwiftUI

struct OperationLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataStore.self) private var store
    @State private var searchText = ""
    @State private var showingClearAlert = false

    private var filteredLog: [OperationLogEntry] {
        if searchText.isEmpty {
            return store.operationLog
        }
        return store.operationLog.filter {
            $0.module.localizedCaseInsensitiveContains(searchText) ||
            $0.action.localizedCaseInsensitiveContains(searchText) ||
            $0.detail.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text("操作日志")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    showingClearAlert = true
                }
                .buttonStyle(.borderless)
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            .padding()

            TextField("搜索...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            List {
                ForEach(filteredLog) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.module)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                            Text(entry.action)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(entry.detail)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 80)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("删除") {
                            store.deleteOperationLogEntry(id: entry.id)
                        }
                    }
                }
            }
        }
        .alert("确认清空", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                store.clearOperationLog()
            }
        } message: {
            Text("将清空所有操作日志记录")
        }
    }
}
