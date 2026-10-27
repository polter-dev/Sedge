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
    /// same way as `SpendingTotal.all` and the tools' `total_spent`.
    static func spending(in database: SedgeDatabase, category: String, from start: String, through end: String) throws -> [ListedTransaction] {
        try database.dbQueue.read { db in
            try ListedTransaction.fetchAll(db, sql: """
                SELECT t.transaction_id, t.date, COALESCE(m.name, t.name) AS store, t.name, t.amount, t.kind
                FROM transactions t
                LEFT JOIN entities m ON m.id = t.merchant_id
                \(SpendingTotal.categoryJoins)
                WHERE NOT t.pending AND t.kind IN ('spending', 'refund')
                  AND t.date BETWEEN ? AND ? AND \(SpendingTotal.categoryOf) = ?
                ORDER BY t.date DESC, t.transaction_id DESC
                """, arguments: [start, end, category])
        }
    }
}

/// The Trends tab's Spending screen: one category's last four months side by side, and the
/// stores that make up this month's spending in it.
struct SpendingView: View {
    let database: SedgeDatabase
    /// Opens the Ask tab.
    let ask: () -> Void
    /// The dataset's "today"; nil until loaded, or when nothing has been saved yet.
    @State private var asOf: String?
    /// Spending per month and category over the first `day` days of each month.
    @State private var totals: [SpendingTotal] = []
    @State private var category = ""
    /// This month's spending in `category`, newest first.
    @State private var rows: [ListedTransaction] = []
    /// The store tapped last, by name.
    @State private var selected: String?

    /// One store in the graph, or "Other stores" for the rest.
    struct Store: Identifiable {
        let name: String
        /// Its transactions this month, newest first, so the first is the latest.
        let rows: [ListedTransaction]
        var id: String { name }
        /// Summed in whole cents, as the tools sum.
        var total: Double { Double(rows.reduce(0) { $0 + Int(($1.amount * 100).rounded()) }) / 100 }
    }

    /// The four months the bars cover, oldest first, as "YYYY-MM": `asOf`'s month and the three before it.
    static func months(endingAt asOf: String) -> [String] {
        guard let year = Int(asOf.prefix(4)), let month = Int(asOf.dropFirst(5).prefix(2)) else { return [] }
        return (0..<4).reversed().map { back in
            // Months counted from year 0, so stepping back past January lands in the year before.
            let index = year * 12 + month - 1 - back
            return String(format: "%04d-%02d", index / 12, index % 12 + 1)
        }
    }

    /// The bars for one category: each month's total over the same first days, oldest first.
    static func bars(_ totals: [SpendingTotal], category: String, asOf: String) -> [(month: String, total: Double)] {
        months(endingAt: asOf).map { month in
            (month, totals.first { $0.month == month && $0.category == category }?.total ?? 0)
        }
    }

    /// The biggest three stores and "Other stores" for the rest, or every store when there are
    /// four or fewer, so the graph never has more than four around the middle.
    static func stores(_ rows: [ListedTransaction]) -> [Store] {
        // Grouping keeps each store's rows in their newest-first order.
        let all = Dictionary(grouping: rows, by: \.store).map { Store(name: $0.key, rows: $0.value) }
            .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
        guard all.count > 4 else { return all }
        let rest = Set(all.dropFirst(3).map(\.name))
        return Array(all.prefix(3)) + [Store(name: "Other stores", rows: rows.filter { rest.contains($0.store) })]
    }

    /// The day of the month of "today": every month is compared over its first this many days.
    private var day: Int { asOf.flatMap { Int($0.suffix(2)) } ?? 31 }

    /// The categories with spending in the four months shown, by name.
    private var categories: [String] {
        let months = asOf.map(Self.months) ?? []
        return Set(totals.filter { months.contains($0.month) }.map(\.category)).sorted { Self.title($0) < Self.title($1) }
    }

