//
//  SpendingPatternTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import SwiftUI
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
            let line = SpendingView.changeLine(totals, category: category, month: bar.month)
            if before > 0 {
                // Whole percents, a half rounded away from zero; a change under half a percent is "+0%".
                let percent = Int(((bar.total - before) / before * 100).rounded())
                let expected = "\(String(format: "%+d", percent))% vs \((previous + "-01").displayDate(.dateTime.month(.abbreviated)))"
                #expect(line == expected, "\(persona) \(category) \(bar.month)")
            } else {
                #expect(line == nil)
            }
        }
    }
}

/// With nothing spent the month before, there is no change line.
@Test func changeLineSkipsAZeroMonthBefore() {
    let totals = [SpendingTotal(month: "2026-05", category: "dining", total: 47)]
    #expect(SpendingView.changeLine(totals, category: "dining", month: "2026-05") == nil)
    #expect(SpendingView.changeLine(totals, category: "dining", month: "2026-06") == "-100% vs May")
    // A drop under half a percent reads "+0%", never "-0%".
    let tiny = totals + [SpendingTotal(month: "2026-06", category: "dining", total: 46.9)]
    #expect(SpendingView.changeLine(tiny, category: "dining", month: "2026-06") == "+0% vs May")
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

/// The chart's axis tops out at the largest bar rounded up to the smallest step of 25, 50, 100,
/// 250, 500, 1,000, 2,500, 5,000 … that reaches it in at most 4 steps; a bar on a step stays there.
@Test func axisTopRoundsUpToANiceStep() {
    let cases: [(largest: Double, top: Double)] = [
        (0, 25), (-12, 25), (18.10, 25), (25, 25), (25.01, 50), (99.99, 100), (100, 100), (100.01, 150),
        (442, 500), (486, 500), (500, 500), (500.01, 750), (966, 1_000), (1_000, 1_000), (2_640, 3_000),
        (4_000, 4_000), (4_001, 5_000), (9_999, 10_000), (10_000, 10_000), (10_001, 15_000),
    ]
    for (largest, top) in cases {
        #expect(SpendingView.axisTop(largest) == top, "\(largest)")
    }
}

/// For each persona and month on the chart: the "All" bars are every category's bars added up to
/// the cent, and the mosaic adds up to the page's bar (categories for "All", stores for each
/// category).
@Test(arguments: ["maya", "daniel"])
func allBarsAndMosaicsAddUp(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: try #require(Int(asOf.suffix(2))))
    let categories = Set(totals.map(\.category))
    func cents(_ dollars: Double) -> Int { Int((dollars * 100).rounded()) }
    let all = SpendingView.bars(totals, category: nil, asOf: asOf)
    for (index, bar) in all.enumerated() {
        let sum = categories.reduce(0) { $0 + cents(SpendingView.bars(totals, category: $1, asOf: asOf)[index].total) }
        #expect(cents(bar.total) == sum, "\(persona) \(bar.month): All isn't the categories added up")
        let blocks = SpendingView.categoryBlocks(totals, month: bar.month)
        #expect(blocks.count <= 4)
        #expect(blocks.reduce(0) { $0 + cents($1.total) } == sum, "\(persona) \(bar.month): the All mosaic doesn't add up")
    }
    for category in categories {
        for bar in SpendingView.bars(totals, category: category, asOf: asOf) {
            let window = SpendingView.window(bar.month, asOf: asOf)
            let rows = try ListedTransaction.spending(in: database, category: category, from: window.from, through: window.through)
            #expect(SpendingView.stores(rows).reduce(0) { $0 + cents($1.total) } == cents(bar.total), "\(persona) \(category) \(bar.month)")
        }
    }
}

/// The biggest change from May to June (both over the 1st to the 30th), counted by hand from the
/// transactions: by store within a category, and by category with "All" (nil).
/// Maya's Corner Cafe: $10.40 + $9.11 in June against $9.29 + $8.81 in May, +$1.41. Her Bean
/// Street coffee: $3.72 + $3.99 + $2.32 + $2.68 against $2.79 + $3.51 + $3.75 + $3.80 + $3.12,
/// -$4.26. Her groceries fell most of any category: $86.97 against $115.23, -$28.26. Daniel's
/// Corner Cafe: $212.04 against $167.87, +$44.17; his groceries rose most: $390.17 against
/// $293.89, +$96.28.
@Test(arguments: [
    ("maya", "dining", "Corner Cafe", 141, "+$1 vs May"),
    ("maya", "coffee", "Bean Street Coffee", -426, "-$4 vs May"),
    ("maya", nil, "groceries", -2826, "-$28 vs May"),
    ("daniel", "dining", "Corner Cafe", 4417, "+$44 vs May"),
    ("daniel", nil, "groceries", 9628, "+$96 vs May"),
] as [(String, String?, String, Int, String)])
func biggestChangeMatchesAHandCount(persona: String, category: String?, name: String, cents: Int, text: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    #expect(asOf == "2026-06-30")
    let change: (name: String, cents: Int)?
    if let category {
        let june = try ListedTransaction.spending(in: database, category: category, from: "2026-06-01", through: asOf)
        let may = try ListedTransaction.spending(in: database, category: category, from: "2026-05-01", through: "2026-05-30")
        change = SpendingView.biggestChange(now: SpendingView.cents(june), before: SpendingView.cents(may))
    } else {
        let totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: 30)
        change = SpendingView.categoryChange(totals, asOf: asOf, month: "2026-06")
    }
    #expect(change?.name == name)
    #expect(change?.cents == cents)
    #expect(SpendingView.changeText(cents, before: "2026-05") == text)
}

