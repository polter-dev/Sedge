//
//  AllMonthsView.swift
//  Sedge
//

import Charts
import SedgeCore
import SwiftUI

/// Every month's spending, with the selected month split into its categories under the chart.
/// It opens on the newest month; tapping another month selects it, and tapping a category row
/// opens that category's transactions for the month. A switch adds money moved between the
/// person's own accounts as its own row and part of each bar. Opened from the Spending screen.
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
    /// The tapped month ("YYYY-MM"); nil is the window's newest month.
    @State private var selectedMonth: String?
    /// The tapped category row, whose transactions the sheet lists; nil when no sheet is open.
    @State private var opened: Opened?

    /// One bar: what it's labeled with and its total in dollars.
    struct Bar: Identifiable {
        let label: String
        let total: Double
        var id: String { label }
    }

    /// One row of the "By category" list: a stored category (`other` for the Other row), the
    /// stored categories it adds up, its exact total in cents and the whole dollars it shows.
    struct Part: Identifiable {
        let category: String
        let folded: [String]
        let cents: Int
        let dollars: Int
        var id: String { category }
    }

    /// A tapped category row: the row's category, the stored categories and month the sheet lists.
    struct Opened: Identifiable, Hashable {
        let category: String
        let folded: [String]
        let month: String
        /// The last day listed, "YYYY-MM-DD"; nil is the whole month. Spending's Other categories
        /// block sets it, as its month only runs to today's day of the month.
        var through: String?
        var id: Self { self }
    }

    /// Adds up the totals that share a label in whole cents, as the tools add.
    static func bars(_ totals: [SpendingTotal], by label: (SpendingTotal) -> String) -> [Bar] {
        Dictionary(grouping: totals, by: label).map { label, same in
            Bar(label: label, total: Double(same.reduce(0) { $0 + Int(($1.total * 100).rounded()) }) / 100)
        }
    }

    /// Each month's total over every category loaded, oldest first: money moved is in it only
    /// when the switch loaded it, so the selected month's bar is always its list's Total.
    static func byMonth(_ totals: [SpendingTotal]) -> [Bar] {
        bars(totals, by: \.month).sorted { $0.label < $1.label }
    }

    /// One month's categories, biggest first (by name on a tie), money moved included only when
    /// it was loaded. Every category without a color of its own is folded into one "Other" row,
    /// since a list of gray rows can't be told apart; money moved has a color of its own, so it
    /// stays its own row. Their whole dollars add up exactly to the month's total in whole dollars.
    static func parts(_ totals: [SpendingTotal], month: String) -> [Part] {
        let byCategory = SpendingView.cents(totals, month: month)
        let rows = Dictionary(grouping: byCategory.keys) { category in
            Color.categoryColors[SpendingView.title(category)] != nil ? category : "other"
        }
        .map { (category: $0.key, folded: $0.value.sorted(), cents: $0.value.reduce(0) { $0 + byCategory[$1, default: 0] }) }
        .sorted { ($0.cents, SpendingView.title($1.category)) > ($1.cents, SpendingView.title($0.category)) }
        return zip(rows, wholeDollars(rows.map(\.cents))).map {
            Part(category: $0.category, folded: $0.folded, cents: $0.cents, dollars: $1)
        }
    }

    /// A row's color, in the list and in the selected month's bar; Other's is `second`.
    static func color(_ category: String) -> Color { Color.category(SpendingView.title(category)) }

    /// The selected month's bar, bottom to top: one segment per list row with the row's cents and
    /// color, so the bar splits exactly as the list does. Reversed so the biggest row sits on top,
    /// as it leads the list.
    static func segments(_ parts: [Part]) -> [(category: String, cents: Int, color: Color)] {
        parts.reversed().map { ($0.category, $0.cents, color($0.category)) }
    }

    /// The transactions a tapped row's sheet lists, oldest first: every one in the row's stored
    /// categories that month (through `through`), so Other's sheet adds up to Other's row.
    static func sheetRows(in database: SedgeDatabase, _ opened: Opened) throws -> [ListedTransaction] {
        // The 31st covers every month, as a shorter month's dates all sort before it.
        try opened.folded.flatMap {
            try ListedTransaction.spending(in: database, category: $0, from: opened.month + "-01", through: opened.through ?? opened.month + "-31")
        }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    /// Cents rounded to the nearest whole dollar, 50 cents to the even dollar, as the bars' dollar
    /// format rounds, so Total always reads the same as its month's bar.
    static func rounded(_ cents: Int) -> Int { Int((Double(cents) / 100).rounded(.toNearestOrEven)) }

    /// Whole dollars for amounts in cents that add up exactly to their total rounded to the
    /// dollar (largest-remainder rounding): each is rounded down, then the dollars still missing
    /// go one each to the biggest leftover cents, the earlier amount first on a tie. Rounding each
    /// on its own can be $1 off: $1.50 + $1.50 + $1.00 is $4, but $2 + $2 + $1 is $5.
    static func wholeDollars(_ cents: [Int]) -> [Int] {
        let floors = cents.map { Int((Double($0) / 100).rounded(.down)) }
        let left = cents.indices.map { cents[$0] - floors[$0] * 100 }
        let missing = rounded(cents.reduce(0, +)) - floors.reduce(0, +)
        let raised = Set(cents.indices.sorted { (left[$0], $1) > (left[$1], $0) }.prefix(missing))
        return cents.indices.map { floors[$0] + (raised.contains($0) ? 1 : 0) }
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

    /// Whole dollars on the axes and labels; cents only clutter a chart.
    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    /// The reader's text size setting.
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The name column in the category list, 112 pt in the design; it grows with the text size.
    @ScaledMetric(relativeTo: .footnote) private var nameWidth: CGFloat = 112

    /// "2026-03" written for people: "March 2026" (or "Mar" / "M" with `month`).
    private static func monthName(_ month: String, _ style: Date.FormatStyle = .dateTime.month(.wide).year()) -> String {
        (month + "-01").displayDate(style)
    }

    var body: some View {
        let months = Self.byMonth(totals)
        let windows = Self.windows(months.map(\.label))
        // The oldest window when the switch takes away a month that held only money moved.
        let window = windows.indices.contains(page) ? windows[page] : windows.last ?? []
        let shown = selectedMonth ?? window.last ?? ""
        let parts = Self.parts(totals, month: shown)
        let total = parts.reduce(0) { $0 + $1.cents }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("By Month").font(.title2.bold()).foregroundStyle(Color.ink)
                pager(window, count: windows.count)
                chart(months, window, shown: shown, parts: parts)
                    // A new window is a new chart, so it slides in while the old one slides out.
                    .id(page)
                    .transition(reduceMotion ? .opacity : .push(from: pagedBack ? .leading : .trailing))
                    .frame(height: 220)
                    .padding(.top, 8)

                // Side by side, or stacked at the largest text sizes so neither is cut off.
                let heading = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                heading {
                    Text("By category").font(.headline).foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    // Empty until the totals load, which would read "-01".
                    if !shown.isEmpty {
                        Text(Self.monthName(shown)).font(.footnote).foregroundStyle(Color.muted)
                            .accessibilityIdentifier("listMonth")
                    }
                }
                .padding(.top, 24)
                // The switch sits right above the list it changes.
                Toggle("Include money moved between my accounts", isOn: $includeMoved)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .background(Color.group, in: .rect(cornerRadius: 12))
                    .padding(.top, 8)
                row("Total", dollars: Self.rounded(total), share: 1, color: .accent, bold: true)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Total")
                    .accessibilityValue(Double(Self.rounded(total)).formatted(Self.dollars))
                ForEach(parts) { part in
                    let title = SpendingView.title(part.category)
                    Button { opened = Opened(category: part.category, folded: part.folded, month: shown) } label: {
                        // Scaled against Total, so even the biggest category's bar is shorter than Total's.
                        row(title, dollars: part.dollars, share: total > 0 ? Double(part.cents) / Double(total) : 0,
                            color: Self.color(part.category))
                            // The design draws 34 pt rows; the whole 44 pt row takes the tap.
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityValue(Double(part.dollars).formatted(Self.dollars))
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
        .sheet(item: $opened) { MonthTransactions(database: database, opened: $0) }
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

    /// Moves `step` windows back in time (or forward when negative). The new window opens on its
    /// newest month, since the tapped month belongs to the window it was tapped in.
    private func turn(by step: Int) {
        pagedBack = step > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3)) {
            page += step
            selectedMonth = nil
        }
    }

    /// The month bars of one window. The shown month is split into its list's rows, in their
    /// colors, with a bold label; the other months are the accent.
    private func chart(_ months: [Bar], _ window: [String], shown: String, parts: [Part]) -> some View {
        Chart {
            ForEach(window, id: \.self) { month in
                let total = months.first { $0.label == month }?.total ?? 0
                if month == shown {
                    ForEach(Self.segments(parts), id: \.category) { segment in
                        BarMark(x: .value("Month", month), y: .value("Spent", Double(segment.cents) / 100), width: .ratio(0.55))
                            .foregroundStyle(segment.color)
                            // VoiceOver reads the categories in the list; a stack would be read as "2026-03, total".
                            .accessibilityHidden(true)
                    }
                    // An invisible line over the stack gives VoiceOver the month as one element, as the other bars.
                    RuleMark(x: .value("Month", month), yStart: .value("Spent", 0), yEnd: .value("Spent", total))
                        .foregroundStyle(.clear)
                        .accessibilityLabel(Self.monthName(month))
                        .accessibilityValue(total.formatted(Self.dollars))
                } else {
                    BarMark(x: .value("Month", month), y: .value("Spent", total), width: .ratio(0.55))
                        .cornerRadius(5)
                        .foregroundStyle(Color.accent)
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
                            .fontWeight(month == shown ? .semibold : nil)
                            .foregroundStyle(month == shown ? Color.ink : Color.muted)
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
                            // The bars recolor and the list's bars resize with the system spring; at once with Reduce Motion.
                            withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { selectedMonth = month }
                        }
                    }
            }
        }
    }

    /// One list row: a color dot and the name, a bar at `share` of its width, and whole dollars.
    /// At the largest text sizes the name sits over the bar and amount, so nothing is cut off.
    private func row(_ name: String, dollars: Int, share: Double, color: Color, bold: Bool = false) -> some View {
        let label = HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).foregroundStyle(Color.ink)
        }
        let bar = GeometryReader { space in
            // A category refunded more than it spent has no bar, and none is wider than Total's.
            Capsule().fill(color).frame(width: space.size.width * min(1, max(0, share)))
        }
        .frame(minWidth: 60)
        .frame(height: 6)
        let amount = Text(Double(dollars), format: Self.dollars)
            .foregroundStyle(bold ? Color.ink : Color.muted)
            .frame(minWidth: 48, alignment: .trailing)
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            label.frame(width: textSize.isAccessibilitySize ? nil : nameWidth, alignment: .leading)
            HStack(spacing: 8) { bar; amount }
        }
        .font(bold ? .footnote.weight(.semibold) : .footnote)
    }
}

