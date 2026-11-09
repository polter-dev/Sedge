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
    let june = TransactionGroups.weeks(rows, month: "2026-06")
    #expect(june.map(\.monday) == ["2026-06-29", "2026-06-22"])
    #expect(june.first?.rows.map(\.id) == ["2"])
    let july = TransactionGroups.weeks(rows, month: "2026-07")
    #expect(july.map(\.monday) == ["2026-06-29"])
    #expect(july.first?.rows.map(\.id) == ["3"])
    #expect(TransactionGroups.months(rows) == ["2026-06", "2026-07"])
}

/// Income is money in; spending, less refunds, is money out (a row with no kind counts as
/// spending); transfers and card payments are in neither, but stay in their week.
@Test func inOutLeavesTransfersOut() throws {
    let rows = [row("7", "2026-06-06", 1, nil), row("6", "2026-06-05", 50, "transfer"), row("5", "2026-06-04", -150.30, "card_payment"),
                row("4", "2026-06-04", 150.30, "card_payment"), row("3", "2026-06-03", -4, "refund"), row("2", "2026-06-02", 10),
                row("1", "2026-06-01", -520, "income")]
    let money = InOut(rows)
    #expect(money.moneyIn == 52000 && money.moneyOut == 700 && money.leftOver == 51300)
    let week = try #require(TransactionGroups.weeks(rows, month: "2026-06").first { $0.monday == "2026-06-01" })
    #expect(week.rows.map(\.id) == ["7", "6", "5", "4", "3", "2", "1"])
    #expect(InOut(week.rows) == money)
}

/// A pending charge is marked pending in the list's rows, and money in and out still count it
/// like a posted one, so showing it as pending changes no sum.
@Test func pendingRowsAreMarkedAndStillCounted() throws {
    let database = try SedgeDatabase()
    let accounts = #"[{"account_id": "a", "name": "Checking", "mask": "4821", "type": "depository", "balances": {"current": 500}}]"#
    let transactions = #"""
        [{"transaction_id": "t1", "account_id": "a", "date": "2026-06-01", "name": "ACME CORP PAYROLL", "amount": -500, "pending": false},
         {"transaction_id": "t2", "account_id": "a", "date": "2026-06-02", "name": "VALUE MART", "amount": 40, "pending": false},
         {"transaction_id": "t3", "account_id": "a", "date": "2026-06-03", "name": "VALUE MART", "amount": 25.5, "pending": true}]
        """#
    try database.save(accounts: JSONDecoder().decode([Account].self, from: Data(accounts.utf8)),
                      transactions: JSONDecoder().decode([Transaction].self, from: Data(transactions.utf8)),
                      asOf: "2026-06-30")
    try Organizer.organize(database)

    let rows = try ListedTransaction.all(in: database)
    #expect(rows.map(\.id) == ["t3", "t2", "t1"])
    #expect(rows.map(\.pending) == [true, false, false])
    // $40.00 + $25.50 out, the pending charge included; $500.00 in.
    #expect(InOut(rows) == InOut(rows.map { ListedTransaction(transaction_id: $0.transaction_id, date: $0.date, store: $0.store, name: $0.name, amount: $0.amount, kind: $0.kind) }))
    #expect(InOut(rows).moneyOut == 6550 && InOut(rows).moneyIn == 50000)
}

/// For maya and daniel and every month: the in/out card and each week header's in and out equal
/// the database's own sums of those rows (income in, spending and refunds out, transfers and card
/// payments in neither), the weeks add up to the month, and every row is listed once, in its week.
@Test(arguments: ["maya", "daniel"]) func monthAndWeekTotalsMatchTheirRows(persona: String) throws {
    let database = try inMemory(persona)
    let rows = try ListedTransaction.all(in: database)
    // The database's own sums in whole cents, by month and Monday (worked out in SQL, not with the app's week math).
    let sums = try database.dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT substr(date, 1, 7) AS month,
                   date(date, '-' || ((CAST(strftime('%w', date) AS INTEGER) + 6) % 7) || ' days') AS monday,
                   -SUM(CASE WHEN kind = 'income' THEN CAST(ROUND(amount * 100) AS INTEGER) ELSE 0 END) AS moneyIn,
                   SUM(CASE WHEN kind = 'income' OR kind IN ('transfer', 'card_payment') THEN 0
                            ELSE CAST(ROUND(amount * 100) AS INTEGER) END) AS moneyOut,
                   COUNT(*) AS count
            FROM transactions GROUP BY 1, 2
            """)
    }
    #expect(rows.count == sums.reduce(0) { $0 + ($1["count"] as Int) })
    let months = TransactionGroups.months(rows)
    #expect(months.count > 1)
    var listed = 0
    for month in months {
        let weeks = TransactionGroups.weeks(rows, month: month)
        let monthSums = sums.filter { $0["month"] == month }
        // The card, summed the way the screen sums it.
        let card = InOut(rows.filter { $0.month == month })
        #expect(card.moneyIn == monthSums.reduce(0) { $0 + ($1["moneyIn"] as Int) }, "\(persona) \(month) in")
        #expect(card.moneyOut == monthSums.reduce(0) { $0 + ($1["moneyOut"] as Int) }, "\(persona) \(month) out")
        #expect(weeks.map(\.monday) == monthSums.map { $0["monday"] as String }.sorted(by: >))
        for week in weeks {
            let sum = try #require(monthSums.first { $0["monday"] == week.monday })
            let header = InOut(week.rows)
            #expect(header.moneyIn == sum["moneyIn"], "\(persona) \(week.monday) in")
            #expect(header.moneyOut == sum["moneyOut"], "\(persona) \(week.monday) out")
            #expect(week.rows.count == sum["count"])
            #expect(week.rows.allSatisfy { TransactionGroups.monday(of: $0.date) == week.monday && $0.month == month })
        }
        // The weeks add up to the month.
        #expect(weeks.reduce(0) { $0 + InOut($1.rows).moneyIn } == card.moneyIn)
        #expect(weeks.reduce(0) { $0 + InOut($1.rows).moneyOut } == card.moneyOut)
        listed += weeks.reduce(0) { $0 + $1.rows.count }
    }
    #expect(listed == rows.count)
}

