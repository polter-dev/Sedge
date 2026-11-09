//
//  CategoryPageTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

/// For Maya and Daniel, in today's month and the month before, every category's page agrees with
/// Trends: its amount is the root's bar and block, each strip bar is the exact total of that month's
/// first-N-days transactions, and its stores add up to the amount. The month's categories sheet
/// adds up to the root's bar too.
@Test(arguments: ["maya", "daniel"]) func categoryPageMatchesTrends(persona: String) throws {
    let database = try inMemory(persona) // in memory: running alongside SedgeTests, the shared file would be locked
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, throughDay: try #require(Int(asOf.suffix(2))))
    let thisMonth = String(asOf.prefix(7))
    func cents(_ dollars: Double) -> Int { Int((dollars * 100).rounded()) }

    for month in [thisMonth, SpendingView.monthBefore(thisMonth)] {
        let blocks = SpendingView.categoryBlocks(totals, month: month)
        let categories = Set(totals.filter { $0.month == month }.map(\.category))
        #expect(!categories.isEmpty, "\(persona) \(month)")
        for category in categories {
            let label = "\(persona) \(category) \(month)"
            let months = CategoryView.stripMonths(opening: month, asOf: asOf)
            #expect(months.count == 6 && months.contains(month), "\(label)")
            let strip = CategoryView.strip(totals, category: category, months: months)
            let amount = try #require(strip.first { $0.month == month }?.cents, "\(label)")

            // The amount is the root's bar for the month, and its block when it has one of its own.
            #expect(amount == cents(SpendingView.bars(totals, category: category, asOf: month + "-01")[3].total), "\(label)")
            if let block = blocks.first(where: { $0.name == category }) {
                #expect(amount == cents(block.total), "\(label): block")
            }

            // Each strip bar is that month's transactions over its first days, counted from the rows.
            for bar in strip {
                guard let barCents = bar.cents else { continue }
                let rows = try CategoryView.rows(in: database, category: category, month: bar.month, asOf: asOf)
                #expect(barCents == rows.reduce(0) { $0 + $1.cents }, "\(label): strip \(bar.month)")
            }

            let rows = try CategoryView.rows(in: database, category: category, month: month, asOf: asOf)
            let stores = CategoryView.stores(rows)
            #expect(stores.reduce(0) { $0 + cents($1.total) } == amount, "\(label): stores")
            #expect(stores.map(\.total) == stores.map(\.total).sorted(by: >), "\(label): stores not biggest first")

            #expect(rows.map(\.date) == rows.map(\.date).sorted(by: >), "\(label): not newest first")
        }

        // The categories sheet: every category once, biggest first, its whole dollars adding up to the bar.
        let sheet = MonthCategoriesSheet.rows(totals, month: month)
        #expect(Set(sheet.map(\.category)) == categories)
        #expect(Array(sheet.prefix(3).map(\.category)) == Array(blocks.prefix(3).map(\.name)), "\(persona) \(month)")
        #expect(sheet.reduce(0) { $0 + $1.dollars } == MonthCategoriesSheet.rounded(cents(SpendingView.bars(totals, category: nil, asOf: month + "-01")[3].total)))
    }
}

/// Maya's June Groceries page, counted by hand: $87 (Value Mart), down from May, so the question
/// asks why it was lower.
@Test func mayaGroceriesJune() throws {
    let database = try inMemory("maya")
    let asOf = try #require(try database.asOf())
    let totals = try SpendingTotal.all(in: database, throughDay: 30)
    let strip = CategoryView.strip(totals, category: "groceries", months: CategoryView.stripMonths(opening: "2026-06", asOf: asOf))
    #expect(strip.map(\.month) == ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"])
    let rows = try CategoryView.rows(in: database, category: "groceries", month: "2026-06", asOf: asOf)
    #expect(CategoryView.stores(rows).map(\.name) == ["Value Mart"])
    #expect(CategoryView.question(totals, category: "groceries", month: "2026-06") == "Why was groceries lower in June than May?")
}

/// The question chip: higher when the month rose, lower when it fell, and what was spent when it
/// didn't change or the data has no month before. Stored names read as people write them.
@Test func categoryQuestionWording() {
    let totals = [
        SpendingTotal(month: "2026-03", category: "groceries", total: 50),
        SpendingTotal(month: "2026-04", category: "groceries", total: 80),
        SpendingTotal(month: "2026-05", category: "groceries", total: 60.5),
        SpendingTotal(month: "2026-06", category: "groceries", total: 60.5),
        SpendingTotal(month: "2026-06", category: "phone_internet", total: 40),
    ]
    #expect(CategoryView.question(totals, category: "groceries", month: "2026-04") == "Why was groceries higher in April than March?")
    #expect(CategoryView.question(totals, category: "groceries", month: "2026-05") == "Why was groceries lower in May than April?")
    #expect(CategoryView.question(totals, category: "groceries", month: "2026-06") == "What did I spend on groceries in June?")
    #expect(CategoryView.question(totals, category: "groceries", month: "2026-03") == "What did I spend on groceries in March?")
    // Nothing on phone and internet in May counts as $0, so June rose.
    #expect(CategoryView.question(totals, category: "phone_internet", month: "2026-06") == "Why was phone internet higher in June than May?")
}

/// "other" reads as "other things" in both questions; other categories keep their own name.
@Test func otherCategoryQuestionWording() {
    let totals = [
        SpendingTotal(month: "2026-05", category: "other", total: 20),
        SpendingTotal(month: "2026-06", category: "other", total: 35),
        SpendingTotal(month: "2026-06", category: "groceries", total: 60),
    ]
    #expect(CategoryView.question(totals, category: "other", month: "2026-06") == "Why was spending on other things higher in June than May?")
    #expect(CategoryView.question(totals, category: "other", month: "2026-05") == "What did I spend on other things in May?")
    #expect(CategoryView.question(totals, category: "groceries", month: "2026-06") == "Why was groceries higher in June than May?")
}

/// The strip covers the last six months when the opened month is one of them, else the six ending
/// at it, and a month before the data starts has no bar while an empty month after it has $0.
@Test func categoryStripMonthsAndDataStart() {
    #expect(CategoryView.stripMonths(opening: "2026-04", asOf: "2026-06-30") == ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"])
    #expect(CategoryView.stripMonths(opening: "2025-11", asOf: "2026-06-30") == ["2025-06", "2025-07", "2025-08", "2025-09", "2025-10", "2025-11"])
    let totals = [
        SpendingTotal(month: "2026-03", category: "dining", total: 12.34),
        SpendingTotal(month: "2026-05", category: "groceries", total: 20),
    ]
    let strip = CategoryView.strip(totals, category: "groceries", months: CategoryView.stripMonths(opening: "2026-06", asOf: "2026-06-30"))
    #expect(strip.map(\.cents) == [nil, nil, 0, 0, 2000, 0])
}
