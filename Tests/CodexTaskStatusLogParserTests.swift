import Foundation

@main
struct CodexTaskStatusLogParserTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func event(_ type: String, detail: String = "") -> Data {
        let payload: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": type, "detail": detail],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return data + Data([0x0A])
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("rollout-test.jsonl")
        var data = event("task_started")
        data.append(event("stream_error"))
        try data.write(to: log)
        expect(
            CodexTaskStatusLogParser.parse(at: log) == .error,
            "failure marker is cached"
        )

        let filler = String(repeating: "x", count: 180)
        let growthHandle = try FileHandle(forWritingTo: log)
        try growthHandle.seekToEnd()
        while data.count < 530 * 1024 {
            let update = event("response_item", detail: filler)
            data.append(update)
            try growthHandle.write(contentsOf: update)
            if data.count % (64 * 1024) < update.count {
                _ = CodexTaskStatusLogParser.parse(at: log)
            }
        }
        try growthHandle.close()
        data.append(event("task_complete"))
        try event("task_complete").append(to: log)

        expect(
            CodexTaskStatusLogParser.parse(at: log) == .error,
            "failure outside tail survives task_complete"
        )

        let oversized = directory.appendingPathComponent("rollout-oversized.jsonl")
        var oversizedData = event("task_started")
        oversizedData.append(
            event("response_item", detail: String(repeating: "x", count: 1024))
        )
        oversizedData.append(event("task_complete"))
        try oversizedData.write(to: oversized)
        expect(
            CodexTaskStatusLogParser.parse(at: oversized, maxBytes: 128) == .idle,
            "oversized record fallback stays within the read cap"
        )

        let noBoundary = directory.appendingPathComponent("rollout-no-boundary.jsonl")
        try Data(repeating: 0x78, count: 1024).write(to: noBoundary)
        expect(
            CodexTaskStatusLogParser.parse(at: noBoundary, maxBytes: 128) == nil,
            "fresh read without a complete line returns nil"
        )

        let continued = directory.appendingPathComponent("rollout-continued.jsonl")
        try event("stream_error").write(to: continued)
        expect(
            CodexTaskStatusLogParser.parse(at: continued) == .error,
            "continuation state is initialized"
        )
        try Data("partial".utf8).append(to: continued)
        expect(
            CodexTaskStatusLogParser.parse(at: continued) == .error,
            "cached continuation without a complete line preserves state"
        )

        let currentVocabulary = directory.appendingPathComponent("rollout-current.jsonl")
        var currentData = event("task_started")
        currentData.append(event("mcp_tool_call_end"))
        try currentData.write(to: currentVocabulary)
        expect(
            CodexTaskStatusLogParser.parse(at: currentVocabulary) == .running,
            "current rollout end events preserve running state"
        )
        try event("turn_aborted").append(to: currentVocabulary)
        expect(
            CodexTaskStatusLogParser.parse(at: currentVocabulary) == .cancelled,
            "turn_aborted is cancelled rather than error"
        )

        let growthGap = directory.appendingPathComponent("rollout-growth-gap.jsonl")
        var growthData = event("task_started")
        growthData.append(
            event("response_item", detail: String(repeating: "x", count: 1024))
        )
        try growthData.write(to: growthGap)
        expect(
            CodexTaskStatusLogParser.parse(at: growthGap, maxBytes: 128) == nil,
            "unrecognized truncated tail reports unavailable"
        )

        let cachedGrowthGap = directory.appendingPathComponent("rollout-cached-growth-gap.jsonl")
        try event("task_started").write(to: cachedGrowthGap)
        expect(
            CodexTaskStatusLogParser.parse(at: cachedGrowthGap, maxBytes: 128) == .running,
            "long-running task establishes a cached running state"
        )
        try event(
            "response_item",
            detail: String(repeating: "x", count: 1024)
        ).append(to: cachedGrowthGap)
        expect(
            CodexTaskStatusLogParser.parse(at: cachedGrowthGap, maxBytes: 128) == .running,
            "large unrecognized growth preserves the cached running state"
        )
        try event("task_complete").append(to: cachedGrowthGap)
        expect(
            CodexTaskStatusLogParser.parse(at: cachedGrowthGap, maxBytes: 128) == .idle,
            "completion after a large growth gap is still detected"
        )