/// A store that stopped counts as a drop to $0, the first name wins a tie, and no change is none.
@Test func biggestChangeCountsAStoppedStore() {
    let stopped = SpendingView.biggestChange(now: ["A": 500], before: ["A": 400, "B": 300])
    #expect(stopped?.name == "B" && stopped?.cents == -300)
    let tie = SpendingView.biggestChange(now: ["B": 100, "A": 100], before: [:])
    #expect(tie?.name == "A" && tie?.cents == 100)
    #expect(SpendingView.biggestChange(now: ["A": 100], before: ["A": 100]) == nil)
    // Under a dollar keeps the cents, so it never reads "+$0".
    #expect(SpendingView.changeText(40, before: "2026-05") == "+$0.40 vs May")
    #expect(SpendingView.changeText(-5, before: "2026-05") == "-$0.05 vs May")
}

/// On the oldest page (March), "All"'s biggest change skips travel, spent only in February and so
/// not in the category sheet, and names the listed category that changed most instead.
@Test func categoryChangeStaysOnListedCategories() {
    let totals = [SpendingTotal(month: "2026-02", category: "travel", total: 900), SpendingTotal(month: "2026-02", category: "dining", total: 50),
                  SpendingTotal(month: "2026-03", category: "dining", total: 80), SpendingTotal(month: "2026-06", category: "coffee", total: 5)]
    // Without the rule, travel's -$900 would win.
    #expect(SpendingView.biggestChange(now: SpendingView.cents(totals, month: "2026-03"), before: SpendingView.cents(totals, month: "2026-02"))?.name == "travel")
    let change = SpendingView.categoryChange(totals, asOf: "2026-06-30", month: "2026-03")
    #expect(change?.name == "dining" && change?.cents == 3000)
    #expect(SpendingView.categoryOrder(totals, asOf: "2026-06-30", month: "2026-03").contains(change?.name ?? ""))
}

/// For Maya and Daniel, every page's "All" biggest change is the same as comparing every category,
/// so leaving out unlisted categories changes none of their numbers.
@Test(arguments: ["maya", "daniel"])
func categoryChangeKeepsPersonaNumbers(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: 30)
    for month in SpendingView.months(endingAt: asOf) {
        let every = SpendingView.biggestChange(now: SpendingView.cents(totals, month: month),
                                               before: SpendingView.cents(totals, month: SpendingView.monthBefore(month)))
        let listed = SpendingView.categoryChange(totals, asOf: asOf, month: month)
        #expect(listed?.name == every?.name && listed?.cents == every?.cents, "\(persona) \(month)")
    }
}

/// A bar tap or VoiceOver page turn slides by default and jumps with Reduce Motion on.
@Test func pageTurnRespectsReduceMotion() {
    #expect(SpendingView.pageTurn(reduceMotion: true) == nil)
    #expect(SpendingView.pageTurn(reduceMotion: false) == .default)
}

/// The card's low point is the one the Cash flow screen leads with: `CashFlow` loaded for 30 days
/// with nothing switched on, and its lowest day's balance.
@Test(arguments: ["maya", "daniel"])
func cashFlowCardLowPointMatchesTheScreen(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let card = try #require(try CashFlow.load(database))
    let screen = try #require(try CashFlow.load(database, days: 30, purchases: [], changes: []))
    let lowest = try #require(screen.shown.map(screen.balance).min())
    let day = try #require(screen.shown.first { screen.balance($0) == lowest }).date
    let expected = "Low point \(lowest.formatted(.currency(code: "USD"))) · \(day.displayDate(.dateTime.month(.abbreviated).day()))"
    #expect(SpendingView.lowPointLine(card) == expected)
}

/// Mosaic widths follow each block's share and fill the space; a sliver is raised to the minimum.
@Test func mosaicSplitKeepsSmallBlocksReadable() {
    #expect(SpendingView.split([300, 100], length: 404, gap: 4, minimum: 56) == [300, 100])
    let sliver = SpendingView.split([300, 100, 1], length: 408, gap: 4, minimum: 56)
    #expect(sliver[2] == 56)
    #expect(abs(sliver.reduce(0, +) - 400) < 0.001)
    #expect(SpendingView.split([1, 1, 1], length: 100, gap: 5, minimum: 56) == [30, 30, 30])
}

