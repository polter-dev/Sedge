import Testing
@testable import SedgeCore

// Today is 2026-06-30, so 2026-05-31 is 30 days back (still counts) and 2026-05-30 is 31 (doesn't).

/// Three April purchases at one store, for a store with a usual: (id prefix, name, amounts).
private func history(_ id: String, _ name: String, _ amounts: [Double]) -> [(String, String, String, Double)] {
    amounts.enumerated().map { ("\(id)\($0.offset)", "2026-04-1\($0.offset)", name, $0.element) }
}

/// A checking and a savings account with the given (id, date, name, amount) checking lines, plus a
/// transfer to savings, organized, with today 2026-06-30.
private func fixture(_ lines: [(String, String, String, Double)], pending: Set<String> = []) throws -> SedgeDatabase {
    let database = try SedgeDatabase()
    let transfer = [Transaction(transaction_id: "xfer-out", account_id: "chk", date: "2026-06-25", name: "TRANSFER TO SAVINGS", amount: 400, pending: false),
                    Transaction(transaction_id: "xfer-in", account_id: "sav", date: "2026-06-25", name: "TRANSFER FROM CHECKING", amount: -400, pending: false)]
    try database.save(
        accounts: [Account(account_id: "chk", name: "Checking", type: "depository", balances: Balances()),
                   Account(account_id: "sav", name: "Savings", type: "depository", balances: Balances())],
        transactions: transfer + lines.map { Transaction(transaction_id: $0.0, account_id: "chk", date: $0.1, name: $0.2, amount: $0.3,
                                                         pending: pending.contains($0.0)) },
        asOf: "2026-06-30")
    try Organizer.organize(database)
    return database
}

@Test func everyEdgeOfTheRule() throws {
    let lines = history("a", "ALPINE HARDWARE", [40, 60, 30]) + [("a-90", "2026-06-20", "ALPINE HARDWARE", 90)] // exactly 1.5× of 60 (and +30)
        + history("b", "BLUE HERON BOOKS", [40, 60, 30]) + [("b-89", "2026-06-20", "BLUE HERON BOOKS", 89.99)] // just under 1.5×
        + history("c", "CEDAR GARDEN SUPPLY", [40, 20, 30]) + [("c-65", "2026-06-20", "CEDAR GARDEN SUPPLY", 65)] // exactly +$25 (and 1.625×)
        + history("d", "DRIFTWOOD OUTFITTERS", [40, 20, 30]) + [("d-64", "2026-06-20", "DRIFTWOOD OUTFITTERS", 64.99)] // just under +$25
        + history("e", "EMBER PIZZA", [10, 10]) + [("e-500", "2026-06-20", "EMBER PIZZA", 500)] // only 2 earlier purchases
        // Only the three just before count: the old $200 doesn't raise the usual above $10.
        + history("f", "FOXGLOVE FLORIST", [200, 10, 10, 10]) + [("f-40", "2026-06-20", "FOXGLOVE FLORIST", 40)]
        + [("g-150", "2026-06-21", "GRANITE CAMERA", 150), // first purchase at exactly $150
           ("h-149", "2026-06-21", "HARBOR LIGHT GIFTS", 149.99), // first purchase just under
           ("i-day30", "2026-05-31", "IRONWOOD FURNITURE", 200), // 30 days back, still counts
           ("j-day31", "2026-05-30", "JUNIPER RUG CO", 200), // 31 days back, too old
           ("k-yes", "2026-06-22", "KESTREL AUDIO", 300), // answered Yes
           ("l-unsure", "2026-06-22", "LANTERN TOOLS", 300), // answered Not sure
           ("m-pay", "2026-06-23", "MERIDIAN PAYROLL DIRECT DEP", -2000), // income
           ("n-pending", "2026-06-29", "NORTHWIND TICKETS", 400)] // still pending
    let database = try fixture(lines, pending: ["n-pending"])
    try Answers.setFamiliar(.yes, transaction: "k-yes", in: database)
    try Answers.setFamiliar(.notSure, transaction: "l-unsure", in: database)
    #expect(try kindOf("xfer-out", database) == "transfer")
    #expect(try kindOf("m-pay", database) == "income")

    let flags = try WorthALook.flagged(in: database)
    // Newest first, ties by id from the end.
    #expect(flags.map(\.transaction_id) == ["g-150", "f-40", "c-65", "a-90", "i-day30"])
    let byID = Dictionary(uniqueKeysWithValues: flags.map { ($0.transaction_id, $0) })
    #expect(byID["a-90"]?.usual == 60 && byID["a-90"]?.reason == "About 1.5× your usual here")
    #expect(byID["c-65"]?.usual == 40)
    #expect(byID["f-40"]?.usual == 10 && byID["f-40"]?.reason == "About 4× your usual here")
    #expect(byID["g-150"]?.usual == nil && byID["g-150"]?.reason == "First purchase here")
    #expect(byID["g-150"]?.store == "Granite Camera")
}

/// Clearing an answer puts the purchase back, and an answered purchase still counts as history.
@Test func answeringRemovesAFlag() throws {
    let database = try fixture([("a", "2026-06-10", "KESTREL AUDIO", 300)])
    #expect(try WorthALook.flagged(in: database).map(\.transaction_id) == ["a"])
    try Answers.setFamiliar(.yes, transaction: "a", in: database)
    #expect(try WorthALook.flagged(in: database).isEmpty)
    try Answers.setFamiliar(nil, transaction: "a", in: database)
    #expect(try WorthALook.flagged(in: database).map(\.transaction_id) == ["a"])
}

/// What each persona's data flags today, printed so it can be checked by hand against the statement
/// names (`swift test --filter worthALookPerPersona`). Jordan and elena are held out, so not here.
/// Otis's one is "CEDAR HOME #041", $86.40 on Jun 17: the organizer groups it with Cedar Cafe by its
/// first word, so it stands against that store's three purchases before it (highest $19.19, May 28).
@Test(arguments: [("maya", [String]()), ("daniel", []), ("nia", []), ("otis", ["otis-0128"])])
func worthALookPerPersona(persona: String, flagged: [String]) throws {
    let flags = try WorthALook.flagged(in: organizedPersona(persona))
    print("\n\(persona): \(flags.count) worth a look")
    for flag in flags { print("  \(flag.date) \(flag.store) \(flag.amount) usual \(flag.usual.map { "\($0)" } ?? "none"): \(flag.reason)") }
    #expect(flags.map(\.transaction_id) == flagged)
}
