import Foundation

enum CodexTaskLogState: Equatable {
    case running
    case waitingApproval
    case waitingUserInput
    case idle
    case error
}

struct CodexTaskStatusLogParser {
    private static let newline: UInt8 = 0x0A
    private static let cache = StateCache()

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
        let result = parse(
            complete.data,
            initialState: initialState,
            currentTurnFailed: initialFailure
        )
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
    ) -> (state: CodexTaskLogState, currentTurnFailed: Bool) {
        var state = initialState
        var currentTurnFailed = initialFailure

        for line in data.split(separator: newline) {
            guard let event = eventType(in: line) else { continue }
            switch event {
            case "task_started", "user_message":
                currentTurnFailed = false
                state = .running
            case "exec_command_begin", "apply_patch_begin", "mcp_tool_call_begin":
                if !currentTurnFailed {
                    state = .running
                }
            case "exec_approval_request", "apply_patch_approval_request":
                if !currentTurnFailed {
                    state = .waitingApproval
                }
            case "request_user_input", "elicitation_request":
                if !currentTurnFailed {
                    state = .waitingUserInput
                }
            case "task_complete":
                state = currentTurnFailed ? .error : .idle
            case "turn_aborted", "error", "stream_error":
                currentTurnFailed = true
                state = .error
            default:
                break
            }
        }
        return (state, currentTurnFailed)
    }

    private static func eventType(in line: Data.SubSequence) -> String? {
        guard line.count < 1_048_576,
              let raw = try? JSONSerialization.jsonObject(
                with: Data(line)
              ) as? [String: Any],
              (raw["type"] as? String) == "event_msg",
              let payload = raw["payload"] as? [String: Any]
        else { return nil }
        return payload["type"] as? String
    }
}
