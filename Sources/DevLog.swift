import Foundation

@MainActor
@Observable
final class DevLog {
    static let shared = DevLog()

    private(set) var entries: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let module: String
        let message: String
        let level: Level
    }

    enum Level { case info, warn, error }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func info(_ module: String, _ msg: String) {
        append(module: module, message: msg, level: .info)
    }

    func warn(_ module: String, _ msg: String) {
        append(module: module, message: msg, level: .warn)
    }

    func error(_ module: String, _ msg: String) {
        append(module: module, message: msg, level: .error)
    }

    func clear() { entries.removeAll() }

    private func append(module: String, message: String, level: Level) {
        let entry = Entry(time: Date(), module: module, message: message, level: level)
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        // Also print to stdout for Xcode console
        let ts = Self.timeFmt.string(from: entry.time)
        let prefix = switch level {
        case .info: "ℹ"
        case .warn: "⚠"
        case .error: "✗"
        }
        print("[\(ts)] [\(module)] \(prefix) \(message)")
    }

    func formatted(_ entry: Entry) -> String {
        let ts = Self.timeFmt.string(from: entry.time)
        return "[\(ts)] [\(entry.module)] \(entry.message)"
    }
}
