//
//  SpendingView.swift
//  Sedge
//

import Charts
import GRDB
import SedgeCore
import SwiftUI

/// What was spent in one month and one category, in dollars (positive is money out).
struct SpendingTotal: Decodable, FetchableRecord {
    /// "YYYY-MM".
    let month: String
    /// The category the person moved the transaction to, else the organizer's category for the store, or `movedCategory`.
    let category: String
    let total: Double

    /// The category name used for money sent to the person's own accounts.
    static let movedCategory = "moved between accounts"

    /// A transaction's category, as the tools' `spendingFilter` reads it: the person's answer
    /// first, then the store's `in_category` edge. Both queries on this screen use it, so they agree.
    static let categoryJoins = """
        LEFT JOIN edges e ON e.kind = 'in_category' AND e.source = t.merchant_id
        LEFT JOIN entities c ON c.id = e.target
        """
    static let categoryOf = "COALESCE(t.category_override, c.name, 'other')"

    /// Spending per month and category, counted the way the tools count it: posted spending
    /// less refunds. With `includeMoved`, transfers and card payments are added as their own
    /// category. Only the side leaving an account (a positive amount) is counted, because the
    /// other side is the same money arriving and would cancel it out. `throughDay` keeps only
    /// the first that many days of each month, so months can be compared at the same point.
    static func all(in database: SedgeDatabase, includeMoved: Bool, throughDay: Int = 31) throws -> [SpendingTotal] {
        try database.dbQueue.read { db in
            try SpendingTotal.fetchAll(db, sql: """
                SELECT substr(t.date, 1, 7) AS month,
                       CASE WHEN t.kind IN ('transfer', 'card_payment') THEN ? ELSE \(categoryOf) END AS category,
                       SUM(ROUND(t.amount * 100)) / 100.0 AS total
                FROM transactions t
                \(categoryJoins)
                WHERE NOT t.pending
                  AND (t.kind IN ('spending', 'refund') OR (? AND t.kind IN ('transfer', 'card_payment') AND t.amount > 0))
                  AND CAST(substr(t.date, 9, 2) AS INTEGER) <= ?
                GROUP BY month, category
                ORDER BY month, category
                """, arguments: [movedCategory, includeMoved, throughDay])
        }
    }
}

extension ListedTransaction {
    /// Spending (and refunds) in one category between two dates, newest first, counted the
    /// same way as `SpendingTotal.all` and the tools' `total_spent`. With `SpendingTotal.movedCategory`
    /// it lists money moved instead, only the side leaving an account, as `SpendingTotal.all` counts it.
    static func spending(in database: SedgeDatabase, category: String, from start: String, through end: String) throws -> [ListedTransaction] {
        try database.dbQueue.read { db in
            try ListedTransaction.fetchAll(db, sql: """
                SELECT t.transaction_id, t.date, COALESCE(m.name, t.name) AS store, t.name, t.amount, t.kind
                FROM transactions t
                LEFT JOIN entities m ON m.id = t.merchant_id
                \(SpendingTotal.categoryJoins)
                WHERE NOT t.pending
                  AND (t.kind IN ('spending', 'refund') OR (t.kind IN ('transfer', 'card_payment') AND t.amount > 0))
                  AND t.date BETWEEN ? AND ?
                  AND CASE WHEN t.kind IN ('transfer', 'card_payment') THEN ? ELSE \(SpendingTotal.categoryOf) END = ?
                ORDER BY t.date DESC, t.transaction_id DESC
                """, arguments: [start, end, SpendingTotal.movedCategory, category])
        }
    }
}

/// The Trends tab's Spending screen: one category's months (or every category's, with "All")
/// four to a page over the whole history, and a mosaic of what made up the picked month.
struct SpendingView: View {
    let database: SedgeDatabase
    /// The dataset's "today"; nil until loaded, or when nothing has been saved yet.
    @State private var asOf: String?
    /// Spending per month and category over the first `day` days of each month.
    @State private var totals: [SpendingTotal] = []
    /// The picked category; nil is "All".
    @State private var category: String?
    /// The page's spending in `category`, newest first; empty with "All".
    @State private var rows: [ListedTransaction] = []
    /// The store tapped last, by name.
    @State private var selected: String?
    /// The picked month, "YYYY-MM"; it starts on today's month.
    @State private var page: String?
    /// The page on screen, by its last month "YYYY-MM"; nil is the last page, ending at today's month.
    @State private var span: String?
    /// The month under the last tap on the chart, cleared again once `page` is set from it.
    @State private var tapped: String?
    /// The store (or, with "All", the category) whose spending changed most from the month before
    /// the page's, the change in cents, and for a store its latest transaction's id.
    @State private var change: (name: String, cents: Int, latest: String?)?
    /// The next 30 days of checking, as the Cash flow screen first shows them; nil without a bank account.
    @State private var cashFlow: CashFlow?
    /// The transaction a double-tapped store opens, by id; nil when none is open.
    @State private var opened: String?
    /// How many recent purchases are worth a look; the row for them shows only above 0.
    @State private var worthALook = 0
    /// True while the Worth a look sheet is open.
    @State private var showingWorthALook = false
    /// True while the category sheet is open.
    @State private var showingCategories = false
    /// The transactions the "Other categories" block opens; nil when that sheet is closed.
    @State private var openedOther: AllMonthsView.Opened?

