import Foundation

enum CodexTaskLogState: Equatable, Sendable {
    case running
    case waitingApproval
    case idle
    case cancelled
    case error
    case unavailable
}

enum CodexTaskStatusSoundEvent: Equatable, Sendable {
    case completed
    case error
    case cancelled
    case approvalRequired
}

struct CodexTaskLogParseResult: Equatable, Sendable {
    let state: CodexTaskLogState
    let startedAt: Date?
    let soundEvents: [CodexTaskStatusSoundEvent]
    let isInitialRead: Bool
}

enum CodexTaskStatusFilePolicy {
    static func selectTopLevelFiles(
        from filesByRecency: [URL],
        maximumCount: Int,
        prioritizing priorityURLs: Set<URL> = []
    ) -> [URL] {
        guard maximumCount > 0 else { return [] }
        let topLevelFiles = filesByRecency.filter {
            !CodexTaskStatusLogParser.isSubagentSession(at: $0)
        }
        let prioritized = topLevelFiles.filter { priorityURLs.contains($0) }
        let remaining = topLevelFiles.lazy.filter { !priorityURLs.contains($0) }
        return prioritized + remaining.prefix(max(0, maximumCount - prioritized.count))
    }
}

enum CodexTaskStatusPolicy {
    static let terminalDecayInterval: TimeInterval = 10 * 60

    static func isPastTerminalDecay(updatedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > terminalDecayInterval
    }

    static func earliestActiveStart(in dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.min()
    }

    static func priority(
        for state: CodexTaskLogState,
        updatedAt: Date?,
        now: Date = Date()
    ) -> Int {
        if state == .error || state == .cancelled,
           let updatedAt,
           isPastTerminalDecay(updatedAt: updatedAt, now: now) {
            return 0
        }
        switch state {
        case .waitingApproval: return 6
        case .running: return 5
        case .error: return 3
        case .cancelled: return 2
        case .idle: return 1
        case .unavailable: return 0
        }
    }
}

enum CodexTaskStatusDirectoryPolicy {
    static func utcDateComponents(for date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    static func date(daysBefore offset: Int, from date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -offset, to: date)
    }
}

struct CodexTaskStatusLogParser {
    private static let newline: UInt8 = 0x0A
    private static let cache = StateCache()
    private static let lifecycleMarkers = [
        "task_started", "user_message", "task_complete", "turn_aborted",
        "error", "stream_error", "exec_command_end", "patch_apply_end",
        "mcp_tool_call_end",
    ].map { Data("\"\($0)\"".utf8) }
    private static let permissionRequestMarker = Data("\"request_permissions\"".utf8)
    private static let functionOutputMarker = Data("\"function_call_output\"".utf8)
    private static let activityMarkers = [
        "agent_message", "message", "reasoning", "function_call",
        "function_call_output", "custom_tool_call", "custom_tool_call_output",
        "local_shell_call", "tool_search_call", "tool_search_output",
        "agent_reasoning", "web_search_end", "image_generation_end",
    ].map { Data("\"\($0)\"".utf8) }

    private struct CacheEntry {
        let offset: UInt64
        let state: CodexTaskLogState
        let startedAt: Date?
        let currentTurnFailed: Bool
        let pendingPermissionCallIDs: Set<String>
    }

