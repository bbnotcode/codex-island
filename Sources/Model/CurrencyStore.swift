import Combine
import Foundation

enum DisplayCurrency: String, CaseIterable, Codable, Identifiable {
    case usd = "USD"
    case cny = "CNY"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case krw = "KRW"
    case cad = "CAD"
    case aud = "AUD"
    case chf = "CHF"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .usd: "$"
        case .cny, .jpy: "¥"
        case .eur: "€"
        case .gbp: "£"
        case .krw: "₩"
        case .cad: "C$"
        case .aud: "A$"
        case .chf: "CHF "
        }
    }

    var menuLabel: String { "\(rawValue)  \(symbol)" }
    var usesWholeUnits: Bool { self == .jpy || self == .krw }
}

@MainActor
final class CurrencyStore: ObservableObject {
    static let shared = CurrencyStore()

    private static let selectionKey = "MacIsland.displayCurrency"
    private static let cacheKey = "MacIsland.currencyRates.v1"
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    private struct CachedRate: Codable {
        let rate: Double
        let fetchedAt: Date
        let sourceDate: String
    }

    private struct RateResponse: Decodable {
        let result: String
        let baseCode: String
        let timeLastUpdateUnix: TimeInterval
        let rates: [String: Double]

        enum CodingKeys: String, CodingKey {
            case result, rates
            case baseCode = "base_code"
            case timeLastUpdateUnix = "time_last_update_unix"
        }
    }

    @Published var currency: DisplayCurrency {
        didSet {
            UserDefaults.standard.set(currency.rawValue, forKey: Self.selectionKey)
            applyCachedRate()
            Task { await refreshIfNeeded(force: true) }
        }
    }

    @Published private(set) var usdRate: Double = 1
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var refreshing = false

    private var cache: [String: CachedRate]
    private var refreshTask: Task<Void, Never>?

    private init() {
        currency = Pref.enumValue(key: Self.selectionKey, default: DisplayCurrency.usd)
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: CachedRate].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
        applyCachedRate()
        Task { await refreshIfNeeded() }
    }

    func converted(usd: Double) -> Double {
        usd * usdRate
    }

    var displayCurrency: DisplayCurrency {
        hasUsableRate ? currency : .usd
    }

    var displaySymbol: String {
        displayCurrency.symbol
    }

    var displayUsesWholeUnits: Bool {
        displayCurrency.usesWholeUnits
    }

    private var hasUsableRate: Bool {
        currency == .usd || cache[currency.rawValue] != nil
    }

    func formatted(usd: Double, compact: Bool = true, includesSymbol: Bool = true) -> String {
        let value = converted(usd: usd)
        let digits: Int
        if displayUsesWholeUnits || value >= 100 {
            digits = 0
        } else if compact, value >= 10 {
            digits = 1
        } else {
            digits = 2
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = L10n.locale
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = true
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return includesSymbol ? displaySymbol + number : number
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refreshIfNeeded(force: true) }
    }

    private func applyCachedRate() {
        if currency == .usd {
            usdRate = 1
            lastUpdated = nil
        } else if let cached = cache[currency.rawValue] {
            usdRate = cached.rate
            lastUpdated = cached.fetchedAt
        } else {
            // Honest fallback: keep USD magnitude until the first rate lands,
            // and show the USD symbol so the value is never mislabeled.
            usdRate = 1
            lastUpdated = nil
        }
    }

    private func refreshIfNeeded(force: Bool = false) async {
        guard currency != .usd else { return }
        if !force, let cached = cache[currency.rawValue],
           Date().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            return
        }

        let requested = currency
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else {
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        refreshing = true
        defer { refreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(RateResponse.self, from: data),
                  decoded.result == "success",
                  decoded.baseCode == "USD" else { return }
            let fetchedAt = Date()
            let sourceDate = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: decoded.timeLastUpdateUnix)
            )
            for target in DisplayCurrency.allCases where target != .usd {
                guard let rate = decoded.rates[target.rawValue], rate.isFinite, rate > 0 else { continue }
                cache[target.rawValue] = CachedRate(
                    rate: rate,
                    fetchedAt: fetchedAt,
                    sourceDate: sourceDate
                )
            }
            persistCache()
            guard currency == requested, let cached = cache[requested.rawValue] else { return }
            usdRate = cached.rate
            lastUpdated = cached.fetchedAt
        } catch {
            // Keep the most recent cached rate. Currency display should remain
            // stable when the Mac is offline or the reference API is down.
        }
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
