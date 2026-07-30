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
        let filler = String(repeating: "x", count: 530 * 1024)
        data.append(event("response_item", detail: filler))
        data.append(event("task_complete"))
        try data.write(to: log)

        expect(
            CodexTaskStatusLogParser.parse(at: log) == .error,
            "failure outside tail survives task_complete"
        )

        var incomplete = event("task_started")
        incomplete.append(event("turn_aborted"))
        incomplete.append(event("response_item", detail: filler))
        try incomplete.write(to: log)
        expect(
            CodexTaskStatusLogParser.parse(at: log) == .error,
            "failure outside tail remains terminal without completion"
        )

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all CodexTaskStatusLogParserTests passed")
    }
}
