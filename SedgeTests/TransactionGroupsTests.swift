//
//  TransactionGroupsTests.swift
//  SedgeTests
//

import Foundation
import GRDB
import SedgeCore
import Testing
@testable import Sedge

private func row(_ id: String, _ date: String, _ amount: Double, _ kind: String? = "spending") -> ListedTransaction {
    ListedTransaction(transaction_id: id, date: date, store: "Bean Street Coffee", name: "BEAN STREET COFFEE", amount: amount, kind: kind)
}

/// Weeks start on Monday: Tue Jun 30 and Sun Jul 5 2026 are in Mon Jun 29's week, Sun Jun 28 is in Mon Jun 22's.
@Test func weeksStartOnMonday() {
    #expect(TransactionGroups.monday(of: "2026-06-29") == "2026-06-29")
    #expect(TransactionGroups.monday(of: "2026-06-30") == "2026-06-29")
    #expect(TransactionGroups.monday(of: "2026-07-05") == "2026-06-29")
    #expect(TransactionGroups.monday(of: "2026-06-28") == "2026-06-22")
    // Across a year end: Fri Jan 1 2027 is in Mon Dec 28 2026's week.
    #expect(TransactionGroups.monday(of: "2027-01-01") == "2026-12-28")
    #expect(TransactionGroups.label(monday: "2026-06-15") == "Jun 15 – 21")
    #expect(TransactionGroups.label(monday: "2026-06-29") == "Jun 29 – Jul 5")
}

/// A week that crosses into July holds only June's days in June, and only July's in July.
@Test func aWeekAcrossMonthsHoldsOnlyTheShownMonth() throws {
    let rows = [row("3", "2026-07-02", 5), row("2", "2026-06-30", 2.68), row("1", "2026-06-24", 3.72)]
    let june = try #require(TransactionGroups.parts(rows, month: "2026-06").first)
    #expect(june.part == .spending)
    #expect(june.weeks.map(\.monday) == ["2026-06-29", "2026-06-22"])
    #expect(june.weeks.first?.rows.map(\.id) == ["2"])
    let july = try #require(TransactionGroups.parts(rows, month: "2026-07").first)
    #expect(july.weeks.map(\.monday) == ["2026-06-29"])
    #expect(july.weeks.first?.rows.map(\.id) == ["3"])
    #expect(TransactionGroups.months(rows) == ["2026-06", "2026-07"])
}

/// Income, Spending (with refunds) and Transfers (with card payments) go to their own parts, in that order.
@Test func kindsGoToTheirParts() {
    let rows = [row("1", "2026-06-01", -520, "income"), row("2", "2026-06-02", 10), row("3", "2026-06-03", -4, "refund"),
                row("4", "2026-06-04", 150.30, "card_payment"), row("5", "2026-06-04", -150.30, "card_payment"),
                row("6", "2026-06-05", 50, "transfer"), row("7", "2026-06-06", 1, nil)]
    let parts = TransactionGroups.parts(rows, month: "2026-06")
    #expect(parts.map(\.part) == [.income, .spending, .transfers])
    #expect(parts.map { $0.rows.map(\.id) } == [["1"], ["2", "3", "7"], ["4", "5", "6"]])
    #expect(parts.map(\.cents) == [-52000, 700, 5000])
}

