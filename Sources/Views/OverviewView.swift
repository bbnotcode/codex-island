import SwiftUI

/// Minimal contribution-style view. Powered by the same local log scan as
/// the cost page, but framed as usage history: cell intensity is token
/// volume, and cell hue follows the dominant provider for that day.
struct OverviewView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject private var screenPref = ScreenPref.shared
    @ObservedObject private var costStore = CostStore.shared
    @ObservedObject private var visibility = ProviderVisibilityStore.shared
    @State private var selectedDate: Date?

    private var days: [OverviewDay] {
        Self.joinDays(
            leftBuckets: costStore.cost(for: visibility.left).dailyTokens,
            rightBuckets: visibility.right.map { costStore.cost(for: $0).dailyTokens } ?? [],
            leftProvider: visibility.left, rightProvider: visibility.right,
            mode: .all
        )
    }

    private var totalTokens: Int {
        days.reduce(0) { $0 + $1.totalTokens }
    }

    private var activeDays: Int {
        days.filter { $0.totalTokens > 0 }.count
    }

    private var leftTokens: Int {
        days.reduce(0) { $0 + $1.leftTokens }
    }

    private var rightTokens: Int {
        days.reduce(0) { $0 + $1.rightTokens }
    }

    private var selectedDay: OverviewDay? {
        guard let selectedDate else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return days.first { cal.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var displayedTokens: Int {
        selectedDay?.totalTokens ?? totalTokens
    }

    private var displayedLeftTokens: Int {
        selectedDay?.leftTokens ?? leftTokens
    }

    private var displayedRightTokens: Int {
        selectedDay?.rightTokens ?? rightTokens
    }

    var body: some View {
        overviewContent
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary

            ContributionGrid(days: days, selectedDate: $selectedDate)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let selectedDay {
                DayDetailStrip(
                    day: selectedDay,
                    leftVisible: true,
                    rightVisible: visibility.right != nil
                )
                .transition(.detailReveal)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .animation(.detailExpand, value: selectedDate)
        .onAppear {
            model.setOverviewDayDetailVisible(screenPref.screen == .overview && selectedDate != nil)
        }
        .onDisappear {
            model.setOverviewDayDetailVisible(false)
        }
        .onChange(of: selectedDate) { _ in
            model.setOverviewDayDetailVisible(screenPref.screen == .overview && selectedDate != nil)
        }
        .onChange(of: screenPref.screen) { screen in
            guard screen != .overview else { return }
            if selectedDate != nil {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selectedDate = nil
                }
            }
            model.setOverviewDayDetailVisible(false)
        }
    }

    private var summary: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryLabel)
                    .font(Typography.sectionLabel)
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.55))

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Self.formatTokens(displayedTokens).value)
                        .font(Typography.chartValue)
                        .foregroundStyle(.white)
                    Text(Self.formatTokens(displayedTokens).unit)
                        .font(Typography.unit)
                        .foregroundStyle(.white.opacity(0.40))
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Text(summarySubline)
                    .font(Typography.label)
                    .foregroundStyle(.white.opacity(0.50))
                if costStore.loading {
                    Text(L10n.tr("Syncing"))
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.36))
                }
            }
            .padding(.bottom, 5)

            ProviderSplitRow(
                leftProvider: visibility.left, rightProvider: visibility.right,
                leftTokens: displayedLeftTokens,
                rightTokens: displayedRightTokens,
                leftVisible: true,
                rightVisible: visibility.right != nil
            )
            .padding(.bottom, 5)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    private var summaryLabel: String {
        guard let selectedDay else { return L10n.tr("%@ TOKENS", Self.currentYearString) }
        return Self.dayLabelFormatter.string(from: selectedDay.date).uppercased()
    }

    private var summarySubline: String {
        guard let selectedDay else { return L10n.tr("%d Active Days", activeDays) }
        switch selectedDay.dominantProvider {
        case .none:   return L10n.tr("No Activity")
        case .left: return "Mostly " + selectedDay.leftProvider.name
        case .right:  return "Mostly " + (selectedDay.rightProvider?.name ?? "")
        case .mixed:  return L10n.tr("Mixed Use")
        }
    }

    private var summaryAccessibilityLabel: String {
        let period = selectedDay.map { Self.dayLabelFormatter.string(from: $0.date) } ?? Self.currentYearString
        var text = "\(period): \(Self.formatTokensSpoken(displayedTokens)). \(visibility.left.name) \(Self.formatTokensSpoken(displayedLeftTokens))"
        if let right = visibility.right { text += ", \(right.name) \(Self.formatTokensSpoken(displayedRightTokens))" }
        return text
    }

    private static func joinDays(
        leftBuckets: [DailyTokenBucket],
        rightBuckets: [DailyTokenBucket],
        leftProvider: IslandProvider, rightProvider: IslandProvider?,
        mode: TokenCountMode
    ) -> [OverviewDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(from: cal.dateComponents([.year], from: today)) ?? today
        let nextYear = cal.date(byAdding: .year, value: 1, to: start) ?? today
        let end = cal.date(byAdding: .day, value: -1, to: nextYear) ?? today
        let dayCount = (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1

        let leftMap = bucketMap(leftBuckets, mode: mode, calendar: cal)
        let rightMap = bucketMap(rightBuckets, mode: mode, calendar: cal)

        return (0..<dayCount).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: start) ?? start
            let key = cal.startOfDay(for: day)
            return OverviewDay(
                leftProvider: leftProvider, rightProvider: rightProvider,
                date: key,
                leftTokens: leftMap[key] ?? 0,
                rightTokens: rightMap[key] ?? 0,
                isFuture: key > today
            )
        }
    }

    private static func bucketMap(
        _ buckets: [DailyTokenBucket],
        mode: TokenCountMode,
        calendar: Calendar
    ) -> [Date: Int] {
        var out: [Date: Int] = [:]
        for bucket in buckets {
            let key = calendar.startOfDay(for: bucket.dayStart)
            let value: Int
            switch mode {
            case .all:      value = bucket.tokens
            case .billable: value = bucket.billableTokens
            }
            out[key, default: 0] += value
        }
        return out
    }

    fileprivate static func formatTokens(_ n: Int) -> (value: String, unit: String) {
        let v = Double(n)
        if n < 1_000 { return ("\(n)", "tok") }
        if n < 10_000 { return (String(format: "%.1f", v / 1_000), "k") }
        if n < 1_000_000 { return (String(format: "%.0f", v / 1_000), "k") }
        if n < 1_000_000_000 { return (String(format: "%.1f", v / 1_000_000), "M") }
        return (String(format: "%.1f", v / 1_000_000_000), "B")
    }

    fileprivate static func formatTokensSpoken(_ n: Int) -> String {
        let formatted = formatTokens(n)
        return L10n.tr("%@ %@ tokens", formatted.value, formatted.unit)
    }

    fileprivate static func formatExactTokens(_ n: Int) -> String {
        integerFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = L10n.locale
        return formatter
    }()

    fileprivate static var currentYearString: String {
        let year = Calendar.current.component(.year, from: Date())
        return "\(year)"
    }
}

