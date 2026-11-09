//
//  CategoryView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// One category's own page, pushed from Trends: the picked month's amount and change, a strip of
/// six months to pick from, then the month's stores and transactions in the category, and a
/// question about the month to take to Ask. Every figure counts the first days of each month up
/// to today's day, as Trends does, so it matches the block that opened it.
struct CategoryView: View {
    let database: SedgeDatabase
    /// The stored category, e.g. "groceries".
    let category: String
    /// The month Trends was showing, "YYYY-MM"; the page opens on it and the strip is set around it.
    let month: String
    /// Opens Ask with a question typed in, unsent.
    var ask: (String) -> Void = { _ in }
    /// The dataset's "today"; nil until loaded.
    @State private var asOf: String?
    /// Spending per month and category over the first `day` days of each month.
    @State private var totals: [SpendingTotal] = []
    /// The month tapped on the strip; nil is `month`.
    @State private var picked: String?
    /// The shown month's transactions in the category, and the month before's, newest first.
    @State private var rows: [ListedTransaction] = []
    @State private var rowsBefore: [ListedTransaction] = []
    /// The store whose history is pushed, by name; nil when none is.
    @State private var history: String?
    @Environment(\.dynamicTypeSize) private var textSize

    private var shown: String { picked ?? month }
    private var day: Int { asOf.flatMap { Int($0.suffix(2)) } ?? 31 }
    private var isThisMonth: Bool { asOf.map { shown == $0.prefix(7) } ?? false }

    /// The strip's six months, oldest first: the last six up to today's month when `month` is one of
    /// them, else the six ending at `month`. Picking a bar never moves the strip.
    static func stripMonths(opening month: String, asOf: String) -> [String] {
        let recent = SpendingView.months(endingAt: asOf, count: 6)
        return recent.contains(month) ? recent : SpendingView.months(endingAt: month, count: 6)
    }

    /// Each strip month's spending in the category, in whole cents, as Trends' bar for it; nil for a
    /// month before the data's first month, which has no bar.
    static func strip(_ totals: [SpendingTotal], category: String, months: [String]) -> [(month: String, cents: Int?)] {
        let first = totals.map(\.month).min() ?? ""
        return months.map { month in (month, month < first ? nil : SpendingView.cents(totals, month: month)[category] ?? 0) }
    }

    /// One month's transactions in the category over the days Trends counts (the 1st through
    /// today's day of the month), newest first.
    static func rows(in database: SedgeDatabase, category: String, month: String, asOf: String) throws -> [ListedTransaction] {
        let window = SpendingView.window(month, asOf: asOf)
        return try ListedTransaction.spending(in: database, category: category, from: window.from, through: window.through)
    }

    /// Every store in the rows, most spent first (by name on a tie).
    static func stores(_ rows: [ListedTransaction]) -> [SpendingView.Store] {
        Dictionary(grouping: rows, by: \.store).map { SpendingView.Store(name: $0.key, rows: $0.value) }
            .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }

    /// The store whose spending changed most from the month before (`SpendingView.biggestChange`);
    /// nil when the month before is before the data, since every store would read as new.
    static func storeChange(_ totals: [SpendingTotal], month: String, rows: [ListedTransaction], before: [ListedTransaction]) -> (name: String, cents: Int)? {
        guard SpendingView.reaches(totals, back: SpendingView.monthBefore(month)) else { return nil }
        return SpendingView.biggestChange(now: SpendingView.cents(rows), before: SpendingView.cents(before))
    }

    /// The question chip's words: why the category was higher or lower than the month before, or
    /// what was spent on it when nothing changed or the data has no month before to compare with.
    /// "other" reads as "other things", so its questions aren't "spend on other in June".
    static func question(_ totals: [SpendingTotal], category: String, month: String) -> String {
        let isOther = category == "other"
        let name = isOther ? "other things" : SpendingView.title(category).lowercased()
        let before = SpendingView.monthBefore(month)
        let spent = { SpendingView.cents(totals, month: $0)[category] ?? 0 }
        let monthName = { ($0 + "-01").displayDate(.dateTime.month(.wide)) }
        guard SpendingView.reaches(totals, back: before), spent(month) != spent(before) else { return "What did I spend on \(name) in \(monthName(month))?" }
        return "Why was \(isOther ? "spending on other things" : name) \(spent(month) > spent(before) ? "higher" : "lower") in \(monthName(month)) than \(monthName(before))?"
    }

