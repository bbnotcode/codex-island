import AppKit
import Combine
import Foundation

@MainActor
final class CodexTaskStatusStore: ObservableObject {
    static let shared = CodexTaskStatusStore()
    private static let enabledKey = "MacIsland.codexTaskStatus"
    private static let displayModeKey = "MacIsland.codexTaskStatusDisplayMode"
    private static let soundEnabledKey = "MacIsland.codexTaskStatusSound"
    private static let pollingInterval: TimeInterval = 15
    nonisolated private static let recentFileAge: TimeInterval = 86_400
    nonisolated private static let fullDirectoryScanInterval: TimeInterval = 5 * 60
    nonisolated private static let maximumDayLookback = 30
    nonisolated private static let maximumTrackedFiles = 24

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
        case idle
        case cancelled
        case error
        case unavailable

        var label: String {
            switch self {
            case .running: "Running"
            case .idle: "Idle"
            case .cancelled: "Cancelled"
            case .error: "Error"
            case .unavailable: "Unavailable"
            }
        }

        var compactLabel: String {
            switch self {
            case .running: "Running short"
            case .idle: "Idle"
            case .cancelled: "Cancelled short"
            case .error: "Error"
            case .unavailable: "Unavailable short"
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
    @Published var soundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEnabled, forKey: Self.soundEnabledKey)
        }
    }
    @Published private(set) var snapshot = Snapshot(
        status: .unavailable,
        threadID: nil,
        updatedAt: nil
    )

    private var timer: Timer?
    private var activityCancellable: AnyCancellable?
    private var refreshInFlight = false
    private var lastScanFingerprint: String?
    private var cachedDayDirectories: [URL] = []
    private var lastFullDirectoryScan: Date?
    private var soundTracker = CodexTaskStatusSoundTracker()

    private init() {
        enabled = Pref.seededBool(
            key: Self.enabledKey,
            default: false
        )
        displayMode = Pref.enumValue(
            key: Self.displayModeKey,
            default: .icon
        )
        soundEnabled = Pref.seededBool(
            key: Self.soundEnabledKey,
            default: false
        )
    }

    func start() {
        guard activityCancellable == nil else { return }
        let visibility = ProviderVisibilityStore.shared
        activityCancellable = Publishers.CombineLatest3(
            $enabled,
            visibility.$claudeVisible,
            visibility.$codexVisible
        )
        .map { enabled, claudeVisible, codexVisible in
            enabled && !claudeVisible && codexVisible
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] active in
            self?.setPollingActive(active)
        }
    }

    private func setPollingActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollingInterval,
            repeats: true
        ) { [weak self] _ in
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
        guard isRenderable, !refreshInFlight else { return }
        refreshInFlight = true
        let previousFingerprint = lastScanFingerprint
        let cachedDayDirectories = cachedDayDirectories
        let lastFullDirectoryScan = lastFullDirectoryScan
        Task { [weak self] in
            guard let self else { return }
            defer { self.refreshInFlight = false }
            let result = await Task.detached(priority: .utility) {
                Self.scan(
                    previousFingerprint: previousFingerprint,
                    cachedDayDirectories: cachedDayDirectories,
                    lastFullDirectoryScan: lastFullDirectoryScan
                )
            }.value
            self.lastScanFingerprint = result.fingerprint
            self.cachedDayDirectories = result.cachedDayDirectories
            self.lastFullDirectoryScan = result.lastFullDirectoryScan
            if let snapshot = result.snapshot {
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ nextSnapshot: Snapshot) {
        let nextStatus = logState(for: nextSnapshot.status)
        snapshot = nextSnapshot
        let event = soundTracker.event(for: nextStatus)
        guard soundEnabled, let event
        else { return }
        playSound(for: event)
    }

    private func logState(for status: Status) -> CodexTaskLogState {
        switch status {
        case .running: .running
        case .idle: .idle
        case .cancelled: .cancelled
        case .error: .error
        case .unavailable: .unavailable
        }
    }

    private func playSound(for event: CodexTaskStatusSoundEvent) {
        let name = switch event {
        case .completed: "Glass"
        case .attention: "Basso"
        }
        if NSSound(named: NSSound.Name(name))?.play() != true {
            NSSound.beep()
        }
    }

    private var isRenderable: Bool {
        let visibility = ProviderVisibilityStore.shared
        return enabled && !visibility.claudeVisible && visibility.codexVisible
    }

    private struct ScanResult: Sendable {
        let fingerprint: String
        let snapshot: Snapshot?
        let cachedDayDirectories: [URL]
        let lastFullDirectoryScan: Date?
    }

    private struct RolloutDiscovery: Sendable {
        let files: [URL]
        let cachedDayDirectories: [URL]
        let lastFullDirectoryScan: Date?
    }

    nonisolated private static func scan(
        previousFingerprint: String?,
        cachedDayDirectories: [URL],
        lastFullDirectoryScan: Date?
    ) -> ScanResult {
        let now = Date()
        guard let discovery = recentRolloutFiles(
            cachedDayDirectories: cachedDayDirectories,
            lastFullDirectoryScan: lastFullDirectoryScan,
            now: now
        ) else {
            return ScanResult(
                fingerprint: "unavailable",
                snapshot: Snapshot(status: .unavailable, threadID: nil, updatedAt: nil),
                cachedDayDirectories: cachedDayDirectories,
                lastFullDirectoryScan: lastFullDirectoryScan
            )
        }
        let files = discovery.files
        CodexTaskStatusLogParser.retainCache(for: Set(files))
        let fingerprint = files.map { url in
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            let modified = values?.contentModificationDate
            let decayPhase = modified.map {
                CodexTaskStatusPolicy.isPastTerminalDecay(updatedAt: $0, now: now) ? 1 : 0
            } ?? 0
            return "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|\(decayPhase)"
        }.joined(separator: "\n")
        guard fingerprint != previousFingerprint else {
            return ScanResult(
                fingerprint: fingerprint,
                snapshot: nil,
                cachedDayDirectories: discovery.cachedDayDirectories,
                lastFullDirectoryScan: discovery.lastFullDirectoryScan
            )
        }

        if files.isEmpty {
            return ScanResult(
                fingerprint: fingerprint,
                snapshot: Snapshot(status: .idle, threadID: nil, updatedAt: nil),
                cachedDayDirectories: discovery.cachedDayDirectories,
                lastFullDirectoryScan: discovery.lastFullDirectoryScan
            )
        }

        let states = files.compactMap(parseState)
        guard let selected = states.max(by: { lhs, rhs in
            let lhsPriority = selectionPriority(lhs)
            let rhsPriority = selectionPriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }) else {
            return ScanResult(
                fingerprint: fingerprint,
                snapshot: Snapshot(status: .unavailable, threadID: nil, updatedAt: nil),
                cachedDayDirectories: discovery.cachedDayDirectories,
                lastFullDirectoryScan: discovery.lastFullDirectoryScan
            )
        }
        return ScanResult(
            fingerprint: fingerprint,
            snapshot: selected,
            cachedDayDirectories: discovery.cachedDayDirectories,
            lastFullDirectoryScan: discovery.lastFullDirectoryScan
        )
    }

    nonisolated private static func selectionPriority(_ snapshot: Snapshot) -> Int {
        let state: CodexTaskLogState = switch snapshot.status {
        case .running: .running
        case .idle: .idle
        case .cancelled: .cancelled
        case .error: .error
        case .unavailable: .unavailable
        }
        return CodexTaskStatusPolicy.priority(
            for: state,
            updatedAt: snapshot.updatedAt
        )
    }

    nonisolated private static func recentRolloutFiles(
        cachedDayDirectories: [URL],
        lastFullDirectoryScan: Date?,
        now: Date
    ) -> RolloutDiscovery? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root: URL
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !codexHome.isEmpty {
            root = URL(fileURLWithPath: codexHome).appendingPathComponent("sessions")
        } else {
            root = home.appendingPathComponent(".codex/sessions")
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path)
        else { return nil }

        let cutoff = now.addingTimeInterval(-recentFileAge)
        var files: [(URL, Date)] = []
        func dayDirectory(for date: Date) -> URL? {
            let components = CodexTaskStatusDirectoryPolicy.utcDateComponents(for: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { return nil }
            return root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
        }

        guard let currentDayDirectory = dayDirectory(for: now) else { return nil }
        let rootPrefix = root.path + "/"
        let cacheMatchesRoot = !cachedDayDirectories.isEmpty
            && cachedDayDirectories.allSatisfy { $0.path.hasPrefix(rootPrefix) }
        let needsFullScan = !cacheMatchesRoot
            || lastFullDirectoryScan.map {
                now.timeIntervalSince($0) >= fullDirectoryScanInterval
            } ?? true

        var directories: [URL]
        if needsFullScan {
            directories = []
            for dayOffset in 0...maximumDayLookback {
                guard let date = CodexTaskStatusDirectoryPolicy.date(
                    daysBefore: dayOffset,
                    from: now
                ), let directory = dayDirectory(for: date) else {
                    continue
                }
                directories.append(directory)
            }
        } else {
            directories = Array(Set(cachedDayDirectories + [currentDayDirectory]))
        }

        var directoriesWithRecentFiles: Set<URL> = [currentDayDirectory]
        for dayDirectory in directories {
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
                directoriesWithRecentFiles.insert(dayDirectory)
            }
        }
        let selectedFiles = files
            .sorted { $0.1 > $1.1 }
            .prefix(maximumTrackedFiles)
            .map(\.0)
        return RolloutDiscovery(
            files: selectedFiles,
            cachedDayDirectories: directoriesWithRecentFiles.sorted {
                $0.path < $1.path
            },
            lastFullDirectoryScan: needsFullScan ? now : lastFullDirectoryScan
        )
    }

    nonisolated private static func parseState(at url: URL) -> Snapshot? {
        guard let parsed = CodexTaskStatusLogParser.parse(at: url),
              let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
              ).contentModificationDate
        else { return nil }

        let status: Status = switch parsed {
        case .running: .running
        case .idle: .idle
        case .cancelled: .cancelled
        case .error: .error
        case .unavailable: .unavailable
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
