import SwiftUI

// MARK: - AutoSaveState

@Observable
@MainActor
final class AutoSaveState {
    private(set) var isShowing = false
    private var hideTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Immediately show the indicator, then hide after 1.5s.
    /// Rapid consecutive calls reset the timer (no stacking).
    func triggerSave() {
        debounceTask?.cancel()
        debounceTask = nil
        showAndScheduleHide()
    }

    /// Wait 1s after the last call, then show the indicator.
    /// Suitable for text input fields.
    func debouncedSave() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            showAndScheduleHide()
        }
    }

    private func showAndScheduleHide() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            isShowing = true
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowing = false
            }
        }
    }
}

// MARK: - AutoSaveIndicator ViewModifier

private struct AutoSaveIndicator: ViewModifier {
    let state: AutoSaveState

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if state.isShowing {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已自动保存")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - View Extension

extension View {
    func autoSaveIndicator(_ state: AutoSaveState) -> some View {
        modifier(AutoSaveIndicator(state: state))
    }
}
