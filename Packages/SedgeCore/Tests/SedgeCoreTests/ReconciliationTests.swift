import Foundation
import GRDB
import Testing
@testable import SedgeCore

/// The parts of a persona's answer key these tests grade against.
struct KindKey: Decodable {
    struct Totals: Decodable { var spending: Double; var income: Double }
    struct Label: Decodable { var transaction_id: String; var kind: String; var linked_transaction_id: String? }
    var totals: Totals
    var transactions: [Label]
}

func kindKey(_ persona: String) throws -> KindKey {
    try JSONDecoder().decode(KindKey.self, from: Data(contentsOf: dataDirectory.appending(path: "\(persona)/answer_key.json")))
}

/// Jan to Jun spending (net of refunds) and income, in dollars, from the saved kinds.
/// Summed in whole cents so rounding can't drift; transfers and card payments don't count.
func totals(_ database: SedgeDatabase) throws -> (spending: Double, income: Double) {
    try database.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: """
            SELECT SUM(CASE WHEN kind IN ('spending', 'refund') THEN ROUND(amount * 100) ELSE 0 END),
                   SUM(CASE WHEN kind = 'income' THEN -ROUND(amount * 100) ELSE 0 END)
            FROM transactions WHERE NOT pending AND date BETWEEN '2026-01-01' AND '2026-06-30'
            """)!
        return ((row[0] as Double) / 100, (row[1] as Double) / 100)
    }
}