/// The category sheet lists categories most spent first in the page's month (June 1–30 here),
/// a tie by name. Counted by hand from the transactions. Maya: rent $650, groceries $86.97,
/// phone and internet $25 + $35 = $60 and utilities $60 (a tie, so by name), transit $40,
/// dining $19.51, the bookstore $18.82, Netflix $17.99, coffee $12.71. Daniel: mortgage
/// $1,850, groceries $390.17, auto loan $325, dining $212.04, gas $165.06, insurance $125,
/// electric $110, shopping $25.01 + $19.05 + $28.97 = $73.03, internet $70, Netflix $17.99,
/// coffee $11.40.
@Test(arguments: [
    ("maya", ["housing", "groceries", "phone_internet", "utilities", "transport", "dining", "education", "subscriptions", "coffee"]),
    ("daniel", ["housing", "groceries", "loans", "dining", "gas", "insurance", "utilities", "shopping", "phone_internet",
                "subscriptions", "coffee"]),
])
func categorySheetOrderMatchesAHandCount(persona: String, expected: [String]) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, includeMoved: false, throughDay: 30)
    #expect(SpendingView.categoryOrder(totals, asOf: asOf, month: "2026-06") == expected)
}

/// An earlier page sorts by its own month, and a category with nothing that month counts $0.
@Test func categorySheetOrderFollowsThePage() {
    let totals = [SpendingTotal(month: "2026-05", category: "dining", total: 30), SpendingTotal(month: "2026-06", category: "coffee", total: 5),
                  SpendingTotal(month: "2026-06", category: "dining", total: 4)]
    #expect(SpendingView.categoryOrder(totals, asOf: "2026-06-30", month: "2026-06") == ["coffee", "dining"])
    #expect(SpendingView.categoryOrder(totals, asOf: "2026-06-30", month: "2026-05") == ["dining", "coffee"])
}

/// For Maya and Daniel, each month's categories on the All months card add up to that month's
/// bar to the cent, the six-month windows cover every month from the oldest to the newest once,
/// and each category's mini chart months add up to its bar (their data fits in one window).
@Test(arguments: ["maya", "daniel"]) func allMonthsBreakdownsAndWindowsAddUp(persona: String) throws {
    let database = try inMemory(persona) // in memory: running alongside SedgeTests, the shared file would be locked
    // Money moved loaded too, to check the card leaves it out as the month bars do.
    let totals = try SpendingTotal.all(in: database, includeMoved: true)
    #expect(totals.contains { $0.category == SpendingTotal.movedCategory })
    let months = AllMonthsView.byMonth(totals)
    #expect(months.count == 6)
    for month in months {
        let parts = AllMonthsView.breakdown(totals, month: month.label)
        let cents = parts.reduce(0) { $0 + Int(($1.total * 100).rounded()) }
        #expect(cents == Int((month.total * 100).rounded()), "\(persona) \(month.label): categories \(cents), bar \(month.total)")
        #expect(!parts.contains { $0.label == "Moved between accounts" })
    }

    let windows = AllMonthsView.windows(months.map(\.label))
    #expect(windows.allSatisfy { $0.count == 6 })
    #expect(windows.first?.last == months.last?.label)
    // Oldest window first, laid end to end: one run of months, each the one after the last.
    let laidOut = windows.reversed().flatMap { $0 }
    #expect(Set(laidOut).count == laidOut.count, "\(persona): windows overlap")
    for (earlier, later) in zip(laidOut, laidOut.dropFirst()) {
        #expect(SpendingView.months(endingAt: later, count: 2).first == earlier, "\(persona): gap between \(earlier) and \(later)")
    }
    #expect(Set(months.map(\.label)).isSubset(of: Set(laidOut)))

    #expect(windows.count == 1)
    for category in AllMonthsView.byCategory(totals) {
        let cents = AllMonthsView.monthly(totals, category: category.label, months: windows[0])
            .reduce(0) { $0 + Int(($1.total * 100).rounded()) }
        #expect(cents == Int((category.total * 100).rounded()), "\(persona) \(category.label)")
    }
}

/// Windows count back six months at a time from the newest month, across years, and the
/// oldest window still has six months when the data starts partway through it.
@Test func allMonthsWindowsCrossTheYear() {
    #expect(AllMonthsView.windows(["2025-03", "2025-11", "2026-06"]) == [
        ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"],
        ["2025-07", "2025-08", "2025-09", "2025-10", "2025-11", "2025-12"],
        ["2025-01", "2025-02", "2025-03", "2025-04", "2025-05", "2025-06"],
    ])
    #expect(AllMonthsView.windows(["2026-02"]) == [["2025-09", "2025-10", "2025-11", "2025-12", "2026-01", "2026-02"]])
    #expect(AllMonthsView.windows([]).isEmpty)
    let span = AllMonthsView.span(["2025-10", "2025-11", "2025-12", "2026-01", "2026-02", "2026-03"])
    #expect(span.contains("Oct 2025") && span.contains("Mar 2026"), "\(span)")
}
