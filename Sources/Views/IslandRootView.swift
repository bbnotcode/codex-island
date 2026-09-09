import SwiftUI
import AppKit

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var alwaysShow = AlwaysShowUsageStore.shared
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @ObservedObject private var taskStatus = CodexTaskStatusStore.shared
    @State private var hovering = false
    @State private var contentVisible = false
    @State private var pillsVisible = false
    @State private var pulseToken: UUID?
    @State private var collapseRequest = UUID()

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Only the rotating loading sweep needs per-frame re-renders
            // (its angle is a function of time). Everything else animates
            // via withAnimation springs paced by display sync, so wrapping
            // the whole tree in TimelineView would re-build every overlay
            // and every gesture closure 120 times per second — competing
            // with the spring for main-thread budget and showing up as
            // hover-spring jank.
            ZStack {
                GlowLayer(
                    isExpanded: model.state == .expanded,
                    hovering: hovering,
                    usesLightSurface: expandedUsesLightSurface
                )

                if model.state == .expanded {
                    ExpandedView(model: model)
                        .modifier(ExpandedContentAppearance(
                            usesLightPalette: expandedUsesLightSurface
                        ))
                        .opacity(contentVisible ? 1 : 0)
                        // Slide down from -8 → 0 on enter pairs with the
                        // 100ms→180ms opacity delay set when opening. On
                        // exit the offset never matters because the
                        // content fully fades before the shape shrinks.
                        .offset(y: contentVisible ? 0 : -8)
                        .allowsHitTesting(contentVisible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: model.size.width, height: model.size.height)
            .background {
                    // Frosted halo. ultraThinMaterial is a backdrop blur of
                    // whatever desktop content is behind the window. Lives
                    // in .background AFTER .frame so it doesn't push the
                    // ZStack's layout box larger than model.size — earlier
                    // attempts that put the halo as a sibling inside the
                    // ZStack with its own oversized .frame ended up
                    // expanding the parent bounds, throwing the logo
                    // overlays off and breaking the compact pill alignment
                    // with the physical notch.
                    //
                    // .padding(-9) extends only the rendering by 9pt past
                    // the silhouette on every side, no layout impact.
                    // Opacity tied to contentVisible so it fades alongside
                    // the panel content (220ms after hover-in, immediately
                    // on hover-out) and the .frame here tracks model.size,
                    // so the halo grows/shrinks with the spring morph.
                    //
                    // Purely decorative, so Reduce Transparency drops it
                    // entirely — the solid black silhouette is the UI.
                    if !reduceTransparency {
                        IslandShape()
                            .fill(.ultraThinMaterial)
                            .padding(-9)
                            .blur(radius: 8)
                            .opacity(contentVisible ? 0.55 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.state != .expanded, let left = visibility.leftSlot {
                        ProviderMark(provider: left)
                            .padding(.leading, logoEdgePadding)
                            .padding(.top, max(0, (model.notch.height - 20) / 2))
                    }
                }
                .overlay(alignment: statusOverlayAlignment) {
                    if model.state != .expanded {
                        CompactCodexTaskStatusOverlay(
                            edgePadding: logoEdgePadding,
                            topPadding: max(0, (model.notch.height - 20) / 2),
                            showsDetails: model.state == .peek,
                            isLeft: visibility.leftSlot == nil
                        )
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.state != .expanded, let right = visibility.rightSlot {
                        ProviderMark(provider: right)
                            .padding(.trailing, logoEdgePadding)
                            .padding(.top, max(0, (model.notch.height - 20) / 2))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.state != .compact, let left = visibility.leftSlot {
                        PeekPillOverlay(provider: left, isLeft: true,
                            topPadding: max(0, (model.notch.height - 14) / 2), pillsVisible: pillsVisible)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.state != .compact, let right = visibility.rightSlot {
                        PeekPillOverlay(provider: right, isLeft: false,
                            topPadding: max(0, (model.notch.height - 14) / 2), pillsVisible: pillsVisible)
                    }
                }
                .contentShape(IslandShape())
                .onTapGesture {
                    // Cmd-click cycles the visualization style of whichever
                    // page is active. Usage rotates Ring/Bar/Stepped/Numeric/
                    // Spark; cost rotates USD/VALUE/TOKENS/TREND. Overview
                    // is fixed to year-to-date.
                    if NSEvent.modifierFlags.contains(.command) {
                        switch ScreenPref.shared.screen {
                        case .usage: StylePref.shared.cycle()
                        case .cost:  CostStylePref.shared.cycle()
                        case .overview: return
                        }
                        return
                    }
                }
                .onHover { h in
                    hovering = h
                    if h {
                        // Re-entering an expanded panel cancels a pending
                        // hover-exit collapse. Hover alone never expands.
                        collapseRequest = UUID()
                    } else if model.state == .expanded {
                        scheduleCollapseAfterHoverExit()
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("CodexIsland panel"))
        .accessibilityHint(accessibilityHintForState)
        .onAppear {
            // Snap to peek on launch when the user has opted into always-show.
            // No animation here — the window is just becoming visible, so the
            // user sees the silhouette appear already at peek width rather
            // than morphing out under their gaze.
            if alwaysShow.enabled && model.state == .compact {
                model.setState(.peek)
                pillsVisible = true
            }
        }
        .onChange(of: alwaysShow.enabled) { enabled in
            // Live toggle — defer to the user's current interaction. If they
            // happen to be hovering, the hover state machine owns the morph
            // and will land on the new rest state on hover-out. If the panel
            // is expanded, leave it alone for the same reason.
            guard !hovering, model.state != .expanded else { return }
            if enabled {
                if model.state == .compact {
                    withAnimation(.openMorph) {
                        model.setState(.peek)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        guard model.state == .peek, !hovering else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            pillsVisible = true
                        }
                    }
                }
            } else {
                if model.state == .peek {
                    withAnimation(.easeOut(duration: 0.08)) {
                        pillsVisible = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        // Re-check `alwaysShow.enabled` — if the user toggled
                        // back on inside the 100ms wait, leave the peek state
                        // alone instead of fighting their newer intent.
                        guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
                        withAnimation(.closeMorph) {
                            model.setState(.compact)
                        }
                    }
                }
            }
        }
        .onReceive(AlertEngine.shared.$pulseEvent) { event in
            guard let event, event.id != pulseToken else { return }
            pulseToken = event.id
            handlePulse(event)
            // Consume the event so a re-emission with the same id doesn't
            // re-trigger; the engine writes a fresh PulseEvent for each new
            // crossing tick.
            AlertEngine.shared.pulseEvent = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandRightClickRequested)) { _ in
            NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange, performanceTime: .now
            )
            expandPanel()
        }
    }

    /// Force-extends the island into peek state for ~4s when the alert
    /// engine signals a fresh threshold crossing. Suppressed when the panel
    /// is already expanded — the user is already looking at the data.
    private func handlePulse(_ event: AlertEngine.PulseEvent) {
        if model.state == .expanded {
            if !contentVisible {
                withAnimation(.strongEaseOut) {
                    contentVisible = true
                }
            }
            return
        }

        if model.state == .compact {
            withAnimation(.openMorph) {
                model.setState(.peek)
            }
            // Match the hover-in cadence so the pulse looks identical to a
            // user-initiated peek: shape commits first, content follows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                guard model.state == .peek else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    pillsVisible = true
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            // If the user is hovering or has expanded the panel meanwhile,
            // don't fight their state — let their interaction own the peek
            // lifecycle from here. Under always-show, `.peek` IS the rest
            // state, so the pulse just resolves into the steady-state pill
            // rather than collapsing back to compact.
            guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                pillsVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                // Mirror the outer 4-second guard — if always-show flipped on
                // during the tiny inner wait, leave the peek state alone.
                guard !hovering, model.state == .peek, !alwaysShow.enabled else { return }
                withAnimation(.closeMorph) {
                    model.setState(.compact)
                }
            }
        }
    }

    private var restState: IslandModel.State {
        alwaysShow.enabled ? .peek : .compact
    }

    private func expandPanel() {
        // Invalidates any delayed collapse that was scheduled on a brief
        // pointer exit while the shape was morphing.
        collapseRequest = UUID()
        guard model.state != .expanded else { return }

        withAnimation(.easeOut(duration: 0.08)) {
            pillsVisible = false
        }
        withAnimation(.openMorph) {
            model.setState(.expanded)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            guard model.state == .expanded else { return }
            withAnimation(.strongEaseOut) {
                contentVisible = true
            }
        }
    }

    private func scheduleCollapseAfterHoverExit() {
        // 1.5s is long enough to cross a small pointer gap or return after an
        // accidental exit, without leaving the expanded dashboard hanging.
        let request = UUID()
        collapseRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard collapseRequest == request, !hovering else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                contentVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard collapseRequest == request, !hovering else { return }
                let target = restState
                withAnimation(.closeMorph) {
                    model.setState(target)
                }
                if target == .peek {
                    withAnimation(.easeOut(duration: 0.18)) {
                        pillsVisible = true
                    }
                }
            }
        }
    }

    private var expandedUsesLightSurface: Bool {
        switch appearanceStore.appearance {
        case .light: return true
        case .dark: return false
        case .system: return systemColorScheme == .light
        }
    }

    private var statusOverlayAlignment: Alignment {
        visibility.leftSlot == nil ? .topLeading : .topTrailing
    }

    private var accessibilityHintForState: String {
        switch model.state {
        case .compact:
            return alwaysShow.enabled
                ? L10n.tr("Right-click to expand. Move away to collapse.")
                : L10n.tr("Right-click to expand. Move away to collapse.")
        case .peek:     return L10n.tr("Right-click to expand. Move away to collapse.")
        case .expanded:
            return ScreenPref.shared.screen == .overview
                ? L10n.tr("Swipe to change pages.")
                : L10n.tr("Command-click to cycle visualization.")
        }
    }

    /// Logo's distance from the silhouette's leading/trailing edge. In
    /// `.peek` we offset the logo inward by `pillSlotWidth` so it stays
    /// physically pinned to its compact position while the silhouette grows
    /// outward — leaving the new outboard space for the percentage pill.
    /// Compact and expanded keep the logo at the silhouette edge (existing
    /// behavior; expanded panel layout depends on it).
    private var logoEdgePadding: CGFloat {
        switch model.state {
        case .compact, .expanded: return 9
        case .peek:               return model.pillSlotWidth + 9
        }
    }
}

