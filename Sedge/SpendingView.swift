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
    /// The organizer's category for the store, or `movedCategory`.
    let category: String
    let total: Double

    /// The category name used for money sent to the person's own accounts.
    static let movedCategory = "moved between accounts"

    /// Spending per month and category, counted the way the tools count it: posted spending
    /// less refunds. With `includeMoved`, transfers and card payments are added as their own
    /// category. Only the side leaving an account (a positive amount) is counted, because the
    /// other side is the same money arriving and would cancel it out.
    static func all(in database: SedgeDatabase, includeMoved: Bool) throws -> [SpendingTotal] {
        try database.dbQueue.read { db in
            try SpendingTotal.fetchAll(db, sql: """
                SELECT substr(t.date, 1, 7) AS month,
                       CASE WHEN t.kind IN ('transfer', 'card_payment') THEN ? ELSE COALESCE(c.name, 'other') END AS category,
                       SUM(ROUND(t.amount * 100)) / 100.0 AS total
                FROM transactions t
                LEFT JOIN edges e ON e.kind = 'in_category' AND e.source = t.merchant_id
                LEFT JOIN entities c ON c.id = e.target
                WHERE NOT t.pending
                  AND (t.kind IN ('spending', 'refund') OR (? AND t.kind IN ('transfer', 'card_payment') AND t.amount > 0))
                GROUP BY month, category
                ORDER BY month, category
                """, arguments: [movedCategory, includeMoved])
        }
    }
}

/// Spending charts: one bar per month, and every category over the whole data.
struct SpendingView: View {
    let database: SedgeDatabase
    /// Off by default: moving money to savings or paying a card isn't spending, and the
    /// purchases on the card were already counted at the store.
    @State private var includeMoved = false
    @State private var totals: [SpendingTotal] = []

    /// One bar (or bar piece) of a chart.
    private struct Bar: Identifiable {
        let label: String
        let group: String
        let total: Double
        var id: String { label + "|" + group }
    }

    /// Adds up the bars that share a label and group.
    private static func summed(_ bars: [Bar]) -> [Bar] {
        Dictionary(grouping: bars, by: \.id).values.map { same in
            Bar(label: same[0].label, group: same[0].group, total: same.map(\.total).reduce(0, +))
        }
    }

    /// Month totals, split into everyday spending and money moved, so the toggle's effect shows.
    private var byMonth: [Bar] {
        Self.summed(totals.map {
            Bar(label: $0.month, group: $0.category == SpendingTotal.movedCategory ? "Moved between accounts" : "Spending", total: $0.total)
        })
        .sorted { $0.id < $1.id }
    }

    /// Category totals for the whole data, biggest first. The group is the category as stored,
    /// so money moved can be colored like it is in the month chart.
    private var byCategory: [Bar] {
        Self.summed(totals.map { Bar(label: Self.title($0.category), group: $0.category, total: $0.total) })
            .sorted { ($0.total, $1.label) > ($1.total, $0.label) }
    }

    /// A stored category written for people: "phone_internet" becomes "Phone internet".
    private static func title(_ category: String) -> String {
        let words = category.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Whole dollars on the axes and labels; cents only clutter a chart.
    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    /// Grows with the text size, so category names never overlap their bars.
    @ScaledMetric private var barRow: CGFloat = 34

    var body: some View {
        List {
            Section {
                Toggle("Include money moved between my accounts", isOn: $includeMoved)
            }
            Section("By month") {
                Chart(byMonth) { bar in
                    BarMark(x: .value("Month", bar.label), y: .value("Spent", bar.total))
                        .foregroundStyle(by: .value("Kind", bar.group))
                }
                // The app's green for spending and a quiet gray for money moved, the same in both charts.
                .chartForegroundStyleScale(["Spending": Color.accentColor, "Moved between accounts": Color.gray])
                // With only spending shown, a one-item legend says nothing.
                .chartLegend(includeMoved ? .visible : .hidden)
                .chartXAxis {
                    AxisMarks { value in
                        // "2026-01" is shown as "Jan".
                        if let month = value.as(String.self) {
                            AxisValueLabel { Text((month + "-01").displayDate(.dateTime.month(.abbreviated))) }
                        }
                    }
                }
                .chartYAxis { AxisMarks(format: Self.dollars) }
                .frame(height: 220)
            }
            Section("By category") {
                Chart(byCategory) { bar in
                    BarMark(x: .value("Spent", bar.total), y: .value("Category", bar.label))
                        .foregroundStyle(bar.group == SpendingTotal.movedCategory ? Color.gray : Color.accentColor)
                        // The total at the end of each bar.
                        .annotation(position: .trailing) {
                            Text(bar.total, format: Self.dollars)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }
                // A quarter more room past the longest bar, so its total isn't drawn over the bar.
                // The low end stays below zero if refunds outweigh a category's spending.
                .chartXScale(domain: min(0, byCategory.map(\.total).min() ?? 0)...max(1, (byCategory.map(\.total).max() ?? 0) * 1.25))
                // Each bar is labeled with its total, so the dollar axis is left out.
                .chartXAxis(.hidden)
                // A fixed height per bar keeps every category name readable.
                .frame(height: CGFloat(byCategory.count) * barRow + 20)
            }
        }
        .overlay {
            if totals.isEmpty { ContentUnavailableView("No spending yet", systemImage: "chart.bar", description: Text("This data has no purchases to chart.")) }
        }
        // Runs when the screen opens and again whenever the toggle changes.
        .task(id: includeMoved) {
            do {
                totals = try SpendingTotal.all(in: database, includeMoved: includeMoved)
            } catch {
                print("Could not read spending:", error)
            }
        }
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        SpendingView(database: try! .open("maya"))
            .navigationTitle("Spending")
    }
}
