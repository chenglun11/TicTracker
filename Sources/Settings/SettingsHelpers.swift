import SwiftUI

struct UnderlineTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .multilineTextAlignment(.leading)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }
    }
}

@MainActor
func autoSaveSecureField(
    _ title: String,
    text: Binding<String>,
    saved: Binding<Bool>,
    focused: FocusState<Bool>.Binding,
    onSave: @escaping () -> Void
) -> some View {
    SecureField(title, text: text)
        .textFieldStyle(UnderlineTextFieldStyle())
        .focused(focused)
        .onChange(of: focused.wrappedValue) { _, isFocused in
            if !isFocused && !text.wrappedValue.isEmpty {
                onSave()
                saved.wrappedValue = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.8))
                    saved.wrappedValue = false
                }
            }
        }
        .overlay(alignment: .trailing) {
            if saved.wrappedValue {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.trailing, 8)
            }
        }
}