/// Uses the hidden Claude logo slot for a compact Codex task signal. This
/// keeps the collapsed silhouette visually balanced without adding text or
/// changing its width. The expanded panel continues to use the full status
/// card.
private struct CompactCodexTaskStatusOverlay: View {
    let edgePadding: CGFloat
    let topPadding: CGFloat
    let showsDetails: Bool
    let isLeft: Bool

    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var store = CodexTaskStatusStore.shared

    var body: some View {
        if shouldShow {
            Group {
                if showsDetails || store.snapshot.status.shouldForceCompactLabel {
                    ZStack {
                        HStack(spacing: 0) {
                            Group {
                                if store.snapshot.status == .idle {
                                    Text(Duration.compact(0))
                                } else {
                                    TimelineView(.periodic(from: .now, by: 30)) { context in
                                        Text(elapsedUpdate(at: context.date))
                                    }
                                }
                            }
                                    .font(Typography.bodyNumber)
                                    .foregroundStyle(statusColor)
                                    .frame(width: 50, alignment: .center)

                            Group {
                                if store.displayMode == .iconAndText
                                    || store.snapshot.status.shouldForceCompactLabel {
                                    Text(compactStatusLabel)
                                        .font(Typography.bodyNumber)
                                        .foregroundStyle(.white.opacity(0.68))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 62, alignment: .center)

                            CodexTaskStatusGlyph(
                                status: store.snapshot.status,
                                size: 22,
                                showsBackground: false
                            )
                            .shadow(color: statusColor.opacity(0.40), radius: 4)
                            .frame(width: 44, alignment: .center)
                        }

                        if store.displayMode == .iconAndText
                            || store.snapshot.status.shouldForceCompactLabel {
                            Text("·")
                                .font(Typography.bodyNumber)
                                .foregroundStyle(.white.opacity(0.32))
                                .offset(x: -31)
                        }
                    }
                    .frame(width: 156)
                    .padding(isLeft ? .leading : .trailing, edgePadding)
                    .padding(.top, max(0, topPadding - 1))
                    .offset(x: isLeft ? -121 : 121)
                } else {
                    CodexTaskStatusGlyph(
                        status: store.snapshot.status,
                        size: 22,
                        showsBackground: false
                    )
                    .shadow(color: statusColor.opacity(0.40), radius: 4)
                    .padding(isLeft ? .leading : .trailing, edgePadding)
                    .padding(.top, max(0, topPadding - 1))
                }
            }
            .allowsHitTesting(false)
            .help(L10n.tr("Codex status: %@", L10n.tr(store.snapshot.status.label)))
            .accessibilityLabel(
                L10n.tr("Codex status: %@", L10n.tr(store.snapshot.status.label))
            )
            .animation(.strongEaseOut, value: store.snapshot)
        }
    }

    private var shouldShow: Bool {
        store.enabled && visibility.selected.count == 1
    }

    private var statusColor: Color {
        CodexTaskStatusGlyph.color(for: store.snapshot.status)
    }

    private var compactStatusLabel: String {
        if store.snapshot.status == .waitingApproval {
            return L10n.tr(
                "Approval count %d",
                store.snapshot.waitingApprovalTaskCount
            )
        }
        if store.snapshot.status == .running,
           store.snapshot.runningTaskCount > 1 {
            return L10n.tr(
                "Active count %d",
                store.snapshot.runningTaskCount
            )
        }
        return L10n.tr(store.snapshot.status.compactLabel)
    }

    private func elapsedUpdate(at now: Date) -> String {
        guard store.snapshot.status == .running
                || store.snapshot.status == .waitingApproval,
              let date = store.snapshot.startedAt else { return "—" }
        return Duration.compact(max(0, now.timeIntervalSince(date)))
    }
}

/// Silhouette + halo + animated sweep. Bundles every layer whose
/// appearance depends on alert severity or the Low Power Mode event
/// predicate, so a UsageStore/AlertEngine/CostStore emission only
/// invalidates this child's body — not the root view's overlays,
/// gestures, or expanded-content branch.
private struct GlowLayer: View {
    let isExpanded: Bool
    let hovering: Bool
    let usesLightSurface: Bool

    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var costStore = CostStore.shared
    @ObservedObject private var lowPower = LowPowerModeStore.shared
    @ObservedObject private var alerts = AlertEngine.shared
    @ObservedObject private var occlusion = WindowOcclusionStore.shared

