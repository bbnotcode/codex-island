import AppKit
import Foundation

@MainActor
final class CodexTaskStatusStore: ObservableObject {
    static let shared = CodexTaskStatusStore()
    private static let enabledKey = "MacIsland.codexTaskStatus"
    private static let displayModeKey = "MacIsland.codexTaskStatusDisplayMode"

    enum DisplayMode: String, CaseIterable, Hashable {
        case icon
        case iconAndText

        var label: String {
            switch self {
            case .icon: "Icon"
            case .iconAndText: "Icon + Text"
            }
        }
    }

    enum Status: String, CaseIterable, Sendable {
        case running
        case waitingApproval
        case waitingUserInput
        case idle
        case error

        var label: String {
            switch self {
            case .running: "Running"
            case .waitingApproval: "Waiting for approval"
            case .waitingUserInput: "Waiting for your input"
            case .idle: "Idle"
            case .error: "Error"
            }
        }

        var compactLabel: String {
            switch self {
            case .running: "Running short"
            case .waitingApproval: "Approval"
            case .waitingUserInput: "Input"
            case .idle: "Idle"
            case .error: "Error"
            }
        }

        fileprivate var priority: Int {
            switch self {
            case .waitingApproval: 5
            case .waitingUserInput: 4
            case .error: 3
            case .running: 2
            case .idle: 1
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        let status: Status
        let threadID: String?
        let updatedAt: Date?
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published var displayMode: DisplayMode {
        didSet {
            UserDefaults.standard.set(
                displayMode.rawValue,
                forKey: Self.displayModeKey
            )
        }
    }
    @Published private(set) var snapshot = Snapshot(
        status: .idle,
        threadID: nil,
        updatedAt: nil
    )

    private var timer: Timer?
    private var refreshInFlight = false

    private init() {
        enabled = Pref.seededBool(
            key: Self.enabledKey,
            default: true
        )
        displayMode = Pref.enumValue(
            key: Self.displayModeKey,
            default: .icon
        )
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func openThread() {
        guard let threadID = snapshot.threadID else {
            openCodexApp()
            return
        }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(threadID)"
        if let url = components.url, NSWorkspace.shared.open(url) { return }
        openCodexApp()
    }

    private func openCodexApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func refresh() {
        guard enabled, !refreshInFlight else { return }
        refreshInFlight = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.scan()
            }.value
            guard let self else { return }
            self.snapshot = result
            self.refreshInFlight = false
        }
    }

    nonisolated private static func scan() -> Snapshot {
        let files = recentRolloutFiles()
        let states = files.compactMap(parseState)
        guard let selected = states.max(by: { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }) else {
            return Snapshot(status: .idle, threadID: nil, updatedAt: nil)
        }
        return selected
    }

    nonisolated private static func recentRolloutFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root: URL
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.isEmpty {
            root = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        } else {
            root = home.appendingPathComponent(".codex/sessions")
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-86400)
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            files.append((url, modified))
        }
        return files
            .sorted { $0.1 > $1.1 }
            .prefix(24)
            .map(\.0)
    }

    nonisolated private static func parseState(at url: URL) -> Snapshot? {
        guard let data = tailData(at: url),
              let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
              ).contentModificationDate
        else { return nil }

        var status = Status.idle
        for line in data.split(separator: 0x0A) {
            guard line.count < 1_048_576,
                  let raw = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (raw["type"] as? String) == "event_msg",
                  let payload = raw["payload"] as? [String: Any],
                  let event = payload["type"] as? String
            else { continue }

            switch event {
            case "task_started", "user_message", "exec_command_begin",
                 "apply_patch_begin", "mcp_tool_call_begin":
                status = .running
            case "exec_approval_request", "apply_patch_approval_request":
                status = .waitingApproval
            case "request_user_input", "elicitation_request":
                status = .waitingUserInput
            case "task_complete":
                status = .idle
            case "turn_aborted", "error", "stream_error":
                status = .error
            default:
                break
            }
        }

        return Snapshot(
            status: status,
            threadID: threadID(from: url),
            updatedAt: modified
        )
    }

    nonisolated private static func tailData(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let maxBytes: UInt64 = 512 * 1024
        try? handle.seek(toOffset: length > maxBytes ? length - maxBytes : 0)
        return try? handle.readToEnd()
    }

    nonisolated private static func threadID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(
            of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) else { return nil }
        return String(stem[range])
    }
}
