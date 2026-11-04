//
//  TransactionsView.swift
//  Sedge
//

import GRDB
import SedgeCore
import SwiftUI

/// One row of the transactions list: the organizer's clean store name next to the raw
/// statement name it came from.
struct ListedTransaction: Decodable, Identifiable, FetchableRecord {
    let transaction_id: String
    let date: String
    /// The organizer's store name, or the raw name if the organizer hasn't run.
    let store: String
    /// The raw statement name, as the bank sent it.
    let name: String
    /// Plaid's sign: positive is money out.
    let amount: Double
    /// spending, income, transfer, card_payment or refund (set by the organizer).
    let kind: String?

    var id: String { transaction_id }
    /// The amount in whole cents, Plaid's sign, so sums never pick up float noise.
    var cents: Int { Int((amount * 100).rounded()) }
    /// "YYYY-MM", the month the stepper files it under.
    var month: String { String(date.prefix(7)) }

    /// Every transaction, or with `merchant` only that store's, newest first, the same order the tools use.
    static func all(in database: SedgeDatabase, merchant: String? = nil) throws -> [ListedTransaction] {
        try database.dbQueue.read { db in
            try ListedTransaction.fetchAll(db, sql: """
                SELECT t.transaction_id, t.date, COALESCE(m.name, t.name) AS store, t.name, t.amount, t.kind
                FROM transactions t LEFT JOIN entities m ON m.id = t.merchant_id
                WHERE ? IS NULL OR t.merchant_id = ?
                ORDER BY t.date DESC, t.transaction_id DESC
                """, arguments: [merchant, merchant])
        }
    }
}

/// The three parts of a month's list, in the order they are shown.
enum MoneyPart: String, CaseIterable {
    case income = "Income", spending = "Spending", transfers = "Transfers"

    /// Transfers and card payments only move money between the person's own accounts, so they
    /// go last and keep Income and Spending clean. Refunds stay with the spending they undo.
    init(kind: String?) {
        switch kind {
        case "income": self = .income
        case "transfer", "card_payment": self = .transfers
        default: self = .spending
        }
    }
}

/// The rows of one Monday-to-Sunday week, newest first.
struct WeekGroup: Identifiable {
    /// The week's Monday, "YYYY-MM-DD".
    let monday: String
    let rows: [ListedTransaction]
    var id: String { monday }
    /// The week's total in whole cents, Plaid's sign.
    var cents: Int { rows.reduce(0) { $0 + $1.cents } }
}

/// One part of one month: its rows, their total, and the rows by week.
struct MonthPart: Identifiable {
    let part: MoneyPart
    let rows: [ListedTransaction]
    var id: MoneyPart { part }
    /// The part's total in whole cents, Plaid's sign, summed from its own rows.
    var cents: Int { rows.reduce(0) { $0 + $1.cents } }
    var weeks: [WeekGroup] { TransactionGroups.weeks(rows) }
}

/// The plain grouping the transactions list and Merchant history use, kept out of the views so
/// it can be tested.
enum TransactionGroups {
    /// Dates are calendar days with no time zone, so the week math runs in UTC, like `displayDate`.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
    private static let day = Date.ISO8601FormatStyle().year().month().day()

