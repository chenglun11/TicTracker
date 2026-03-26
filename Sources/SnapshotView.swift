import SwiftUI

struct SnapshotView: View {
    @Environment(DataStore.self) private var store
    @State private var showingRestore = false
    @State private var selectedSnapshot: SnapshotEntry?
    @State private var manualDescription = ""
    @State private var manager = SnapshotManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                Text("数据快照")
                    .font(.headline)
                Spacer()
                Button("手动快照") {
                    if !manualDescription.isEmpty {
                        SnapshotManager.shared.saveSnapshot(from: store, description: manualDescription)
                        manualDescription = ""
                    }
                }
                .buttonStyle(.borderless)
                .disabled(manualDescription.isEmpty)
            }
            .padding()

            HStack {
                TextField("快照描述", text: $manualDescription)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            List {
                ForEach(manager.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.description)
                                .font(.body)
                            HStack(spacing: 4) {
                                Text(entry.timestamp, style: .date)
                                Text(entry.timestamp, style: .time)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("恢复") {
                            selectedSnapshot = entry
                            showingRestore = true
                        }
                        .buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("删除", role: .destructive) {
                            manager.deleteSnapshot(id: entry.id)
                        }
                    }
                }
            }
        }
        .alert("确认恢复", isPresented: $showingRestore) {
            Button("取消", role: .cancel) { }
            Button("恢复", role: .destructive) {
                if let snapshot = selectedSnapshot {
                    _ = manager.restoreSnapshot(id: snapshot.id, to: store)
                }
            }
        } message: {
            Text("恢复快照将覆盖当前数据，当前数据会自动备份")
        }
    }
}