    var body: some View {
        let stores = Self.stores(rows)
        let cents = rows.reduce(0) { $0 + $1.cents }
        ScrollView {
            if let asOf {
                VStack(alignment: .leading, spacing: 10) {
                    header(asOf)
                    if rows.isEmpty {
                        let what = SpendingView.title(category).lowercased()
                        let name = (shown + "-01").displayDate(.dateTime.month(.wide))
                        Text(isThisMonth ? "No \(what) spending so far this month."
                                         : "No \(what) spending in the first \(day) days of \(name).")
                            .font(.row)
                            .foregroundStyle(Color.muted)
                            .padding(.top, 10)
                    } else {
                        heading("Stores")
                        ForEach(stores) { storeRow($0, share: cents > 0 ? $0.total * 100 / Double(cents) : 0) }
                        // With one store the change row would only repeat that store's row above it.
                        if stores.count > 1, let change = Self.storeChange(totals, month: shown, rows: rows, before: rowsBefore) { changeRow(change) }
                        // Only the count: the header above already gives the amount.
                        heading(MerchantHistoryView.count(rows.count, visits: false))
                        ForEach(rows) { transactionRow($0) }
                    }
                    questionChip.padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(Color.background)
        .navigationTitle(SpendingView.title(category))
        .navigationBarTitleDisplayMode(.inline)
        // Runs each time the page shows, so a transaction moved to another category counts here,
        // and again whenever another month is picked.
        .task(id: shown) {
            do {
                let asOf = try database.asOf()
                guard let asOf else { return }
                totals = try SpendingTotal.all(in: database, throughDay: Int(asOf.suffix(2)) ?? 31)
                rows = try Self.rows(in: database, category: category, month: shown, asOf: asOf)
                rowsBefore = try Self.rows(in: database, category: category, month: SpendingView.monthBefore(shown), asOf: asOf)
                self.asOf = asOf
            } catch {
                print("Could not read the category:", error)
            }
        }
        .navigationDestination(item: $history) { store in
            // shortcut: rows matched by store name, so two stores sharing a name share a history;
            // match by merchant id if the organizer ever gives two stores one name.
            MerchantHistoryView(rows: ((try? ListedTransaction.all(in: database)) ?? []).filter { $0.store == store }, database: database)
                .navigationTitle(store)
        }
    }

    /// The month's amount with its change from the month before, over the six-month strip. The
    /// amount is the shown month's strip bar, so the two always agree.
    private func header(_ asOf: String) -> some View {
        let bars = Self.strip(totals, category: category, months: Self.stripMonths(opening: month, asOf: asOf))
        let amount = Double(bars.first { $0.month == shown }?.cents ?? 0) / 100
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { amountLabel(amount); Spacer(minLength: 8); changePill }
                VStack(alignment: .leading, spacing: 4) { amountLabel(amount); changePill }
            }
            strip(bars)
        }
    }

    private func amountLabel(_ amount: Double) -> some View {
        Text(amount, format: .currency(code: "USD").precision(.fractionLength(0)))
            .font(.bigValue)
            .foregroundStyle(Color.ink)
            .accessibilityIdentifier("categoryAmount")
    }

    /// The change from the month before in a soft capsule, the same words as on Trends; nothing when there is none.
    @ViewBuilder
    private var changePill: some View {
        if let line = SpendingView.changeLine(totals, category: category, month: shown) {
            Text(line)
                .font(.row.weight(.medium))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.soft, in: .capsule)
        }
    }

    /// Six small bars with a letter under each, as on Merchant history; the shown month's in
    /// `chartNow` with a bold letter. A month before the data has a letter and no bar.
    private func strip(_ bars: [(month: String, cents: Int?)]) -> some View {
        // The tallest bar is 48 pt; `max(…, 1)` keeps six empty months from dividing by zero.
        let top = CGFloat(max(bars.compactMap(\.cents).max() ?? 0, 1))
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(bars, id: \.month) { bar in
                let isShown = bar.month == shown
                let name = (bar.month + "-01").displayDate(.dateTime.month(.wide))
                Button { picked = bar.month } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isShown ? Color.chartNow : Color.chartPast)
                            // A refund-heavy month below $0 shows no height rather than a negative one.
                            .frame(width: 28, height: 48 * CGFloat(max(bar.cents ?? 0, 0)) / top)
                        Text((bar.month + "-01").displayDate(.dateTime.month(.narrow)))
                            .font(isShown ? .note.weight(.semibold) : .note)
                            .foregroundStyle(isShown ? Color.ink : Color.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(bar.cents == nil)
                .accessibilityLabel(bar.cents.map { "\(name), \(amountText(cents: $0))" } ?? name)
                .accessibilityAddTraits(isShown ? .isSelected : [])
                .accessibilityIdentifier("stripBar")
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(Color.ink).padding(.top, 14)
    }

    /// A store's name and visit count over a bar at its share of the month, with its amount;
    /// tapping it opens the store's history.
    private func storeRow(_ store: SpendingView.Store, share: Double) -> some View {
        let purchases = MerchantHistoryView.purchases(store.rows)
        let count = MerchantHistoryView.count(purchases.isEmpty ? store.rows.count : purchases.count, visits: !purchases.isEmpty)
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return Button { history = store.name } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    layout {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.name).font(.subheadline).foregroundStyle(Color.ink)
                            Text(count).font(.note).foregroundStyle(Color.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(store.total, format: .currency(code: "USD")).font(.subheadline).monospacedDigit().foregroundStyle(Color.ink)
                    }
                    GeometryReader { space in
                        // A store refunded more than it spent has no bar.
                        Capsule().fill(SpendingView.color(category)).frame(width: space.size.width * min(1, max(0, share)))
                    }
                    .frame(height: 6)
                }
                chevron
            }
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("categoryStore")
    }

    /// "Biggest change · Corner Cafe · +$22 vs May", red when the store rose and green when it fell,
    /// as on Trends; tapping it opens the store's history.
    private func changeRow(_ change: (name: String, cents: Int)) -> some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))
        return Button { history = change.name } label: {
            HStack(spacing: 8) {
                layout {
                    Text("Biggest change").font(.row).foregroundStyle(Color.muted)
                    Text(change.name)
                        .font(.link.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(SpendingView.changeText(change.cents, before: SpendingView.monthBefore(shown)))
                        .font(.link.weight(.semibold))
                        .foregroundStyle(change.cents > 0 ? Color.moneySpent : Color.moneyBack)
                }
                chevron
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("categoryChange")
    }

    /// One transaction in the page's list: date, store and amount.
    private func transactionRow(_ row: ListedTransaction) -> some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 12))
        return NavigationLink {
            TransactionDetailView(database: database, id: row.id)
        } label: {
            HStack(spacing: 8) {
                layout {
                    Text(row.date.displayDate(.dateTime.month(.abbreviated).day())).font(.footnote).foregroundStyle(Color.muted)
                        .frame(minWidth: textSize.isAccessibilitySize ? nil : 56, alignment: .leading)
                    Text(row.store).font(.subheadline).foregroundStyle(Color.ink).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.amount, format: .currency(code: "USD")).font(.subheadline).monospacedDigit().foregroundStyle(Color.ink)
                }
                chevron
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("categoryTransaction")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.row).foregroundStyle(Color.muted).accessibilityHidden(true)
    }

    /// The question about the shown month in a chip that looks like Ask's example questions (muted
    /// text on `surface` with a `line` edge, hugging its text); tapping it opens Ask with it typed in.
    private var questionChip: some View {
        let text = Self.question(totals, category: category, month: shown)
        return Button { ask(text) } label: {
            Text(text)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.muted)
        .background(Color.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
        .accessibilityIdentifier("categoryQuestion")
    }
}

