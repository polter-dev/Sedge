//
//  SpendingPatternTests.swift
//  SedgeTests
//

import Foundation
import GRDB
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
    let totals = try SpendingTotal.all(in: database, throughDay: 30)
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
        let stores = CategoryView.stores(rows)
        let cents = stores.reduce(0) { $0 + Int(($1.total * 100).rounded()) }
        #expect(cents == Int((bars[3].total * 100).rounded()), "\(category): stores don't add up to June")
        // Each store's first row is its latest.
        for store in stores {
            #expect(store.rows.first?.date == store.rows.map(\.date).max())
        }
    }
}

/// For every month on the chart and every category, the stores shown for that month (over the
/// same days as its bar) add up to its bar, and the change line beside the total is the
/// change between its bar and the month before's.
@Test(arguments: ["maya", "daniel"])
func pickedMonthMatchesItsBar(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let day = try #require(Int(asOf.suffix(2)))
    let totals = try SpendingTotal.all(in: database, throughDay: day)
    for category in Set(totals.map(\.category)) {
        let bars = SpendingView.bars(totals, category: category, asOf: asOf)
        #expect(SpendingView.window(bars[3].month, asOf: asOf) == (bars[3].month + "-01", asOf))
        for (index, bar) in bars.enumerated() {
            let window = SpendingView.window(bar.month, asOf: asOf)
            let rows = try ListedTransaction.spending(in: database, category: category, from: window.from, through: window.through)
            let cents = CategoryView.stores(rows).reduce(0) { $0 + Int(($1.total * 100).rounded()) }
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

/// For each persona and month on the chart: the bars are every category's bars added up to the
/// cent, the mosaic of categories adds up to the page's bar, and each category's stores to its bar.
@Test(arguments: ["maya", "daniel"])
func allBarsAndMosaicsAddUp(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, throughDay: try #require(Int(asOf.suffix(2))))
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
            #expect(CategoryView.stores(rows).reduce(0) { $0 + cents($1.total) } == cents(bar.total), "\(persona) \(category) \(bar.month)")
        }
    }
}

/// Every block of the Spending mosaic is its category's color, Other categories in `second`, in
/// each of Maya's and Daniel's four months.
@Test(arguments: ["maya", "daniel"])
func allMosaicBlocksUseTheCategoryColors(persona: String) throws {
    let database = try inMemory(persona)
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, throughDay: try #require(Int(asOf.suffix(2))))
    for month in SpendingView.months(endingAt: asOf) {
        let blocks = SpendingView.categoryBlocks(totals, month: month)
        #expect(!blocks.isEmpty, "\(persona) \(month)")
        for block in blocks {
            let expected = block.name == SpendingView.otherCategories ? Color.second : Color.category(SpendingView.title(block.name))
            #expect(SpendingView.color(block.name) == expected, "\(persona) \(month) \(block.name)")
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
        let totals = try SpendingTotal.all(in: database, throughDay: 30)
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

/// On an earlier page (November to February), "All"'s biggest change picks among that page's
/// categories: travel, spent only in January, fell $900 in February and wins over dining's +$10.
@Test func categoryChangeUsesThePickedPagesCategories() {
    let totals = [SpendingTotal(month: "2026-01", category: "travel", total: 900), SpendingTotal(month: "2026-01", category: "dining", total: 40),
                  SpendingTotal(month: "2026-02", category: "dining", total: 50), SpendingTotal(month: "2026-06", category: "coffee", total: 5)]
    let change = SpendingView.categoryChange(totals, asOf: "2026-06-30", month: "2026-02")
    #expect(change?.name == "travel" && change?.cents == -90000, "\(String(describing: change))")
    #expect(SpendingView.pageEnd(holding: "2026-02", asOf: "2026-06-30") == "2026-02")
    #expect(SpendingView.pageEnd(holding: "2025-11", asOf: "2026-06-30") == "2026-02")
    #expect(SpendingView.pageEnd(holding: "2025-10", asOf: "2026-06-30") == "2025-10")
    #expect(SpendingView.pageEnd(holding: "2026-03", asOf: "2026-06-30") == "2026-06")
}

/// For Maya and Daniel, every page's "All" biggest change is the same as comparing every category,
/// so leaving out unlisted categories changes none of their numbers.
@Test(arguments: ["maya", "daniel"])
func categoryChangeKeepsPersonaNumbers(persona: String) throws {
    let database = try SedgeDatabase.open(persona)
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, throughDay: 30)
    for month in SpendingView.months(endingAt: asOf) {
        let every = SpendingView.biggestChange(now: SpendingView.cents(totals, month: month),
                                               before: SpendingView.cents(totals, month: SpendingView.monthBefore(month)))
        let listed = SpendingView.categoryChange(totals, asOf: asOf, month: month)
        #expect(listed?.name == every?.name && listed?.cents == every?.cents, "\(persona) \(month)")
    }
}

/// A VoiceOver page turn slides by default and jumps with Reduce Motion on.
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

/// The cash-flow card follows the picked month, for today's June and two earlier months: its money
/// in, money out and left over are the Transactions screen's `InOut` of the same days (the 1st
/// through the 30th, February's through its 28th), and its checking balance is the shared
/// wind-back's at the end of that last day, 0, 31 and 122 days before June 30.
@Test(arguments: ["maya", "daniel"])
func cashFlowCardFollowsThePickedMonth(persona: String) throws {
    let database = try inMemory(persona)
    let rows = try ListedTransaction.all(in: database)
    let closing = try #require(try database.dbQueue.read { try Simulator.closingBalances($0, days: 123) })
    for (month, last, back) in [("2026-06", "2026-06-30", 0), ("2026-05", "2026-05-30", 31), ("2026-02", "2026-02-28", 122)] {
        let card = try SpendingView.monthFlow(in: database, month: month, asOf: "2026-06-30")
        let money = InOut(rows.filter { $0.date >= month + "-01" && $0.date <= last })
        #expect(money.moneyOut > 0, "\(persona) \(month)")
        #expect(card.money == money, "\(persona) \(month)")
        #expect(card.money.leftOver == money.moneyIn - money.moneyOut)
        #expect(card.lastDay == last)
        #expect(card.checking == closing[back], "\(persona) \(month)")
    }
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
    let totals = try SpendingTotal.all(in: database, throughDay: 30)
    #expect(SpendingView.categoryOrder(totals, asOf: asOf, month: "2026-06") == expected)
}

/// An earlier page sorts by its own month, and a category with nothing that month counts $0.
@Test func categorySheetOrderFollowsThePage() {
    let totals = [SpendingTotal(month: "2026-05", category: "dining", total: 30), SpendingTotal(month: "2026-06", category: "coffee", total: 5),
                  SpendingTotal(month: "2026-06", category: "dining", total: 4)]
    #expect(SpendingView.categoryOrder(totals, asOf: "2026-06-30", month: "2026-06") == ["coffee", "dining"])
    #expect(SpendingView.categoryOrder(totals, asOf: "2026-06-30", month: "2026-05") == ["dining", "coffee"])
}

/// Largest-remainder rounding keeps the rows on Total where rounding each row is $1 off, either way.
@Test func wholeDollarsAddUpWherePlainRoundingIsOff() {
    // $1.50 + $1.50 + $1.00 = $4.00, but rounded one by one it is $2 + $2 + $1 = $5.
    #expect([150, 150, 100].map(MonthCategoriesSheet.rounded).reduce(0, +) == 5)
    #expect(MonthCategoriesSheet.wholeDollars([150, 150, 100]) == [2, 1, 1])
    // $1.40 + $1.40 + $1.20 = $4.00, but rounded one by one it is $1 + $1 + $1 = $3.
    #expect([140, 140, 120].map(MonthCategoriesSheet.rounded).reduce(0, +) == 3)
    #expect(MonthCategoriesSheet.wholeDollars([140, 140, 120]) == [2, 1, 1])
    // A category refunded more than it spent is rounded the same way, and the rows still add up to $669.
    #expect(MonthCategoriesSheet.wholeDollars([65_000, 1_951, -30]) == [650, 19, 0])
    #expect(MonthCategoriesSheet.wholeDollars([]).isEmpty)
}

/// A transaction the person moved out of Dining into Coffee is listed on Coffee's page, not Dining's.
@Test(arguments: ["maya", "daniel"]) func categoryPageFollowsTheMovedCategory(persona: String) throws {
    let database = try inMemory(persona) // in memory: running alongside SedgeTests, the shared file would be locked
    let dining = try CategoryView.rows(in: database, category: "dining", month: "2026-06", asOf: "2026-06-30")
    let moved = try #require(dining.first)
    try Answers.setCategory("coffee", transaction: moved.id, in: database)
    #expect(try CategoryView.rows(in: database, category: "coffee", month: "2026-06", asOf: "2026-06-30").contains { $0.id == moved.id })
    #expect(try !CategoryView.rows(in: database, category: "dining", month: "2026-06", asOf: "2026-06-30").contains { $0.id == moved.id })
}

/// A span of months is written across the year in UTC, e.g. "Oct 2025 – Mar 2026".
@Test func spanCrossesTheYear() {
    let span = SpendingView.span(["2025-10", "2025-11", "2025-12", "2026-01", "2026-02", "2026-03"])
    #expect(span.contains("Oct 2025") && span.contains("Mar 2026"), "\(span)")
}

/// The month's categories sheet names its days only when they cut a past month short. As of June
/// 30, May (31 days) lists May 1 – 30, while June is "so far" and April (30 days) and February
/// (28 days, its window running past its end) are whole. As of mid-month (June 15) every past
/// month is cut short at the 15th.
@MainActor @Test func monthCategoriesTitleNamesDaysOnlyForCutShortPastMonths() {
    let title = MonthCategoriesSheet.title
    #expect(title("2026-05", "2026-06-30") == "May 1\u{2009}–\u{2009}30, 2026")
    #expect(title("2026-06", "2026-06-30") == "June so far")
    #expect(title("2026-04", "2026-06-30") == "April")
    #expect(title("2026-02", "2026-06-30") == "February")
    #expect(title("2026-05", "2026-06-15") == "May 1\u{2009}–\u{2009}15, 2026")
    #expect(title("2026-04", "2026-06-15") == "Apr 1\u{2009}–\u{2009}15, 2026")
    #expect(title("2026-02", "2026-06-15") == "Feb 1\u{2009}–\u{2009}15, 2026")
    #expect(title("2026-06", "2026-06-15") == "June so far")
}

/// Spending pages for 3, 4, 9, 16 and 24 months of history up to June 2026 (one made-up total a
/// month): the last page ends at June, each page before ends four months earlier, and the
/// earliest page holds the first month with spending.
@Test(arguments: [(3, 1), (4, 1), (9, 3), (16, 4), (24, 6)])
func spendingPagesCoverTheWholeHistory(history: Int, count: Int) throws {
    let asOf = "2026-06-30"
    let months = SpendingView.months(endingAt: asOf, count: history)
    let totals = months.map { SpendingTotal(month: $0, category: "dining", total: 10) }
    let pages = SpendingView.pages(totals, asOf: asOf)
    #expect(pages.count == count)
    #expect(pages.last == "2026-06")
    for (earlier, later) in zip(pages, pages.dropFirst()) {
        #expect(SpendingView.months(endingAt: later, count: 5).first == earlier, "\(history): \(earlier) to \(later)")
    }
    let earliest = SpendingView.months(endingAt: try #require(pages.first))
    #expect(earliest.contains(try #require(months.first)), "\(history): \(earliest)")
}

/// Years under the bar labels: none on a page in today's year, else under the first month and
/// January. No spending at all still has the last page.
@Test func spendingPageYearsShowOnAnEarlierYear() {
    let asOf = "2026-06-30"
    #expect(SpendingView.months(endingAt: "2026-02").map { SpendingView.axisYear($0, pageEnd: "2026-02", asOf: asOf) }
            == ["2025", nil, "2026", nil])
    #expect(SpendingView.months(endingAt: "2025-06").map { SpendingView.axisYear($0, pageEnd: "2025-06", asOf: asOf) }
            == ["2025", nil, nil, nil])
    #expect(SpendingView.months(endingAt: "2026-06").allSatisfy { SpendingView.axisYear($0, pageEnd: "2026-06", asOf: asOf) == nil })
    #expect(SpendingView.pages([], asOf: asOf) == ["2026-06"])
}

/// The dots for 1, 4, 5 and 7 pages on every page, oldest first: which pages have a dot, which
/// dot is filled, and whether the left and right chevrons show. The newest page fills the
/// right-most dot and the earliest the left-most.
@Test func spendingDotsSlideWithThePage() {
    typealias Dots = (dots: Range<Int>, filled: Int, left: Bool, right: Bool)
    let expected: [Int: [Dots]] = [
        1: [(0..<1, 0, false, false)],
        4: (0..<4).map { (0..<4, $0, false, false) },
        5: [(0..<4, 0, false, true), (0..<4, 1, false, true), (1..<5, 1, true, false), (1..<5, 2, true, false), (1..<5, 3, true, false)],
        7: [(0..<4, 0, false, true), (0..<4, 1, false, true), (1..<5, 1, true, true), (2..<6, 1, true, true),
            (3..<7, 1, true, false), (3..<7, 2, true, false), (3..<7, 3, true, false)],
    ]
    for (count, all) in expected {
        #expect(all.count == count)
        for (index, want) in all.enumerated() {
            let got = SpendingView.dotWindow(count: count, index: index)
            #expect(got.dots == want.dots && got.filled == want.filled && got.left == want.left && got.right == want.right,
                    "\(count) pages, page \(index): \(got)")
        }
        #expect(SpendingView.dotWindow(count: count, index: count - 1).filled == min(count, 4) - 1)
        #expect(SpendingView.dotWindow(count: count, index: 0).filled == 0)
    }
}

/// For Maya and Daniel, the bars on the page before the last (November to February) equal the
/// month totals for January and February, each over its 1st to the 30th (all of February):
/// every category's bar and the "All" bar against `total_spent`.
@Test(arguments: ["maya", "daniel"])
func earlierPageBarsMatchTheMonthTotals(persona: String) throws {
    let database = try inMemory(persona) // in memory: running alongside SedgeTests, the shared file would be locked
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, throughDay: 30)
    let pages = SpendingView.pages(totals, asOf: asOf)
    #expect(pages == ["2026-02", "2026-06"])
    for category in [nil] + Set(totals.map(\.category)).sorted() as [String?] {
        let bars = SpendingView.bars(totals, category: category, asOf: pages[0])
        #expect(bars.map(\.month) == ["2025-11", "2025-12", "2026-01", "2026-02"])
        // Before the data starts there is no bar.
        #expect(bars.prefix(2).allSatisfy { $0.total == 0 })
        for (month, end) in [("2026-01", "2026-01-30"), ("2026-02", "2026-02-28")] {
            let bar = try #require(bars.first { $0.month == month })
            let tool = try totalSpent(category, month + "-01", end, in: database)
            #expect(abs(bar.total - tool) < 0.005, "\(persona) \(category ?? "All") \(month): bar \(bar.total), total_spent \(tool)")
        }
    }
}

