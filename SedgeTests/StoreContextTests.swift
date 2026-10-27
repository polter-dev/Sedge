//
//  StoreContextTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

/// The rule behind "Sedge's context" on the transaction screen. On the main actor, like the app's own types.
@MainActor
struct StoreContextTests {
    /// Earlier visits of $8, $14 and $11: above, below and between them, and their range.
    @Test func comparesWithTheLastThreeVisits() {
        let earlier = [8.0, 14.0, 11.0]
        #expect(StoreContext.compare(48, earlier: earlier) == StoreContext(headline: "Higher than your last three visits.", range: "Those were $8.00–$14.00."))
        #expect(StoreContext.compare(5.5, earlier: earlier).headline == "Lower than your last three visits.")
        #expect(StoreContext.compare(11, earlier: earlier).headline == "In line with your last three visits.")
        // Equal to the highest or lowest is still in line, not higher or lower.
        #expect(StoreContext.compare(14, earlier: earlier).headline == "In line with your last three visits.")
        #expect(StoreContext.compare(8, earlier: earlier).headline == "In line with your last three visits.")
        // Float sums like 0.1 + 0.2 still compare equal to 0.30 once in cents.
        #expect(StoreContext.compare(0.1 + 0.2, earlier: [0.3, 0.3, 0.3]) == StoreContext(headline: "In line with your last three visits.", range: "Those were all $0.30."))
        // Only the three newest earlier visits count: a $100 fourth one doesn't widen the range.
        #expect(StoreContext.compare(48, earlier: earlier + [100]).range == "Those were $8.00–$14.00.")
    }

    /// With fewer than three earlier visits there is nothing to compare, and it says so.
    @Test(arguments: [[], [8.0], [8.0, 14.0]]) func fewerThanThreeSaysSo(earlier: [Double]) {
        #expect(StoreContext.compare(48, earlier: earlier) == StoreContext(headline: "Fewer than three earlier visits here, so there’s nothing to compare yet.", range: nil))
    }

    /// The earlier visits come from the same store, before this one, newest first, and leave out
    /// refunds, pending charges and anything after it.
    @Test func earlierChargesAreTheStoresPreviousThree() throws {
        let database = try SedgeDatabase()
        let accounts = """
            [{"account_id": "a", "name": "Checking", "mask": "4821", "type": "depository", "balances": {"current": 500}}]
            """
        // Five visits, a refund, a pending charge, a later visit and another store.
        let rows: [(id: String, date: String, name: String, amount: Double, pending: Bool)] = [
            ("t1", "2026-06-01", "JUNIPER CAFE 004", 9, false),
            ("t2", "2026-06-05", "JUNIPER CAFE 004", 8, false),
            ("t3", "2026-06-09", "JUNIPER CAFE 004", 14, false),
            ("t4", "2026-06-12", "REFUND JUNIPER CAFE 004", -14, false),
            ("t5", "2026-06-15", "JUNIPER CAFE 004", 11, false),
            ("t6", "2026-06-17", "JUNIPER CAFE 004", 30, true),
            ("t7", "2026-06-17", "VALUE MART", 60, false),
            ("t8", "2026-06-19", "JUNIPER CAFE 004", 48, false),
            ("t9", "2026-06-25", "JUNIPER CAFE 004", 12, false),
        ]
        let transactions = "[" + rows.map {
            #"{"transaction_id": "\#($0.id)", "account_id": "a", "date": "\#($0.date)", "name": "\#($0.name)", "amount": \#($0.amount), "pending": \#($0.pending)}"#
        }.joined(separator: ",") + "]"
        try database.save(accounts: JSONDecoder().decode([Account].self, from: Data(accounts.utf8)),
                          transactions: JSONDecoder().decode([Transaction].self, from: Data(transactions.utf8)),
                          asOf: "2026-06-30")
        try Organizer.organize(database)

        let charge = try #require(try TransactionDetail.load("t8", in: database))
        #expect(charge.store == "Juniper Cafe")
        #expect(charge.account == "Checking" && charge.mask == "4821")
        #expect(try charge.earlierCharges(in: database) == [11, 14, 8])
        #expect(StoreContext.compare(charge.amount, earlier: try charge.earlierCharges(in: database))
                == StoreContext(headline: "Higher than your last three visits.", range: "Those were $8.00–$14.00."))

        // The second visit has only one before it.
        let second = try #require(try TransactionDetail.load("t2", in: database))
        #expect(try second.earlierCharges(in: database) == [9])
    }
}
