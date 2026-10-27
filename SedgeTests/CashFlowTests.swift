//
//  CashFlowTests.swift
//  SedgeTests
//

import Foundation
import GRDB
import SedgeCore
import Testing
@testable import Sedge

/// A persona's data in memory, organized, so these tests never touch the files the other tests reopen.
private func inMemory(_ persona: String) throws -> SedgeDatabase {
    let database = try SedgeDatabase()
    try Persona.load(accounts: try #require(Bundle.main.url(forResource: "\(persona).accounts", withExtension: "json")),
                     transactions: try #require(Bundle.main.url(forResource: "\(persona).transactions", withExtension: "json")),
                     into: database)
    try Organizer.organize(database)
    return database
}

/// The lowest projected balance and its day are the simulator's minimum checking balance and the
/// first day it happens, for 30, 60 and 90 days.
@Test(arguments: Persona.all) func lowestIsTheSimulatorsMinimum(persona: String) throws {
    let database = try inMemory(persona)
    for days in [30, 60, 90] {
        let cashFlow = try #require(try CashFlow.load(database, days: days))
        let simulated = try database.dbQueue.read { try Simulator.simulate($0, days: days) }
        let minimum = try #require(simulated.map { $0.balances[cashFlow.account]! }.min())
        let lowest = try #require(cashFlow.lowest(cashFlow.shown))
        #expect(simulated.count == days)
        #expect(lowest.balance == minimum)
        #expect(lowest.date == simulated.first { $0.balances[cashFlow.account] == minimum }?.date)
    }
}

/// Maya pays Netflix and rent from checking, so cancelling Netflix from tomorrow adds back every
/// Netflix charge in the projection, and rent +$200 from tomorrow takes $200 per rent charge.
@Test func scenariosMoveTheEndBalanceByTheirCharges() throws {
    let database = try inMemory("maya")
    for days in [30, 60, 90] {
        let plan = try #require(try CashFlow.load(database, days: days))
        let tomorrow = try #require(plan.without.first?.date)
        let end = plan.balance(try #require(plan.without.last))
        func charged(_ name: String) -> [Double] {
            plan.without.flatMap(\.bills).filter { $0.name == name && $0.account == plan.account }.map(\.amount)
        }
        #expect(plan.bills.contains { $0.name == "Netflix" && $0.isSubscription })
        #expect(plan.bills.first?.name == "Oakwood Apartments Rent")
        // Rent comes out tomorrow and Maya is paid later, so tomorrow is her lowest day.
        #expect(plan.lowReason == "After Oakwood Apartments Rent")

        let cancelled = try #require(try CashFlow.load(database, days: days, changes: [.init(cancelling: "Netflix", from: tomorrow)]))
        let netflix = charged("Netflix")
        #expect(!netflix.isEmpty)
        #expect(abs(cancelled.balance(try #require(cancelled.with?.last)) - end - netflix.reduce(0, +)) < 0.005)

        let raised = try #require(try CashFlow.load(database, days: days,
                                                    changes: [.init(merchant: "Oakwood Apartments Rent", from: tomorrow, by: 200)]))
        let rent = charged("Oakwood Apartments Rent")
        #expect(!rent.isEmpty)
        #expect(abs(raised.balance(try #require(raised.with?.last)) - (end - 200 * Double(rent.count))) < 0.005)
    }
}
