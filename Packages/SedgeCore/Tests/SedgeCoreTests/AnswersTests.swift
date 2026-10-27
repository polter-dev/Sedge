import Foundation
import Testing
@testable import SedgeCore

/// The account named `name` in an account_balances answer.
func balanceRow(_ name: String, _ answer: [String: Any]) -> [String: Any]? {
    rows(answer, "accounts").first { $0["name"] as? String == name }
}

/// Each account answer comes back from account_balances, and clearing it removes the field.
@Test func ownerAnswerIsReturnedAndCleared() throws {
    let database = try organizedPersona("maya")
    let account = try #require(try database.dbQueue.read { db in try Account.fetchOne(db) })
    #expect(balanceRow(account.name, try call("account_balances", [:], on: database))?["owner"] == nil)

    for (owner, shown) in [(Answers.Owner.mine, "mine"), (.shared, "shared")] {
        try Answers.setOwner(owner, account: account.account_id, in: database)
        #expect(balanceRow(account.name, try call("account_balances", [:], on: database))?["owner"] as? String == shown)
    }
    // Reloading the data and organizing again (every app launch does both) keeps the answer.
    try loadPersona("maya", into: database)
    try Organizer.organize(database)
    #expect(balanceRow(account.name, try call("account_balances", [:], on: database))?["owner"] as? String == "shared")
    try Answers.setOwner(nil, account: account.account_id, in: database)
    #expect(balanceRow(account.name, try call("account_balances", [:], on: database))?["owner"] == nil)
    #expect(throws: Answers.Failure.notFound("nope")) { try Answers.setOwner(.mine, account: "nope", in: database) }
}

/// The familiar and category answers come back on the transaction's row, and clearing removes them.
@Test func transactionAnswersAreReturnedAndCleared() throws {
    let database = try organizedPersona("daniel")
    // daniel-0128 is the only Corner Cafe charge on May 2.
    let input: [String: Any] = ["merchant": "Corner Cafe", "start_date": "2026-05-02", "end_date": "2026-05-02"]
    func row() throws -> [String: Any] { try #require(rows(try call("find_transactions", input, on: database)).first) }
    #expect(try row()["familiar"] == nil && row()["category"] == nil)

    for (familiar, shown) in [(Answers.Familiar.yes, "yes"), (.notSure, "not_sure")] {
        try Answers.setFamiliar(familiar, transaction: "daniel-0128", in: database)
        #expect(try row()["familiar"] as? String == shown)
    }
    try Answers.setCategory("groceries", transaction: "daniel-0128", in: database)
    #expect(try row()["category"] as? String == "groceries")

    // Reloading the data and organizing again (every app launch does both) keeps the answers.
    try loadPersona("daniel", into: database)
    try Organizer.organize(database)
    #expect(try row()["familiar"] as? String == "not_sure" && row()["category"] as? String == "groceries")

    try Answers.setFamiliar(nil, transaction: "daniel-0128", in: database)
    try Answers.setCategory(nil, transaction: "daniel-0128", in: database)
    #expect(try row()["familiar"] == nil && row()["category"] == nil)
    #expect(throws: Answers.Failure.unknownCategory("snacks")) { try Answers.setCategory("snacks", transaction: "daniel-0128", in: database) }
    #expect(throws: Answers.Failure.notFound("nope")) { try Answers.setFamiliar(.yes, transaction: "nope", in: database) }
}

/// Moving one $48.13 dining charge to groceries moves exactly that much between the two
/// categories, and every total that isn't split by category stays the same.
@Test func categoryAnswerMovesSpending() throws {
    let database = try organizedPersona("daniel")
    let quarters: [String: Any] = ["first_start": "2026-01-01", "first_end": "2026-03-31",
                                   "second_start": "2026-04-01", "second_end": "2026-06-30"]
    func spent(_ category: String?) throws -> Double {
        try call("total_spent", firstHalf(category.map { ["category": $0] } ?? [:]), on: database)["total"] as! Double
    }
    func compared(_ category: String) throws -> [String: Any] {
        try call("compare_periods", quarters.merging(["category": category]) { mine, _ in mine }, on: database)
    }
    func top() throws -> String { Tool.topMerchants.call(Data(#"{"start_date":"2026-01-01","end_date":"2026-06-30","limit":10}"#.utf8), database: database) }

    let before = (dining: try spent("dining"), groceries: try spent("groceries"), all: try spent(nil),
                  diningQuarters: try compared("dining"), groceriesQuarters: try compared("groceries"), top: try top())
    // The charge is a store's dining charge to begin with, or the test proves nothing.
    #expect(rows(try call("total_spent", firstHalf(["category": "dining"]), on: database)).contains { $0["amount"] as? Double == 48.13 })

    try Answers.setCategory("groceries", transaction: "daniel-0128", in: database)

    #expect(try spent("dining") == cents(before.dining - 48.13))
    #expect(try spent("groceries") == cents(before.groceries + 48.13))
    #expect(try spent(nil) == before.all)
    // May 2 is in the second range, so only that side moves.
    let dining = try compared("dining"), groceries = try compared("groceries")
    #expect(dining["first"] as? Double == before.diningQuarters["first"] as? Double)
    #expect(dining["second"] as? Double == cents(before.diningQuarters["second"] as! Double - 48.13))
    #expect(groceries["first"] as? Double == before.groceriesQuarters["first"] as? Double)
    #expect(groceries["second"] as? Double == cents(before.groceriesQuarters["second"] as! Double + 48.13))
    // top_merchants ranks stores, not categories, so the store keeps the charge and nothing changes.
    #expect(try top() == before.top)
}