private struct OverviewDay: Identifiable {
    let leftProvider: IslandProvider
    let rightProvider: IslandProvider?
    let date: Date
    let leftTokens: Int
    let rightTokens: Int
    var isFuture = false

    var id: Date { date }
    var totalTokens: Int { leftTokens + rightTokens }

    var dominantProvider: DominantProvider {
        guard totalTokens > 0 else { return .none }
        let leftShare = Double(leftTokens) / Double(totalTokens)
        let rightShare = Double(rightTokens) / Double(totalTokens)
        if leftShare >= 0.60 { return .left }
        if rightShare >= 0.60 { return .right }
        return .mixed
    }
}

private enum DominantProvider {
    case none
    case left
    case right
    case mixed
}

private struct ContributionGrid: View {
    let days: [OverviewDay]
    @Binding var selectedDate: Date?

    private var intensityScale: TokenIntensityScale {
        TokenIntensityScale(values: days.map(\.totalTokens))
    }

    var body: some View {
        let scale = intensityScale

        VStack(alignment: .leading, spacing: 7) {
            MonthRail(marks: monthMarks)
                .frame(width: gridWidth, height: 12, alignment: .leading)

            HStack(alignment: .top, spacing: gridSpacing) {
                ForEach(weeks) { week in
                    VStack(spacing: verticalSpacing) {
                        ForEach(Array(week.slots.enumerated()), id: \.offset) { _, slot in
                            switch slot {
                            case .spacer:
                                Color.clear.frame(width: cellSize, height: cellSize)
                            case .day(let day):
                                if day.isFuture {
                                    FutureContributionCell(day: day.date, cellSize: cellSize)
                                } else {
                                    ContributionCell(
                                        day: day,
                                        intensityScale: scale,
                                        cellSize: cellSize,
                                        isSelected: isSelected(day)
                                    ) {
                                        toggleSelection(day)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: cellSize, height: gridHeight, alignment: .top)
                }
            }
            .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        }
        .frame(width: gridWidth, height: gridHeight + 19, alignment: .topLeading)
        .frame(maxWidth: .infinity, minHeight: gridHeight + 19, maxHeight: gridHeight + 19, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("Daily token usage in %@", OverviewView.currentYearString))
    }

    private var weeks: [ContributionWeek] {
        guard let first = days.first?.date,
              let today = days.last?.date else { return [] }
        let cal = calendar
        let start = weekStart(containing: first, calendar: cal)
        let map = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        var out: [ContributionWeek] = []
        out.reserveCapacity(weekCount)

        for week in 0..<weekCount {
            guard let weekStartDate = cal.date(byAdding: .day, value: week * 7, to: start) else {
                continue
            }
            var slots: [ContributionSlot] = []
            slots.reserveCapacity(7)

            for row in 0..<7 {
                let offset = week * 7 + row
                guard let date = cal.date(byAdding: .day, value: offset, to: start) else {
                    slots.append(.spacer)
                    continue
                }
                if date < first || date > today {
                    slots.append(.spacer)
                } else if let day = map[date] {
                    slots.append(.day(day))
                }
            }
            out.append(ContributionWeek(id: weekStartDate, slots: slots))
        }
        return out
    }

    private var weekCount: Int {
        guard let first = days.first?.date,
              let last = days.last?.date else { return 1 }
        let cal = calendar
        let start = weekStart(containing: first, calendar: cal)
        let daySpan = cal.dateComponents([.day], from: start, to: last).day ?? 0
        return max(1, daySpan / 7 + 1)
    }

    private var cellSize: CGFloat {
        return 11.6
    }

    private var gridSpacing: CGFloat {
        return 2.35
    }

    private var verticalSpacing: CGFloat {
        return gridSpacing
    }

    private var gridWidth: CGFloat {
        CGFloat(weekCount) * cellSize + CGFloat(max(0, weekCount - 1)) * gridSpacing
    }

    private var gridHeight: CGFloat {
        CGFloat(7) * cellSize + CGFloat(6) * gridSpacing
    }

    private var monthMarks: [MonthMark] {
        guard let first = days.first?.date,
              let last = days.last?.date else { return [] }
        let cal = calendar
        let start = weekStart(containing: first, calendar: cal)
        var cursor = cal.date(from: cal.dateComponents([.year, .month], from: first)) ?? first
        var marks: [MonthMark] = []

        while cursor <= last {
            let dayOffset = cal.dateComponents([.day], from: start, to: cursor).day ?? 0
            let weekIndex = max(0, dayOffset / 7)
            marks.append(MonthMark(
                id: cursor,
                label: Self.monthFormatter.string(from: cursor),
                x: CGFloat(weekIndex) * (cellSize + gridSpacing)
            ))
            guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    private func isSelected(_ day: OverviewDay) -> Bool {
        guard !day.isFuture else { return false }
        guard let selectedDate else { return false }
        return calendar.isDate(day.date, inSameDayAs: selectedDate)
    }

    private func toggleSelection(_ day: OverviewDay) {
        guard !day.isFuture else { return }
        if isSelected(day) {
            selectedDate = nil
        } else {
            selectedDate = day.date
        }
    }

    private func weekStart(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: date) ?? date
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()
}

private struct ContributionWeek: Identifiable {
    let id: Date
    let slots: [ContributionSlot]
}

private enum ContributionSlot {
    case spacer
    case day(OverviewDay)
}

private struct MonthMark: Identifiable {
    let id: Date
    let label: String
    let x: CGFloat
}

private struct MonthRail: View {
    let marks: [MonthMark]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(marks) { mark in
                Text(mark.label)
                    .font(Typography.caption)
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: mark.x, y: 0)
            }
        }
    }
}

private struct FutureContributionCell: View {
    let day: Date
    let cellSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.white.opacity(0.012))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.030), lineWidth: 0.5)
            }
        .frame(width: cellSize, height: cellSize)
        .accessibilityHidden(true)
    }

    private var cornerRadius: CGFloat {
        min(3, cellSize * 0.22)
    }
}

