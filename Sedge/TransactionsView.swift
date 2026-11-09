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
    /// The stored category ("phone_internet"), the person's answer first, as the Spending screen
    /// counts it. Only `all` reads it; a query without the column leaves it nil.
    var category: String? = nil
    /// True for a charge the bank hasn't posted yet. Only `all` reads it; a query without the column leaves it nil.
    var pending: Bool? = nil

    var id: String { transaction_id }
    /// The amount in whole cents, Plaid's sign, so sums never pick up float noise.
    var cents: Int { Int((amount * 100).rounded()) }
    /// "YYYY-MM", the month the list files it under.
    var month: String { String(date.prefix(7)) }

    /// Every transaction, or with `merchant` only that store's, newest first, the same order the tools use.
    static func all(in database: SedgeDatabase, merchant: String? = nil) throws -> [ListedTransaction] {
        try database.dbQueue.read { db in
            try ListedTransaction.fetchAll(db, sql: """
                SELECT t.transaction_id, t.date, COALESCE(m.name, t.name) AS store, t.name, t.amount, t.kind,
                       \(SpendingTotal.categoryOf) AS category, t.pending
                FROM transactions t LEFT JOIN entities m ON m.id = t.merchant_id
                \(SpendingTotal.categoryJoins)
                WHERE ? IS NULL OR t.merchant_id = ?
                ORDER BY t.date DESC, t.transaction_id DESC
                """, arguments: [merchant, merchant])
        }
    }
}

/// What a row counts as on the transactions list.
enum MoneyPart {
    case income, spending, transfers

    /// Transfers and card payments only move money between the person's own accounts, so they
    /// count as neither money in nor money out. Refunds count against the spending they undo.
    init(kind: String?) {
        switch kind {
        case "income": self = .income
        case "transfer", "card_payment": self = .transfers
        default: self = .spending
        }
    }
}

/// Money in and money out of some rows, in whole cents, each summed from the rows themselves.
struct InOut: Equatable {
    /// Income, flipped from Plaid's sign so money that came in is above zero.
    let moneyIn: Int
    /// Spending less refunds. Transfers and card payments are in neither number.
    let moneyOut: Int
    /// What is left of the money in after the money out.
    var leftOver: Int { moneyIn - moneyOut }

