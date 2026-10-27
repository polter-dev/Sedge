import Foundation
import GRDB
import Testing
@testable import SedgeCore

/// A persona loaded and organized in a fresh in-memory database.
func organizedPersona(_ persona: String, useGraph: Bool = true, asOf: String = Persona.asOf) throws -> SedgeDatabase {
    let database = try SedgeDatabase()
    try loadPersona(persona, into: database, asOf: asOf)
    try Organizer.organize(database, useGraph: useGraph)
    return database
}

/// transaction_id -> merchant_id, as the organizer saved it.
func merchantIDs(_ database: SedgeDatabase) throws -> [String: String] {
    try database.dbQueue.read { db in
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT transaction_id, merchant_id FROM transactions")
            .map { ($0[0] as String, $0[1] as String) })
    }
}

/// Grading uses only the training personas: jordan and elena are held out.
@Test(arguments: ["maya", "daniel"])
func groupingMatchesTheAnswerKey(persona: String) throws {
    struct Key: Decodable { var transactions: [Label] }
    struct Label: Decodable { var transaction_id: String; var true_merchant: String? }
    let file = try Data(contentsOf: dataDirectory.appending(path: "\(persona)/answer_key.json"))
    // Transfers and card payments have no store (true_merchant is null); matching them is #4.
    let labels = try JSONDecoder().decode(Key.self, from: file).transactions.compactMap { label in
        label.true_merchant.map { (id: label.transaction_id, truth: $0) }
    }
    let predicted = try merchantIDs(organizedPersona(persona))

    // Pairwise scoring: every pair of transactions is either grouped together or not,
    // by the organizer and by the answer key. Precision: of the pairs we grouped, how
    // many belong together. Recall: of the pairs that belong together, how many we grouped.
    var bothSame = 0, predictedSame = 0, trulySame = 0
    for i in labels.indices {
        for j in labels.indices where j > i {
            let same = predicted[labels[i].id] == predicted[labels[j].id]
            let truth = labels[i].truth == labels[j].truth
            if same { predictedSame += 1 }
            if truth { trulySame += 1 }
            if same && truth { bothSame += 1 }
        }
    }
    let precision = Double(bothSame) / Double(predictedSame)
    let recall = Double(bothSame) / Double(trulySame)
    print("\(persona): pairwise precision \(precision), recall \(recall)")
    #expect(precision >= 0.95)
    #expect(recall >= 0.95)
}

@Test func mayaRecurringAndBeanStreet() throws {
    let database = try organizedPersona("maya")
    let cadence = { (raw: String) in
        try database.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT e.cadence FROM edges e JOIN transactions t ON t.transaction_id = e.source
                WHERE e.kind = 'recurring' AND t.name = ?
                """, arguments: [raw])
        }
    }
    #expect(try cadence("NETFLIX.COM") == ["monthly"])
    #expect(try cadence("OAKWOOD APARTMENTS RENT") == ["monthly"])
    #expect(try cadence("BEAN STREET COFFEE PAYROLL") == ["biweekly"])
    #expect(try cadence("BEAN STREET COFFEE") == [])

    // Netflix went from 15.49 to 17.99 in April: still one bill, now expected at the new price.
    let netflix = try database.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT typical_amount, next_expected_date FROM edges
            WHERE kind = 'recurring' AND target = 'merchant:netflix' LIMIT 1
            """)
    }
    #expect(netflix?["typical_amount"] == 17.99)
    #expect(netflix?["next_expected_date"] == "2026-07-03")

    let storeOf = try database.dbQueue.read { db in
        try Dictionary(Row.fetchAll(db, sql: "SELECT name, merchant_id FROM transactions").map { ($0[0] as String, $0[1] as String) },
                       uniquingKeysWith: { first, _ in first })
    }
    #expect(storeOf["SQ *BEAN ST COFFEE"] == storeOf["BEANSTREET CAFE"])
    #expect(storeOf["REFUND BEANSTREET CAFE"] == storeOf["BEANSTREET CAFE"])
    #expect(storeOf["SQ *BEAN ST COFFEE"] == "merchant:bean street coffee")
    #expect(storeOf["CITY TRANSIT PASS"] != storeOf["CITY UTILITIES PMT"])

    // Each refund points back at the purchase it reverses (the answer key's link for maya).
    let refunds = try database.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT target FROM edges WHERE kind = 'refund_of' ORDER BY target")
    }
    #expect(refunds == ["maya-0065", "maya-0088"])
}

@Test func categoriesForDaniel() throws {
    let database = try organizedPersona("daniel")
    let categoryOf = try database.dbQueue.read { db in
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT m.name, c.name FROM edges e
            JOIN entities m ON m.id = e.source JOIN entities c ON c.id = e.target
            WHERE e.kind = 'in_category'
            """).map { ($0[0] as String, $0[1] as String) })
    }
    #expect(categoryOf["Amazon"] == "shopping")
    #expect(categoryOf["Value Mart"] == "groceries")
    #expect(categoryOf["Corner Cafe"] == "dining")
    #expect(categoryOf["Home Mortgage"] == "housing")
    #expect(categoryOf["Northpoint Services Payroll"] == "income")
}

@Test func withoutTheGraphEachRawNameIsItsOwnStore() throws {
    let database = try organizedPersona("maya", useGraph: false)
    try database.dbQueue.read { db in
        let rawNames = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT name) FROM transactions")
        let merchants = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entities WHERE kind = 'merchant'")
        let mixed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (SELECT merchant_id FROM transactions GROUP BY merchant_id HAVING COUNT(DISTINCT name) > 1)
            """)
        let links = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE kind IN ('recurring', 'refund_of')")
        #expect(merchants == rawNames)
        #expect(mixed == 0)
        #expect(links == 0)
    }
}

