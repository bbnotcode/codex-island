import AppKit
import Sparkle
import SwiftUI

/// Thin wrapper around `SPUStandardUpdaterController` so the rest of the app
/// can talk to Sparkle without importing it directly. Holds Sparkle's UI
/// driver (alert + download window) too — no extra delegate plumbing needed.
///
/// Auto-check cadence and the "automatically download" preference are stored
/// by Sparkle itself in NSUserDefaults under SU* keys, so we don't duplicate
/// that state here.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    enum LocalUpdateState: Equatable {
        case idle, checking, failed
        case current(String)
        case available(String)
    }

    private let controller: SPUStandardUpdaterController
    let updatesEnabled: Bool
    @Published private(set) var localUpdateState: LocalUpdateState = .idle
    private var localCheckTimer: Timer?

    @Published var automaticallyChecks: Bool {
        didSet {
            guard updatesEnabled else {
                if automaticallyChecks { automaticallyChecks = false }
                return
            }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private init() {
        updatesEnabled = Bundle.main.object(forInfoDictionaryKey: "CodexIslandLocalBuild") as? Bool != true
        controller = SPUStandardUpdaterController(
            startingUpdater: updatesEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecks = updatesEnabled && controller.updater.automaticallyChecksForUpdates
        if !updatesEnabled {
            checkLocalBuildForUpdates()
            localCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) {
                [weak self] _ in
                Task { @MainActor in self?.checkLocalBuildForUpdates() }
            }
        }
    }

    func checkForUpdates() {
        if updatesEnabled {
            controller.checkForUpdates(nil)
        } else {
            checkLocalBuildForUpdates()
        }
    }

    func openLocalSyncTool() {
        guard !updatesEnabled else { return }
        let repository = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tool = repository.appendingPathComponent("同步上游并构建.command")
        guard FileManager.default.fileExists(atPath: tool.path) else { return }
        NSWorkspace.shared.open(tool)
    }

    func checkLocalBuildForUpdates() {
        guard !updatesEnabled, localUpdateState != .checking else { return }
        localUpdateState = .checking
        Task {
            do {
                var request = URLRequest(
                    url: URL(string: "https://api.github.com/repos/ericjypark/codex-island/releases/latest")!
                )
                request.setValue("CodexIsland-local-update-check", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                localUpdateState = Self.isNewer(latest, than: current)
                    ? .available(latest)
                    : .current(current)
            } catch {
                localUpdateState = .failed
            }
        }
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
}