    /// The Monday on or before a "YYYY-MM-DD" date: weeks run Monday to Sunday.
    static func monday(of date: String) -> String {
        guard let day = try? Date(date, strategy: day) else { return date }
        // .weekday counts Sunday as 1, so Monday is 2 and Sunday is 6 days after Monday.
        let back = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -back, to: day)!.formatted(Self.day)
    }

    /// The months that have rows, oldest first, as "YYYY-MM".
    static func months(_ rows: [ListedTransaction]) -> [String] {
        Set(rows.map(\.month)).sorted()
    }

    /// Rows grouped by week, newest week first; each week keeps the rows' own order.
    static func weeks(_ rows: [ListedTransaction]) -> [WeekGroup] {
        Dictionary(grouping: rows) { monday(of: $0.date) }
            .map { WeekGroup(monday: $0.key, rows: $0.value) }
            .sorted { $0.monday > $1.monday }
    }

    /// One month's Income, Spending and Transfers, skipping a part with no rows. Only the month's
    /// own rows are used, so a week that crosses into the next month holds just this month's days.
    static func parts(_ rows: [ListedTransaction], month: String) -> [MonthPart] {
        let shown = rows.filter { $0.month == month }
        return MoneyPart.allCases.map { part in MonthPart(part: part, rows: shown.filter { MoneyPart(kind: $0.kind) == part }) }
            .filter { !$0.rows.isEmpty }
    }

    /// "Jun 15 – 21", or "Jun 29 – Jul 5" when the Sunday is in the next month.
    static func label(monday: String) -> String {
        guard let start = try? Date(monday, strategy: day) else { return monday }
        let sunday = calendar.date(byAdding: .day, value: 6, to: start)!.formatted(Self.day)
        let sameMonth = sunday.prefix(7) == monday.prefix(7)
        return "\(monday.displayDate(.dateTime.month(.abbreviated).day())) – \(sunday.displayDate(sameMonth ? .dateTime.day() : .dateTime.month(.abbreviated).day()))"
    }
}

/// Money out as "$48.00", money in as "+$2,140.55", the way the design writes every amount.
func amountText(_ amount: Double) -> String {
    amount < 0 ? (-amount).formatted(.currency(code: "USD").sign(strategy: .always())) : amount.formatted(.currency(code: "USD"))
}

/// Whole cents written like `amountText`.
func amountText(cents: Int) -> String { amountText(Double(cents) / 100) }

/// The list of transactions from the chosen database, one month at a time: Income, Spending,
/// then Transfers, each grouped by Monday-to-Sunday week. Tapping a row opens it.
struct TransactionsView: View {
    let rows: [ListedTransaction]
    let database: SedgeDatabase
    /// The month shown, "YYYY-MM"; nil until the screen opens on the data's "today".
    @State private var month: String?
    /// +1 when moving to a later month, -1 to an earlier one, so the slide follows the arrow.
    @State private var direction = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var months: [String] { TransactionGroups.months(rows) }

