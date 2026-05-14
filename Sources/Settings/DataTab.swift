import SwiftUI

struct DataTab: View {
    @Bindable var store: DataStore
    @State private var showClearTodayAlert = false
    @State private var showClearAllAlert = false
    @State private var importResult: String?
    @State private var showOperationLog = false
    @State private var showSnapshot = false

    var body: some View {
        Form {
            Section("统计") {
                LabeledContent("已记录天数", value: "\(store.totalDaysTracked) 天")
                LabeledContent("累计点击次数", value: "\(store.totalSupportCount) 次")
            }

            Section("操作记录") {
                HStack {
                    Button("操作日志") {
                        showOperationLog = true
                    }
                    Button("数据快照") {
                        showSnapshot = true
                    }
                }
                HStack {
                    Button("打开数据文件") {
                        openPreferencesInFinder()
                    }
                    Button("打开快照目录") {
                        openSnapshotDirectory()
                    }
                }
            }

            Section("导出 / 导入") {
                HStack {
                    Button("导出 JSON") {
                        exportData()
                    }
                    Button("导出 CSV") {
                        exportCSV()
                    }
                    Button("导入 JSON") {
                        importData()
                    }
                }
                if let result = importResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("成功") ? .green : .red)
                }
            }

            Section("清除数据") {
                HStack {
                    Button("清除今日数据") {
                        showClearTodayAlert = true
                    }
                    Button("清除全部历史") {
                        showClearAllAlert = true
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .alert("确认清除今日数据？", isPresented: $showClearTodayAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { store.clearToday() }
        } message: {
            Text("今日的支持记录和日报将被删除")
        }
        .alert("确认清除全部历史？", isPresented: $showClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) { store.clearAllHistory() }
        } message: {
            Text("所有支持记录和日报将被永久删除，此操作不可撤销")
        }
        .sheet(isPresented: $showOperationLog) {
            OperationLogView()
                .environment(store)
                .frame(minWidth: 600, minHeight: 400)
        }
        .sheet(isPresented: $showSnapshot) {
            SnapshotView()
                .environment(store)
                .frame(minWidth: 600, minHeight: 400)
        }
    }

    private func exportData() {
        guard let json = store.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TicTrackerData.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportCSV() {
        let csv = store.exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TicTrackerData.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            importResult = store.importJSON(from: content) ? "导入成功" : "导入失败：格式不正确"
        }
    }

    private func openPreferencesInFinder() {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let plistPath = prefsDir.appendingPathComponent("com.maxli.TicTracker.plist").path
        NSWorkspace.shared.selectFile(plistPath, inFileViewerRootedAtPath: prefsDir.path)
    }

    private func openSnapshotDirectory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let snapshotDir = appSupport.appendingPathComponent("TicTracker/snapshots")
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: snapshotDir.path)
    }
}

// MARK: - About Tab