/// Maya's June, the design's example: In +$1,040.00, Out $966.00, $74.00 left over, and the weeks
/// newest first with $28.19, $24.23, +$520.00 and $118.21, $87.38, then +$520.00 and $707.99. Her
/// Bean Street Coffee rows carry the coffee category, for their dot.
@Test func mayasJuneMatchesTheDesign() throws {
    let rows = try ListedTransaction.all(in: try inMemory("maya"))
    let june = InOut(rows.filter { $0.month == "2026-06" })
    #expect(june.moneyIn == 104000 && june.moneyOut == 96600 && june.leftOver == 7400)
    let weeks = TransactionGroups.weeks(rows, month: "2026-06").map { InOut($0.rows) }
    #expect(weeks.map(\.moneyIn) == [0, 0, 52000, 0, 52000])
    #expect(weeks.map(\.moneyOut) == [2819, 2423, 11821, 8738, 70799])
    #expect(rows.filter { $0.store == "Bean Street Coffee" && $0.kind == "spending" }.allSatisfy { $0.category == "coffee" })
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

/// Merchant history's change reads as Trends' (`SpendingView.changeText`), with "(so far)" only
/// while the data's today isn't its month's last day.
@MainActor @Test func storeChangeTextMatchesTrends() {
    for cents in [-426, 540, -5, 0] {
        #expect(MerchantHistoryView.changeText(cents, lastMonth: "2026-05", asOf: "2026-06-30") == SpendingView.changeText(cents, before: "2026-05"))
        #expect(MerchantHistoryView.changeText(cents, lastMonth: "2026-05", asOf: "2026-06-15") == SpendingView.changeText(cents, before: "2026-05") + " (so far)")
    }
    #expect(MerchantHistoryView.changeText(-426, lastMonth: "2026-05", asOf: "2026-06-29") == "-$4 vs May (so far)")
    // February's last day is the 28th in 2026; July's is the 31st.
    #expect(!MerchantHistoryView.changeText(100, lastMonth: "2026-01", asOf: "2026-02-28").contains("so far"))
    #expect(MerchantHistoryView.changeText(100, lastMonth: "2026-06", asOf: "2026-07-30").hasSuffix("(so far)"))
    #expect(!MerchantHistoryView.changeText(100, lastMonth: "2026-06", asOf: "2026-07-31").contains("so far"))
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