private struct ContributionCell: View {
    let day: OverviewDay
    let intensityScale: TokenIntensityScale
    let cellSize: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            cellFill
        }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(strokeColor, lineWidth: isSelected ? 1.2 : 0.5)
            }
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { hovering = $0 }
            .help(helpText)
            .accessibilityElement()
            .accessibilityLabel(helpText)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var cellFill: some View {
        let opacity = day.totalTokens > 0 ? intensityScale.opacity(for: day.totalTokens) : 0.035
        switch day.dominantProvider {
        case .none:
            Color.white.opacity(opacity)
        case .left:
            day.leftProvider.color.opacity(opacity)
        case .right:
            (day.rightProvider?.color ?? .clear).opacity(opacity)
        case .mixed:
            ZStack {
                (day.rightProvider?.color ?? .clear).opacity(opacity)
                day.leftProvider.color.opacity(opacity)
                    .clipShape(DiagonalProviderSplitShape(share: leftShare))
            }
        }
    }

    private var cornerRadius: CGFloat {
        min(3, cellSize * 0.22)
    }

    private var leftShare: CGFloat {
        guard day.totalTokens > 0 else { return 0.5 }
        return CGFloat(Double(day.leftTokens) / Double(day.totalTokens))
    }

    private var strokeColor: Color {
        if isSelected { return .white.opacity(0.72) }
        if hovering { return .white.opacity(0.22) }
        guard day.totalTokens > 0 else { return .white.opacity(0.04) }
        return .white.opacity(0.06 + Double(intensityScale.level(for: day.totalTokens)) * 0.012)
    }

    private var helpText: String {
        L10n.tr(
            "%@: %@, %@",
            Self.dayFormatter.string(from: day.date),
            OverviewView.formatTokensSpoken(day.totalTokens),
            dominanceLabel
        )
    }

    private var dominanceLabel: String {
        switch day.dominantProvider {
        case .none:   return L10n.tr("No Activity")
        case .left: return "Mostly " + day.leftProvider.name
        case .right:  return "Mostly " + (day.rightProvider?.name ?? "")
        case .mixed:  return L10n.tr("Mixed Use")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
}

private struct DiagonalProviderSplitShape: Shape {
    let share: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(1, max(0, share))
        let diagonal = s <= 0.5
            ? CGFloat(sqrt(Double(2 * s)))
            : 2 - CGFloat(sqrt(Double(2 * (1 - s))))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        if diagonal <= 1 {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * diagonal, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * diagonal))
        } else {
            let overflow = diagonal - 1
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * overflow))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * overflow, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.closeSubpath()
        return path
    }
}