@Test func cleansStatementNames() {
    #expect(Organizer.clean("SQ *BEAN ST COFFEE").name == "bean st coffee")
    #expect(Organizer.clean("TST* CORNER CAFE").name == "corner cafe")
    #expect(Organizer.clean("POS DEBIT VALUE-MART #104").name == "value mart")
    #expect(Organizer.clean("TMOBILE*AUTOPAY").name == "tmobile")
    #expect(Organizer.clean("NETFLIX.COM").name == "netflix")
    #expect(Organizer.clean("SHELL OIL 1234567").name == "shell oil")
    #expect(Organizer.clean("REFUND SHELL SERVICE STATION") == ("shell service station", true))
    #expect(Organizer.sameStore("shell", "shell oil"))
    #expect(!Organizer.sameStore("shell", "shelby diner"))
    #expect(!Organizer.sameStore("home goods", "home mortgage"))
}

/// Two names that tie on count and length must still give the same merchant on every run.
@Test func tieBreakIsDeterministic() {
    #expect(Organizer.sameStore("starbucks", "starbacks"))
    var ids = Set<String>()
    for _ in 0..<200 { ids.insert(Organizer.groupedMerchants(["STARBUCKS", "STARBACKS"])["STARBUCKS"]!.id) }
    #expect(ids.count == 1)
}

/// A processor tag that isn't listed by name is still dropped, keeping the store name after it.
@Test func unlistedProcessorTagKeepsStoreName() {
    #expect(Organizer.clean("DD *DOORDASH").name.contains("doordash"))
}

@Test func unlistedProcessorTagDoesNotMergeStores() {
    let m = Organizer.groupedMerchants(["IC* SAFEWAY", "IC* COSTCO"])
    #expect(m["IC* SAFEWAY"]?.id != m["IC* COSTCO"]?.id)
}

// MARK: - Twice a month

/// recurring_charges for one kind ("income" or "bills"), as "cadence amount next" lines.
func seriesFound(_ database: SedgeDatabase, _ kind: String) throws -> [String] {
    try rows(call("recurring_charges", ["kind": kind], on: database), "series")
        .map { "\($0["cadence"]!) \($0["amount"]!) \($0["next"]!)" }
}

/// How many transactions the organizer put in a recurring series.
func inSeries(_ database: SedgeDatabase) throws -> Int {
    try database.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges WHERE kind = 'recurring'")! }
}

/// Pay on the 15th and the last day, 2026. A weekend moves it to Friday (Feb 13, Jan 30, ...), so
/// Fri Mar 13 to Tue Mar 31 is 18 days, too long for biweekly: it is still one twice-monthly series,
/// and the next pay is the 15th's, a month after Jun 15.
@Test func payOnTheFifteenthAndLastDayIsTwiceMonthly() throws {
    let pay = ["2026-01-15", "2026-01-30", "2026-02-13", "2026-02-27", "2026-03-13", "2026-03-31",
               "2026-04-15", "2026-04-30", "2026-05-15", "2026-05-29", "2026-06-15", "2026-06-30"]
    let database = try seriesDatabase(asOf: "2026-06-30", paydays: pay, paycheck: 800)
    #expect(try seriesFound(database, "income") == ["twice_monthly 800 2026-07-15"])
    #expect(try inSeries(database) == pay.count)
}

/// Pay on the 1st and 15th, 2026, paid the Friday before a weekend: Sun Feb 1 on Fri Jan 30,
/// Sun Mar 1 on Fri Feb 27, Sun Feb 15 on Fri Feb 13. Twice-monthly, not biweekly.
@Test func payOnTheFirstAndFifteenthIsTwiceMonthly() throws {
    let pay = ["2026-01-01", "2026-01-15", "2026-01-30", "2026-02-13", "2026-02-27", "2026-03-13",
               "2026-04-01", "2026-04-15", "2026-05-01", "2026-05-15", "2026-06-01", "2026-06-15"]
    let database = try seriesDatabase(asOf: "2026-06-30", paydays: pay, paycheck: 800)
    #expect(try seriesFound(database, "income") == ["twice_monthly 800 2026-07-01"])
    #expect(try inSeries(database) == pay.count)
}

/// Every 14 days for all of 2026 lands three times in January and July and drifts through the
/// month, so it stays biweekly even though every other paycheck is 28 days apart.
@Test func trueBiweeklyPayStaysBiweekly() throws {
    let start = try Simulator.date("2026-01-02")
    let pay = (0..<26).map { Simulator.text(Simulator.calendar.date(byAdding: .day, value: 14 * $0, to: start)!) }
    #expect(pay.filter { $0.hasPrefix("2026-01") }.count == 3)
    let database = try seriesDatabase(asOf: "2026-12-31", paydays: pay, paycheck: 800)
    #expect(try seriesFound(database, "income") == ["biweekly 800 2027-01-01"])
}

/// A bill on one day of the month stays monthly: every other charge is two months apart.
@Test func monthlyBillOnOneDayStaysMonthly() throws {
    let database = try seriesDatabase(asOf: "2026-06-30", rent: (1...6).map { "2026-0\($0)-03" })
    #expect(try seriesFound(database, "bills") == ["monthly 500 2026-07-03"])
}
