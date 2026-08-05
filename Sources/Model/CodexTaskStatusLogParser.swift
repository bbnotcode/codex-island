import Foundation

enum CodexTaskLogState: Equatable {
    case running
    case idle
    case cancelled
    case error
    case unavailable
}

enum CodexTaskStatusSoundEvent: Equatable {
    case completed
    case attention
}

enum CodexTaskStatusSoundPolicy {
    static func event(
        previous: CodexTaskLogState,
        current: CodexTaskLogState
    ) -> CodexTaskStatusSoundEvent? {
        guard previous == .running else { return nil }
        switch current {
        case .idle:
            return .completed
        case .cancelled, .error:
            return .attention
        case .running, .unavailable:
            return nil
        }
    }
}

enum CodexTaskStatusPolicy {
    static func priority(
        for state: CodexTaskLogState,
        updatedAt: Date?,
        now: Date = Date()
    ) -> Int {
        if state == .error || state == .cancelled,
           let updatedAt,
           now.timeIntervalSince(updatedAt) > 10 * 60 {
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
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        let length = (try? handle.seekToEnd()) ?? 0
        let cached = cache.entry(for: url)
        let canContinue = cached.map {
            length >= $0.offset && length - $0.offset <= maxBytes
        } ?? false
        let readStart: UInt64
        let initialState: CodexTaskLogState
        let initialFailure: Bool
        if canContinue, let cached {
            readStart = cached.offset
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
        if !canContinue, complete.data.isEmpty, complete.consumedBytes == 0 {
            return nil
        }
        let result = parse(
            complete.data,
            initialState: initialState,
            currentTurnFailed: initialFailure
        )
        if !canContinue, !result.recognizedLifecycle {
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
        return result.state
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
    ) -> (state: CodexTaskLogState, currentTurnFailed: Bool, recognizedLifecycle: Bool) {
        var state = initialState
        var currentTurnFailed = initialFailure
        var recognizedLifecycle = false

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
        }
        return (state, currentTurnFailed, recognizedLifecycle)
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
