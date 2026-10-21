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

    /// Every transaction, newest first, the same order the tools use.
    static func all(in database: SedgeDatabase) throws -> [ListedTransaction] {
        try database.dbQueue.read { db in
            try ListedTransaction.fetchAll(db, sql: """
                SELECT t.transaction_id, t.date, COALESCE(m.name, t.name) AS store, t.name, t.amount, t.kind
                FROM transactions t LEFT JOIN entities m ON m.id = t.merchant_id
                ORDER BY t.date DESC, t.transaction_id DESC
                """)
        }
    }
}

/// The list of transactions from the chosen database.
struct TransactionsView: View {
    let rows: [ListedTransaction]

    var body: some View {
        List(rows) { row in
            HStack {
                VStack(alignment: .leading) {
                    Text(row.store)
                    Text(row.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(row.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    // Flip Plaid's sign so money in shows as positive, like a bank statement.
                    Text(-row.amount, format: .currency(code: "USD"))
                    switch row.kind {
                    case "income":
                        Label("Income", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.green)
                    // A card payment is also money moving between the person's own accounts.
                    case "transfer", "card_payment":
                        Label("Transfer", systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.blue)
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No transactions", systemImage: "tray", description: Text("This data has no transactions yet.")) }
        }
    }
}

#Preview {
    NavigationStack {
        TransactionsView(rows: [
            ListedTransaction(transaction_id: "1", date: "2026-06-28", store: "Netflix", name: "NETFLIX.COM 866-579-7172 CA", amount: 17.99, kind: "spending"),
            ListedTransaction(transaction_id: "2", date: "2026-06-26", store: "Acme Corp Payroll", name: "ACME CORP PAYROLL DIR DEP", amount: -2140.55, kind: "income"),
            ListedTransaction(transaction_id: "3", date: "2026-06-25", store: "Card Payment", name: "PAYMENT THANK YOU", amount: -450, kind: "card_payment"),
        ])
        .navigationTitle("Transactions")
    }
}
