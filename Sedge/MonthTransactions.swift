//
//  MonthTransactions.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// A sheet of one category's transactions in one month, oldest first, under their count and
/// exact total, counted the same way as Trends counts the category.
struct MonthTransactions: View {
    let database: SedgeDatabase
    let opened: Opened
    @State private var rows: [ListedTransaction] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    /// The date column, 56 pt in the design; it grows with the text size.
    @ScaledMetric(relativeTo: .footnote) private var dateWidth: CGFloat = 56

    /// What the sheet lists: a category, the stored categories it adds up, a month and its last day.
    struct Opened: Identifiable, Hashable {
        let category: String
        let folded: [String]
        let month: String
        /// The last day listed, "YYYY-MM-DD": today's day of the month, as Trends counts each month.
        let through: String
        var id: Self { self }
    }

    /// The transactions the sheet lists, oldest first: every one in the stored categories that
    /// month through `through`, so a sheet for several categories adds up to all of them.
    static func sheetRows(in database: SedgeDatabase, _ opened: Opened) throws -> [ListedTransaction] {
        try opened.folded.flatMap {
            try ListedTransaction.spending(in: database, category: $0, from: opened.month + "-01", through: opened.through)
        }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

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
                rows = try Self.sheetRows(in: database, opened)
            } catch {
                print("Could not read transactions:", error)
            }
        }
    }
}