/// The sheet a category row opens: that row's transactions in one month, oldest first,
/// under their count and exact total, counted the same way as the row. Spending's Other
/// categories block opens it too.
struct MonthTransactions: View {
    let database: SedgeDatabase
    let opened: AllMonthsView.Opened
    @State private var rows: [ListedTransaction] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    /// The date column, 56 pt in the design; it grows with the text size.
    @ScaledMetric(relativeTo: .footnote) private var dateWidth: CGFloat = 56

    var body: some View {
        let cents = rows.reduce(0) { $0 + $1.cents }
        // Side by side, or stacked at the largest text sizes so no word is split across lines.
        let line = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                line {
                    Text("\(SpendingView.title(opened.category)) · \((opened.month + "-01").displayDate(.dateTime.month(.wide).year()))")
                        .font(.title3.bold())
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    Button("Done") { dismiss() }.font(.headline).frame(minHeight: 44)
                }
                line {
                    Text("^[\(rows.count) transaction](inflect: true)").foregroundStyle(Color.muted)
                    Spacer(minLength: 8)
                    Text(Double(cents) / 100, format: .currency(code: "USD")).fontWeight(.semibold).foregroundStyle(Color.ink)
                }
                .font(.footnote)
                .padding(.top, 6)
                .padding(.bottom, 10)
                ForEach(rows) { row in
                    let date = Text(row.date.displayDate(.dateTime.month(.abbreviated).day())).font(.footnote).foregroundStyle(Color.muted)
                    let store = Text(row.store).font(.subheadline).foregroundStyle(Color.ink)
                    let amount = Text(row.amount, format: .currency(code: "USD")).font(.subheadline).foregroundStyle(Color.ink)
                    // At the largest text sizes the date sits over the store, and the amount gets its own line.
                    let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        date.frame(width: textSize.isAccessibilitySize ? nil : dateWidth, alignment: .leading)
                        store.frame(maxWidth: .infinity, alignment: .leading)
                        amount
                    }
                    .padding(.vertical, textSize.isAccessibilitySize ? 6 : 0)
                    .frame(minHeight: 36)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // About eight rows at medium and all of them at large; at the largest text sizes it opens at large.
        .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.background)
        .task {
            do {
                rows = try AllMonthsView.sheetRows(in: database, opened)
            } catch {
                print("Could not read transactions:", error)
            }
        }
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        AllMonthsView(database: try! .open("maya"))
            .navigationTitle("All months")
    }
}