    /// One store in the mosaic, or "Other stores" for the rest.
    struct Store: Identifiable {
        let name: String
        /// Its transactions this month, newest first, so the first is the latest.
        let rows: [ListedTransaction]
        var id: String { name }
        /// Summed in whole cents, as the tools sum.
        var total: Double { Double(rows.reduce(0) { $0 + Int(($1.amount * 100).rounded()) }) / 100 }
    }

    /// The name of the "All" mosaic's block that adds up the smaller categories.
    static let otherCategories = "Other categories"

    /// A mosaic block's color: with "All" its own category's, the same as on All months (Other
    /// categories in `second`); with one category picked, every store block takes that category's.
    static func blockColor(_ name: String, category: String?) -> Color { AllMonthsView.color(category ?? name) }

    /// The four months the bars cover (or `count` months), oldest first, as "YYYY-MM": `asOf`'s
    /// month and the ones before it. `asOf` may be "YYYY-MM-DD" or "YYYY-MM".
    static func months(endingAt asOf: String, count: Int = 4) -> [String] {
        guard let year = Int(asOf.prefix(4)), let month = Int(asOf.dropFirst(5).prefix(2)) else { return [] }
        return (0..<count).reversed().map { back in
            // Months counted from year 0, so stepping back past January lands in the year before.
            let index = year * 12 + month - 1 - back
            return String(format: "%04d-%02d", index / 12, index % 12 + 1)
        }
    }

    /// The bars for one category, or every category added up when it is nil: each month's
    /// total over its first days up to today's day, oldest first. Added in whole cents.
    static func bars(_ totals: [SpendingTotal], category: String?, asOf: String) -> [(month: String, total: Double)] {
        months(endingAt: asOf).map { month in
            let cents = totals.filter { $0.month == month && (category == nil || $0.category == category) }
                .reduce(0) { $0 + Int(($1.total * 100).rounded()) }
            return (month, Double(cents) / 100)
        }
    }

    /// The top of the chart's dollar axis: the largest bar rounded up to the smallest nice step
    /// (25, 50, 100, 250, 500, 1,000, 2,500, 5,000 …) that reaches it in at most 4 steps. The
    /// axis starts at $0, so a bar of $0 or less still gets one step.
    static func axisTop(_ largest: Double) -> Double {
        var step = 25.0
        var next = 0
        while (largest / step).rounded(.up) > 4 {
            // 25 → 50 → 100 → 250 → 500 → 1,000 → 2,500 …
            step *= [2, 2, 2.5][next % 3]
            next += 1
        }
        return max(1, (largest / step).rounded(.up)) * step
    }

    /// The days one month's bar covers: its first day through the same day of the month as
    /// today, so the mosaic and the latest row for that month add up to its bar. A shorter month
    /// just ends sooner, since "2026-02-30" still sorts after every February date.
    static func window(_ month: String, asOf: String) -> (from: String, through: String) {
        (month + "-01", month + "-" + asOf.suffix(2))
    }

    /// The days `window` lists, written as Trends writes a span, e.g. "May 1 – 30, 2026"; nil for
    /// today's month or a window that covers the whole month, whose sheets keep the month's name.
    static func period(_ month: String, asOf: String) -> String? {
        let day = Date.ISO8601FormatStyle().year().month().day()
        // A day past the month's end rolls into the next month ("2026-04-31" reads as May 1), so the
        // window is the whole month exactly when the day after its last day isn't in the month.
        guard month != asOf.prefix(7), let start = try? Date(month + "-01", strategy: day),
              let last = try? Date(window(month, asOf: asOf).through, strategy: day),
              (last + 86_400).formatted(day).hasPrefix(month) else { return nil }
        // The dates are midnight UTC, so they're shown in UTC too, as `AllMonthsView.span` does.
        return (start..<last).formatted(Date.IntervalFormatStyle(timeZone: .gmt).month(.abbreviated).day().year())
    }

    /// The pages of four months over the whole history, each by its last month, oldest first.
    /// The last page ends at `asOf`'s month and each one before ends four months earlier, until a
    /// page holds the first month with spending. With no spending there is still the last page.
    static func pages(_ totals: [SpendingTotal], asOf: String) -> [String] {
        let last = String(asOf.prefix(7))
        var pages = [last]
        // Only months up to today count, so data saved past `asOf` can't add pages.
        guard let first = totals.map(\.month).filter({ $0 <= last }).min() else { return pages }
        while let start = months(endingAt: pages[0]).first, start > first {
            pages.insert(monthBefore(start), at: 0)
        }
        return pages
    }

    /// The page dots for page `index` of `count` (oldest first): at most four dots, as indexes of
    /// pages, which of them is filled, and whether more pages lie past the left or right dot.
    static func dotWindow(count: Int, index: Int) -> (dots: Range<Int>, filled: Int, left: Bool, right: Bool) {
        // The window slides with the page, keeping it one dot in from the left, so the end dots
        // fill only on the oldest and newest pages.
        let start = max(0, min(index - 1, count - 4))
        let end = min(count, start + 4)
        return (start..<end, index - start, start > 0, end < count)
    }

    /// The year shown under a bar's month label, e.g. "2025", or nil. A page that isn't all in
    /// today's year shows it under its first month and under January, so the year is never a guess.
    static func axisYear(_ month: String, pageEnd: String, asOf: String) -> String? {
        guard let first = months(endingAt: pageEnd).first, first.prefix(4) != asOf.prefix(4),
              month == first || month.hasSuffix("-01") else { return nil }
        return String(month.prefix(4))
    }

    /// The month before `month`, "YYYY-MM".
    static func monthBefore(_ month: String) -> String { months(endingAt: month + "-01")[2] }