    init(_ rows: [ListedTransaction]) {
        moneyIn = -rows.filter { MoneyPart(kind: $0.kind) == .income }.reduce(0) { $0 + $1.cents }
        moneyOut = rows.filter { MoneyPart(kind: $0.kind) == .spending }.reduce(0) { $0 + $1.cents }
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

    /// One month's rows of every kind by week, newest first. Only the month's own rows are used,
    /// so a week that crosses into the next month holds just this month's days.
    static func weeks(_ rows: [ListedTransaction], month: String) -> [WeekGroup] {
        weeks(rows.filter { $0.month == month })
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

/// The list of transactions from the chosen database, one month at a time: the month's money in
/// and out, then every row in one run of Monday-to-Sunday weeks. Tapping a row opens it.
struct TransactionsView: View {
    let rows: [ListedTransaction]
    let database: SedgeDatabase
    /// True after a pull-to-refresh sync of the bank data failed, until one works.
    var syncFailed = false
    /// The month shown, "YYYY-MM"; nil until the screen opens on the data's "today".
    @State private var month: String?
    /// +1 when moving to a later month, -1 to an earlier one, so the slide follows the change.
    @State private var direction = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The 6 pt month dots and the 8 pt dots on the in/out card grow with the text.
    @ScaledMetric(relativeTo: .caption2) private var pageDot: CGFloat = 6
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 8

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
            if let month { pageDots(month) }
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let month {
                ToolbarItem(placement: .principal) { monthMenu(month) }
            }
        }
        // A sideways swipe changes month; mostly-vertical drags are left to scrolling.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
            let x = drag.translation.width
            guard abs(x) > 60, abs(x) > 2 * abs(drag.translation.height) else { return }
            step(x < 0 ? 1 : -1)
        })
        .background(NoContentBackSwipe())
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No transactions", systemImage: "tray") }
        }
        .task(id: months) {
            // Opens on the month of the data's "today"; a refresh keeps the month already shown.
            guard month.map(months.contains) != true else { return }
            let today = (try? database.asOf()).map { String($0.prefix(7)) }
            month = today.flatMap { months.contains($0) ? $0 : nil } ?? months.last
        }
    }

    /// "June 2026".
    private func monthName(_ month: String) -> String { "\(month)-01".displayDate(.dateTime.month(.wide).year()) }

    /// Shows another month, sliding in from the side it is on.
    private func show(_ newMonth: String) {
        guard let month, newMonth != month else { return }
        direction = newMonth > month ? 1 : -1
        withAnimation(.easeInOut(duration: 0.25)) { self.month = newMonth }
    }

    /// Moves `by` months through the months that have data, if there is one that way.
    private func step(_ by: Int) {
        guard let month, let index = months.firstIndex(of: month), months.indices.contains(index + by) else { return }
        show(months[index + by])
    }

    /// The title: the month as a menu of every month with data, newest first. The screen's name
    /// is the nav bar's subtitle under it.
    private func monthMenu(_ month: String) -> some View {
        Menu {
            Picker("Month", selection: Binding(get: { month }, set: show)) {
                ForEach(months.reversed(), id: \.self) { Text(monthName($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(monthName(month)).font(.callout.weight(.semibold)).foregroundStyle(Color.ink)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Color.accent)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Color.soft, in: .capsule)
        }
        // The nav bar has a fixed height, so the title stops growing before it spills out.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel("Month")
        .accessibilityValue(monthName(month))
    }

    /// One dot per month with data, the shown month's dark. The menu says the same, so VoiceOver skips it.
    private func pageDots(_ month: String) -> some View {
        HStack(spacing: 6) {
            ForEach(months, id: \.self) { Circle().fill($0 == month ? Color.accent : Color.line).frame(width: pageDot, height: pageDot) }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(Color.background)
        .accessibilityHidden(true)
    }

    /// The in/out card, then the month's weeks in one group, each week's header above its rows.
    private func list(_ month: String) -> some View {
        List {
            Section { card(InOut(rows.filter { $0.month == month })) }
                .listRowBackground(Color.group)
            Section {
                ForEach(TransactionGroups.weeks(rows, month: month)) { week in
                    weekHeader(week)
                        .listRowBackground(Color.soft)
                        .listRowSeparator(.hidden)
                    ForEach(week.rows) { row in
                        NavigationLink {
                            TransactionDetailView(database: database, id: row.id)
                        } label: {
                            WeekRow(row: row)
                        }
                    }
                }
            } footer: {
                if syncFailed { Text(bankSyncFailedMessage).foregroundStyle(.secondary) }
            }
            .listRowBackground(Color.group)
        }
        .listSectionSpacing(16)
        // The month dots already space the list from the title, so the list's own top gap shrinks.
        .contentMargins(.top, 10, for: .scrollContent)
        .themedBackground()
    }

    /// Money in and out side by side (stacked at the largest text sizes), a bar split by the two,
    /// and what is left over.
    private func card(_ money: InOut) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        // The bar only splits money that came in and went out; a month of refunds draws no bar.
        let shareIn = max(money.moneyIn, 0), shareOut = max(money.moneyOut, 0)
        let dollars = { (cents: Int) in (Double(cents) / 100).formatted(.currency(code: "USD")) }
        return VStack(alignment: .leading, spacing: 10) {
            layout {
                figure("In", amountText(cents: -money.moneyIn), color: .moneyBack)
                Spacer(minLength: 0)
                figure("Out", amountText(cents: money.moneyOut), color: .moneySpent)
            }
            if shareIn + shareOut > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        Capsule().fill(Color.moneyBack)
                            .frame(width: max(geometry.size.width - 2, 0) * CGFloat(shareIn) / CGFloat(shareIn + shareOut))
                        Capsule().fill(Color.moneySpent)
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            Text(money.leftOver >= 0 ? "\(dollars(money.leftOver)) left over" : "\(dollars(-money.leftOver)) more out than in")
                .font(.note)
                .foregroundStyle(Color.muted)
        }
        .padding(.vertical, 2)
    }

    /// "● In +$1,040.00": a dot, a muted word and the figure in the dot's color.
    private func figure(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: dot, height: dot)
            Text(label).font(.row).foregroundStyle(Color.muted)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                // Each figure stays on one line next to the other.
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The week's range, then its money in (green, only when some came in) and money out (red).
    private func weekHeader(_ week: WeekGroup) -> some View {
        let money = InOut(week.rows)
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(TransactionGroups.label(monday: week.monday)).foregroundStyle(Color.ink)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if money.moneyIn != 0 { Text(amountText(cents: -money.moneyIn)).foregroundStyle(Color.moneyBack) }
                if money.moneyOut != 0 || money.moneyIn == 0 { Text(amountText(cents: money.moneyOut)).foregroundStyle(Color.moneySpent) }
            }
            .monospacedDigit()
        }
        .font(.row.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Turns off the swipe-anywhere back gesture while its screen shows. Since iOS 26 a sideways pan
/// anywhere on a pushed screen can go back, and it is not tied to the month swipe, so a swipe
/// meant to change month could leave the screen instead. The back button and the swipe from the
/// screen's left edge are separate gestures and still go back.
private struct NoContentBackSwipe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = false
        }

        // Turned back on as the screen leaves, so the screens before and after it keep the gesture.
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = true
        }
    }
}