/// The month's categories, opened from Trends' "Other categories" block: Total, then every
/// category spent in the month, biggest first, each with a share bar and whole dollars that add up
/// to Total. Tapping one opens its category page.
struct MonthCategoriesSheet: View {
    let totals: [SpendingTotal]
    /// "YYYY-MM".
    let month: String
    /// The dataset's "today", "YYYY-MM-DD", for the title.
    let asOf: String
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The month's categories, most spent first (by name on a tie), with their exact cents and
    /// whole dollars that add up to the month's total in whole dollars.
    static func rows(_ totals: [SpendingTotal], month: String) -> [(category: String, cents: Int, dollars: Int)] {
        let spent = SpendingView.cents(totals, month: month)
            .sorted { ($0.value, SpendingView.title($1.key)) > ($1.value, SpendingView.title($0.key)) }
        return zip(spent, wholeDollars(spent.map(\.value))).map { ($0.key, $0.value, $1) }
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

    var body: some View {
        let rows = Self.rows(totals, month: month)
        let total = rows.reduce(0) { $0 + $1.cents }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ShareRow(name: "Total", dollars: Self.rounded(total), share: 1, color: .chartPast, bold: true)
                        .padding(.bottom, 6)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Total")
                        .accessibilityValue(Self.rounded(total).formatted(.currency(code: "USD")))
                    ForEach(rows, id: \.category) { row in
                        let title = SpendingView.title(row.category)
                        Button { open(row.category) } label: {
                            ShareRow(name: title, dollars: row.dollars, share: total > 0 ? Double(row.cents) / Double(total) : 0,
                                     color: SpendingView.color(row.category))
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(title)
                        .accessibilityValue(row.dollars.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                        .accessibilityIdentifier("monthCategory")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color.background)
            // The system's inline title and toolbar Done, as on the Worth a look sheet.
            .navigationTitle(SpendingView.monthLabel(month, asOf: asOf))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.background)
    }
}

/// One row of a category list: a color dot and the name, a bar at `share` of its width, and whole
/// dollars. At the largest text sizes the name sits over the bar and amount, so nothing is cut off.
struct ShareRow: View {
    let name: String
    let dollars: Int
    let share: Double
    let color: Color
    var bold = false
    @Environment(\.dynamicTypeSize) private var textSize
    /// The name column, 112 pt in the design; it grows with the text size.
    @ScaledMetric(relativeTo: .footnote) private var nameWidth: CGFloat = 112

    var body: some View {
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
        let amount = Text(Double(dollars), format: .currency(code: "USD").precision(.fractionLength(0)))
            .foregroundStyle(bold ? Color.ink : Color.muted)
            .frame(minWidth: 48, alignment: .trailing)
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            label.frame(width: textSize.isAccessibilitySize ? nil : nameWidth, alignment: .leading)
            HStack(spacing: 8) { bar; amount }
        }
        .font(bold ? .footnote.weight(.semibold) : .footnote)
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        CategoryView(database: try! .open("maya"), category: "groceries", month: "2026-06")
    }
}