    /// The change beside "Your patterns": the month's bar against the month before's, e.g.
    /// "+24% vs Apr". Nil when nothing was spent the month before, as there is no percentage to give.
    static func changeLine(_ totals: [SpendingTotal], category: String?, month: String) -> String? {
        // The four bars ending at `month`; the last two are the month before and the month itself.
        let pair = Array(bars(totals, category: category, asOf: month + "-01").suffix(2))
        guard pair.count == 2, pair[0].total > 0 else { return nil }
        // Rounded to a whole percent first, so a tiny drop reads "+0%" and never "-0%".
        let percent = Int(((pair[1].total - pair[0].total) / pair[0].total * 100).rounded())
        return String(format: "%+d%%", percent) + " vs " + (pair[0].month + "-01").displayDate(.dateTime.month(.abbreviated))
    }

    /// The biggest three stores and "Other stores" for the rest, or every store when there are
    /// four or fewer, so the mosaic never has more than four blocks.
    static func stores(_ rows: [ListedTransaction]) -> [Store] {
        // Grouping keeps each store's rows in their newest-first order.
        let all = Dictionary(grouping: rows, by: \.store).map { Store(name: $0.key, rows: $0.value) }
            .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
        guard all.count > 4 else { return all }
        let rest = Set(all.dropFirst(3).map(\.name))
        return Array(all.prefix(3)) + [Store(name: "Other stores", rows: rows.filter { rest.contains($0.store) })]
    }

    /// The "All" mosaic for one month: the biggest three categories and `otherCategories` for the
    /// rest added up in cents, or every category when there are four or fewer.
    static func categoryBlocks(_ totals: [SpendingTotal], month: String) -> [(name: String, total: Double)] {
        let all = rankedCategories(totals, month: month)
        guard all.count > 4 else { return all }
        let rest = all.dropFirst(3).reduce(0) { $0 + Int(($1.total * 100).rounded()) }
        return Array(all.prefix(3)) + [(name: otherCategories, total: Double(rest) / 100)]
    }

    /// The categories `otherCategories` adds up in one month; none when there are four or fewer.
    static func otherCategoryNames(_ totals: [SpendingTotal], month: String) -> [String] {
        let all = rankedCategories(totals, month: month)
        return all.count > 4 ? all.dropFirst(3).map(\.name) : []
    }

    /// One month's categories, most spent first (by name on a tie).
    private static func rankedCategories(_ totals: [SpendingTotal], month: String) -> [(name: String, total: Double)] {
        totals.filter { $0.month == month }.map { (name: $0.category, total: $0.total) }
            .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }

    /// Each store's spending in whole cents.
    static func cents(_ rows: [ListedTransaction]) -> [String: Int] {
        Dictionary(rows.map { ($0.store, Int(($0.amount * 100).rounded())) }, uniquingKeysWith: +)
    }

    /// Each category's spending in one month, in whole cents.
    static func cents(_ totals: [SpendingTotal], month: String) -> [String: Int] {
        Dictionary(totals.filter { $0.month == month }.map { ($0.category, Int(($0.total * 100).rounded())) }, uniquingKeysWith: +)
    }

    /// The name whose spending changed most between two months, up or down, and by how many
    /// cents (positive when it rose). A name missing from one month spent $0 then. The first
    /// name alphabetically wins a tie; nil when nothing changed.
    static func biggestChange(now: [String: Int], before: [String: Int]) -> (name: String, cents: Int)? {
        let changes = Set(now.keys).union(before.keys).map { (name: $0, cents: (now[$0] ?? 0) - (before[$0] ?? 0)) }
        guard let top = changes.max(by: { (abs($0.cents), $1.name) < (abs($1.cents), $0.name) }), top.cents != 0 else { return nil }
        return top
    }

    /// With "All", the category whose spending changed most from the month before `month`, among
    /// the ones the category sheet lists, so tapping it always picks a listed category. On the
    /// oldest page the month before is not one of the four shown, so a category spent only then is left out.
    static func categoryChange(_ totals: [SpendingTotal], asOf: String, month: String) -> (name: String, cents: Int)? {
        let listed = Set(categoryOrder(totals, asOf: asOf, month: month))
        return biggestChange(now: cents(totals, month: month), before: cents(totals, month: monthBefore(month)).filter { listed.contains($0.key) })
    }

    /// How a VoiceOver page turn moves: the default slide, or none with Reduce Motion.
    static func pageTurn(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .default }

    /// The biggest change for people, always signed, e.g. "+$22 vs May" or "-$4 vs May". Under
    /// a dollar it keeps the cents, so a small change never reads "+$0".
    static func changeText(_ cents: Int, before month: String) -> String {
        let style = abs(cents) < 100 ? FloatingPointFormatStyle<Double>.Currency(code: "USD") : dollars
        return (Double(cents) / 100).formatted(style.sign(strategy: .always()))
            + " vs " + (month + "-01").displayDate(.dateTime.month(.abbreviated))
    }

    /// "Low point $1,236.45 · Jul 1": the shown line's lowest balance, as the Cash flow screen gives it.
    static func lowPointLine(_ cashFlow: CashFlow) -> String? {
        cashFlow.lowest(cashFlow.shown).map {
            "Low point \($0.balance.formatted(.currency(code: "USD"))) · \($0.date.displayDate(.dateTime.month(.abbreviated).day()))"
        }
    }