/// One row of the week list: a dot for what it is, the store, and the amount. Pay is green;
/// transfers and card payments are dimmed and marked as not counted. A pending row's amount is
/// dimmed and marked Pending, though it still counts in the sums.
private struct WeekRow: View {
    let row: ListedTransaction
    @ScaledMetric(relativeTo: .callout) private var dot: CGFloat = 8
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let part = MoneyPart(kind: row.kind)
        let pending = row.pending == true
        // Side by side normally; stacked at the largest text sizes, so neither is squeezed.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
        HStack(spacing: 12) {
            Circle()
                .fill(part == .income ? Color.moneyBack : part == .transfers ? Color.line : Color.category(SpendingView.title(row.category ?? "other")))
                .frame(width: dot, height: dot)
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.store).foregroundStyle(part == .transfers ? Color.muted : Color.ink)
                    if part == .transfers {
                        Text("Transfer · not counted").font(.note).foregroundStyle(Color.muted)
                    }
                    if pending {
                        Text("Pending").font(.note).foregroundStyle(Color.muted)
                    }
                }
                Spacer(minLength: 0)
                Text(amountText(row.amount))
                    .fontWeight(part == .transfers ? .regular : .medium)
                    .monospacedDigit()
                    .foregroundStyle(pending || part == .transfers ? Color.muted : part == .income ? Color.moneyBack : Color.ink)
            }
        }
        .font(.callout)
        // VoiceOver reads the whole row as one item: store, the transfer or pending note, amount.
        .accessibilityElement(children: .combine)
    }
}

/// Merchant history, opened from a transaction: this month's total at the store, the change from
/// last month and a six-month chart, then the store's visits by month and Monday-to-Sunday week.
/// The card, the chart and the list all use the store's own purchases, so they never disagree.
struct MerchantHistoryView: View {
    let rows: [ListedTransaction]
    let database: SedgeDatabase
    /// The data's "today", "YYYY-MM-DD", read when the screen opens.
    @State private var asOf: String?
    /// False until the chart first appears, so its bars grow from zero once.
    @State private var grown = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The store's purchases. A store with none (a payroll, a transfer) lists all its rows instead.
    /// Static so the Transaction screen's "Merchant history" row counts the same rows.
    static func purchases(_ rows: [ListedTransaction]) -> [ListedTransaction] { rows.filter { $0.kind == "spending" } }
    private var purchases: [ListedTransaction] { Self.purchases(rows) }
    private var shown: [ListedTransaction] { purchases.isEmpty ? rows : purchases }