    var body: some View {
        ZStack {
            LoadingSweep(
                active: !occlusion.isOccluded
                    && (lowPower.effectiveEnabled ? glowEventActive : true),
                tint: glowColor
            )

            IslandShape()
                .fill(isExpanded && usesLightSurface
                    ? IslandColor.expandedLightBackground
                    : .black)
                .overlay {
                    IslandShape()
                        .strokeBorder(
                            (usesLightSurface ? Color.black : Color.white)
                                .opacity(isExpanded ? 0.12 : 0),
                            lineWidth: 0.5
                        )
                }
                // Halo follows LPM's event predicate: under LPM it's
                // suppressed at rest and lights up only on refresh,
                // hover, or an active alert. Off-LPM it stays at the
                // ambient 0.35 the way it always has.
                .shadow(
                    color: glowColor.opacity(
                        lowPower.effectiveEnabled ? (glowEventActive ? 0.35 : 0) : 0.35
                    ),
                    radius: 14, y: 0
                )
                .animation(.easeInOut(duration: 0.25), value: glowEventActive)
                // 0.45s cross-fade so a threshold crossing (e.g. 79%→80%)
                // doesn't visibly snap the hue from cobalt to amber.
                .animation(.easeInOut(duration: 0.45), value: alerts.severity)
                .shadow(
                    color: isExpanded ? .black.opacity(0.5) : .clear,
                    radius: 20, y: 10
                )
                .animation(.easeInOut(duration: 0.20), value: usesLightSurface)
        }
    }

