import Foundation
import GRDB

/// "Worth a look": recent purchases the person hasn't said look familiar that stand out at their
/// store, either well above the store's purchases just before them or a large first purchase.
/// It is a spending observation only; nothing here judges a purchase or changes a total.
public enum WorthALook {
    /// How far back from today a purchase is looked at: 30 days back still counts, 31 doesn't.
    static let windowDays = 30
    /// A store needs this many earlier purchases before one can be "above usual", the same three
    /// the Transaction screen compares with; with fewer there is no usual yet.
    static let earlierNeeded = 3
    /// Above usual means at least this many times the highest of those three purchases…
    static let timesUsual = 1.5
    /// …and at least this many dollars more, so a $6 coffee after $3 ones isn't worth a look.
    static let dollarsOverUsual = 25.0
    /// A first purchase at a store is worth a look from this amount; smaller first visits are everyday.
    static let firstPurchaseMinimum = 150.0

    /// One purchase worth a look.
    public struct Flag: Equatable, Sendable {
        public let transaction_id: String
        public let date: String
        /// The organizer's store name.
        public let store: String
        /// Plaid's sign: positive is money out, so always positive here.
        public let amount: Double
        /// The highest of the store's three purchases before it, or nil for a first purchase.
        public let usual: Double?

        /// The one-line reason shown with it: "First purchase here" or "About 2× your usual here".
        public var reason: String {
            guard let usual else { return "First purchase here" }
            return "About \((amount / usual).formatted(.number.precision(.fractionLength(0...1))))× your usual here"
        }
    }

    /// The purchases worth a look, newest first: posted spending dated in the 30 days up to the
    /// dataset's today, with no "Does this look familiar?" answer, that either is at least 1.5× and
    /// at least $25 more than the highest of the same store's three posted purchases just before it,
    /// or is the store's first purchase and is $150 or more. Stores are the organizer's own
    /// grouping (`merchant_id`), and same-day purchases are ordered by id, as in the transactions list.
    public static func flagged(in database: SedgeDatabase) throws -> [Flag] {
        try database.dbQueue.read { db in
            guard let asOf = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'") else { return [] }
            let start = Simulator.text(Simulator.calendar.date(byAdding: .day, value: -windowDays, to: try Simulator.date(asOf))!)
            // Every posted purchase up to today, each store's oldest first, so a purchase's history is the rows before it.
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.merchant_id, t.transaction_id, t.date, m.name AS store, t.amount, t.familiar
                FROM transactions t JOIN entities m ON m.id = t.merchant_id
                WHERE t.kind = 'spending' AND NOT t.pending AND t.date <= ?
                ORDER BY t.merchant_id, t.date, t.transaction_id
                """, arguments: [asOf])
            // Whole cents, so float noise (37.4999999) never decides an exact boundary like 1.5× or +$25.
            let cents = { (dollars: Double) in (dollars * 100).rounded() }
            var flags: [Flag] = []
            var earlier: [Double] = [] // the current store's purchases so far, in cents, oldest first
            for (index, row) in rows.enumerated() {
                if index > 0, rows[index - 1]["merchant_id"] as String != row["merchant_id"] { earlier = [] }
                let amount = cents(row["amount"])
                defer { earlier.append(amount) }
                guard row["date"] as String >= start, row["familiar"] as String? == nil else { continue }
                var usual: Double?
                if earlier.isEmpty {
                    guard amount >= cents(firstPurchaseMinimum) else { continue }
                } else {
                    guard earlier.count >= earlierNeeded, let high = earlier.suffix(earlierNeeded).max(),
                          amount >= timesUsual * high, amount >= high + cents(dollarsOverUsual) else { continue }
                    usual = high / 100
                }
                flags.append(Flag(transaction_id: row["transaction_id"], date: row["date"], store: row["store"],
                                  amount: amount / 100, usual: usual))
            }
            return flags.sorted { ($0.date, $0.transaction_id) > ($1.date, $1.transaction_id) }
        }
    }
}