        let now = Date()
        expect(
            CodexTaskStatusPolicy.priority(for: .running, updatedAt: now, now: now)
                > CodexTaskStatusPolicy.priority(for: .error, updatedAt: now, now: now),
            "live running work outranks a recent error"
        )
        expect(
            CodexTaskStatusPolicy.priority(
                for: .error,
                updatedAt: now.addingTimeInterval(-11 * 60),
                now: now
            ) < CodexTaskStatusPolicy.priority(for: .idle, updatedAt: now, now: now),
            "stale terminal state decays below idle"
        )
        expect(
            !CodexTaskStatusPolicy.isPastTerminalDecay(
                updatedAt: now.addingTimeInterval(-9 * 60),
                now: now
            ) && CodexTaskStatusPolicy.isPastTerminalDecay(
                updatedAt: now.addingTimeInterval(-11 * 60),
                now: now
            ),
            "terminal decay phase changes after ten minutes"
        )

        let utcBoundary = ISO8601DateFormatter().date(
            from: "2026-08-07T01:00:00Z"
        )!
        let utcComponents = CodexTaskStatusDirectoryPolicy.utcDateComponents(
            for: utcBoundary
        )
        expect(
            utcComponents.year == 2026
                && utcComponents.month == 8
                && utcComponents.day == 7,
            "rollout directory components use the UTC date"
        )

        var completionSounds = CodexTaskStatusSoundTracker()
        _ = completionSounds.event(for: .running)
        expect(
            completionSounds.event(for: .idle) == .completed,
            "running to idle emits a completion sound event"
        )
        var errorSounds = CodexTaskStatusSoundTracker()
        _ = errorSounds.event(for: .running)
        expect(
            errorSounds.event(for: .error) == .attention,
            "running to error emits an attention sound event"
        )
        var cancelledSounds = CodexTaskStatusSoundTracker()
        _ = cancelledSounds.event(for: .running)
        expect(
            cancelledSounds.event(for: .cancelled) == .attention,
            "running to cancelled emits an attention sound event"
        )
        var startupSounds = CodexTaskStatusSoundTracker()
        expect(
            startupSounds.event(for: .error) == nil,
            "startup and non-running transitions stay silent"
        )
        var interruptedSounds = CodexTaskStatusSoundTracker()
        _ = interruptedSounds.event(for: .running)
        expect(
            interruptedSounds.event(for: .unavailable) == nil,
            "temporary unavailable state stays silent"
        )
        expect(
            interruptedSounds.event(for: .idle) == .completed,
            "completion after a temporary unavailable state still emits a sound"
        )

        let shortTask = directory.appendingPathComponent("rollout-short-task.jsonl")
        var shortTaskData = event("task_started")
        shortTaskData.append(event("task_complete"))
        try shortTaskData.write(to: shortTask)
        let shortTaskResult = CodexTaskStatusLogParser.parseUpdate(at: shortTask)
        expect(
            shortTaskResult?.state == .idle
                && shortTaskResult?.soundEvents == [.completed],
            "short task completed between polls still emits a completion event"
        )

        let incrementalTask = directory.appendingPathComponent("rollout-incremental-task.jsonl")
        try event("task_started").write(to: incrementalTask)
        let startedResult = CodexTaskStatusLogParser.parseUpdate(at: incrementalTask)
        try event("task_complete").append(to: incrementalTask)
        let completedResult = CodexTaskStatusLogParser.parseUpdate(at: incrementalTask)
        expect(
            startedResult?.soundEvents.isEmpty == true
                && completedResult?.soundEvents == [.completed],
            "incremental task completion emits exactly one completion event"
        )

        let parallelTask = directory.appendingPathComponent("rollout-parallel-task.jsonl")
        var parallelTaskData = event("task_started")
        parallelTaskData.append(event("turn_aborted"))
        try parallelTaskData.write(to: parallelTask)
        expect(
            CodexTaskStatusLogParser.parseUpdate(at: parallelTask)?.soundEvents
                == [.attention],
            "each independently parsed task emits its own terminal event"
        )

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all CodexTaskStatusLogParserTests passed")
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
