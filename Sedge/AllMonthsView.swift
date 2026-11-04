//
//  AllMonthsView.swift
//  Sedge
//

import Charts
import SedgeCore
import SwiftUI

/// Every month's spending and every category's over all the data, with a switch that adds
/// money moved between the person's own accounts as its own category bar. Opened from the Spending screen.
/// Tapping a month shows its categories under the chart; tapping a category shows its months under its row.
struct AllMonthsView: View {
    let database: SedgeDatabase
    /// Off by default: moving money to savings or paying a card isn't spending, and the
    /// purchases on the card were already counted at the store.
    @State private var includeMoved = false
    @State private var totals: [SpendingTotal] = []
    /// Which six-month window the chart shows: 0 is the newest, 1 the one before it, and so on.
    @State private var page = 0
    /// Whether the last chevron tapped went back in time, so the chart slides in from that side.
    @State private var pagedBack = true
    /// The tapped month ("YYYY-MM") whose categories show under the chart, or nil.
    @State private var selectedMonth: String?
    /// The tapped category row, by its title, whose months show under it, or nil.
    @State private var selectedCategory: String?

    /// One bar: what it's labeled with and its total in dollars.
    struct Bar: Identifiable {
        let label: String
        let total: Double
        var id: String { label }
    }

    /// Adds up the totals that share a label in whole cents, as the tools add.
    static func bars(_ totals: [SpendingTotal], by label: (SpendingTotal) -> String) -> [Bar] {
        Dictionary(grouping: totals, by: label).map { label, same in
            Bar(label: label, total: Double(same.reduce(0) { $0 + Int(($1.total * 100).rounded()) }) / 100)
        }
    }

    /// Each month's spending over all categories, oldest first. Money moved is left out: it's
    /// not spending, and a second bar per month would be read by VoiceOver as one unnamed pair.
    static func byMonth(_ totals: [SpendingTotal]) -> [Bar] {
        bars(totals.filter { $0.category != SpendingTotal.movedCategory }, by: \.month).sorted { $0.label < $1.label }
    }

    /// Each category's total over all the data, biggest first, money moved included when loaded.
    static func byCategory(_ totals: [SpendingTotal]) -> [Bar] {
        bars(totals) { SpendingView.title($0.category) }.sorted { ($0.total, $1.label) > ($1.total, $0.label) }
    }

    /// One month's categories, biggest first. Money moved is left out, as it is from the month
    /// bars, so they add up to that month's bar.
    static func breakdown(_ totals: [SpendingTotal], month: String) -> [Bar] {
        byCategory(totals.filter { $0.month == month && $0.category != SpendingTotal.movedCategory })
    }

    /// One category's total (by its title) in each of `months`, in their order, $0 where it has none.
    static func monthly(_ totals: [SpendingTotal], category: String, months: [String]) -> [Bar] {
        months.map { month in
            Bar(label: month, total: byCategory(totals.filter { $0.month == month }).first { $0.label == category }?.total ?? 0)
        }
    }

    /// Six-month windows over `months` ("YYYY-MM"), newest window first, each with its oldest
    /// month first. The first ends at the newest month and each next one ends the month before
    /// the last one began, until a window reaches the oldest month. So every month from the
    /// oldest to the newest is in exactly one window; the oldest window may start before the data.
    static func windows(_ months: [String]) -> [[String]] {
        guard let oldest = months.min(), let newest = months.max() else { return [] }
        var windows = [SpendingView.months(endingAt: newest, count: 6)]
        while let start = windows.last?.first, start > oldest {
            // The seven months ending at this window's first month, less that month: the six before it.
            windows.append(Array(SpendingView.months(endingAt: start, count: 7).dropLast()))
        }
        return windows
    }

    /// A window written for people, e.g. "Jan – Jun 2026" or "Oct 2025 – Mar 2026".
    static func span(_ window: [String]) -> String {
        let day = Date.ISO8601FormatStyle().year().month().day()
        guard let first = window.first, let last = window.last,
              let start = try? Date(first + "-01", strategy: day), let end = try? Date(last + "-01", strategy: day)
        else { return "" }
        // The dates are midnight UTC, so they're shown in UTC too, as `displayDate` does.
        return (start..<end).formatted(Date.IntervalFormatStyle(timeZone: .gmt).month(.abbreviated).year())
    }

    /// The category bar money moved gets, as `SpendingView.title` writes it.
    private static let movedLabel = SpendingView.title(SpendingTotal.movedCategory)

    /// Whole dollars on the axes and labels; cents only clutter a chart.
    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    /// The reader's text size setting.
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The name column in the month card, 112 pt in the design; it grows with the text size.
    @ScaledMetric(relativeTo: .caption) private var nameWidth: CGFloat = 112