    var body: some View {
        List {
            // A store with no purchases has no visits to sum up.
            if let asOf, let summary = StoreSummary(rows, asOf: asOf) {
                Section { card(summary) }
                    .listRowBackground(Color.group)
            }
            ForEach(TransactionGroups.monthWeeks(shown), id: \.month) { month, weeks in
                Section {
                    ForEach(weeks) { week in
                        weekHeader(week)
                            .listRowBackground(Color.soft)
                            .listRowSeparator(.hidden)
                        ForEach(week.rows) { row in
                            NavigationLink {
                                TransactionDetailView(database: database, id: row.id)
                            } label: {
                                TransactionRow(row: row, title: row.date.displayDate(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            }
                        }
                    }
                } header: {
                    monthHeader(month, weeks: weeks)
                }
                .listRowBackground(Color.group)
            }
        }
        .listSectionSpacing(.compact)
        .themedBackground()
        .task { asOf = try? database.asOf() }
    }

    /// "1 visit", "2 visits"; a store with no purchases counts transactions instead.
    private func count(_ count: Int) -> String { Self.count(count, visits: !purchases.isEmpty) }
    static func count(_ count: Int, visits: Bool) -> String {
        let word = visits ? "visit" : "transaction"
        return count == 1 ? "1 \(word)" : "\(count) \(word)s"
    }

    /// "June", or "June 2025" outside the data's current year.
    private func monthName(_ month: String) -> String {
        let sameYear = asOf.map { $0.prefix(4) == month.prefix(4) } ?? true
        return "\(month)-01".displayDate(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
    }

    /// "JUNE · 4 visits · $12.71".
    private func monthHeader(_ month: String, weeks: [WeekGroup]) -> some View {
        let rows = weeks.reduce(0) { $0 + $1.rows.count }
        let cents = weeks.reduce(0) { $0 + $1.cents }
        return Text("\(monthName(month).uppercased()) · \(count(rows)) · \(amountText(cents: cents))")
            .font(.footnote)
            .foregroundStyle(Color.muted)
            // Shown as written: only the month is in capitals.
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    /// A week's range over its count, with the week's total on the right.
    private func weekHeader(_ week: WeekGroup) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            VStack(alignment: .leading, spacing: 1) {
                Text(TransactionGroups.label(monday: week.monday)).font(.row.weight(.medium)).foregroundStyle(Color.ink)
                Text(count(week.rows.count)).font(.note).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 0)
            Text(amountText(cents: week.cents)).font(.row.weight(.medium)).monospacedDigit().foregroundStyle(Color.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// This month's total with its change from last month, the six-month chart, and every visit's count and total.
    private func card(_ summary: StoreSummary) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        let month = monthName(summary.bars[summary.bars.count - 1].month)
        let lastMonth = monthName(summary.bars[summary.bars.count - 2].month)
        let change = summary.change
        let money = { (cents: Int) in (Double(cents) / 100).formatted(.currency(code: "USD")) }
        return VStack(alignment: .leading, spacing: 12) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(money(summary.cents))
                        .font(.bigValue)
                        .foregroundStyle(Color.amountNow)
                    Text(summary.visits == 0 ? "No visits in \(month)" : "\(count(summary.visits)) in \(month) · \(summary.range) each")
                        .font(.row)
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                    // Green when less went to the store than last month, red when more.
                    Text(change == 0 ? "Same" : "\(money(abs(change))) \(change < 0 ? "less" : "more")")
                        .font(.row.weight(.medium))
                        .foregroundStyle(change < 0 ? Color.moneyBack : change > 0 ? Color.moneySpent : Color.muted)
                    Text("\(change == 0 ? "as" : "than") \(lastMonth)")
                        .font(.note)
                        .foregroundStyle(Color.muted)
                }
                .accessibilityElement(children: .combine)
            }
            chart(summary)
            Text("\(count(summary.allVisits)) since \(summary.first.displayDate(.dateTime.month(.abbreviated).day())) · \(money(summary.allCents)) in all")
                .font(.note)
                .foregroundStyle(Color.muted)
        }
        .padding(.vertical, 4)
    }

    /// One bar per month, the latest in `chartNow`, each with its total above and its letter below.
    private func chart(_ summary: StoreSummary) -> some View {
        // The tallest bar is 64 pt; `max(…, 1)` keeps six empty months from dividing by zero.
        let top = CGFloat(max(summary.bars.map(\.cents).max() ?? 0, 1))
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(summary.bars.enumerated()), id: \.element.month) { index, bar in
                let now = index == summary.bars.count - 1
                VStack(spacing: 4) {
                    // At the largest text sizes the totals would overlap, so only the letters stay.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(amountText(cents: bar.cents))
                            .font(now ? .note.weight(.medium) : .note)
                            .foregroundStyle(now ? Color.ink : Color.muted)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(now ? Color.chartNow : Color.chartPast)
                        .frame(width: 40, height: grown ? 64 * CGFloat(bar.cents) / top : 0)
                        // Bars grow from zero one after another; Reduce Motion shows them at full height.
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.04 * Double(index)), value: grown)
                    Text("\(bar.month)-01".displayDate(.dateTime.month(.narrow)))
                        .font(.note)
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(monthName(bar.month)), \(amountText(cents: bar.cents))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storeChart")
        .onAppear { grown = true }
    }
}