    /// Splits `length` into one piece per amount, by its share, with `gap` between pieces. A piece
    /// under `minimum` is raised to it and the others share what is left, so no label is squeezed
    /// out; when even that doesn't fit, the pieces are equal.
    static func split(_ amounts: [Double], length: CGFloat, gap: CGFloat, minimum: CGFloat) -> [CGFloat] {
        // Never below 0, since the first layout pass can measure no width at all.
        let space = max(0, length - gap * CGFloat(amounts.count - 1))
        // A category refunded more than it spent has no area to show.
        let shares = amounts.map { CGFloat(max($0, 0)) }
        let sum = shares.reduce(0, +)
        guard sum > 0, space >= minimum * CGFloat(shares.count) else { return shares.map { _ in space / CGFloat(shares.count) } }
        let small = Set(shares.indices.filter { space * shares[$0] / sum < minimum })
        // shortcut: one pass, so a piece shrunk to make room could dip a little under `minimum`;
        // repeat until none does if a dataset ever shows a clipped block.
        let left = space - minimum * CGFloat(small.count)
        let bigSum = shares.indices.filter { !small.contains($0) }.reduce(0) { $0 + shares[$1] }
        return shares.indices.map { small.contains($0) ? minimum : left * shares[$0] / bigSum }
    }

    /// The day of the month of "today": every month is compared over its first this many days.
    private var day: Int { asOf.flatMap { Int($0.suffix(2)) } ?? 31 }

    /// Today's month, "YYYY-MM": the last page and the last bar.
    private var thisMonth: String { String((asOf ?? "").prefix(7)) }

    /// The month the screen shows, "YYYY-MM": the page's, else today's.
    private var shownMonth: String { page ?? thisMonth }

    /// The categories with spending in the four months shown, in the category sheet's order.
    private var categories: [String] {
        asOf == nil ? [] : Self.categoryOrder(totals, asOf: span ?? thisMonth, month: shownMonth)
    }

    /// The categories with spending in the four months ending at `asOf`, most spent in `month`
    /// first (a category with none that month counts $0), and by name on a tie.
    static func categoryOrder(_ totals: [SpendingTotal], asOf: String, month: String) -> [String] {
        let months = months(endingAt: asOf)
        let spent = cents(totals, month: month)
        return Set(totals.filter { months.contains($0.month) }.map(\.category))
            .sorted { (spent[$1] ?? 0, title($0)) < (spent[$0] ?? 0, title($1)) }
    }

