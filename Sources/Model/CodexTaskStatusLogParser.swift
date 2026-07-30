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

    static func parse(at url: URL, maxBytes: UInt64 = 512 * 1024) -> CodexTaskLogState? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let length = (try? handle.seekToEnd()) ?? 0
        let rawStart = length > maxBytes ? length - maxBytes : 0
        let tailStart = completeLineStart(handle: handle, rawStart: rawStart)
        let failedBeforeTail = failureMarker(handle: handle, before: tailStart)
        try? handle.seek(toOffset: tailStart)
        guard let tail = try? handle.readToEnd() else { return nil }
        return parse(tail, currentTurnFailed: failedBeforeTail).state
    }

    private static func completeLineStart(
        handle: FileHandle,
        rawStart: UInt64
    ) -> UInt64 {
        guard rawStart > 0 else { return 0 }
        try? handle.seek(toOffset: rawStart - 1)
        guard let boundary = try? handle.read(upToCount: 1),
              boundary.first != newline
        else { return rawStart }

        try? handle.seek(toOffset: rawStart)
        var offset = rawStart
        while let chunk = try? handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            if let newlineIndex = chunk.firstIndex(of: newline) {
                return offset + UInt64(newlineIndex + 1)
            }
            offset += UInt64(chunk.count)
        }
        return offset
    }

    private static func failureMarker(
        handle: FileHandle,
        before endOffset: UInt64
    ) -> Bool {
        guard endOffset > 0 else { return false }
        try? handle.seek(toOffset: 0)
        var remaining = endOffset
        var pending = Data()
        var currentTurnFailed = false

        while remaining > 0 {
            let count = Int(min(remaining, 64 * 1024))
            guard let chunk = try? handle.read(upToCount: count),
                  !chunk.isEmpty
            else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: newline) {
                updateFailureMarker(
                    event: eventType(in: pending[..<newlineIndex]),
                    currentTurnFailed: &currentTurnFailed
                )
                pending.removeSubrange(...newlineIndex)
            }
        }
        return currentTurnFailed
    }

    private static func parse(
        _ data: Data,
        currentTurnFailed initialFailure: Bool
    ) -> (state: CodexTaskLogState, currentTurnFailed: Bool) {
        var state: CodexTaskLogState = initialFailure ? .error : .idle
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

    private static func updateFailureMarker(
        event: String?,
        currentTurnFailed: inout Bool
    ) {
        switch event {
        case "task_started", "user_message":
            currentTurnFailed = false
        case "turn_aborted", "error", "stream_error":
            currentTurnFailed = true
        default:
            break
        }
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