/// For maya and daniel, every month's Income, Spending and Transfers totals equal the sum of
/// their rows straight from the database, the week totals add up to them, and every row is listed once.
@Test(arguments: ["maya", "daniel"]) func monthTotalsMatchTheirRows(persona: String) throws {
    let database = try inMemory(persona)
    let rows = try ListedTransaction.all(in: database)
    // The database's own sums, in whole cents, by month and part.
    let sums = try database.dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT substr(date, 1, 7) AS month,
                   CASE WHEN kind = 'income' THEN 'Income'
                        WHEN kind IN ('transfer', 'card_payment') THEN 'Transfers'
                        ELSE 'Spending' END AS part,
                   SUM(CAST(ROUND(amount * 100) AS INTEGER)) AS cents, COUNT(*) AS count
            FROM transactions GROUP BY 1, 2
            """)
    }
    var listed = 0
    let months = TransactionGroups.months(rows)
    #expect(months.count > 1)
    for month in months {
        let parts = TransactionGroups.parts(rows, month: month)
        for part in parts {
            let sum = try #require(sums.first { $0["month"] == month && $0["part"] == part.part.rawValue })
            #expect(part.cents == sum["cents"], "\(persona) \(month) \(part.part)")
            #expect(part.rows.count == sum["count"])
            #expect(part.weeks.reduce(0) { $0 + $1.cents } == part.cents)
            #expect(part.weeks.allSatisfy { week in week.rows.allSatisfy { TransactionGroups.monday(of: $0.date) == week.monday && $0.month == month } })
            listed += part.weeks.reduce(0) { $0 + $1.rows.count }
        }
        #expect(parts.count == sums.filter { $0["month"] == month }.count)
    }
    #expect(listed == rows.count)
}

/// Merchant history's card: this month's total, visit count and smallest-to-largest visit, from
/// the store's purchases only (the design's Bean Street Coffee example, plus the pay the café
/// sends Maya, which is no visit), the first purchase's date, and six months of bars.
@Test func storeSummaryUsesThisMonthsPurchases() throws {
    let rows = [row("8", "2026-06-30", 2.68), row("7", "2026-06-26", -520, "income"), row("6", "2026-06-22", 3.72),
                row("5", "2026-06-15", 3.99), row("4", "2026-06-09", 2.32), row("3", "2026-05-28", 3.51),
                row("2", "2026-05-04", 3.80), row("1", "2026-05-01", -520, "income")]
    let bars = zip(["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"], [0, 0, 0, 0, 731, 1271]).map { StoreSummary.Bar(month: $0, cents: $1) }
    #expect(StoreSummary(rows, asOf: "2026-06-30") == StoreSummary(cents: 1271, visits: 4, range: "$2.32–$3.99", allVisits: 6, allCents: 2002,
                                                                   first: "2026-05-04", bars: bars))
    #expect(StoreSummary(rows, asOf: "2026-06-30")?.change == 540)
    let july = try #require(StoreSummary(rows, asOf: "2026-07-15"))
    #expect(july.cents == 0 && july.visits == 0 && july.range == "–" && july.change == -1271)
    #expect(july.bars.map(\.month) == ["2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07"])
    // The six months step back across a year end.
    #expect(StoreSummary(rows, asOf: "2027-02-01")?.bars.map(\.month) == ["2026-09", "2026-10", "2026-11", "2026-12", "2027-01", "2027-02"])
    #expect(StoreSummary([row("1", "2026-06-01", 5)], asOf: "2026-06-30")?.range == "$5.00")
    #expect(StoreSummary([row("1", "2026-06-01", -520, "income")], asOf: "2026-06-30") == nil)
}

/// Maya's Bean Street Coffee, the design's example: $12.71 in June, $4.26 less than May, and the
/// six bars $10.25, $10.66, $13.96, $12.02, $16.97 and $12.71 ($76.57 in all over 26 visits).
/// Her pay from the café and its two refunds are left out.
@Test func mayasBeanStreetMatchesTheDesign() throws {
    let database = try inMemory("maya")
    let id = try #require(try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT id FROM entities WHERE name = 'Bean Street Coffee'") })
    let asOf = try #require(try database.asOf())
    let summary = try #require(StoreSummary(try ListedTransaction.all(in: database, merchant: id), asOf: asOf))
    #expect(summary.cents == 1271)
    #expect(summary.change == -426)
    #expect(summary.bars.map(\.cents) == [1025, 1066, 1396, 1202, 1697, 1271])
    #expect(summary.allCents == 7657 && summary.allVisits == 26)
}

/// For every store maya and daniel bought from: the big total is the store's purchases in the
/// as-of month straight from the database, the change is this month minus last month, the six
/// bars are each month's sum, and each month's week groups add up to that month, every purchase once.
@Test(arguments: ["maya", "daniel"]) func merchantHistoryMatchesItsRows(persona: String) throws {
    let database = try inMemory(persona)
    let asOf = try #require(try database.asOf())
    // The database's own purchase sums, in whole cents, by store and month.
    let sums = try database.dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT merchant_id, substr(date, 1, 7) AS month, SUM(CAST(ROUND(amount * 100) AS INTEGER)) AS cents
            FROM transactions WHERE kind = 'spending' AND merchant_id IS NOT NULL GROUP BY 1, 2
            """)
    }
    let sum = { (store: String, month: String) -> Int in sums.first { $0["merchant_id"] == store && $0["month"] == month }?["cents"] ?? 0 }
    let stores = Set(sums.map { $0["merchant_id"] as String })
    #expect(stores.count >= 2)
    for store in stores {
        let rows = try ListedTransaction.all(in: database, merchant: store)
        let summary = try #require(StoreSummary(rows, asOf: asOf))
        let months = summary.bars.map(\.month)
        #expect(months.last == String(asOf.prefix(7)))
        #expect(summary.cents == sum(store, String(asOf.prefix(7))), "\(persona) \(store)")
        #expect(summary.change == sum(store, months[5]) - sum(store, months[4]))
        #expect(summary.bars.map(\.cents) == months.map { sum(store, $0) })
        let purchases = rows.filter { $0.kind == "spending" }
        var listed = 0
        for (month, weeks) in TransactionGroups.monthWeeks(purchases) {
            #expect(weeks.reduce(0) { $0 + $1.cents } == sum(store, month), "\(persona) \(store) \(month)")
            #expect(weeks.allSatisfy { week in week.rows.allSatisfy { TransactionGroups.monday(of: $0.date) == week.monday && $0.month == month } })
            #expect(weeks.map(\.monday) == weeks.map(\.monday).sorted(by: >))
            listed += weeks.reduce(0) { $0 + $1.rows.count }
        }
        #expect(listed == purchases.count)
    }
}
