import SwiftUI

struct SettingsView: View {
    @Bindable var store: DataStore
    @State private var newDept = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("新部门名称", text: $newDept)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加", action: add)
                    .disabled(newDept.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            List {
                ForEach(store.departments, id: \.self) { dept in
                    Text(dept)
                }
                .onDelete { store.removeDepartment(at: $0) }
            }
        }
        .navigationTitle("部门管理")
    }

    private func add() {
        store.addDepartment(newDept)
        newDept = ""
    }
}
