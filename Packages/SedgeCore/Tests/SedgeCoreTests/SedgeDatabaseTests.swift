import Foundation
import GRDB
import Testing
@testable import SedgeCore

/// `tools/data`, found from this file's location so the tests run from any directory.
let dataDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "../../../../tools/data")
    .standardized

func loadPersona(_ persona: String, into database: SedgeDatabase) throws {
    let folder = dataDirectory.appending(path: persona)
    try Persona.load(
        accounts: folder.appending(path: "accounts.json"),
        transactions: folder.appending(path: "transactions.json"),
        into: database)
}

func counts(_ database: SedgeDatabase) throws -> (accounts: Int, transactions: Int) {
    try database.dbQueue.read { db in
        (try Account.fetchCount(db), try Transaction.fetchCount(db))
    }
}

@Test(arguments: zip(Persona.all, [130, 184, 208, 154]))
func loadsEachPersona(persona: String, expectedTransactions: Int) throws {
    let database = try SedgeDatabase()
    try loadPersona(persona, into: database)

    // The account count comes straight from the file rather than being typed in here.
    let accountsFile = try Data(contentsOf: dataDirectory.appending(path: "\(persona)/accounts.json"))
    let expectedAccounts = try JSONDecoder().decode([Account].self, from: accountsFile).count

    let saved = try counts(database)
    #expect(saved.transactions == expectedTransactions)
    #expect(saved.accounts == expectedAccounts)
    #expect(try database.asOf() == "2026-06-30")
}

@Test func savingTwiceKeepsTheSameRowCount() throws {
    let database = try SedgeDatabase()
    try loadPersona("maya", into: database)
    try loadPersona("maya", into: database)
    #expect(try counts(database).transactions == 130)
    #expect(try counts(database).accounts == 2)
}

/// A Plaid-shaped sync: a pending charge, then its posted copy, plus Plaid's
/// extra fields (which must be kept) and fields we don't store (which are ignored).
@Test func postedTransactionReplacesItsPendingCopy() throws {
    let json = """
    {
      "accounts": [{"account_id": "acc", "name": "Plaid Checking", "official_name": null, "mask": "0000",
                    "type": "depository", "subtype": "checking",
                    "balances": {"current": 110.0, "available": 100.0, "limit": null,
                                 "iso_currency_code": "USD", "unofficial_currency_code": null}}],
      "transactions": [
        {"transaction_id": "posted", "account_id": "acc", "date": "2026-06-02", "name": "STARBUCKS 123",
         "amount": 4.33, "iso_currency_code": "USD", "pending": false, "pending_transaction_id": "pend",
         "merchant_name": "Starbucks", "location": {"city": null},
         "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": "FOOD_AND_DRINK_COFFEE",
                                       "confidence_level": "VERY_HIGH"}},
        {"transaction_id": "pend", "account_id": "acc", "date": "2026-06-01", "name": "STARBUCKS",
         "amount": 4.33, "iso_currency_code": "USD", "pending": true, "pending_transaction_id": null},
        {"transaction_id": "other", "account_id": "acc", "date": "2026-06-01", "name": "UBER",
         "amount": 9.5, "iso_currency_code": "USD", "pending": true, "pending_transaction_id": null}
      ]
    }
    """
    struct Sync: Decodable { var accounts: [Account]; var transactions: [Transaction] }
    let sync = try JSONDecoder().decode(Sync.self, from: Data(json.utf8))

    let database = try SedgeDatabase()
    try database.save(accounts: sync.accounts, transactions: sync.transactions, asOf: "2026-06-02")
    try database.save(accounts: sync.accounts, transactions: sync.transactions, asOf: "2026-06-02")

    let saved = try database.allTransactions()
    #expect(saved.map(\.transaction_id) == ["posted", "other"])
    #expect(saved[0].merchant_name == "Starbucks")
    #expect(saved[0].personal_finance_category?.detailed == "FOOD_AND_DRINK_COFFEE")
    #expect(try database.dbQueue.read { try Account.fetchOne($0)?.balances.available } == 100.0)
}