private struct TokenIntensityScale {
    private let values: [Int]

    init(values: [Int]) {
        self.values = values.filter { $0 > 0 }.sorted()
    }

    func level(for tokens: Int) -> Int {
        guard tokens > 0, !values.isEmpty else { return 0 }
        let rank = Double(upperBound(tokens)) / Double(values.count)
        switch rank {
        case ..<0.15: return 1
        case ..<0.35: return 2
        case ..<0.60: return 3
        case ..<0.80: return 4
        case ..<0.93: return 5
        default:      return 6
        }
    }

    func opacity(for tokens: Int) -> Double {
        switch level(for: tokens) {
        case 1:  return 0.14
        case 2:  return 0.26
        case 3:  return 0.42
        case 4:  return 0.62
        case 5:  return 0.82
        case 6:  return 0.98
        default: return 0.035
        }
    }

    private func upperBound(_ value: Int) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

private struct DayDetailStrip: View {
    let day: OverviewDay
    let leftVisible: Bool
    let rightVisible: Bool

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(.white.opacity(0.075))
                .frame(height: 0.5)

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.detailFormatter.string(from: day.date).uppercased())
                        .font(Typography.sectionLabel)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)

                    Text(L10n.tr("All Tokens"))
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                }
                .frame(width: 116, alignment: .leading)

                TokenSplitMeter(
                    leftProvider: day.leftProvider, rightProvider: day.rightProvider,
                    leftTokens: leftVisible ? day.leftTokens : 0,
                    rightTokens: rightVisible ? day.rightTokens : 0
                )
                .frame(width: 150)

                Spacer(minLength: 0)

                detailMetric(
                    label: L10n.tr("TOTAL"),
                    spokenLabel: L10n.tr("Total"),
                    value: day.totalTokens,
                    color: .white.opacity(0.78),
                    dimmed: true
                )

                if leftVisible {
                    detailMetric(label: day.leftProvider.name.uppercased(), spokenLabel: day.leftProvider.name, value: day.leftTokens, color: day.leftProvider.color)
                }

                if rightVisible {
                    detailMetric(label: day.rightProvider?.name.uppercased() ?? "", spokenLabel: day.rightProvider?.name, value: day.rightTokens, color: (day.rightProvider?.color ?? .clear))
                }
            }
        }
        .frame(height: 46)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func detailMetric(
        label: String,
        spokenLabel: String? = nil,
        value: Int,
        color: Color,
        dimmed: Bool = false
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(Typography.chip)
                .tracking(0.5)
                .foregroundStyle(color.opacity(dimmed ? 0.70 : 0.82))
                .lineLimit(1)

            Text(OverviewView.formatExactTokens(value))
                .font(Typography.bodyNumber)
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
        }
        .frame(width: 82, alignment: .trailing)
        .help(L10n.tr("%@: %@ tokens", spokenLabel ?? label, OverviewView.formatExactTokens(value)))
    }

    private var accessibilityLabel: String {
        var text = "\(Self.detailFormatter.string(from: day.date)), all tokens. Total \(OverviewView.formatTokensSpoken(day.totalTokens)), \(day.leftProvider.name) \(OverviewView.formatTokensSpoken(day.leftTokens))"
        if let right = day.rightProvider { text += ", \(right.name) \(OverviewView.formatTokensSpoken(day.rightTokens))" }
        return text
    }

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}

