import Combine
import Foundation

@MainActor
final class AutoCollapseDelayStore: ObservableObject {
    static let shared = AutoCollapseDelayStore()
    static let allowedMilliseconds = Array(stride(from: 500, through: 3_000, by: 500))

    private static let key = "MacIsland.autoCollapseDelayMilliseconds"
    private let defaults: UserDefaults

    @Published var milliseconds: Int {
        didSet {
            let validated = Self.validated(milliseconds)
            if milliseconds != validated {
                milliseconds = validated
            }
            defaults.set(milliseconds, forKey: Self.key)
        }
    }

    var seconds: TimeInterval {
        TimeInterval(milliseconds) / 1_000
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        milliseconds = Self.validated(defaults.integer(forKey: Self.key))
    }

    static func validated(_ milliseconds: Int) -> Int {
        allowedMilliseconds.contains(milliseconds) ? milliseconds : 1_500
    }
}
