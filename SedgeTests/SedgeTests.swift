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

    /// A nickname is trimmed and capped at 24 characters, and a blank one shows the default name.
    @Test func nicknameRules() {
        #expect(MainView.dataName(choice: "maya", nickname: "") == "Maya")
        #expect(MainView.dataName(choice: "bank", nickname: "   \n") == "Bank")
        #expect(MainView.dataName(choice: "maya", nickname: "  Mo  ") == "Mo")
        #expect(MainView.dataName(choice: "maya", nickname: String(repeating: "a", count: 30)) == String(repeating: "a", count: 24))
        // A cut that lands just after a space doesn't keep the space.
        #expect(MainView.dataName(choice: "maya", nickname: String(repeating: "a", count: 23) + " bcd") == String(repeating: "a", count: 23))
    }

    /// Stored dates are shown for people on the same day in any time zone, and other text is left alone.
    @Test func datesAreShownForPeople() {
        let shown = "2026-06-30".displayDate()
        #expect(shown.contains("30") && shown.contains("2026") && !shown.contains("-"))
        // A month name, not a number: the style asks for an abbreviated month.
        #expect("2026-01-01".displayDate(.dateTime.month(.abbreviated)) != "1")
        #expect("not a date".displayDate() == "not a date")
    }

    /// The spending, cash-flow and profile screens each have something to show for every sample person.
    @Test(arguments: Persona.all) func newScreensHaveData(persona: String) throws {
        let database = try SedgeDatabase.open(persona)

        // Money moved between accounts only shows up when the toggle asks for it, and adds to the total.
        let spending = try SpendingTotal.all(in: database, includeMoved: false)
        let withMoved = try SpendingTotal.all(in: database, includeMoved: true)
        #expect(!spending.isEmpty)
        #expect(!spending.contains { $0.category == SpendingTotal.movedCategory })
        #expect(withMoved.contains { $0.category == SpendingTotal.movedCategory && $0.total > 0 })

        // A $400 purchase tomorrow lowers every projected checking balance by $400.
        let tomorrow = try #require(try CashFlow.load(database)?.without.first?.date)
        let whatIf = try #require(try CashFlow.load(database, purchases: [(400, tomorrow)]))
        let with = try #require(whatIf.with)
        #expect(whatIf.without.count == CashFlow.days)
        #expect(zip(whatIf.without, with).allSatisfy { abs($0.balances[whatIf.account]! - $1.balances[whatIf.account]! - 400) < 0.01 })
        #expect(!whatIf.bills.isEmpty)

        let facts = try Profile.facts(in: database)
        #expect(facts.contains { $0.kind == "income" && !$0.evidence.isEmpty })
    }

    /// Every About you tile, in reading order, as VoiceOver reads it: everything the tile shows.
    /// The amounts are the profile's (tools/personas.md), and the next dates are the simulator's.
    /// Maya is paid every other Friday (Jun 19, then Jul 3). Daniel is paid on the last business
    /// day, which the simulator projects from its latest days (Jun 30, May 29) as Jul 30, not the
    /// real Fri Jul 31: a known limit (docs/assumptions.md, Simulator) that Cash flow shares.
    @Test(arguments: [
        ("maya", ["Income, $520.00, Every two weeks from Bean Street Coffee, about $1,126.67 a month, Next Jul 3",
                  "Housing, Oakwood Apartments Rent, rent, $650.00 a month, Next Jul 1",
                  "Accounts, Credit Card, credit card", "Accounts, Checking, checking"]),
        ("daniel", ["Income, $5,200.00, A month from Northpoint Services Payroll, Next Jul 30",
                    "Loans, Auto Loan Payment, auto, $325.00, Next Jul 7",
                    "Housing, Home Mortgage, mortgage, $1,850.00 a month, Next Jul 1",
                    "Accounts, Card A, credit card", "Accounts, Card B, credit card",
                    "Accounts, Checking, checking", "Accounts, Savings, savings"]),
    ]) func profileTilesKeepEveryValue(persona: String, tiles: [String]) throws {
        let (facts, next) = try ProfileView.load(SedgeDatabase.open(persona))
        #expect(facts.map { ProfileView.spoken($0, next: next) } == tiles)
    }

    /// The tuition tile shows the profile's paid and refunded to the cent: "+back" and "−spent"
    /// when money came back, only what was spent when nothing did. Its chip is the last payment's term.
    @Test func tuitionTileShowsPaidAndRefunded() throws {
        let transactions = """
            [{"transaction_id": "p1", "account_id": "chk", "date": "2026-01-10", "name": "STATE U BURSAR", "amount": 4250.55, "pending": false},
             {"transaction_id": "r1", "account_id": "chk", "date": "2026-02-15", "name": "REFUND STATE U BURSAR", "amount": -1200.30, "pending": false},
             {"transaction_id": "p2", "account_id": "chk", "date": "2026-05-08", "name": "STATE U BURSAR", "amount": 3100.10, "pending": false}]
            """
        let account = #"[{"account_id": "chk", "name": "Checking", "type": "depository", "balances": {}}]"#
        // With reconciliation off the refund is income, so the same payments have nothing back.
        for useReconciliation in [true, false] {
            let database = try SedgeDatabase()
            try database.save(accounts: JSONDecoder().decode([Account].self, from: Data(account.utf8)),
                               transactions: JSONDecoder().decode([Transaction].self, from: Data(transactions.utf8)),
                               asOf: "2026-06-30")
            try Organizer.organize(database, useReconciliation: useReconciliation)
            let tuition = try #require(try Profile.facts(in: database).first { $0.kind == "tuition" })
            #expect(tuition.value.paid == 7350.65 && tuition.value.refunded == (useReconciliation ? 1200.30 : 0))
            #expect(ProfileView.spoken(tuition, next: [:]) == (useReconciliation
                ? "Tuition, State U Bursar, +$1,200.30 back, −$7,350.65 spent, Spring Term"
                : "Tuition, State U Bursar, $7,350.65, spent, Spring Term"))
        }
    }

    /// Tuition's chip is the term of its last payment, by month: Jan–May spring, Jun–Jul summer, Aug–Dec fall.
    @Test func tuitionTermsSplitAtTheirMonths() {
        let terms = ["2026-01-01", "2026-05-31", "2026-06-01", "2026-07-31", "2026-08-01", "2026-12-31"].map(ProfileView.term)
        #expect(terms == ["Spring Term", "Spring Term", "Summer Term", "Summer Term", "Fall Term", "Fall Term"])
        #expect(ProfileView.term("not a date") == nil)
    }

    /// When Plaid connects but the download fails, the bank screen gets its plain line. The
    /// failure is made up here, so the test never needs the quickstart server.
    @Test func syncFailureAfterConnectingShowsMessage() async throws {
        struct DownloadFailed: Error {}
        let database = try SedgeDatabase()
        let failed = await finishConnecting(publicToken: "public-test", institution: "Test Bank", database: database,
                                            exchange: { _ in }, sync: { _ in throw DownloadFailed() })
        #expect(failed == bankSyncFailedMessage)
        let worked = await finishConnecting(publicToken: "public-test", institution: "Test Bank", database: database,
                                            exchange: { _ in }, sync: { _ in })
        #expect(worked == nil)
    }

    /// A Plaid download keeps the bank's statement text as the name, not Plaid's rewritten one,
    /// and falls back to Plaid's name when the original is missing or null.
    @Test func bankImportKeepsTheOriginalDescription() throws {
        let json = """
        {"accounts": [], "transactions": [
          {"transaction_id": "a", "account_id": "x", "date": "2026-06-01", "amount": 15.49, "pending": false,
           "name": "Netflix", "original_description": "NETFLIX.COM", "merchant_name": "Netflix"},
          {"transaction_id": "b", "account_id": "x", "date": "2026-06-02", "amount": 4.5, "pending": false,
           "name": "BEAN ST COFFEE", "original_description": null},
          {"transaction_id": "c", "account_id": "x", "date": "2026-06-03", "amount": 9, "pending": false,
           "name": "SHELL"}
        ]}
        """
        let response = try JSONDecoder().decode(AllTransactionsResponse.self, from: Data(json.utf8))
        #expect(response.transactions.map(\.name) == ["NETFLIX.COM", "BEAN ST COFFEE", "SHELL"])
        #expect(response.transactions[0].merchant_name == "Netflix")
    }
}