extension TransactionGroups {
    /// Merchant history's list: the rows by month, newest month first, each month by week, newest
    /// week first. A week that crosses months holds only that month's days, as on the transactions list.
    static func monthWeeks(_ rows: [ListedTransaction]) -> [(month: String, weeks: [WeekGroup])] {
        months(rows).reversed().map { month in (month, weeks(rows.filter { $0.month == month })) }
    }
}

/// The numbers on Merchant history's card, from the store's own purchases only: a visit is a row
/// the organizer calls spending, so pay, refunds and transfers at the store aren't visits.
struct StoreSummary: Equatable {
    /// One month's purchases for the chart.
    struct Bar: Equatable {
        /// "YYYY-MM".
        let month: String
        /// The month's purchases in whole cents.
        let cents: Int
    }

    /// This month's purchases in whole cents.
    let cents: Int
    /// How many purchases are in this month.
    let visits: Int
    /// "$2.32–$3.99", this month's smallest to largest purchase, or "–" with none this month.
    let range: String
    /// Every purchase at the store, any month.
    let allVisits: Int
    /// Every purchase at the store, any month, in whole cents.
    let allCents: Int
    /// The first purchase's date, "YYYY-MM-DD".
    let first: String
    /// The six months up to and including this month, oldest first; a month with no purchases is 0.
    let bars: [Bar]

    /// This month minus last month, in whole cents: below zero when less went to the store.
    var change: Int { cents - bars[bars.count - 2].cents }
}

extension StoreSummary {
    /// `asOf` is the data's "today"; "this month" is its month. Nil when the store has no purchases.
    init?(_ rows: [ListedTransaction], asOf: String) {
        let purchases = MerchantHistoryView.purchases(rows)
        guard let first = purchases.map(\.date).min(),
              let year = Int(asOf.prefix(4)), let monthNumber = Int(asOf.dropFirst(5).prefix(2)) else { return nil }
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
        allCents = purchases.reduce(0) { $0 + $1.cents }
        self.first = first
        // Months counted from year 0, so stepping back across a year end is plain subtraction.
        let now = year * 12 + monthNumber - 1
        bars = (now - 5...now).map { index in
            let key = String(format: "%04d-%02d", index / 12, index % 12 + 1)
            return Bar(month: key, cents: purchases.filter { $0.month == key }.reduce(0) { $0 + $1.cents })
        }
    }
}

/// One Merchant history visit: its date over the bank's statement name, and the amount.
private struct TransactionRow: View {
    let row: ListedTransaction
    let title: String
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
                    .font(.row)
                    .foregroundStyle(Color.muted)
            }
            Spacer(minLength: 8)
            Text(amountText(row.amount))
                .monospacedDigit()
        }
        // VoiceOver reads the whole row as one item: title, statement name, amount.
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        TransactionsView(rows: [
            ListedTransaction(transaction_id: "1", date: "2026-06-28", store: "Netflix", name: "NETFLIX.COM 866-579-7172 CA", amount: 17.99, kind: "spending", category: "subscriptions"),
            ListedTransaction(transaction_id: "2", date: "2026-06-26", store: "Acme Corp Payroll", name: "ACME CORP PAYROLL DIR DEP", amount: -2140.55, kind: "income"),
            ListedTransaction(transaction_id: "3", date: "2026-06-25", store: "Card Payment", name: "PAYMENT THANK YOU", amount: -450, kind: "card_payment"),
        ], database: try! SedgeDatabase())
        .navigationTitle("Transactions")
        .navigationSubtitle("Transactions · Maya")
    }
}
