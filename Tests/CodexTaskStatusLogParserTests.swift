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
        while data.count < 530 * 1024 {
            let update = event("response_item", detail: filler)
            data.append(update)
            try update.append(to: log)
            if data.count % (64 * 1024) < update.count {
                _ = CodexTaskStatusLogParser.parse(at: log)
            }
        }
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
