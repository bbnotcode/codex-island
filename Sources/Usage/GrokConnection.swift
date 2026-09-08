import Foundation

/// The CLI owns its refresh token. Reading its session never rotates or writes it.
enum GrokConnection {
    struct Credential: Decodable {
        let key: String
        let expires_at: String?
        let email: String?
        let user_id: String?
    }

    private struct OptionalCredential: Decodable {
        let value: Credential?
        init(from decoder: Decoder) throws { value = try? Credential(from: decoder) }
    }

    static func credential(from data: Data, now: Date = Date()) throws -> Credential {
        let entries = try JSONDecoder().decode([String: OptionalCredential].self, from: data)
            .compactMapValues(\.value)
        let scopes = entries.keys.filter { $0.hasPrefix("https://auth.x.ai::") }.sorted()
        let candidates = scopes + entries.keys.filter { $0 == "https://accounts.x.ai/sign-in" }.sorted()
        let credentials = candidates.compactMap { entries[$0] }.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !credentials.isEmpty else { throw ProviderConnectionError.signIn }
        guard let entry = credentials.first(where: {
            guard let expiry = ProviderPayload.date($0.expires_at) else { return true }
            return expiry > now
        }) else { throw ProviderConnectionError.expired }
        return entry
    }

    static func fetch() async throws -> ConnectedUsage {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        let path = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path), data.count <= 1_048_576 else {
            throw ProviderConnectionError.signIn
        }
        let credential = try credential(from: data)
        let billing = try await request("billing?format=credits", token: credential.key)
        var usage = try parse(billing)
        usage.account = credential.email
        usage.accountID = credential.user_id ?? credential.email
        if let settings = try? await request("settings", token: credential.key, timeout: 2),
           let plan = try? JSONDecoder().decode(Settings.self, from: settings) {
            usage.plan = plan.subscription_tier_display
        }
        usage.updatedAt = Date()
        return usage
    }

    private struct Settings: Decodable { let subscription_tier_display: String? }
    private struct Billing: Decodable { let config: Config }
    private struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodEnd: String?
        let onDemandUsed: Amount?
        let onDemandCap: Amount?
    }
    private struct Period: Decodable { let end: String? }
    private struct Amount: Decodable { let val: Double? }

    static func parse(_ data: Data) throws -> ConnectedUsage {
        let config = try JSONDecoder().decode(Billing.self, from: data).config
        let reset = ProviderPayload.date(config.currentPeriod?.end ?? config.billingPeriodEnd)
        var used = config.creditUsagePercent.map { $0 / 100 }
        if used == nil, let cap = config.onDemandCap?.val, cap > 0,
           let amount = config.onDemandUsed?.val { used = amount / cap }
        let fraction = ProviderPayload.fraction(used)
        return ConnectedUsage(
            limits: [ConnectedLimit(id: "credits", label: "Credits", usedFraction: fraction, resetAt: reset, kind: .credits)],
            message: fraction == nil ? "Signed in. Grok did not report credit usage." : nil
        )
    }

    private static func request(_ path: String, token: String, timeout: TimeInterval = 12) async throws -> Data {
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/\(path)") else {
            throw ProviderConnectionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral, delegate: NoProviderRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProviderConnectionError.invalidResponse }
        guard response.statusCode == 200 else { throw ProviderConnectionError.http(response.statusCode) }
        guard data.count <= 2_097_152 else { throw ProviderConnectionError.invalidResponse }
        return data
    }
}

final class NoProviderRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
