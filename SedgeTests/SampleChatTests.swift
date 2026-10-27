//
//  SampleChatTests.swift
//  SedgeTests
//

import Foundation
import GRDB
import SedgeCore
import Testing
@testable import Sedge

/// The sample conversation compares the same days of earlier months, cut short when a month is.
@Test func monthToDateKeepsTheSameDays() {
    #expect(ChatTurn.monthToDate("2026-06-30", monthsBack: 0) == ("2026-06-01", "2026-06-30"))
    #expect(ChatTurn.monthToDate("2026-06-30", monthsBack: 1) == ("2026-05-01", "2026-05-30"))
    #expect(ChatTurn.monthToDate("2026-03-31", monthsBack: 1) == ("2026-02-01", "2026-02-28"))
    #expect(ChatTurn.monthToDate("2026-01-15", monthsBack: 3) == ("2025-10-01", "2025-10-15"))
}

/// The sample's quick check asks about June's largest transfer or card payment, even when more
/// than 10 rows of $100 or more come after it (Jordan).
@Test(arguments: ["maya", "daniel", "jordan", "elena"])
func transferCheckPicksLargestJuneMove(persona: String) throws {
    let database = try SedgeDatabase()
    try Persona.load(accounts: try #require(Bundle.main.url(forResource: "\(persona).accounts", withExtension: "json")),
                     transactions: try #require(Bundle.main.url(forResource: "\(persona).transactions", withExtension: "json")),
                     into: database)
    try Organizer.organize(database)
    let best = try database.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT date, amount FROM transactions
            WHERE date BETWEEN '2026-06-01' AND '2026-06-30' AND kind IN ('transfer','card_payment') AND amount > 0
            ORDER BY amount DESC LIMIT 1
            """)
    }
    let quick = try ChatTurn.sample(in: database).answer.quickCheck
    guard let best else { #expect(quick == nil); return }
    let amount: Double = best["amount"], date: String = best["date"]
    #expect(quick?.factKey == "own_transfer_\(date)")
    #expect(quick?.question.contains(amount.formatted(.currency(code: "USD"))) == true)
}