    /// Under Low Power Mode the halo + sweep are gated on this predicate:
    /// the user sees glow only when something is happening (a fetch is in
    /// flight, the cursor is hovering, or an alert is active). Off-LPM it's
    /// ignored — both surfaces run continuously.
    private var glowEventActive: Bool {
        hovering
            || usageStore.loading
            || costStore.loading
            || alerts.severity != .none
    }

    /// Silhouette glow color. Cobalt is the ambient default; alert
    /// thresholds replace it with amber/red so the user gets the signal
    /// passively, even before hovering. All three share the same opacity
    /// so the glow's visual weight is constant — only the hue signals
    /// severity.
    private var glowColor: Color {
        switch alerts.severity {
        case .none:     return IslandColor.cobalt
        case .warning:  return IslandColor.alertAmber
        case .critical: return IslandColor.alertRed
        }
    }
}

/// Gives expanded content a real semantic color scheme. Compact and peek
/// remain dark; expanded descendants resolve `Color.primary` and related
/// hierarchy against the selected light/dark surface without altering brand
/// or status hues.
private struct ExpandedContentAppearance: ViewModifier {
    let usesLightPalette: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesLightPalette {
            content
                .environment(\.colorScheme, .light)
        } else {
            content.environment(\.colorScheme, .dark)
        }
    }
}

