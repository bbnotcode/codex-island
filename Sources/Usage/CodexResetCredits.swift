import Foundation

struct CodexResetCredit: Identifiable, Equatable {
    let id: String
    let status: String
    let expiresAt: Date
    let title: String
    let description: String

    var isAvailable: Bool {
        status.lowercased() == "available"
    }
}

struct CodexResetCredits: Equatable {
    var availableCount: Int
    var credits: [CodexResetCredit]

    static let empty = CodexResetCredits(availableCount: 0, credits: [])

    /// Status alone isn't enough: with 30-minute polling a credit can lapse
    /// mid-cycle while the last snapshot still reports it "available".
    var availableCredits: [CodexResetCredit] {
        availableCredits(at: Date())
    }

    func availableCredits(at now: Date) -> [CodexResetCredit] {
        credits.filter { $0.isAvailable && $0.expiresAt > now }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    /// The next opportunity the UI should surface. A reset credit can make
    /// capacity recover sooner than the provider's ordinary window reset, so
    /// compare both clocks and show the earliest future date.
    func nearestResetDate(
        comparedTo systemResetAt: Date?,
        now: Date = Date()
    ) -> Date? {
        let creditResetAt = availableCredits(at: now).first?.expiresAt
        return [systemResetAt, creditResetAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }

    static func localizedMinute(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: date)
    }

    /// Fixed-width numeric form for the narrow notch pill. Keep the date
    /// order compact and force a 24-hour clock so localized AM/PM markers
    /// cannot grow back across the provider logo.
    static func compactLocalizedMinute(
        _ date: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}
