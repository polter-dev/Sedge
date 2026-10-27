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

/// The list of transactions from the chosen database, grouped by day like a bank statement.
/// Tapping one opens it.
struct TransactionsView: View {
    let rows: [ListedTransaction]
    let database: SedgeDatabase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The rows split into days, keeping their newest-first order.
    private var days: [(date: String, rows: [ListedTransaction])] {
        rows.reduce(into: []) { days, row in
            if days.last?.date == row.date {
                days[days.count - 1].rows.append(row)
            } else {
                days.append((row.date, [row]))
            }
        }
    }

    var body: some View {
        // Side by side normally; stacked at the largest text sizes, so neither the name
        // nor the amount is squeezed to a few letters per line.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        List {
            ForEach(days, id: \.date) { day in
                Section(day.date.displayDate()) {
                    ForEach(day.rows) { row in
                        NavigationLink {
                            TransactionDetailView(database: database, id: row.id)
                        } label: {
                            layout {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.store)
                                    Text(row.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: stacked ? .leading : .trailing, spacing: 2) {
                                    // Flip Plaid's sign so money in shows as positive, like a bank statement.
                                    Text(-row.amount, format: .currency(code: "USD"))
                                        .monospacedDigit()
                                    kindTag(row.kind)
                                }
                            }
                            // VoiceOver reads the whole row as one item: store, statement name, amount, tag.
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .listRowBackground(Color.group)
            }
        }
        .themedBackground()
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No transactions", systemImage: "tray", description: Text("This data has no transactions yet.")) }
        }
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