    /// A stored category written for people: "phone_internet" becomes "Phone internet".
    private static func title(_ category: String) -> String {
        let words = category.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Whole dollars on the axes and labels; cents only clutter a chart.
    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    /// Every node in the graph is this wide (the design's "equal node sizes"); it grows with the text size.
    @ScaledMetric(relativeTo: .caption) private var nodeWidth: CGFloat = 96

    var body: some View {
        ScrollView {
            if let asOf, !categories.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    patterns(asOf)
                    connected
                    Button("Ask about a tradeoff →", action: ask)
                        .font(.link)
                        // Wrapped lines at large text sizes stay flush left, like the rest of the screen.
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(Color.background)
        .overlay {
            // Spending only older than the four months shown counts as none.
            if categories.isEmpty { ContentUnavailableView("No spending yet", systemImage: "chart.bar", description: Text("This data has no purchases to chart.")) }
        }
        // Runs when the screen opens and again whenever another category is picked.
        .task(id: category) {
            do {
                if asOf == nil {
                    asOf = try database.asOf()
                    totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: day)
                    // The design opens on dining; any other data opens on its first category.
                    category = categories.contains("dining") ? "dining" : categories.first ?? ""
                }
                guard let asOf else { return }
                rows = try ListedTransaction.spending(in: database, category: category,
                                                      from: String(asOf.prefix(8)) + "01", through: asOf)
                selected = nil
            } catch {
                print("Could not read spending:", error)
            }
        }
    }

    /// "Your patterns": this month so far and the three months before it, over the same days.
    private func patterns(_ asOf: String) -> some View {
        let bars = Self.bars(totals, category: category, asOf: asOf)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your patterns").font(.title2.bold())
                Spacer()
                Text(asOf.displayDate(.dateTime.month(.wide))).font(.row).foregroundStyle(Color.muted)
            }
            .foregroundStyle(Color.ink)
            HStack(spacing: 4) {
                Menu {
                    Picker("Category", selection: $category) {
                        ForEach(categories, id: \.self) { Text(Self.title($0)) }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(Self.title(category))
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .foregroundStyle(Color.ink)
                    // Apple's minimum tap target, taller than the design's caption line.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Category")
                .accessibilityValue(Self.title(category))
                Text(day == 1 ? "· the first day of each month" : "· same first \(day) days each month")
                    .foregroundStyle(Color.muted)
            }
            .font(.row)
            Text(bars.last?.total ?? 0, format: Self.dollars)
                .font(.bigValue)
                .foregroundStyle(Color.ink)
            Chart {
                ForEach(bars, id: \.month) { bar in
                    BarMark(x: .value("Month", bar.month), y: .value("Spent", bar.total), width: .ratio(0.55))
                        .cornerRadius(5)
                        // This month in full, the months before it faded, as in the design.
                        .foregroundStyle(Color.accent.opacity(bar.month == bars.last?.month ? 1 : 0.35))
                        .accessibilityLabel((bar.month + "-01").displayDate(.dateTime.month(.wide)))
                        .accessibilityValue(bar.total.formatted(Self.dollars))
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.line)
            }
            .chartXAxis {
                AxisMarks { value in
                    // "2026-06" is shown as "Jun".
                    if let month = value.as(String.self) {
                        AxisValueLabel { Text((month + "-01").displayDate(.dateTime.month(.abbreviated))).foregroundStyle(Color.muted) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                    AxisValueLabel(format: Self.dollars).foregroundStyle(Color.muted)
                }
            }
            .frame(height: 175)
            .padding(.top, 8)
        }
    }

    /// "Connected spending": the category in the middle and its stores around it, with this
    /// month's amount at each. Tapping a store shows its latest transaction below.
    @ViewBuilder
    private var connected: some View {
        let stores = Self.stores(rows)
        HStack(alignment: .firstTextBaseline) {
            Text("Connected spending").font(.headline).foregroundStyle(Color.ink)
            Spacer()
            Text("Tap a merchant").font(.row).foregroundStyle(Color.muted)
        }
        .padding(.top, 18)
        .padding(.bottom, 20)
        if stores.isEmpty {
            Text("No \(Self.title(category).lowercased()) spending so far this month.")
                .font(.row)
                .foregroundStyle(Color.muted)
        } else {
            VStack(spacing: 7) {
                HStack(alignment: .top) { node(stores, 0); Spacer(minLength: 8); node(stores, 1) }
                Text(Self.title(category))
                    .font(.row)
                    .foregroundStyle(Color.contrast)
                    // Two lines tall like a store node, whatever the name's length.
                    .lineLimit(2, reservesSpace: true)
                    .padding(10)
                    .frame(width: nodeWidth, alignment: .leading)
                    .background(Color.accent, in: .rect(cornerRadius: 12))
                HStack(alignment: .bottom) { node(stores, 2); Spacer(minLength: 8); node(stores, 3) }
            }
            .background {
                // A line from the middle toward each corner, under the nodes, meaning "categorized as".
                Canvas { context, size in
                    let corners = [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15), CGPoint(x: 0.15, y: 0.85), CGPoint(x: 0.85, y: 0.85)]
                    for corner in corners.prefix(stores.count) {
                        var line = Path()
                        line.move(to: CGPoint(x: size.width / 2, y: size.height / 2))
                        line.addLine(to: CGPoint(x: corner.x * size.width, y: corner.y * size.height))
                        context.stroke(line, with: .color(.line), lineWidth: 2)
                    }
                }
                .accessibilityHidden(true)
            }
            Text("Lines mean “categorized as.” Equal node sizes.")
                .font(.row)
                .foregroundStyle(Color.muted)
                .padding(.top, 5)
            if let store = stores.first(where: { $0.name == selected }), let row = store.rows.first {
                latest(row)
            }
        }
    }

    /// The store in slot `index` (top left, top right, bottom left, bottom right), if there is one.
    @ViewBuilder
    private func node(_ stores: [Store], _ index: Int) -> some View {
        if index < stores.count {
            let store = stores[index]
            Button { selected = store.name } label: {
                VStack(spacing: 2) {
                    Text(store.name).lineLimit(2)
                    Text(store.total, format: Self.dollars)
                }
                .font(.row)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(maxWidth: nodeWidth, minHeight: 44)
                .background(Color.soft, in: .rect(cornerRadius: 12))
                .overlay {
                    if selected == store.name { RoundedRectangle(cornerRadius: 12).stroke(Color.ink, lineWidth: 1.5) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(store.name), \(store.total.formatted(Self.dollars))")
            .accessibilityHint("Shows the latest transaction")
            .accessibilityIdentifier("store")
            .accessibilityAddTraits(selected == store.name ? .isSelected : [])
        }
    }

    /// The tapped store's latest transaction; tapping it opens the transaction.
    private func latest(_ row: ListedTransaction) -> some View {
        NavigationLink {
            TransactionsView(rows: [row])
                .navigationTitle("Transaction")
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
        SpendingView(database: try! .open("maya")) {}
            .navigationTitle("Spending")
    }
}
