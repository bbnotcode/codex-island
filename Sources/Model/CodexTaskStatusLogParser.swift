import Foundation

enum CodexTaskLogState: Equatable, Sendable {
    case running
    case idle
    case cancelled
    case error
    case unavailable
}

enum CodexTaskStatusSoundEvent: Equatable, Sendable {
    case completed
    case attention
}

struct CodexTaskLogParseResult: Equatable, Sendable {
    let state: CodexTaskLogState
    let soundEvents: [CodexTaskStatusSoundEvent]
}

struct CodexTaskStatusSoundTracker {
    private(set) var hasRunningTask = false

    mutating func event(for state: CodexTaskLogState) -> CodexTaskStatusSoundEvent? {
        switch state {
        case .running:
            hasRunningTask = true
            return nil
        case .unavailable:
            // A temporary read gap must not erase a known running task.
            return nil
        case .idle:
            guard hasRunningTask else { return nil }
            hasRunningTask = false
            return .completed
        case .cancelled, .error:
            guard hasRunningTask else { return nil }
            hasRunningTask = false
            return .attention
        }
    }
}

enum CodexTaskStatusPolicy {
    static let terminalDecayInterval: TimeInterval = 10 * 60

    static func isPastTerminalDecay(updatedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > terminalDecayInterval
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

    private struct CacheEntry {
        let offset: UInt64
        let state: CodexTaskLogState
        let currentTurnFailed: Bool
    }

    private final class StateCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: CacheEntry] = [:]

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
        }
    }

    static func retainCache(for urls: Set<URL>) {
        cache.retain(urls: urls)
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
        let initialFailure: Bool
        if hasCachedBaseline, let cached {
            readStart = canContinue
                ? cached.offset
                : (length > maxBytes ? length - maxBytes : 0)
            initialState = cached.state
            initialFailure = cached.currentTurnFailed
        } else {
            readStart = length > maxBytes ? length - maxBytes : 0
            initialState = .idle
            initialFailure = false
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
                ? cached.map { CodexTaskLogParseResult(state: $0.state, soundEvents: []) }
                : nil
        }
        let result = parse(
            complete.data,
            initialState: initialState,
            currentTurnFailed: initialFailure
        )
        if !result.recognizedLifecycle, !hasCachedBaseline {
            return nil
        }
        cache.set(
            CacheEntry(
                offset: readStart + UInt64(complete.consumedBytes),
                state: result.state,
                currentTurnFailed: result.currentTurnFailed
            ),
            for: url
        )
        return CodexTaskLogParseResult(
            state: result.state,
            soundEvents: result.soundEvents
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
        currentTurnFailed initialFailure: Bool
    ) -> (
        state: CodexTaskLogState,
        currentTurnFailed: Bool,
        recognizedLifecycle: Bool,
        soundEvents: [CodexTaskStatusSoundEvent]
    ) {
        var state = initialState
        var currentTurnFailed = initialFailure
        var recognizedLifecycle = false
        var soundTracker = CodexTaskStatusSoundTracker()
        var soundEvents: [CodexTaskStatusSoundEvent] = []
        _ = soundTracker.event(for: initialState)

        for line in data.split(separator: newline) {
            guard let event = eventType(in: line) else { continue }
            switch event {
            case "task_started", "user_message":
                recognizedLifecycle = true
                currentTurnFailed = false
                state = .running
            case "exec_command_end", "patch_apply_end", "mcp_tool_call_end":
                recognizedLifecycle = true
                if !currentTurnFailed {
                    state = .running
                }
            case "task_complete":
                recognizedLifecycle = true
                state = currentTurnFailed ? .error : .idle
            case "turn_aborted":
                recognizedLifecycle = true
                currentTurnFailed = false
                state = .cancelled
            case "error", "stream_error":
                recognizedLifecycle = true
                currentTurnFailed = true
                state = .error
            default:
                break
            }
            if let soundEvent = soundTracker.event(for: state) {
                soundEvents.append(soundEvent)
            }
        }
        return (state, currentTurnFailed, recognizedLifecycle, soundEvents)
    }

    private static func eventType(in line: Data.SubSequence) -> String? {
        guard line.count < 1_048_576,
              lifecycleMarkers.contains(where: { line.range(of: $0) != nil }),
              let raw = try? JSONSerialization.jsonObject(
                with: Data(line)
              ) as? [String: Any],
              (raw["type"] as? String) == "event_msg",
              let payload = raw["payload"] as? [String: Any]
        else { return nil }
        return payload["type"] as? String
    }
}