    /// A stored category written for people: "phone_internet" becomes "Phone internet".
    static func title(_ category: String) -> String {
        let words = category.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Whole dollars on the axes and labels; cents only clutter a chart.
    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    /// The page dots, 6 pt in the design, grow with the text.
    @ScaledMetric(relativeTo: .caption2) private var dotSize: CGFloat = 6
    /// The Worth a look count badge, 20 pt in the design, grows with its number.
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 20
    /// The mosaic's height, 132 pt in the design; it grows with the text so labels still fit.
    @ScaledMetric(relativeTo: .caption) private var mosaicHeight: CGFloat = 132
    /// The shortest and narrowest a mosaic block gets (56 and 80 pt in the design), so its two lines fit.
    @ScaledMetric(relativeTo: .caption) private var blockHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .caption) private var blockWidth: CGFloat = 80
    /// A block narrower than this shows only its name's first word.
    @ScaledMetric(relativeTo: .caption) private var shortName: CGFloat = 84
    /// The reader's Reduce Motion setting: when on, a new category or page changes the chart without animating.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            if let asOf, !totals.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    patternsHeader
                    categoryButton
                    pager(asOf)
                    cashFlowCard
                    connected
                    allMonthsLink
                    if let store = Self.stores(rows).first(where: { $0.name == selected }), let row = store.rows.first {
                        latest(row)
                    }
                    if worthALook > 0 { worthALookRow }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(Color.background)
        .overlay {
            // Any spending in the history keeps the screen, since a page with none can still be swiped past.
            if totals.isEmpty { ContentUnavailableView("No spending yet", systemImage: "chart.bar", description: Text("This data has no purchases to chart.")) }
        }
        // Runs each time the screen shows, so a transaction moved to another category counts
        // here, and again whenever another category or month page is picked.
        .task(id: [category ?? "", page ?? ""]) {
            do {
                let first = asOf == nil
                asOf = try database.asOf()
                totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: day)
                if first {
                    // The design opens on dining; any other data opens on its first category.
                    category = categories.contains("dining") ? "dining" : categories.first
                    page = thisMonth
                }
                guard let asOf else { return }
                let before = Self.monthBefore(shownMonth)
                if let category {
                    let window = Self.window(shownMonth, asOf: asOf), earlier = Self.window(before, asOf: asOf)
                    rows = try ListedTransaction.spending(in: database, category: category, from: window.from, through: window.through)
                    let beforeRows = try ListedTransaction.spending(in: database, category: category, from: earlier.from, through: earlier.through)
                    change = Self.biggestChange(now: Self.cents(rows), before: Self.cents(beforeRows)).map { top in
                        // A store that spent nothing this month opens its latest from the month before.
                        (top.name, top.cents, (rows + beforeRows).first { $0.store == top.name }?.id)
                    }
                } else {
                    rows = []
                    change = Self.categoryChange(totals, asOf: asOf, month: shownMonth).map { ($0.name, $0.cents, nil) }
                }
            } catch {
                print("Could not read spending:", error)
            }
        }
        // Each time the screen shows, so the card matches the Cash flow screen it opens.
        .task {
            do {
                cashFlow = try CashFlow.load(database)
            } catch {
                print("Could not project:", error)
            }
            countWorthALook()
        }
        // Closing the sheet counts again, since answers given in it take purchases off.
        .sheet(isPresented: $showingWorthALook, onDismiss: countWorthALook) { WorthALookView(database: database) }
        .sheet(item: $openedOther) { MonthTransactions(database: database, opened: $0) }
        // A tapped store belongs to one category, so picking another clears it.
        .onChange(of: category) { selected = nil }
        // A double-tapped store's latest transaction, the same screen its row below opens.
        .navigationDestination(item: $opened) { TransactionDetailView(database: database, id: $0) }
    }

    /// "Your patterns" and the page's change from the month before, side by side, or stacked
    /// once both no longer fit on one line.
    private var patternsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack { patternsTitle; Spacer(minLength: 8); changePill }
            VStack(alignment: .leading, spacing: 4) { patternsTitle; changePill }
        }
    }

    /// The pager: one page per four months, today's last, so swiping right goes back in time.
    /// A swipe picks the new page's newest month and a tap on a bar picks that month. The dots
    /// below say where the page sits in the timeline.
    private func pager(_ asOf: String) -> some View {
        let pages = Self.pages(totals, asOf: asOf)
        return VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(pages, id: \.self) { end in
                        monthPage(end, asOf: asOf)
                            .containerRelativeFrame(.horizontal)
                            // Keeps the zero line's end from peeking into the next page.
                            .clipped()
                            // VoiceOver reads only the page on screen, so each month is named once.
                            .accessibilityHidden(end != (span ?? thisMonth))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $span)
            // Opens on today's month, the last page, with nothing after it.
            .defaultScrollAnchor(.trailing)
            .accessibilityIdentifier("months")
            // The big total always matches a bar on screen, so a new page picks its newest month.
            .onChange(of: span) { if let span { page = span } }
            dots(pages)
        }
        // A new category re-heights the bars and rolls the total in place; with Reduce Motion
        // they change at once.
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: category)
    }

    /// One page, by its last month: the marked month's total and the page's four bars on their own
    /// dollar axis. The marked month is the picked one when it's on this page, else the page's
    /// newest, which a swipe picks. Its bar is in `chartNow` and the others in the lighter
    /// `chartPast`; a month before today's also gets a ring and its amount above it. Either way
    /// its axis label is bold.
    private func monthPage(_ end: String, asOf: String) -> some View {
        let bars = Self.bars(totals, category: category, asOf: end)
        let top = Self.axisTop(bars.map(\.total).max() ?? 0)
        let month = bars.contains { $0.month == shownMonth } ? shownMonth : end
        let total = bars.first { $0.month == month }?.total ?? 0
        let isEarlier = month != thisMonth
        return VStack(alignment: .leading, spacing: 8) {
            Text(total, format: Self.dollars)
                .font(.bigValue)
                .foregroundStyle(Color.ink)
                // The total rolls digit by digit to the new category's amount.
                .contentTransition(.numericText(value: total))
                .accessibilityIdentifier("total")
            Chart {
                ForEach(bars, id: \.month) { bar in
                    BarMark(x: .value("Month", bar.month), y: .value("Spent", bar.total), width: .ratio(0.55))
                        .cornerRadius(5)
                        .foregroundStyle(bar.month == month ? Color.chartNow : Color.chartPast)
                        .accessibilityLabel((bar.month + "-01").displayDate(.dateTime.month(.wide)))
                        .accessibilityValue(bar.total.formatted(Self.dollars))
                        // Lets a test find the page's bar, which is otherwise marked by color, ring and bold label.
                        .accessibilityIdentifier(bar.month == month ? "shownMonth" : "")
                        // An earlier page's amount above its bar, so it doesn't rest on color either.
                        .annotation(position: .top) {
                            if bar.month == month && isEarlier {
                                Text(bar.total, format: Self.dollars).font(.row.weight(.semibold)).foregroundStyle(Color.ink)
                            }
                        }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.graphLine)
            }
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks { value in
                    // "2026-06" is shown as "Jun" ("J" at the largest text sizes, as on All months);
                    // the marked month in bold ink. A page outside today's year adds the year under it.
                    if let label = value.as(String.self) {
                        AxisValueLabel {
                            VStack(spacing: 0) {
                                Text((label + "-01").displayDate(.dateTime.month(dynamicTypeSize.isAccessibilitySize ? .narrow : .abbreviated)))
                                    .fontWeight(label == month ? .semibold : .regular)
                                    .foregroundStyle(label == month ? Color.ink : Color.muted)
                                if let year = Self.axisYear(label, pageEnd: end, asOf: asOf) {
                                    Text(year).foregroundStyle(Color.muted)
                                }
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                // Only $0 and the top, as in the design.
                AxisMarks(position: .leading, values: [0, top]) { _ in
                    AxisValueLabel(format: Self.dollars).foregroundStyle(Color.muted)
                }
            }
            .chartOverlay { proxy in
                // The earlier page's 1.5 pt ink ring. Charts can't outline a bar, so it is drawn over it.
                GeometryReader { geometry in
                    if isEarlier, let plot = proxy.plotFrame.map({ geometry[$0] }),
                       let x = proxy.position(forX: month), let barTop = proxy.position(forY: total),
                       let zero = proxy.position(forY: 0.0) {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.ink, lineWidth: 1.5)
                            // Each month gets an equal column; its bar is 55% of it, as in the BarMark.
                            .frame(width: plot.width / CGFloat(bars.count) * 0.55, height: abs(zero - barTop))
                            .position(x: plot.minX + x, y: plot.minY + (barTop + zero) / 2)
                    }
                }
                .allowsHitTesting(false)
            }
            // A tap anywhere in a month's column picks that month, without stopping the screen from scrolling.
            .chartXSelection(value: $tapped)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
            }
            .onChange(of: tapped) {
                guard let tapped else { return }
                // The tapped month is on the page on screen, so the page stays and only the pick moves.
                page = tapped
                self.tapped = nil
            }
            .frame(height: 175)
        }
    }

    /// One dot per page, at most four, the newest page on the right and the page on screen in ink.
    /// With more pages, a muted chevron sits on each side that has more beyond its dots. VoiceOver
    /// reads the page's span, e.g. "Mar – Jun 2026", and swipes up or down to turn the page, since
    /// the pages themselves are swiped sideways.
    private func dots(_ pages: [String]) -> some View {
        let index = pages.firstIndex(of: span ?? thisMonth) ?? pages.count - 1
        let window = Self.dotWindow(count: pages.count, index: index)
        return HStack(spacing: 6) {
            // Both chevrons always take their room, so the dots stay centered as they come and go.
            Image(systemName: "chevron.left").opacity(window.left ? 1 : 0)
            ForEach(window.dots, id: \.self) { dot in
                let isShown = dot == index
                Circle()
                    .fill(isShown ? Color.ink : Color.line)
                    .frame(width: isShown ? dotSize + 1 : dotSize, height: isShown ? dotSize + 1 : dotSize)
            }
            Image(systemName: "chevron.right").opacity(window.right ? 1 : 0)
        }
        .font(.note.weight(.semibold))
        .foregroundStyle(Color.muted)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Months")
        .accessibilityValue(AllMonthsView.span(Self.months(endingAt: pages[index])))
        // Lets a test see which dot is filled, which is otherwise shown only by color and size.
        .accessibilityIdentifier("filledDot\(window.filled)")
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? index + 1 : index - 1
            if pages.indices.contains(next) { withAnimation(Self.pageTurn(reduceMotion: reduceMotion)) { span = pages[next] } }
        }
    }

    /// One block: "Cash flow" with this person's projected checking balance for the next 30 days
    /// and its low point, opening the Cash flow screen, then the biggest change from the month
    /// before. The line and low point come from `CashFlow`, the same as that screen's first view.
    private var cashFlowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                CashFlowView(database: database).navigationTitle("Cash flow")
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cash flow").font(.cardTitle).foregroundStyle(Color.ink)
                            if let cashFlow, let line = Self.lowPointLine(cashFlow) {
                                Text(line).font(.row).foregroundStyle(Color.muted)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.row)
                            .foregroundStyle(Color.muted)
                            .accessibilityHidden(true)
                    }
                    if let cashFlow { balanceLine(cashFlow) }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cashFlow")
            if let change {
                Rectangle().fill(Color.line).frame(height: 1)
                changeRow(change)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, change == nil ? 14 : 4)
        .background(Color.group, in: .rect(cornerRadius: 14))
    }

    /// The projected balance, day by day, with the low point marked and labeled under it. The
    /// title above already says the low point, so VoiceOver skips the drawing.
    private func balanceLine(_ cashFlow: CashFlow) -> some View {
        let low = cashFlow.lowest(cashFlow.shown)
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return VStack(spacing: 2) {
            Chart {
                ForEach(cashFlow.shown, id: \.date) { day in
                    LineMark(x: .value("Day", day.date), y: .value("Balance", cashFlow.balance(day)))
                        .foregroundStyle(Color.chartLine)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                if let low {
                    PointMark(x: .value("Day", low.date), y: .value("Balance", low.balance))
                        .symbol {
                            Circle().fill(Color.chartLine).stroke(Color.group, lineWidth: 1.5).frame(width: 9, height: 9)
                        }
                }
            }
            // Only the shape matters, so no axes; the room at the bottom is for the low point's label.
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false), range: .plotDimension(startPadding: 20, endPadding: 4))
            .chartOverlay { proxy in
                // The low point's amount and day just under it. Drawn over the chart, since a
                // Charts annotation there gets moved above the point when it nears the edge. At the
                // largest text sizes it would cover the dates, and the title above already says it.
                GeometryReader { geometry in
                    if !dynamicTypeSize.isAccessibilitySize, let low, let plot = proxy.plotFrame.map({ geometry[$0] }),
                       let x = proxy.position(forX: low.date), let y = proxy.position(forY: low.balance) {
                        // Starts under the point on the left half and ends under it on the right half, so it stays on the card.
                        let onLeft = x < plot.width / 2
                        Text("\(low.balance.formatted(Self.dollars)) · \(low.date.displayDate(format))")
                            .font(.note.weight(.medium))
                            .foregroundStyle(Color.muted)
                            .fixedSize()
                            .frame(width: plot.width, alignment: onLeft ? .leading : .trailing)
                            .offset(x: onLeft ? max(0, x - 6) : -max(0, plot.width - x - 6))
                            .position(x: plot.midX, y: plot.minY + y + 13)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: 84)
            // The days the line covers: it starts tomorrow, the first projected day.
            HStack {
                Text(cashFlow.shown.first?.date.displayDate(format) ?? "")
                Spacer()
                Text(cashFlow.shown.last?.date.displayDate(format) ?? "")
            }
            .font(.note)
            .foregroundStyle(Color.muted)
        }
        .accessibilityHidden(true)
    }

    /// "Biggest change · Corner Cafe · +$22 vs May": red when spending rose, green when it fell.
    /// Tapping it opens the store's latest transaction, or with "All" picks that category.
    private func changeRow(_ change: (name: String, cents: Int, latest: String?)) -> some View {
        let name = category == nil ? Self.title(change.name) : change.name
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        return Button {
            if category == nil { category = change.name } else { opened = change.latest }
        } label: {
            HStack(spacing: 8) {
                layout {
                    Text("Biggest change").font(.row).foregroundStyle(Color.muted)
                    Text(name)
                        .font(.link.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.changeText(change.cents, before: Self.monthBefore(shownMonth)))
                        .font(.link.weight(.semibold))
                        .foregroundStyle(change.cents > 0 ? Color.moneySpent : Color.moneyBack)
                }
                Image(systemName: "chevron.right")
                    .font(.row)
                    .foregroundStyle(Color.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("biggestChange")
    }

    /// "All months & categories": the longer view drills down from the short one it widens.
    private var allMonthsLink: some View {
        NavigationLink {
            AllMonthsView(database: database).navigationTitle("All months")
        } label: {
            // The whole 44 pt row takes the tap, not only the words.
            Text("All months & categories →").frame(minHeight: 44).contentShape(.rect)
        }
        .font(.link)
    }

    /// "1 purchase worth a look →" with the count in a small badge, opening the Worth a look sheet.
    private var worthALookRow: some View {
        Button { showingWorthALook = true } label: {
            HStack(spacing: 8) {
                Text("\(worthALook)")
                    .font(.note.weight(.semibold))
                    .foregroundStyle(Color.contrast)
                    .frame(minWidth: badgeSize, minHeight: badgeSize)
                    .background(Color.accent, in: .capsule)
                    .accessibilityHidden(true)
                Text(worthALook == 1 ? "1 purchase worth a look" : "\(worthALook) purchases worth a look")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("→").accessibilityHidden(true)
            }
            .font(.row.weight(.medium))
            .foregroundStyle(Color.muted)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("worthALook")
    }

    /// Counts the purchases worth a look again, with the same rule the sheet lists them by.
    private func countWorthALook() {
        do {
            worthALook = try WorthALook.flagged(in: database).count
        } catch {
            print("Could not read purchases worth a look:", error)
        }
    }

    private var patternsTitle: some View {
        Text("Your patterns").font(.title2.bold()).foregroundStyle(Color.ink)
    }

    /// The page's change from the month before, in a soft capsule; nothing when there is none to give.
    @ViewBuilder
    private var changePill: some View {
        if let line = Self.changeLine(totals, category: category, month: shownMonth) {
            Text(line)
                .font(.row.weight(.medium))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.soft, in: .capsule)
        }
    }

    /// The picked category's name and a grid icon in a soft capsule, opening the category sheet.
    private var categoryButton: some View {
        Button { showingCategories = true } label: {
            HStack(spacing: 6) {
                Text(category.map(Self.title) ?? "All").font(.link).foregroundStyle(Color.ink)
                Image(systemName: "square.grid.2x2").font(.row).foregroundStyle(Color.ink)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Color.soft, in: .capsule)
            // Apple's minimum tap target: the 32 pt capsule sits in a 44 pt row.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category")
        .accessibilityValue(category.map(Self.title) ?? "All")
        .accessibilityHint("Shows every category to pick from")
        .sheet(isPresented: $showingCategories) { categorySheet }
    }

    /// "Category": "All", then every category, most spent in the page's month first, each with
    /// that month's amount. Picking one closes the sheet as the chart changes behind it.
    private var categorySheet: some View {
        let spent = Self.cents(totals, month: shownMonth)
        let month = (shownMonth + "-01").displayDate(.dateTime.month(.wide))
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Category").font(.headline).foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    Text(shownMonth == thisMonth ? "\(month) so far" : month).font(.row).foregroundStyle(Color.muted)
                }
                // Two columns, or one once large text widens the cells.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    categoryCell(nil, cents: spent.values.reduce(0, +))
                    ForEach(categories, id: \.self) { categoryCell($0, cents: spent[$0] ?? 0) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.group)
    }

    /// One cell of the category sheet; `name` nil is "All". The picked one has an accent ring and a checkmark.
    private func categoryCell(_ name: String?, cents: Int) -> some View {
        let picked = name == category
        let title = name.map(Self.title) ?? "All"
        let amount = (Double(cents) / 100).formatted(Self.dollars)
        return Button {
            category = name
            showingCategories = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                    Text(amount).font(.caption).foregroundStyle(Color.muted)
                }
                Spacer(minLength: 8)
                if picked { Image(systemName: "checkmark").font(.row.weight(.semibold)).foregroundStyle(Color.ink) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(Color.soft, in: .rect(cornerRadius: 12))
            .overlay { if picked { RoundedRectangle(cornerRadius: 12).stroke(Color.accent, lineWidth: 1.5) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(amount)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("categoryCell")
    }

    /// "Connected spending": the page's month as a mosaic, a block per store (or per category with
    /// "All") sized by its amount. The blocks add up to the page's total.
    @ViewBuilder
    private var connected: some View {
        let name = (shownMonth + "-01").displayDate(.dateTime.month(.wide))
        let blocks: [(name: String, total: Double)] = category == nil
            ? Self.categoryBlocks(totals, month: shownMonth)
            : Self.stores(rows).map { ($0.name, $0.total) }
        // Side by side, or stacked at the largest text sizes so the heading keeps the full width.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text("Connected spending · \(name)").font(.headline).foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            Text(category == nil ? "by category" : "by store").font(.row).foregroundStyle(Color.muted)
        }
        .padding(.top, 10)
        if blocks.isEmpty {
            let what = category.map { Self.title($0).lowercased() + " " } ?? ""
            Text(shownMonth == thisMonth ? "No \(what)spending so far this month."
                                         : "No \(what)spending in the first \(day) days of \(name).")
                .font(.row)
                .foregroundStyle(Color.muted)
        } else {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // At the largest text sizes the blocks stack full width, so every name fits whole.
                    VStack(spacing: 4) {
                        ForEach(blocks, id: \.name) { block($0, width: nil, height: nil) }
                    }
                } else {
                    mosaic(blocks)
                }
            }
            // The new category's or month's blocks fade in once they load, a little after the tap.
            .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.25), value: blocks.map(\.name))
        }
    }

    /// The biggest block on the left; on the right the second over the rest side by side. Widths
    /// and heights follow each block's share of the month.
    private func mosaic(_ blocks: [(name: String, total: Double)]) -> some View {
        GeometryReader { geometry in
            let amounts = blocks.map(\.total)
            let width = geometry.size.width
            let rest = Array(blocks.dropFirst(2))
            let share = Self.split([amounts[0], amounts.dropFirst().reduce(0, +)], length: width, gap: 4, minimum: blockWidth)
            // The right column is wide enough for its bottom blocks side by side, as long as the left keeps its minimum.
            let needed = CGFloat(rest.count) * (blockWidth + 4) - 4
            let right = max(0, min(max(share[1], needed), width - 4 - blockWidth))
            let columns = blocks.count > 1 ? [width - 4 - right, right] : [width]
            HStack(spacing: 4) {
                block(blocks[0], width: columns[0], height: geometry.size.height)
                if blocks.count > 1 {
                    let heights = rest.isEmpty ? [geometry.size.height]
                        : Self.split([amounts[1], amounts.dropFirst(2).reduce(0, +)], length: geometry.size.height, gap: 4, minimum: blockHeight)
                    VStack(spacing: 4) {
                        block(blocks[1], width: columns[1], height: heights[0])
                        if !rest.isEmpty {
                            let widths = Self.split(rest.map(\.total), length: columns[1], gap: 4, minimum: blockWidth)
                            HStack(spacing: 4) {
                                ForEach(Array(rest.enumerated()), id: \.element.name) { index, item in
                                    block(item, width: widths[index], height: heights[1])
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: mosaicHeight)
    }

    /// One mosaic block, tinted with `blockColor` so the text stays ink on every block. With a
    /// store, one tap selects it and shows its latest transaction below, two open that transaction;
    /// with "All", a tap picks that category, and "Other categories" opens the transactions it adds up.
    @ViewBuilder
    private func block(_ item: (name: String, total: Double), width: CGFloat?, height: CGFloat?) -> some View {
        let isAll = category == nil
        let name = isAll ? Self.title(item.name) : item.name
        let face = VStack(alignment: .leading, spacing: 2) {
            // A narrow block shows the name's first word, so it never clips mid-word.
            Text(width.map { $0 < shortName } == true ? String(name.split(separator: " ").first ?? "") : name).font(.row.weight(.medium))
            Text(item.total, format: Self.dollars).font(.row)
        }
        .lineLimit(width == nil ? nil : 1)
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // A given size is exact; without one the block is full width and as tall as its text.
        .frame(minWidth: width, maxWidth: width ?? .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        // A light tint of the category color: the hue matches All months without a wall of strong color.
        .background(Self.blockColor(item.name, category: category).opacity(0.22), in: .rect(cornerRadius: 10))
        .overlay {
            if !isAll && selected == item.name { RoundedRectangle(cornerRadius: 10).stroke(Color.ink, lineWidth: 1.5) }
        }
        let label = "\(name), \(item.total.formatted(Self.dollars))"
        if isAll {
            // Several categories together have no single category to pick, so Other lists their transactions.
            let isOther = item.name == Self.otherCategories
            Button {
                if !isOther {
                    category = item.name
                } else if let asOf {
                    openedOther = .init(category: item.name, folded: Self.otherCategoryNames(totals, month: shownMonth),
                                        month: shownMonth, through: Self.window(shownMonth, asOf: asOf).through,
                                        period: Self.period(shownMonth, asOf: asOf))
                }
            } label: { face }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint(isOther ? "Shows its transactions" : "Shows this category")
                .accessibilityIdentifier("categoryBlock")
        } else {
            let latest = Self.stores(rows).first { $0.name == item.name }?.rows.first?.id
            Button { selected = item.name } label: { face }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .simultaneousGesture(TapGesture(count: 2).onEnded { opened = latest })
                .accessibilityHint("Shows the latest transaction")
                // VoiceOver's double tap is the button's own tap, so opening is offered as a named action.
                .accessibilityAction(named: "Open latest transaction") { opened = latest }
                .accessibilityIdentifier("store")
                .accessibilityAddTraits(selected == item.name ? .isSelected : [])
        }
    }

    /// The tapped store's latest transaction; tapping it opens the transaction.
    private func latest(_ row: ListedTransaction) -> some View {
        NavigationLink {
            TransactionDetailView(database: database, id: row.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.store).font(.subheadline).foregroundStyle(Color.ink)
                    Text(row.date.displayDate(.dateTime.month(.abbreviated).day()) + " · Latest transaction")
                        .font(.row)
                        .foregroundStyle(Color.muted)
                }
                Spacer()
                Text(row.amount, format: .currency(code: "USD"))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
            // A plain button only takes taps on what it draws; this makes the gap in the middle tappable too.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("latest")
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        SpendingView(database: try! .open("maya"))
            .navigationTitle("Spending")
    }
}
