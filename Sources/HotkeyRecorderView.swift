import SwiftUI
import Carbon

struct HotkeyRecorderView: View {
    @Binding var binding: HotkeyBinding?
    var allBindings: [String: HotkeyBinding] = [:]
    var currentDept: String = ""

    @State private var isRecording = false
    @State private var conflictDept: String?
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(label)
                    .font(.callout.monospaced())
                    .frame(minWidth: 80)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(isRecording ? Color.accentColor : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)

            if binding != nil {
                Button {
                    binding = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除快捷键")
            }
        }
        .onDisappear { stopRecording() }
        .alert("快捷键冲突", isPresented: Binding(
            get: { conflictDept != nil },
            set: { if !$0 { conflictDept = nil } }
        )) {
            Button("确定") { conflictDept = nil }
        } message: {
            Text("该快捷键已被「\(conflictDept ?? "")」使用")
        }
    }

    private var label: String {
        if isRecording { return "按下快捷键…" }
        return binding?.displayString ?? "未设置"
    }

    private func startRecording() {
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape cancels
            if event.keyCode == 0x35 {
                stopRecording()
                return nil
            }
            // Require at least one modifier (not just shift)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = flags.contains(.control) || flags.contains(.command) || flags.contains(.option)
            guard hasModifier else { return event }

            var carbonMods: UInt32 = 0
            if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
            if flags.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if flags.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }

            let candidate = HotkeyBinding(keyCode: event.keyCode, carbonModifiers: carbonMods)
            if let conflict = allBindings.first(where: {
                $0.key != currentDept && $0.value == candidate
            }) {
                conflictDept = conflict.key
            } else {
                binding = candidate
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
