import SwiftUI

struct DepartmentTab: View {
    @Bindable var store: DataStore
    @State private var newDept = ""
    @State private var editingDept: String?
    @State private var editText = ""
    @State private var deletingDept: String?
    @State private var saveState = AutoSaveState()

    var body: some View {
        VStack(spacing: 0) {
            // Add row
            HStack(spacing: 8) {
                TextField("新项目名称", text: $newDept)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newDept.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Sort buttons
            HStack {
                Text("项目列表")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("按名称") {
                    withAnimation { store.departments.sort() }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                Button("按次数") {
                    withAnimation {
                        store.departments.sort {
                            store.totalCountForDepartment($0) > store.totalCountForDepartment($1)
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Department list — native List drag reorder
            List {
                ForEach(Array(store.departments.enumerated()), id: \.element) { i, dept in
                    if editingDept == dept {
                        HStack(spacing: 8) {
                            TextField("项目名称", text: $editText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { commitRename(dept) }
                            Button("确定") { commitRename(dept) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("取消") { editingDept = nil }
                                .controlSize(.small)
                        }
                    } else {
                        deptRow(i: i, dept: dept)
                    }
                }
                .onMove { from, to in
                    store.departments.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .alert("确认删除「\(deletingDept ?? "")」？", isPresented: Binding(
            get: { deletingDept != nil },
            set: { if !$0 { deletingDept = nil } }
        )) {
            Button("取消", role: .cancel) { deletingDept = nil }
            Button("删除", role: .destructive) {
                if let dept = deletingDept {
                    store.departments.removeAll { $0 == dept }
                    store.hotkeyBindings.removeValue(forKey: dept)
                }
                deletingDept = nil
            }
        } message: {
            let count = store.totalCountForDepartment(deletingDept ?? "")
            Text(count > 0 ? "该项目已有 \(count) 条历史记录，删除后项目名将从列表移除" : "确定要删除这个项目吗？")
        }
        .onChange(of: store.departments) { _, _ in saveState.triggerSave() }
        .autoSaveIndicator(saveState)
    }

    @ViewBuilder
    private func deptRow(i: Int, dept: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(departmentColors[i % departmentColors.count].gradient)
                .frame(width: 8, height: 8)
            Text(dept)
                .font(.body)
            if let binding = store.hotkeyBindings[dept] {
                Text(binding.displayString)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            Text("\(store.totalCountForDepartment(dept)) 次")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                editingDept = dept
                editText = dept
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Button {
                deletingDept = dept
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
    }

    private func add() {
        store.addDepartment(newDept)
        newDept = ""
    }

    private func commitRename(_ oldName: String) {
        store.renameDepartment(from: oldName, to: editText)
        editingDept = nil
    }
}

// MARK: - General Tab

