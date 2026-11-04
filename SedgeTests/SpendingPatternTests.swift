//
//  SpendingPatternTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

/// What `total_spent` says for one category between two dates.
/// With no category, every category together.
private func totalSpent(_ category: String?, _ start: String, _ end: String, in database: SedgeDatabase) throws -> Double {
    struct Result: Decodable { let total: Double }
    var arguments = ["start_date": start, "end_date": end]
    arguments["category"] = category
    let input = try JSONSerialization.data(withJSONObject: arguments)
    let output = try #require(Tool.named("total_spent")).call(input, database: database)
    return try JSONDecoder().decode(Result.self, from: Data(output.utf8)).total
}

/// For Maya at her `as_of` (June 30), every category's four bars equal `total_spent` over the
/// first 30 days of March to June, and the stores in the graph add up to June's bar.
@Test func patternBarsMatchTotalSpent() throws {
    let database = try inMemory("maya") // in memory: running alongside SedgeTests, the shared file would be locked
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

/// For every month on the chart and every category, the stores shown for that month (over the
/// same days as its bar) add up to its bar, and the change line beside "Your patterns" is the
/// change between its bar and the month before's.
@Test(arguments: ["maya", "daniel"])
func pickedMonthMatchesItsBar(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let day = try #require(Int(asOf.suffix(2)))
    let totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: day)
    for category in Set(totals.map(\.category)) {
        let bars = SpendingView.bars(totals, category: category, asOf: asOf)
        #expect(SpendingView.window(bars[3].month, asOf: asOf) == (bars[3].month + "-01", asOf))
        for (index, bar) in bars.enumerated() {
            let window = SpendingView.window(bar.month, asOf: asOf)
            let rows = try ListedTransaction.spending(in: database, category: category, from: window.from, through: window.through)
            let cents = SpendingView.stores(rows).reduce(0) { $0 + Int(($1.total * 100).rounded()) }
            #expect(cents == Int((bar.total * 100).rounded()), "\(persona) \(category) \(bar.month): stores don't add up to the bar")

            // The month before the oldest bar isn't drawn, so its total is read straight from the totals.
            let previous = SpendingView.months(endingAt: bar.month + "-01")[2]
            let before = index > 0 ? bars[index - 1].total
                                   : totals.first { $0.month == previous && $0.category == category }?.total ?? 0
            let line = SpendingView.changeLine(totals, category: category, month: bar.month, isThisMonth: false)
            let name = (bar.month + "-01").displayDate(.dateTime.month(.wide))
            if before > 0 {
                // Whole percents, a half rounded away from zero; a change under half a percent is "+0%".
                let percent = Int(((bar.total - before) / before * 100).rounded())
                let expected = "\(name) · \(String(format: "%+d", percent))% vs \((previous + "-01").displayDate(.dateTime.month(.abbreviated)))"
                #expect(line == expected, "\(persona) \(category) \(bar.month)")
            } else {
                #expect(line == name)
            }
        }
    }
}

/// With nothing spent the month before, the change line names the month and gives no percentage.
@Test func changeLineSkipsAZeroMonthBefore() {
    let totals = [SpendingTotal(month: "2026-05", category: "dining", total: 47)]
    #expect(SpendingView.changeLine(totals, category: "dining", month: "2026-05", isThisMonth: false) == "May")
    #expect(SpendingView.changeLine(totals, category: "dining", month: "2026-06", isThisMonth: true) == "June so far · -100% vs May")
    // A drop under half a percent reads "+0%", never "-0%".
    let tiny = totals + [SpendingTotal(month: "2026-06", category: "dining", total: 46.9)]
    #expect(SpendingView.changeLine(tiny, category: "dining", month: "2026-06", isThisMonth: true) == "June so far · +0% vs May")
}

/// Stepping back from January lands in the year before.
@Test func patternMonthsCrossTheYear() {
    #expect(SpendingView.months(endingAt: "2026-02-14") == ["2025-11", "2025-12", "2026-01", "2026-02"])
}

/// For Maya, each month's bar on the All months screen equals `total_spent` over that whole
/// month, each category's bar equals `total_spent` over all the data, and the money-moved
/// switch adds its own category bar without changing any other bar.
@Test func allMonthsBarsMatchTotalSpent() throws {
    let database = try inMemory("maya") // in memory: running alongside SedgeTests, the shared file would be locked
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, includeMoved: false)
    let months = AllMonthsView.byMonth(totals)
    #expect(months.count >= 6)
    for bar in months {
        // The month's last day: the day before the first of the next month.
        let first = try Date(bar.label + "-01T12:00:00Z", strategy: .iso8601)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let days = try #require(calendar.range(of: .day, in: .month, for: first)).count
        let tool = try totalSpent(nil, bar.label + "-01", bar.label + String(format: "-%02d", days), in: database)
        #expect(abs(bar.total - tool) < 0.005, "\(bar.label): bar \(bar.total), total_spent \(tool)")
    }

    let categories = Set(totals.map(\.category))
    for bar in AllMonthsView.byCategory(totals) {
        let category = try #require(categories.first { SpendingView.title($0) == bar.label })
        let tool = try totalSpent(category, "2000-01-01", asOf, in: database)
        #expect(abs(bar.total - tool) < 0.005, "\(category): bar \(bar.total), total_spent \(tool)")
    }

    let withMoved = try SpendingTotal.all(in: database, includeMoved: true)
    #expect(AllMonthsView.byMonth(withMoved).map(\.total) == months.map(\.total))
    let movedBars = AllMonthsView.byCategory(withMoved)
    #expect(movedBars.contains { $0.label == "Moved between accounts" && $0.total > 0 })
    #expect(movedBars.filter { $0.label != "Moved between accounts" }.map(\.total) == AllMonthsView.byCategory(totals).map(\.total))
}