    private final class StateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: CacheEntry] = [:]
        private var subagentSessions: [URL: Bool] = [:]

        func entry(for url: URL) -> CacheEntry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[url]
        }

        func set(_ entry: CacheEntry, for url: URL) {
            lock.lock()
            defer { lock.unlock() }
            entries[url] = entry
        }

        func retain(urls: Set<URL>) {
            lock.lock()
            defer { lock.unlock() }
            entries = entries.filter { urls.contains($0.key) }
            subagentSessions = subagentSessions.filter { urls.contains($0.key) }
        }

        func waitingApprovalURLs() -> Set<URL> {
            lock.lock()
            defer { lock.unlock() }
            return Set(entries.compactMap { url, entry in
                entry.state == .waitingApproval ? url : nil
            })
        }

        func activeURLs() -> Set<URL> {
            lock.lock()
            defer { lock.unlock() }
            return Set(entries.compactMap { url, entry in
                entry.state == .running || entry.state == .waitingApproval ? url : nil
            })
        }

        func subagentSession(for url: URL) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return subagentSessions[url]
        }

        func setSubagentSession(_ isSubagent: Bool, for url: URL) {
            lock.lock()
            defer { lock.unlock() }
            subagentSessions[url] = isSubagent
        }
    }

    static func retainCache(for urls: Set<URL>) {
        cache.retain(urls: urls)
    }

    static func waitingApprovalURLs() -> Set<URL> {
        cache.waitingApprovalURLs()
    }

    static func activeURLs() -> Set<URL> {
        cache.activeURLs()
    }

    static func isSubagentSession(at url: URL, maxBytes: Int = 64 * 1024) -> Bool {
        if let cached = cache.subagentSession(for: url) { return cached }
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maxBytes)
        else { return false }
        try? handle.close()

        for line in data.split(separator: newline) {
            guard let raw = try? JSONSerialization.jsonObject(
                with: Data(line)
            ) as? [String: Any],
                (raw["type"] as? String) == "session_meta",
                let payload = raw["payload"] as? [String: Any]
            else { continue }
            let source = payload["source"] as? [String: Any]
            let isSubagent = source?["subagent"] != nil
            cache.setSubagentSession(isSubagent, for: url)
            return isSubagent
        }
        return false
    }

    static func parse(at url: URL, maxBytes: UInt64 = 512 * 1024) -> CodexTaskLogState? {
        parseUpdate(at: url, maxBytes: maxBytes)?.state
    }

    static func parseUpdate(
        at url: URL,
        maxBytes: UInt64 = 512 * 1024
    ) -> CodexTaskLogParseResult? {
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        let length = (try? handle.seekToEnd()) ?? 0
        let cached = cache.entry(for: url)
        let hasCachedBaseline = cached.map {
            length >= $0.offset
        } ?? false
        let canContinue = cached.map {
            length >= $0.offset && length - $0.offset <= maxBytes
        } ?? false
        let readStart: UInt64
        let initialState: CodexTaskLogState
        let initialStartedAt: Date?
        let initialFailure: Bool
        let initialPendingPermissionCallIDs: Set<String>
        if hasCachedBaseline, let cached {
            readStart = canContinue
                ? cached.offset
                : (length > maxBytes ? length - maxBytes : 0)
            // Preserve terminal and approval markers across a capped suffix
            // read. In particular, task_complete must not turn a preceding
            // error outside the tail window into a false success sound.
            initialState = cached.state
            initialStartedAt = cached.startedAt
            initialFailure = cached.currentTurnFailed
            initialPendingPermissionCallIDs = cached.pendingPermissionCallIDs
        } else {
            readStart = length > maxBytes ? length - maxBytes : 0
            initialState = .idle
            initialStartedAt = nil
            initialFailure = false
            initialPendingPermissionCallIDs = []
        }

        try? handle.seek(toOffset: readStart)
        let readLimit = Int(min(maxBytes, UInt64(Int.max)))
        guard let raw = try? handle.read(upToCount: readLimit) else { return nil }
        let complete = completeLines(
            in: raw,
            droppingLeadingPartialLine: !canContinue && readStart > 0
        )
        if complete.data.isEmpty, complete.consumedBytes == 0 {
            return hasCachedBaseline
                ? cached.map {
                    CodexTaskLogParseResult(
                        state: $0.state,
                        startedAt: $0.startedAt,
                        soundEvents: [],
                        isInitialRead: false
                    )
                }
                : nil
        }
        let result = parse(
            complete.data,
            initialState: initialState,
            startedAt: initialStartedAt,
            currentTurnFailed: initialFailure,
            pendingPermissionCallIDs: initialPendingPermissionCallIDs
        )
        if !result.recognizedLifecycle, let cached, hasCachedBaseline {
            return CodexTaskLogParseResult(
                state: cached.state,
                startedAt: cached.startedAt,
                soundEvents: [],
                isInitialRead: false
            )
        }
        if !result.recognizedLifecycle, !hasCachedBaseline {
            return nil
        }
        cache.set(
            CacheEntry(
                offset: readStart + UInt64(complete.consumedBytes),
                state: result.state,
                startedAt: result.startedAt,
                currentTurnFailed: result.currentTurnFailed,
                pendingPermissionCallIDs: result.pendingPermissionCallIDs
            ),
            for: url
        )
        return CodexTaskLogParseResult(
            state: result.state,
            startedAt: result.startedAt,
            soundEvents: result.soundEvents,
            isInitialRead: !hasCachedBaseline
        )
    }

    private static func completeLines(
        in data: Data,
        droppingLeadingPartialLine: Bool
    ) -> (data: Data, consumedBytes: Int) {
        var lowerBound = data.startIndex
        if droppingLeadingPartialLine {
            guard let firstNewline = data.firstIndex(of: newline) else {
                return (Data(), 0)
            }
            lowerBound = data.index(after: firstNewline)
        }
        guard let lastNewline = data.lastIndex(of: newline),
              lastNewline >= lowerBound
        else {
            return (Data(), 0)
        }
        let upperBound = data.index(after: lastNewline)
        return (
            Data(data[lowerBound..<upperBound]),
            data.distance(from: data.startIndex, to: upperBound)
        )
    }

    private static func parse(
        _ data: Data,
        initialState: CodexTaskLogState,
        startedAt initialStartedAt: Date?,
        currentTurnFailed initialFailure: Bool,
        pendingPermissionCallIDs initialPendingPermissionCallIDs: Set<String>
    ) -> (
        state: CodexTaskLogState,
        startedAt: Date?,
        currentTurnFailed: Bool,
        recognizedLifecycle: Bool,
        soundEvents: [CodexTaskStatusSoundEvent],
        pendingPermissionCallIDs: Set<String>
    ) {
        var state = initialState
        var startedAt = initialStartedAt
        var currentTurnFailed = initialFailure
        var pendingPermissionCallIDs = initialPendingPermissionCallIDs
        var recognizedLifecycle = false
        var soundEvents: [CodexTaskStatusSoundEvent] = []

        for line in data.split(separator: newline) {
            guard let event = parsedEvent(
                in: line,
                expectsPermissionOutput: !pendingPermissionCallIDs.isEmpty
            ) else { continue }
            switch event {
            case let .lifecycle("task_started", eventDate),
                 let .lifecycle("user_message", eventDate):
                recognizedLifecycle = true
                currentTurnFailed = false
                pendingPermissionCallIDs.removeAll()
                startedAt = eventDate ?? startedAt
                state = .running
            case .lifecycle("exec_command_end", _),
                 .lifecycle("patch_apply_end", _),
                 .lifecycle("mcp_tool_call_end", _):
                recognizedLifecycle = true
                if !currentTurnFailed && pendingPermissionCallIDs.isEmpty {
                    state = .running
                }
            case .lifecycle("task_complete", _):
                recognizedLifecycle = true
                if !pendingPermissionCallIDs.isEmpty {
                    state = .waitingApproval
                } else if currentTurnFailed {
                    state = .error
                } else {
                    state = .idle
                    startedAt = nil
                    soundEvents.append(.completed)
                }
            case .lifecycle("turn_aborted", _):
                recognizedLifecycle = true
                currentTurnFailed = false
                pendingPermissionCallIDs.removeAll()
                startedAt = nil
                state = .cancelled
                soundEvents.append(.cancelled)
            case .lifecycle("error", _), .lifecycle("stream_error", _):
                recognizedLifecycle = true
                if !currentTurnFailed {
                    soundEvents.append(.error)
                }
                currentTurnFailed = true
                pendingPermissionCallIDs.removeAll()
                startedAt = nil
                state = .error
            case let .permissionRequested(callID):
                recognizedLifecycle = true
                if pendingPermissionCallIDs.insert(callID).inserted {
                    soundEvents.append(.approvalRequired)
                }
                state = .waitingApproval
            case let .permissionResolved(callID):
                guard pendingPermissionCallIDs.remove(callID) != nil else { continue }
                recognizedLifecycle = true
                if pendingPermissionCallIDs.isEmpty {
                    state = currentTurnFailed ? .error : .running
                }
            case .activity:
                recognizedLifecycle = true
                if !currentTurnFailed && pendingPermissionCallIDs.isEmpty {
                    state = .running
                }
            default:
                break
            }
        }
        return (
            state,
            startedAt,
            currentTurnFailed,
            recognizedLifecycle,
            soundEvents,
            pendingPermissionCallIDs
        )
    }

    private enum ParsedEvent {
        case lifecycle(String, Date?)
        case permissionRequested(String)
        case permissionResolved(String)
        case activity
    }

    private static func parsedEvent(
        in line: Data.SubSequence,
        expectsPermissionOutput: Bool
    ) -> ParsedEvent? {
        guard line.count < 1_048_576,
              lifecycleMarkers.contains(where: { line.range(of: $0) != nil })
                || line.range(of: permissionRequestMarker) != nil
                || (expectsPermissionOutput && line.range(of: functionOutputMarker) != nil)
                || activityMarkers.contains(where: { line.range(of: $0) != nil }),
              let raw = try? JSONSerialization.jsonObject(
                with: Data(line)
              ) as? [String: Any],
              let payload = raw["payload"] as? [String: Any]
        else { return nil }

        if (raw["type"] as? String) == "event_msg",
           let type = payload["type"] as? String {
            if [
                "agent_message", "agent_reasoning", "web_search_end",
                "image_generation_end",
            ].contains(type) { return .activity }
            let startedAt = (payload["started_at"] as? Double)
                ?? (payload["started_at"] as? Int).map(TimeInterval.init)
            return .lifecycle(
                type,
                startedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        guard (raw["type"] as? String) == "response_item",
              let type = payload["type"] as? String
        else { return nil }
        if type == "function_call",
           (payload["name"] as? String) == "request_permissions",
           let callID = payload["call_id"] as? String {
            return .permissionRequested(callID)
        }
        if type == "function_call_output", expectsPermissionOutput,
           let callID = payload["call_id"] as? String {
            return .permissionResolved(callID)
        }
        if [
            "message", "reasoning", "function_call", "function_call_output",
            "custom_tool_call", "custom_tool_call_output", "local_shell_call",
            "tool_search_call", "tool_search_output",
        ].contains(type) {
            return .activity
        }
        return nil
    }
}
