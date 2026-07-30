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
    private var lastScanFingerprint: String?

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
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
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
        ) else {
            showOpenFailure(L10n.tr("Codex is not installed on this Mac."))
            return
        }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.showOpenFailure(L10n.tr("Codex could not be opened."))
            }
        }
    }

    private func showOpenFailure(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Unable to open Codex")
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.runModal()
    }

    private func refresh() {
        guard enabled, !refreshInFlight else { return }
        refreshInFlight = true
        let previousFingerprint = lastScanFingerprint
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.scan(previousFingerprint: previousFingerprint)
            }.value
            guard let self else { return }
            self.lastScanFingerprint = result.fingerprint
            if let snapshot = result.snapshot {
                self.snapshot = snapshot
            }
            self.refreshInFlight = false
        }
    }

    private struct ScanResult: Sendable {
        let fingerprint: String
        let snapshot: Snapshot?
    }

    nonisolated private static func scan(previousFingerprint: String?) -> ScanResult {
        let files = recentRolloutFiles()
        let fingerprint = files.map { url in
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        }.joined(separator: "\n")
        guard fingerprint != previousFingerprint else {
            return ScanResult(fingerprint: fingerprint, snapshot: nil)
        }

        let states = files.compactMap(parseState)
        guard let selected = states.max(by: { lhs, rhs in
            if lhs.status.priority != rhs.status.priority {
                return lhs.status.priority < rhs.status.priority
            }
            return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }) else {
            return ScanResult(
                fingerprint: fingerprint,
                snapshot: Snapshot(status: .idle, threadID: nil, updatedAt: nil)
            )
        }
        return ScanResult(fingerprint: fingerprint, snapshot: selected)
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

        let cutoff = Date().addingTimeInterval(-86400)
        var files: [(URL, Date)] = []
        let calendar = Calendar(identifier: .gregorian)
        for dayOffset in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else {
                continue
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { continue }
            let dayDirectory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dayDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls {
                guard url.lastPathComponent.hasPrefix("rollout-"),
                      url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .contentModificationDateKey]
                      ),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= cutoff
                else { continue }
                files.append((url, modified))
            }
        }
        return files
            .sorted { $0.1 > $1.1 }
            .prefix(24)
            .map(\.0)
    }

    nonisolated private static func parseState(at url: URL) -> Snapshot? {
        guard let parsed = CodexTaskStatusLogParser.parse(at: url),
              let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
              ).contentModificationDate
        else { return nil }

        let status: Status = switch parsed {
        case .running: .running
        case .waitingApproval: .waitingApproval
        case .waitingUserInput: .waitingUserInput
        case .idle: .idle
        case .error: .error
        }

        return Snapshot(
            status: status,
            threadID: threadID(from: url),
            updatedAt: modified
        )
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