    /// How a card or a mini chart opens: it unfolds from the top, or only fades in with Reduce Motion.
    private var reveal: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)) }

    /// Runs a tap's change with the design's 0.3 s snappy animation, or a 0.15 s fade with Reduce Motion.
    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3), change)
    }

    /// "2026-03" written for people: "March 2026" (or "Mar" / "M" with `month`).
    private static func monthName(_ month: String, _ style: Date.FormatStyle = .dateTime.month(.wide).year()) -> String {
        (month + "-01").displayDate(style)
    }

    var body: some View {
        let months = Self.byMonth(totals), categories = Self.byCategory(totals)
        let windows = Self.windows(months.map(\.label))
        let window = windows.indices.contains(page) ? windows[page] : []
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text("By month").font(.title2.bold()).foregroundStyle(Color.ink)
                Text("Tap a month to see its categories. Tap it again to clear.").font(.row).foregroundStyle(Color.muted)
                pager(window, count: windows.count)
                chart(months, window)
                    // A new window is a new chart, so it slides in while the old one slides out.
                    .id(page)
                    .transition(reduceMotion ? .opacity : .push(from: pagedBack ? .leading : .trailing))
                    .frame(height: 220)
                    .padding(.top, 8)
                if let month = selectedMonth {
                    card(month, total: months.first { $0.label == month }?.total ?? 0, parts: Self.breakdown(totals, month: month))
                        .padding(.top, 12)
                        .transition(reveal)
                }

                Text("By category").font(.headline).foregroundStyle(Color.ink).padding(.top, 24)
                Text("All the data, biggest first. Tap a category to see its months.").font(.row).foregroundStyle(Color.muted)
                // The switch sits right above the chart it changes.
                Toggle("Include money moved between my accounts", isOn: $includeMoved)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .background(Color.group, in: .rect(cornerRadius: 12))
                    .padding(.vertical, 8)
                // Plain rows rather than a chart: a chart's axis label stays on one line and runs off
                // the screen at large text sizes, while a row's text wraps and the row grows to fit.
                ForEach(categories) { bar in
                    row(bar, largest: categories[0].total, window: window)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.background)
        // Runs each time the screen shows, so a bank sync or a moved transaction counts here,
        // and again whenever the switch changes.
        .task(id: includeMoved) {
            do {
                totals = try SpendingTotal.all(in: database, includeMoved: includeMoved)
            } catch {
                print("Could not read spending:", error)
            }
        }
    }

    /// The chevrons that step through six-month windows, with the window's name between them.
    /// At the largest text sizes the name moves under the chevrons so it isn't cut off.
    private func pager(_ window: [String], count: Int) -> some View {
        let back = chevron("chevron.left", "Earlier months", disabled: page + 1 >= count) { turn(by: 1) }
        let forward = chevron("chevron.right", "Later months", disabled: page == 0) { turn(by: -1) }
        let name = Text(Self.span(window)).font(.cardTitle).foregroundStyle(Color.ink).contentTransition(.numericText())
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { back; Spacer(minLength: 8); name; Spacer(minLength: 8); forward }
            VStack(spacing: 0) { HStack { back; Spacer(); forward }; name }
        }
        .padding(.top, 8)
    }

    /// One 44 × 44 chevron button, at 35% when there's nothing that way.
    private func chevron(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ink)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    /// Moves `step` windows back in time (or forward when negative), closing the month card,
    /// which belongs to the window it was opened in.
    private func turn(by step: Int) {
        pagedBack = step > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3)) {
            page += step
            selectedMonth = nil
        }
    }

    /// The month bars of one window. The tapped month is split into its categories' colors and
    /// the other months fade to the line color; with none tapped, every month is the accent.
    private func chart(_ months: [Bar], _ window: [String]) -> some View {
        Chart {
            ForEach(window, id: \.self) { month in
                let total = months.first { $0.label == month }?.total ?? 0
                if month == selectedMonth {
                    // Reversed so the biggest category sits on top, as it leads the card's list.
                    ForEach(Self.breakdown(totals, month: month).reversed()) { part in
                        BarMark(x: .value("Month", month), y: .value("Spent", part.total), width: .ratio(0.55))
                            .foregroundStyle(Color.category(part.label))
                            // VoiceOver reads the categories in the card; a stack would be read as "2026-03, total".
                            .accessibilityHidden(true)
                    }
                    // An invisible line over the stack gives VoiceOver the month as one element, as before the tap.
                    RuleMark(x: .value("Month", month), yStart: .value("Spent", 0), yEnd: .value("Spent", total))
                        .foregroundStyle(.clear)
                        .accessibilityLabel(Self.monthName(month))
                        .accessibilityValue(total.formatted(Self.dollars))
                } else {
                    BarMark(x: .value("Month", month), y: .value("Spent", total), width: .ratio(0.55))
                        .cornerRadius(5)
                        .foregroundStyle(selectedMonth == nil ? Color.accent : Color.line)
                        .accessibilityLabel(Self.monthName(month))
                        .accessibilityValue(total.formatted(Self.dollars))
                }
            }
        }
        // All six months keep a column, even one with no data, so the bars don't change width.
        .chartXScale(domain: window)
        .chartXAxis {
            AxisMarks { value in
                // "2026-01" is shown as "Jan".
                if let month = value.as(String.self) {
                    // At the accessibility text sizes "Jan" becomes "J", so six months still fit side by side.
                    AxisValueLabel {
                        Text(Self.monthName(month, .dateTime.month(textSize.isAccessibilitySize ? .narrow : .abbreviated)))
                            .fontWeight(month == selectedMonth ? .semibold : nil)
                            .foregroundStyle(month == selectedMonth ? Color.ink : Color.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.line)
                AxisValueLabel(format: Self.dollars).foregroundStyle(Color.muted)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // The whole column takes the tap (about 58 pt wide), not only the thin bar.
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        if let month: String = proxy.value(atX: location.x - geometry[plot].origin.x) {
                            animate { selectedMonth = selectedMonth == month ? nil : month }
                        }
                    }
            }
        }
    }

    /// The card under the chart for a tapped month: its total and each category's share.
    private func card(_ month: String, total: Double, parts: [Bar]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.monthName(month)).font(.cardTitle).foregroundStyle(Color.ink)
                    Text("\(total, format: Self.dollars) across ^[\(parts.count) category](inflect: true)")
                        .font(.row).foregroundStyle(Color.muted)
                }
                Spacer()
                Button { animate { selectedMonth = nil } } label: {
                    Label("Clear", systemImage: "xmark")
                }
                .font(.link)
                .frame(minHeight: 44)
                .padding(.top, -10)
            }
            ForEach(parts) { part in
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    HStack(spacing: 8) {
                        Circle().fill(Color.category(part.label)).frame(width: 10, height: 10)
                        Text(part.label).font(.row).foregroundStyle(Color.ink)
                    }
                    .frame(width: textSize.isAccessibilitySize ? nil : nameWidth, alignment: .leading)
                    // The biggest category fills the space and the others are its share.
                    GeometryReader { space in
                        Capsule().fill(Color.category(part.label))
                            .frame(width: space.size.width * max(0, part.total) / max(parts[0].total, 1))
                    }
                    .frame(minWidth: 60)
                    .frame(height: 6)
                    Text(part.total, format: Self.dollars).font(.row).foregroundStyle(Color.muted)
                        .frame(minWidth: 48, alignment: textSize.isAccessibilitySize ? .leading : .trailing)
                }
                .frame(minHeight: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(part.label)
                .accessibilityValue(part.total.formatted(Self.dollars))
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(Color.group, in: .rect(cornerRadius: 12))
    }

    /// One category's row: its name, total and bar. Tapped, it shows its months in `window` under it.
    private func row(_ bar: Bar, largest: Double, window: [String]) -> some View {
        let selected = bar.label == selectedCategory
        // Money moved in the quieter chart gray; its name above says what it is. A tapped row takes its category's color.
        let color = selected ? Color.category(bar.label) : bar.label == Self.movedLabel ? Color.second : Color.accent
        return VStack(alignment: .leading, spacing: 0) {
            Button { animate { selectedCategory = selected ? nil : bar.label } } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(bar.label)  \(Text(bar.total, format: Self.dollars).foregroundStyle(Color.muted))")
                            .font(.row)
                            .foregroundStyle(Color.ink)
                        Spacer()
                        if selected { Image(systemName: "chevron.down").font(.row.weight(.semibold)).foregroundStyle(Color.muted) }
                    }
                    // Biggest first, so the first bar fills the width and the others are its share.
                    GeometryReader { space in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color)
                            .frame(width: space.size.width * max(0, bar.total) / max(largest, 1))
                    }
                    .frame(height: 18)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // One VoiceOver element per category, read as its name and total.
            .accessibilityLabel(bar.label)
            .accessibilityValue(bar.total.formatted(Self.dollars))
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected {
                miniChart(Self.monthly(totals, category: bar.label, months: window), category: bar.label, window: window)
                    .transition(reveal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.group : .clear, in: .rect(cornerRadius: 12))
        // The row's content lines up with the rest of the screen; only its tapped background reaches wider.
        .padding(.horizontal, -12)
    }

    /// Six small columns: one category's total in each month of the window.
    private func miniChart(_ bars: [Bar], category: String, window: [String]) -> some View {
        let top = max(bars.map(\.total).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(category) · each month, \(Self.span(window))").font(.row).foregroundStyle(Color.muted)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(bars) { bar in
                    VStack(spacing: 3) {
                        // At the largest sizes the amounts don't fit six across; VoiceOver still reads them.
                        if !textSize.isAccessibilitySize {
                            Text(bar.total, format: Self.dollars).font(.note).foregroundStyle(Color.muted)
                        }
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.category(category))
                            .frame(height: 56 * max(0, bar.total) / top)
                        Text(Self.monthName(bar.label, .dateTime.month(textSize.isAccessibilitySize ? .narrow : .abbreviated)))
                            .font(.note).foregroundStyle(Color.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.monthName(bar.label))
                    .accessibilityValue(bar.total.formatted(Self.dollars))
                }
            }
        }
        .padding(.top, 8)
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        AllMonthsView(database: try! .open("maya"))
            .navigationTitle("All months")
    }
}