/// Per-provider peek pill overlay. Observes ProviderVisibilityStore,
/// UsageStore, and AlertEngine — but not CostStore, so a Codex log
/// scan completing doesn't re-render the pill that has no cost data
/// in it.
private struct PeekPillOverlay: View {
    let provider: IslandProvider
    let isLeft: Bool
    let topPadding: CGFloat
    let pillsVisible: Bool

    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @ObservedObject private var connections = ProviderConnectionStore.shared
    @ObservedObject private var quotaPreferences = ProviderQuotaPreferences.shared
    @ObservedObject private var usageStore = UsageStore.shared
    @ObservedObject private var alerts = AlertEngine.shared

    var body: some View {
        let selected = currentWindow
        NotchPeekPill(
            usage: selected.usage,
            loading: provider.usesLegacyUsage ? usageStore.loading : connections.loading.contains(provider),
            tint: tint,
            alignment: isLeft ? .leading : .trailing,
            fallbackResetText: provider.usesLegacyUsage ? (selected.kind == .weekly ? "7d" : "5h") : "",
            severity: severity,
            showsAbsoluteResetTime: provider == .codex
        )
        .padding(isLeft ? .leading : .trailing, 14)
        .padding(.top, topPadding)
        // Two opacity bindings stack:
        //   - `pillsVisible` is the peek lifecycle (hover-in / hover-out).
        //   - `isVisible` is the user's settings toggle.
        // Both must be 1 to render. Animating `isVisible` with the same
        // openMorph spring as the panel layout keeps the toggle fade in
        // lockstep with the rest of the chrome.
        .opacity((pillsVisible && isVisible) ? 1 : 0)
        .animation(.openMorph, value: isVisible)
        .offset(x: pillsVisible ? 0 : (isLeft ? -6 : 6))
        .allowsHitTesting(false)
        .accessibilityLabel(peekLabel(
            for: selected.usage,
            kind: selected.kind,
            provider: providerLabel
        ))
        // Mirror the visual opacity gate exactly — both `pillsVisible` and
        // `isVisible` must be true for the pill to render. Keying the
        // accessibility hide on only `isVisible` lets VoiceOver reach a
        // pill that is visually invisible during the peek-out lifecycle.
        .accessibilityHidden(!(pillsVisible && isVisible))
    }

    private var isVisible: Bool {
        visibility.selected.contains(provider)
    }

    private var currentWindow: (kind: UsageWindow, usage: WindowUsage) {
        switch provider {
        case .claude: return (.fiveHour, usageStore.claude.fiveHour)
        case .codex:
            let selected = usageStore.codex.preferredWindow
            let resetAt = usageStore.codexResetCredits.nearestResetDate(
                comparedTo: selected.usage.resetAt
            )
            return (
                selected.kind,
                WindowUsage(
                    usedPercent: selected.usage.usedPercent,
                    resetAt: resetAt,
                    error: selected.usage.error
                )
            )
        case .grok, .antigravity:
            return (.fiveHour, connections.primary(provider)?.window ?? .unknown)
        }
    }

