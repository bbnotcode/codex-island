import SwiftUI

struct ConnectedUsageBlock: View {
    let provider: IslandProvider
    @ObservedObject private var connections = ProviderConnectionStore.shared
    @ObservedObject private var preferences = ProviderQuotaPreferences.shared
    @ObservedObject private var style = StylePref.shared

    var body: some View {
        let snapshot = connections.snapshot(provider)
        let limits = connections.limits(provider)
        Group {
            if !snapshot.limits.isEmpty && !limits.isEmpty {
                UsageChartsRow(color: provider.color, style: style.style, seed: provider == .grok ? 5 : 7,
                    metrics: limits.map { limit in
                        UsageChartMetric(id: limit.id, label: limit.label, window: limit.window,
                                         historyKey: snapshot.historyKey(provider: provider, limit: limit))
                    })
                    .help(limits.first?.groupLabel ?? provider.name)
            } else {
                VStack(spacing: 8) {
                    if connections.loading.contains(provider) {
                        ProgressView().controlSize(.small)
                    }
                    Text(L10n.tr(snapshot.needsLogin ? "Connect your account" : "Usage unavailable"))
                        .font(Typography.label).foregroundStyle(.white.opacity(0.65))
                    Button(L10n.tr("Open provider settings")) {
                        UserDefaults.standard.set("providers", forKey: "Settings.activeTab")
                        SettingsWindowController.shared.show()
                    }
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.8))
                    .buttonStyle(PressableButtonStyle(scale: 0.97))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, IslandPanelLayout.columnInset)
    }
}

struct ProviderDataUnavailable: View {
    let message: String
    var body: some View {
        Text(L10n.tr(message))
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .padding(.horizontal, IslandPanelLayout.columnInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