private struct TokenSplitMeter: View {
    let leftProvider: IslandProvider
    let rightProvider: IslandProvider?
    let leftTokens: Int
    let rightTokens: Int

    private var total: Int { leftTokens + rightTokens }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.055))

                if total > 0 {
                    HStack(spacing: 0) {
                        if leftTokens > 0 {
                            Rectangle()
                                .fill(leftProvider.color.opacity(0.78))
                                .frame(width: segmentWidth(leftTokens, in: geo.size.width))
                        }

                        if rightTokens > 0 {
                            Rectangle()
                                .fill((rightProvider?.color ?? .clear).opacity(0.78))
                                .frame(width: segmentWidth(rightTokens, in: geo.size.width))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 5)
    }

    private func segmentWidth(_ value: Int, in width: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(3, width * CGFloat(Double(value) / Double(total)))
    }
}

private struct ProviderSplitRow: View {
    let leftProvider: IslandProvider
    let rightProvider: IslandProvider?
    let leftTokens: Int
    let rightTokens: Int
    let leftVisible: Bool
    let rightVisible: Bool

    private var total: Int { leftTokens + rightTokens }

    private var visibleCount: Int {
        (leftVisible ? 1 : 0) + (rightVisible ? 1 : 0)
    }

    var body: some View {
        if visibleCount == 0 {
            Text(L10n.tr("Providers Hidden"))
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.36))
        } else {
            HStack(spacing: 8) {
                if leftVisible {
                    splitChip(
                        color: leftProvider.color,
                        label: leftProvider.name,
                        value: leftTokens
                    )
                }
                if rightVisible {
                    splitChip(
                        color: (rightProvider?.color ?? .clear),
                        label: rightProvider?.name ?? "",
                        value: rightTokens
                    )
                }
            }
        }
    }

    private func splitChip(color: Color, label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(label) \(share(value))")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(1)
        }
    }

    private func share(_ value: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(value) / Double(total) * 100).rounded()))%"
    }
}
