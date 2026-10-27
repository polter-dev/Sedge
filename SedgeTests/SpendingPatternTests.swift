//
//  SpendingPatternTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

/// What `total_spent` says for one category between two dates.
private func totalSpent(_ category: String, _ start: String, _ end: String, in database: SedgeDatabase) throws -> Double {
    struct Result: Decodable { let total: Double }
    let input = try JSONSerialization.data(withJSONObject: ["category": category, "start_date": start, "end_date": end])
    let output = try #require(Tool.named("total_spent")).call(input, database: database)
    return try JSONDecoder().decode(Result.self, from: Data(output.utf8)).total
}

/// For Maya at her `as_of` (June 30), every category's four bars equal `total_spent` over the
/// first 30 days of March to June, and the stores in the graph add up to June's bar.
@Test func patternBarsMatchTotalSpent() throws {
    let database = try SedgeDatabase.open("maya")
    let asOf = try #require(try database.asOf())
    #expect(asOf == "2026-06-30")
    let totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: 30)
    let categories = Set(totals.map(\.category))
    #expect(categories.contains("dining"))

    for category in categories {
        let bars = SpendingView.bars(totals, category: category, asOf: asOf)
        // March 31 is left out, so March is compared over the same 30 days as June.
        #expect(bars.map(\.month) == ["2026-03", "2026-04", "2026-05", "2026-06"])
        for bar in bars {
            let tool = try totalSpent(category, bar.month + "-01", bar.month + "-30", in: database)
            #expect(abs(bar.total - tool) < 0.005, "\(category) \(bar.month): bar \(bar.total), total_spent \(tool)")
        }

        let rows = try ListedTransaction.spending(in: database, category: category, from: "2026-06-01", through: asOf)
        let stores = SpendingView.stores(rows)
        #expect(stores.count <= 4)
        let cents = stores.reduce(0) { $0 + Int(($1.total * 100).rounded()) }
        #expect(cents == Int((bars[3].total * 100).rounded()), "\(category): stores don't add up to June")
        // Each store's first row is its latest.
        for store in stores {
            #expect(store.rows.first?.date == store.rows.map(\.date).max())
        }
    }
}

/// Past four stores, the three biggest stay and the rest become "Other stores", whose amount
/// is theirs added up and whose latest transaction is the newest among them.
@Test func graphGroupsTheSmallStores() {
    func row(_ id: String, _ date: String, _ store: String, _ amount: Double) -> ListedTransaction {
        ListedTransaction(transaction_id: id, date: date, store: store, name: store, amount: amount, kind: "spending")
    }
    // Newest first, as the query returns them.
    let rows = [row("1", "2026-06-20", "E", 5), row("2", "2026-06-18", "A", 50), row("3", "2026-06-15", "D", 8),
                row("4", "2026-06-10", "B", 40), row("5", "2026-06-05", "C", 30), row("6", "2026-06-02", "A", 10.01)]
    let stores = SpendingView.stores(rows)
    #expect(stores.map(\.name) == ["A", "B", "C", "Other stores"])
    #expect(stores.map(\.total) == [60.01, 40, 30, 13])
    #expect(stores[0].rows.first?.transaction_id == "2")
    #expect(stores[3].rows.first?.transaction_id == "1")
}

/// Stepping back from January lands in the year before.
@Test func patternMonthsCrossTheYear() {
    #expect(SpendingView.months(endingAt: "2026-02-14") == ["2025-11", "2025-12", "2026-01", "2026-02"])
}
