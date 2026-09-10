import Foundation

@main
@MainActor
struct AutoCollapseDelayTests {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                print("PASS \(label)")
            } else {
                print("FAIL \(label)")
                failures += 1
            }
        }

        let suiteName = "AutoCollapseDelayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AutoCollapseDelayStore(defaults: defaults)
        expect(store.milliseconds == 1_500, "missing preference uses the existing 1.5s default")
        expect(store.seconds == 1.5, "milliseconds convert to seconds")

        store.milliseconds = 500
        expect(defaults.integer(forKey: "MacIsland.autoCollapseDelayMilliseconds") == 500,
               "selected delay persists")

        store.milliseconds = 750
        expect(store.milliseconds == 1_500, "unsupported delay returns to the safe default")
        expect(AutoCollapseDelayStore.allowedMilliseconds == [500, 1_000, 1_500, 2_000, 2_500, 3_000],
               "slider exposes half-second steps across the intended range")

        if failures > 0 { exit(1) }
        print("all AutoCollapseDelayTests passed")
    }
}
