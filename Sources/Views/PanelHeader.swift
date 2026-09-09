import SwiftUI

/// Ordered provider titles with a
/// notch-width spacer in the middle that hides the title content behind
/// the physical notch. Lives outside `PagedContent` so it stays fixed
/// while the data area swipes between usage/cost/overview screens.
///
/// Plan tags ("MAX" / "PLUS") are sourced from `UsageStore` since the
/// subscription tier is a property of the account, not the current page.
struct PanelHeader: View {
    let notch: NotchInfo
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var connections = ProviderConnectionStore.shared

    var body: some View {
        HStack(spacing: 0) {
            if let left = visibility.leftSlot {
                title(left, isLeft: true)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
            Color.clear.frame(width: notch.width)
            if let right = visibility.rightSlot {
                title(right, isLeft: false)
            } else {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .frame(height: IslandPanelLayout.headerHeight(notch: notch))
        .padding(.horizontal, IslandPanelLayout.horizontalInset)
    }

    private func title(_ provider: IslandProvider, isLeft: Bool) -> some View {
        let plan = provider == .claude ? usageStore.claude.plan
            : provider == .codex ? usageStore.codex.plan : connections.snapshot(provider).plan
        return HStack(spacing: 8) {
            if isLeft { ProviderMark(provider: provider) }
            else { Spacer(minLength: 0) }
            if !isLeft, provider == .codex { CodexResetStatus() }
            Text(provider.name)
                .font(Typography.providerTitle)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let plan = provider.planDisplayName(plan) {
                Text(plan.uppercased())
                    .font(Typography.chip)
                    .tracking(0.8)
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    .help(plan)
            }
            if isLeft {
                if provider == .codex { CodexResetStatus() }
                Spacer(minLength: 0)
            } else { ProviderMark(provider: provider) }
        }
        .frame(maxWidth: .infinity)
    }
}
