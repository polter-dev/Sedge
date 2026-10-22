//
//  SedgeTests.swift
//  SedgeTests
//
//  Created by Marcus Ruth on 9/28/26.
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

// One at a time: several tests reload the same persona file, and two writers at once would lock it.
@Suite(.serialized)
struct SedgeTests {
    /// Each persona and the bank get their own file, and nothing else opens a file.
    @Test func eachChoiceHasItsOwnFile() {
        #expect(SedgeDatabase.fileName(for: "bank") == "sedge.sqlite")
        #expect(SedgeDatabase.fileName(for: "maya") == "sedge-maya.sqlite")
        let personaFiles = Set(Persona.all.compactMap(SedgeDatabase.fileName(for:)))
        #expect(personaFiles.count == Persona.all.count)
        #expect(!personaFiles.contains("sedge.sqlite"))
        #expect(SedgeDatabase.fileName(for: "../maya") == nil)
        #expect(SedgeDatabase.fileName(for: "") == nil)
    }

    /// Opening a persona loads its data with the fixed "today" and organizes it, so the list
    /// shows clean store names next to the raw statement names.
    @Test func openingMayaShowsStoreNames() throws {
        let database = try SedgeDatabase.open("maya")
        #expect(try database.asOf() == Persona.asOf)
        let rows = try ListedTransaction.all(in: database)
        let netflix = rows.filter { $0.name == "NETFLIX.COM" }
        #expect(netflix.count == 6)
        #expect(netflix.allSatisfy { $0.store == "Netflix" && $0.kind == "spending" })
        #expect(rows.contains { $0.kind == "income" })
    }

    /// Stored dates are shown for people on the same day in any time zone, and other text is left alone.
    @Test func datesAreShownForPeople() {
        let shown = "2026-06-30".displayDate()
        #expect(shown.contains("30") && shown.contains("2026") && !shown.contains("-"))
        // A month name, not a number: the style asks for an abbreviated month.
        #expect("2026-01-01".displayDate(.dateTime.month(.abbreviated)) != "1")
        #expect("not a date".displayDate() == "not a date")
    }

    /// The spending, what-if and profile screens each have something to show for every sample person.
    @Test(arguments: Persona.all) func newScreensHaveData(persona: String) throws {
        let database = try SedgeDatabase.open(persona)

        // Money moved between accounts only shows up when the toggle asks for it, and adds to the total.
        let spending = try SpendingTotal.all(in: database, includeMoved: false)
        let withMoved = try SpendingTotal.all(in: database, includeMoved: true)
        #expect(!spending.isEmpty)
        #expect(!spending.contains { $0.category == SpendingTotal.movedCategory })
        #expect(withMoved.contains { $0.category == SpendingTotal.movedCategory && $0.total > 0 })

        // A $400 purchase tomorrow lowers every projected checking balance by $400.
        let whatIf = try #require(try WhatIf.load(database, extra: 400, on: nil))
        let with = try #require(whatIf.with)
        #expect(whatIf.without.count == WhatIf.days)
        #expect(zip(whatIf.without, with).allSatisfy { abs($0.balances[whatIf.account]! - $1.balances[whatIf.account]! - 400) < 0.01 })
        #expect(!whatIf.billDays.isEmpty)

        let facts = try Profile.facts(in: database)
        #expect(facts.contains { $0.kind == "income" && !$0.evidence.isEmpty })
    }

    /// When Plaid connects but the download fails, the bank screen gets its plain line. The
    /// failure is made up here, so the test never needs the quickstart server.
    @Test func syncFailureAfterConnectingShowsMessage() async throws {
        struct DownloadFailed: Error {}
        let database = try SedgeDatabase()
        let failed = await finishConnecting(publicToken: "public-test", database: database,
                                            exchange: { _ in }, sync: { _ in throw DownloadFailed() })
        #expect(failed == bankSyncFailedMessage)
        let worked = await finishConnecting(publicToken: "public-test", database: database,
                                            exchange: { _ in }, sync: { _ in })
        #expect(worked == nil)
    }
}
