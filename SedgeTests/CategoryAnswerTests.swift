//
//  CategoryAnswerTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

/// The Spending screen counts a transaction the person moved to another category there.
@Test func spendingScreenUsesTheCategoryAnswer() throws {
    // In memory, so this test never touches the persona files the other tests reopen.
    let database = try SedgeDatabase()
    try Persona.load(accounts: try #require(Bundle.main.url(forResource: "daniel.accounts", withExtension: "json")),
                     transactions: try #require(Bundle.main.url(forResource: "daniel.transactions", withExtension: "json")),
                     into: database)
    try Organizer.organize(database)
    func may(_ category: String) throws -> Double {
        try SpendingTotal.all(in: database, includeMoved: false).first { $0.month == "2026-05" && $0.category == category }?.total ?? 0
    }
    let dining = try may("dining"), groceries = try may("groceries")

    // daniel-0128 is a $48.13 dining charge on May 2.
    try Answers.setCategory("groceries", transaction: "daniel-0128", in: database)
    #expect(abs(try may("dining") - (dining - 48.13)) < 0.005)
    #expect(abs(try may("groceries") - (groceries + 48.13)) < 0.005)
}