/// transaction_id -> (kind, linked id) for every transaction the organizer marked as moving
/// money between accounts.
func links(_ database: SedgeDatabase) throws -> [String: String] {
    try database.dbQueue.read { db in
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT transaction_id, kind || ' -> ' || COALESCE(linked_transaction_id, 'nil') FROM transactions
            WHERE kind IN ('transfer', 'card_payment') OR linked_transaction_id IS NOT NULL
            """).map { ($0[0] as String, $0[1] as String) })
    }
}

/// Checks all four personas, as the issue's Done-when asks, so this test may read the
/// held-out answer keys. Nothing here is tuned from them.
@Test(arguments: Persona.all)
func transfersAndCardPaymentsAreLinked(persona: String) throws {
    let key = try kindKey(persona)
    let expected = Dictionary(uniqueKeysWithValues: key.transactions
        .filter { $0.kind == "transfer" || $0.kind == "card_payment" }
        .map { ($0.transaction_id, "\($0.kind) -> \($0.linked_transaction_id ?? "nil")") })
    #expect(!expected.isEmpty)
    // Equal dictionaries: every true pair is found with the right partner, and nothing else is.
    #expect(try links(organizedPersona(persona)) == expected)
}

@Test(arguments: Persona.all)
func totalsMatchTheAnswerKey(persona: String) throws {
    let key = try kindKey(persona)
    let on = try totals(organizedPersona(persona))
    #expect(abs(on.spending - key.totals.spending) < 0.01)
    #expect(abs(on.income - key.totals.income) < 0.01)

    // The "no reconciliation" ablation: report how far its totals move.
    let database = try SedgeDatabase()
    try loadPersona(persona, into: database)
    try Organizer.organize(database, useReconciliation: false)
    let off = try totals(database)
    print(String(format: "%@: without reconciliation, spending %.2f -> %.2f (%+.2f), income %.2f -> %.2f (%+.2f)",
                 persona, on.spending, off.spending, off.spending - on.spending,
                 on.income, off.income, off.income - on.income))
    #expect(try links(database).isEmpty)
}

/// Two cards paid the same amount on the same day: each payment goes to the card its name mentions,
/// and a matching paycheck and store charge without a transfer word stay unpaired.
@Test func sameDayCardPaymentsGoToTheNamedCard() throws {
    func account(_ id: String, _ name: String, _ type: String) -> Account {
        Account(account_id: id, name: name, type: type, balances: Balances())
    }
    func line(_ id: String, _ account: String, _ name: String, _ amount: Double) -> Transaction {
        Transaction(transaction_id: id, account_id: account, date: "2026-03-25", name: name, amount: amount, pending: false)
    }
    let database = try SedgeDatabase()
    try database.save(
        accounts: [account("chk", "Checking", "depository"), account("a", "Card A", "credit"), account("b", "Card B", "credit")],
        transactions: [
            // Card B's side sorts first, so only the name tie-break can get this right.
            line("1-in-b", "b", "PAYMENT RECEIVED THANK YOU", -40),
            line("2-in-a", "a", "PAYMENT RECEIVED THANK YOU", -40),
            line("3-out-a", "chk", "PAYMENT CARD A", 40),
            line("4-out-b", "chk", "PAYMENT CARD B", 40),
            line("5-pay", "chk", "ACME PAYROLL", -12),
            line("6-shop", "a", "VALUE MART", 12),
        ],
        asOf: "2026-03-31")
    try Organizer.organize(database)
    #expect(try links(database) == [
        "3-out-a": "card_payment -> 2-in-a", "2-in-a": "card_payment -> 3-out-a",
        "4-out-b": "card_payment -> 1-in-b", "1-in-b": "card_payment -> 4-out-b",
    ])
}

private func account(_ id: String, _ name: String, _ type: String) -> Account {
    Account(account_id: id, name: name, type: type, balances: Balances())
}
private func line(_ id: String, _ account: String, _ date: String, _ name: String, _ amount: Double) -> Transaction {
    Transaction(transaction_id: id, account_id: account, date: date, name: name, amount: amount, pending: false)
}

/// Two same-amount card payments a day apart, with each card posting on a different lag:
/// the closest date would cross them, so the card named in the payment must win.
@Test func overlappingCardPaymentsWithDifferentLags() throws {
    let database = try SedgeDatabase()
    try database.save(
        accounts: [account("chk", "Checking", "depository"), account("a", "Card A", "credit"), account("b", "Card B", "credit")],
        transactions: [
            line("1-out-a", "chk", "2026-03-20", "PAYMENT CARD A", 40),
            line("2-out-b", "chk", "2026-03-21", "PAYMENT CARD B", 40),
            line("3-in-b", "b", "2026-03-20", "PAYMENT RECEIVED THANK YOU", -40),
            line("4-in-a", "a", "2026-03-21", "PAYMENT RECEIVED THANK YOU", -40),
        ],
        asOf: "2026-03-31")
    try Organizer.organize(database)
    let got = try links(database)
    #expect(got == [
        "1-out-a": "card_payment -> 4-in-a", "4-in-a": "card_payment -> 1-out-a",
        "2-out-b": "card_payment -> 3-in-b", "3-in-b": "card_payment -> 2-out-b",
    ])
}

/// A savings transfer whose inflow posts late must not take the card's same-day inflow.
@Test func transferDoesNotTakeTheCardInflow() throws {
    let database = try SedgeDatabase()
    try database.save(
        accounts: [account("chk", "Checking", "depository"), account("a", "Card A", "credit"), account("sav", "Savings", "depository")],
        transactions: [
            line("1-xfer", "chk", "2026-03-01", "ONLINE TRANSFER TO SAVINGS", 100),
            line("2-card", "chk", "2026-03-02", "PAYMENT CARD A", 100),
            line("3-in-a", "a", "2026-03-02", "PAYMENT RECEIVED THANK YOU", -100),
            line("4-in-sav", "sav", "2026-03-04", "ONLINE TRANSFER FROM CHECKING", -100),
        ],
        asOf: "2026-03-31")
    try Organizer.organize(database)
    let got = try links(database)
    #expect(got == [
        "1-xfer": "transfer -> 4-in-sav", "4-in-sav": "transfer -> 1-xfer",
        "2-card": "card_payment -> 3-in-a", "3-in-a": "card_payment -> 2-card",
    ])
}

/// One account name inside another: "TO TAX SAVINGS" also contains "savings", and
/// "BUSINESS CREDIT CARD" also contains "credit card". Each outflow must go to the longer name
/// it mentions, even when the shorter account's inflow posts closer to it.
@Test(arguments: [("Savings", "Tax Savings", "depository", "transfer"),
                  ("Credit Card", "Business Credit Card", "credit", "card_payment")])
func accountNameInsideAnotherGoesToTheLongerName(short: String, long: String, type: String, kind: String) throws {
    let database = try SedgeDatabase()
    try database.save(
        accounts: [account("chk", "Checking", "depository"), account("short", short, type), account("long", long, type)],
        transactions: [
            line("1-out-long", "chk", "2026-03-01", "ONLINE TRANSFER TO \(long.uppercased())", 100),
            line("2-out-short", "chk", "2026-03-02", "ONLINE TRANSFER TO \(short.uppercased())", 100),
            line("3-in-short", "short", "2026-03-02", "ONLINE TRANSFER FROM CHECKING", -100),
            line("4-in-long", "long", "2026-03-04", "ONLINE TRANSFER FROM CHECKING", -100),
        ],
        asOf: "2026-03-31")
    try Organizer.organize(database)
    #expect(try links(database) == [
        "1-out-long": "\(kind) -> 4-in-long", "4-in-long": "\(kind) -> 1-out-long",
        "2-out-short": "\(kind) -> 3-in-short", "3-in-short": "\(kind) -> 2-out-short",
    ])
}