/// Maya's data starts in January 2026, so January has no month before it to compare with: no
/// Biggest change on Trends or for a category's stores, while February still compares. December,
/// before the data, can't be picked, though it shares January's page.
@Test func firstDataMonthHasNoBiggestChange() throws {
    let database = try inMemory("maya")
    let asOf = "2026-06-30"
    let totals = try SpendingTotal.all(in: database, throughDay: 30)
    let first = try #require(totals.map(\.month).min())
    #expect(first == "2026-01")
    #expect(SpendingView.categoryChange(totals, asOf: asOf, month: first) == nil)
    #expect(SpendingView.categoryChange(totals, asOf: asOf, month: "2026-02") != nil)
    let rows = try CategoryView.rows(in: database, category: "groceries", month: first, asOf: asOf)
    let before = try CategoryView.rows(in: database, category: "groceries", month: "2025-12", asOf: asOf)
    // Without the rule every January store would read as new against an empty December.
    #expect(!rows.isEmpty && SpendingView.biggestChange(now: SpendingView.cents(rows), before: SpendingView.cents(before)) != nil)
    #expect(CategoryView.storeChange(totals, month: first, rows: rows, before: before) == nil)
    #expect(SpendingView.reaches(totals, back: first))
    #expect(!SpendingView.reaches(totals, back: "2025-12"))
    #expect(SpendingView.months(endingAt: SpendingView.pages(totals, asOf: asOf)[0]).contains("2025-12"))
}