    var body: some View {
        ZStack {
            if let month {
                list(month)
                    // A new identity per month, so changing month swaps the whole list with the transition.
                    .id(month)
                    // The old list only fades: a leaving view keeps the transition it was last drawn
                    // with, so a slide on it would go the previous step's way after a change of direction.
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(x: 24 * CGFloat(direction)).combined(with: .opacity),
                        removal: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let month { stepper(month) }
        }
        .background(Color.background)
        // The design's centered title; a large title has no list to collapse into above the stepper.
        .navigationBarTitleDisplayMode(.inline)
        // A sideways swipe changes month like the arrows; mostly-vertical drags are left to scrolling.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
            let x = drag.translation.width
            guard abs(x) > 60, abs(x) > 2 * abs(drag.translation.height) else { return }
            step(x < 0 ? 1 : -1)
        })
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No transactions", systemImage: "tray", description: Text("This data has no transactions yet.")) }
        }
        .task(id: months) {
            // Opens on the month of the data's "today"; a refresh keeps the month already shown.
            guard month.map(months.contains) != true else { return }
            let today = (try? database.asOf()).map { String($0.prefix(7)) }
            month = today.flatMap { months.contains($0) ? $0 : nil } ?? months.last
        }
    }

    /// Moves `by` months through the months that have data, if there is one that way.
    private func step(_ by: Int) {
        guard let month, let index = months.firstIndex(of: month), months.indices.contains(index + by) else { return }
        direction = by
        withAnimation(.easeInOut(duration: 0.25)) { self.month = months[index + by] }
    }

    /// The ‹ June 2026 › bar with the month's money in and out.
    private func stepper(_ month: String) -> some View {
        let parts = TransactionGroups.parts(rows, month: month)
        let total = { (part: MoneyPart) in parts.first { $0.part == part }?.cents ?? 0 }
        let index = months.firstIndex(of: month) ?? 0
        return HStack {
            stepButton("Previous month", systemImage: "chevron.left", enabled: index > 0) { step(-1) }
            Spacer(minLength: 8)
            VStack(spacing: 0) {
                Text("\(month)-01".displayDate(.dateTime.month(.wide).year()))
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                // Plaid's sign is positive for money out, so income is flipped to show what came in.
                Text("In \((Double(-total(.income)) / 100).formatted(.currency(code: "USD"))) · Out \((Double(total(.spending)) / 100).formatted(.currency(code: "USD")))")
                    .font(.row)
                    .foregroundStyle(Color.muted)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            stepButton("Next month", systemImage: "chevron.right", enabled: index < months.count - 1) { step(1) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.background)
    }

    /// One of the stepper's 44 × 44 pt arrows, faded when there is no month that way.
    private func stepButton(_ label: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                // The button stays 44 pt at every text size, so the arrow stops growing before it spills out.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(Color.accent)
                .frame(width: 44, height: 44)
                .background(Color.soft, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    /// One month's parts, each a heading and its weeks.
    private func list(_ month: String) -> some View {
        List {
            ForEach(TransactionGroups.parts(rows, month: month)) { part in
                Section {
                    TotalLine(title: Text(part.part.rawValue).font(.title3.weight(.semibold)).foregroundStyle(Color.ink),
                              total: amountText(cents: part.cents))
                        .accessibilityAddTraits(.isHeader)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))
                }
                ForEach(part.weeks) { week in
                    Section {
                        ForEach(week.rows) { row in
                            NavigationLink {
                                TransactionDetailView(database: database, id: row.id)
                            } label: {
                                TransactionRow(row: row, title: row.store, tag: true)
                            }
                        }
                    } header: {
                        TotalLine(title: Text(TransactionGroups.label(monday: week.monday)), total: amountText(cents: week.cents))
                    }
                    .listRowBackground(Color.group)
                }
            }
        }
        .listSectionSpacing(.compact)
        // The stepper already spaces the list from the title, so the list's own top gap goes.
        .contentMargins(.top, 0, for: .scrollContent)
        .themedBackground()
    }
}

/// Merchant history, opened from a transaction: a summary of the store's month, then the store's
/// rows by Monday-to-Sunday week with each week's count and total. Every number comes from the
/// store's own rows.
struct MerchantHistoryView: View {
    let rows: [ListedTransaction]
    let database: SedgeDatabase
    /// The data's "today", "YYYY-MM-DD", read when the screen opens.
    @State private var asOf: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            // A store with no purchases (only pay or transfers) has no visits to sum up.
            if let asOf, let summary = StoreSummary(rows, asOf: asOf) {
                Section { card(summary, month: String(asOf.prefix(7))) }
                    .listRowBackground(Color.soft)
            }
            ForEach(TransactionGroups.weeks(rows)) { week in
                Section {
                    ForEach(week.rows) { row in
                        NavigationLink {
                            TransactionDetailView(database: database, id: row.id)
                        } label: {
                            TransactionRow(row: row, title: row.date.displayDate(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), tag: false)
                        }
                    }
                } header: {
                    TotalLine(title: Text("\(TransactionGroups.label(monday: week.monday)) · \(count(week.rows.count))"),
                              total: amountText(cents: week.cents))
                }
                .listRowBackground(Color.group)
            }
        }
        .listSectionSpacing(.compact)
        .themedBackground()
        .task { asOf = try? database.asOf() }
    }

    /// "1 visit", "2 visits". A store that also pays the person (Maya's café pays her wages) has
    /// rows that aren't visits, so its weeks count transactions instead.
    private func count(_ count: Int) -> String {
        let word = rows.allSatisfy { $0.kind == "spending" } ? "visit" : "transaction"
        return count == 1 ? "1 \(word)" : "\(count) \(word)s"
    }

    /// This month's total, visit count and usual visit, with the whole history's count under them.
    private func card(_ summary: StoreSummary, month: String) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return VStack(alignment: .leading, spacing: 12) {
            layout {
                stat(amountText(cents: summary.cents), "this month")
                stat("\(summary.visits)", "\(summary.visits == 1 ? "visit" : "visits") in \("\(month)-01".displayDate(.dateTime.month(.wide)))")
                stat(summary.range, "usual visit")
            }
            Text("\(summary.allVisits == 1 ? "1 visit" : "\(summary.allVisits) visits") since \(summary.first.displayDate(.dateTime.month(.wide).day())).")
                .font(.row)
                .foregroundStyle(Color.muted)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(Color.ink)
            Text(label).font(.note).foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The numbers on Merchant history's card, from the store's own purchases only: a visit is a row
/// the organizer calls spending, so pay, refunds and transfers at the store aren't visits.
struct StoreSummary: Equatable {
    /// This month's purchases in whole cents.
    let cents: Int
    /// How many purchases are in this month.
    let visits: Int
    /// "$2.32–$3.99", this month's smallest to largest purchase, or "–" with none this month.
    let range: String
    /// Every purchase at the store, any month.
    let allVisits: Int
    /// The first purchase's date, "YYYY-MM-DD".
    let first: String
}

extension StoreSummary {
    /// `asOf` is the data's "today"; "this month" is its month. Nil when the store has no purchases.
    init?(_ rows: [ListedTransaction], asOf: String) {
        let purchases = rows.filter { $0.kind == "spending" }
        guard let first = purchases.map(\.date).min() else { return nil }
        let month = purchases.filter { $0.month == asOf.prefix(7) }
        cents = month.reduce(0) { $0 + $1.cents }
        visits = month.count
        let sizes = month.map { abs($0.cents) }
        let money = { (cents: Int) in (Double(cents) / 100).formatted(.currency(code: "USD")) }
        if let low = sizes.min(), let high = sizes.max() {
            range = low == high ? money(low) : "\(money(low))–\(money(high))"
        } else {
            range = "–"
        }
        allVisits = purchases.count
        self.first = first
    }
}

/// A title with a total on the right, or the total under the title at the largest text sizes,
/// so neither is squeezed. Used for part headings and week headers.
private struct TotalLine: View {
    let title: Text
    let total: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .lastTextBaseline))
        layout {
            title
            Spacer(minLength: 8)
            Text(total).monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(Color.muted)
        // Section headers are shown as written, not in capitals.
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// One transaction: a title over the bank's statement name, and the amount with its kind tag.
private struct TransactionRow: View {
    let row: ListedTransaction
    let title: String
    /// Whether to show the Income or Transfer tag; Merchant history is all one store, so it doesn't.
    let tag: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Side by side normally; stacked at the largest text sizes, so neither the name
        // nor the amount is squeezed to a few letters per line.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .center))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(row.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                Text(amountText(row.amount))
                    .monospacedDigit()
                if tag { kindTag(row.kind) }
            }
        }
        // VoiceOver reads the whole row as one item: title, statement name, amount, tag.
        .accessibilityElement(children: .combine)
    }

    /// A small tag for money that isn't everyday spending. The icon is drawn inside the text,
    /// because a list lines up every Label's icon in one column, which left a wide gap here.
    @ViewBuilder
    private func kindTag(_ kind: String?) -> some View {
        switch kind {
        case "income":
            Text("\(Image(systemName: "arrow.down.circle")) Income")
                .font(.caption)
                .foregroundStyle(.tint)
                .accessibilityLabel("Income")
        // A card payment is also money moving between the person's own accounts.
        case "transfer", "card_payment":
            Text("\(Image(systemName: "arrow.left.arrow.right")) Transfer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Transfer")
        default:
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        TransactionsView(rows: [
            ListedTransaction(transaction_id: "1", date: "2026-06-28", store: "Netflix", name: "NETFLIX.COM 866-579-7172 CA", amount: 17.99, kind: "spending"),
            ListedTransaction(transaction_id: "2", date: "2026-06-26", store: "Acme Corp Payroll", name: "ACME CORP PAYROLL DIR DEP", amount: -2140.55, kind: "income"),
            ListedTransaction(transaction_id: "3", date: "2026-06-25", store: "Card Payment", name: "PAYMENT THANK YOU", amount: -450, kind: "card_payment"),
        ], database: try! SedgeDatabase())
        .navigationTitle("Transactions")
    }
}
