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

struct SettingsStatusRow: View {
    let title: String
    let value: String
    var systemImage: String = "circle"
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}

struct SettingsHint: View {
    let text: String
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