    private var severity: AlertEngine.Severity {
        alerts.providerSeverities[provider] ?? .none
    }

    private var tint: Color { provider.color }
    private var providerLabel: String { provider.name }

    private func peekLabel(
        for window: WindowUsage,
        kind: UsageWindow,
        provider providerName: String
    ) -> String {
        let windowName = L10n.tr(kind == .fiveHour ? "5-hour" : "weekly")
        if !self.provider.usesLegacyUsage {
            guard window.hasReading else { return L10n.tr("%@: usage unavailable", providerName) }
            return L10n.tr("%@: %d%%", providerName, window.displayedPercentInt(mode: UsageDisplayModeStore.shared.mode))
        }
        if !window.hasReading {
            return L10n.tr("%@: no data for %@ window", providerName, windowName)
        }
        let mode = UsageDisplayModeStore.shared.mode
        let pct = window.displayedPercentInt(mode: mode)
        guard let resetAt = window.resetAt else {
            return mode == .used
                ? L10n.tr("%@: %d percent of %@ window used", providerName, pct, windowName)
                : L10n.tr("%@: %d percent of %@ window remaining", providerName, pct, windowName)
        }
        let resetPhrase: String
        if provider == .codex {
            resetPhrase = L10n.tr(
                "resets at %@",
                CodexResetCredits.localizedMinute(resetAt, locale: L10n.locale)
            )
        } else {
            let remaining = max(0, resetAt.timeIntervalSinceNow)
            resetPhrase = remaining >= 3600
                ? L10n.tr("resets in %d hours", Int((remaining / 3600).rounded(.down)))
                : L10n.tr("resets in %d minutes", max(1, Int((remaining / 60).rounded(.down))))
        }
        return mode == .used
            ? L10n.tr("%@: %d percent of %@ window used, %@", providerName, pct, windowName, resetPhrase)
            : L10n.tr("%@: %d percent of %@ window remaining, %@", providerName, pct, windowName, resetPhrase)
    }
}

/// Cobalt angular-gradient sweep that orbits the silhouette while data is
/// fetching. Owns its own TimelineView so the parent (IslandRootView) doesn't
/// re-render every overlay alongside the sweep — that was competing with the
/// hover spring for main-thread budget.
///
/// Tick rate is 30Hz (was 120Hz). 3.6s/revolution at 30Hz = 12° per frame,
/// indistinguishable from 120Hz to the eye for a slow continuous orbit but
/// 4× cheaper on the main thread. The bigger CPU saving comes from gating
/// `active` on `!isWindowOccluded` upstream — when a fullscreen app or
/// another window covers the menu bar entirely, the sweep stops rendering
/// (the user can't see it anyway), dropping idle CPU to ~0%.
///
/// Earlier attempts to push rotation into Core Animation (CAGradientLayer or
/// `.rotationEffect` over a static gradient) all subtly changed the glow
/// feel — SwiftUI's per-frame conic re-shading produces an alive,
/// atmospheric look that a rotated static texture loses. This is the
/// minimum-cost approach that preserves the exact original render.
private struct LoadingSweep: View {
    let active: Bool
    /// Color of the orbiting trail. Cobalt by default; switches to amber
    /// or red while the alert engine reports a tracked window above its
    /// warning/critical threshold so the entire glow shares one hue.
    let tint: Color

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let rotation = (t * 100).truncatingRemainder(dividingBy: 360)
                IslandShape()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: tint.opacity(0.0), location: 0.55),
                                .init(color: tint, location: 0.78),
                                .init(color: .white.opacity(0.95), location: 0.92),
                                .init(color: tint.opacity(0.0), location: 1.00),
                            ]),
                            center: .center,
                            angle: .degrees(rotation)
                        ),
                        lineWidth: 4
                    )
                    .blur(radius: 3)
            }
        }
    }
}
