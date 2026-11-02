import Foundation
import GRDB

/// Ways to save: the person's flexible stores, ranked by how little they seem to value each one
/// ("revealed preference": what people keep buying when money is tight is what they value).
/// Each suggestion is to stop spending at one store, worth its average monthly spending.
/// Fixed obligations are never suggested: rent, mortgage, bills, tuition, loan payments, and
/// card payments or transfers between the person's own accounts.
public enum Savings {
    /// One suggested cut.
    public struct Cut: Codable, Equatable, Sendable {
        public let store: String
        public let category: String
        /// Everything spent at the store (less refunds) divided by the months in the data.
        public let per_month: Double
        /// The value score, 0 to 1: lower means the person seems to value this store less.
        public let value: Double
        /// What the score was worked out from, e.g. "bought in 6 of 25 weeks; 40% of usual in low-balance weeks".
        public let evidence: String
    }

    /// The cuts for one goal, least-valued first, and whether they reach it.
    public struct Plan: Codable, Equatable, Sendable {
        public let goal_per_month: Double
        public let cuts: [Cut]
        public let total_per_month: Double
        public let reached: Bool
        /// Missing when the goal is reached.
        public let short_by: Double?
        public let note: String?
    }

    /// At most this many cuts, so the answer stays short.
    static let maxCuts = 5

    /// Store categories that are bills by nature, so never cut. Education is included so a
    /// student's books and fees are never suggested, not only tuition.
    static let fixedCategories: Set<String> = ["housing", "utilities", "phone_internet", "insurance", "loans", "education", "income"]
    /// Categories of everyday choices, which stay cuttable even on a schedule (a subscription, a
    /// weekly coffee). A recurring store in any other category (transport, other) is taken as a bill.
    static let everydayCategories: Set<String> = ["subscriptions", "coffee", "dining", "groceries", "gas", "shopping"]

    /// The cuts for a goal of `goal` dollars a month, from the app's database.
    public static func plan(in database: SedgeDatabase, goal: Double) throws -> Plan {
        try database.dbQueue.read { db in try plan(db, goalPerMonth: goal) }
    }

    /// One posted spending or refund transaction, with its store and the store's category.
    private struct Line: Decodable, FetchableRecord {
        let merchant, store, category, date: String
        let cents: Int
    }

    static func plan(_ db: Database, goalPerMonth goal: Double) throws -> Plan {
        let ranked = try ranked(db)
        // Cuts are taken in ranked order until they reach the goal, at most `maxCuts`.
        var cuts: [Cut] = []
        for cut in ranked where cuts.count < maxCuts && sum(cuts) < cents(goal) { cuts.append(cut) }
        let total = sum(cuts)
        let reached = total >= cents(goal)
        let note = reached ? nil : sum(ranked) < cents(goal)
            ? "Can't reach the goal without cutting bills." : "Short of the goal within \(maxCuts) cuts."
        return Plan(goal_per_month: cents(goal), cuts: cuts, total_per_month: total, reached: reached,
                    short_by: reached ? nil : cents(cents(goal) - total), note: note)
    }

    /// Every flexible store the person still shops at, as a cut, least valued first.
    static func ranked(_ db: Database) throws -> [Cut] {
        guard let asOf = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'"),
              let earliest = try String.fetchOne(db, sql: "SELECT MIN(date) FROM transactions WHERE NOT pending") else {
            throw ToolError("No data has been loaded.")
        }
        let today = try Simulator.date(asOf)
        /// How many days before today a "YYYY-MM-DD" day is (0 is today).
        func daysBack(_ date: String) throws -> Int {
            Simulator.calendar.dateComponents([.day], from: try Simulator.date(date), to: today).day!
        }
        // Whole weeks of data, counted back from today: week 0 is the last 7 days. Days before the
        // oldest whole week still count toward the monthly average, just not toward the weekly parts.
        let weeks = (try daysBack(earliest) + 1) / 7
        guard weeks >= 4 else { throw ToolError("Needs at least 4 weeks of transactions.") }
        // Months the data covers, counted the way the profile counts them for income (a part month counts).
        let months = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT substr(date, 1, 7)) FROM transactions WHERE NOT pending")!

        // Stores that are fixed obligations, by name: the profile's rent, mortgage, tuition and loans
        // (including the person's own corrections), so a landlord or lender with an unusual name is caught.
        let obligations = Set(try Profile.facts(db).filter { ["housing", "tuition", "loan"].contains($0.kind) }
            .map { $0.value.name.lowercased() })
        // Stores with a recurring series of charges. Outside the everyday categories, a steady charge
        // on a schedule (a phone plan, a transit pass, software) is a bill.
        let recurring = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT e.target FROM edges e JOIN transactions t ON t.transaction_id = e.source
            WHERE e.kind = 'recurring' AND t.kind = 'spending'
            """))
        // Only spending and refunds: transfers and card payments are never spending, so never cut.
        let lines = try Line.fetchAll(db, sql: """
            SELECT t.merchant_id AS merchant, m.name AS store, COALESCE(c.name, 'other') AS category, t.date,
                   CAST(ROUND(t.amount * 100) AS INTEGER) AS cents
            FROM transactions t JOIN entities m ON m.id = t.merchant_id
            LEFT JOIN edges e ON e.kind = 'in_category' AND e.source = t.merchant_id
            LEFT JOIN entities c ON c.id = e.target
            WHERE t.kind IN ('spending', 'refund') AND NOT t.pending
            ORDER BY t.date, t.transaction_id
            """).filter { line in
                !fixedCategories.contains(line.category) && !obligations.contains(line.store.lowercased())
                    && (everydayCategories.contains(line.category) || !recurring.contains(line.merchant))
            }
        // Only habits the person still has: bought in at least 2 calendar months, and at least once in the
        // last 60 days. Stopping at a store bought from once, or not lately, saves nothing from now on.
        let stores = try Dictionary(grouping: lines, by: \.merchant).filter { _, group in
            let purchases = group.filter { $0.cents > 0 }
            let recent = try purchases.contains { try daysBack($0.date) <= 60 }
            return group.map(\.cents).reduce(0, +) > 0 && Set(purchases.map { $0.date.prefix(7) }).count >= 2 && recent
        }

        // Every day of data, today included, for the tight-stretch rate below.
        let days = try daysBack(earliest) + 1
        // Tight days (as days back from today), or nil with no bank balance to tell them from others.
        let tight = try tightDays(db, today: today, days: days, daysBack: daysBack)
        let largest = stores.values.map { $0.map(\.cents).reduce(0, +) }.max() ?? 1

        var ranked: [Cut] = []
        // Sorted, so stores that tie on everything below still come out in the same order every run.
        for key in stores.keys.sorted() {
            let group = stores[key]!, first = group[0]
            let net = group.map(\.cents).reduce(0, +)
            // Spending on tight days (refunds included), and the whole weeks with a purchase.
            var lean = 0
            var bought = Set<Int>()
            for line in group {
                let back = try daysBack(line.date)
                if tight?.contains(back) == true { lean += line.cents }
                if line.cents > 0 && back / 7 < weeks { bought.insert(back / 7) }
            }
            // The value score is the average of three parts, each from 0 to 1:
            //  - kept up: spending per day in the tight stretches as a share of the store's usual
            //    spending per day (over all the data), capped at 1. Spending kept up when money is
            //    short is valued; spending dropped then is easy to give up. With no bank balance it
            //    is 0.5, so it moves no store up or down.
            //  - regular: the share of weeks with a purchase. A habit is valued; a rare buy is not.
            //  - size: this store's spending as a share of the biggest flexible store's. A big share
            //    of what the person chooses to spend shows they value it.
            // `net` is above 0 for every store kept, so the usual rate is never a division by zero.
            let kept = tight.map { tight in min(1, max(0, Double(lean) / Double(tight.count) / (Double(net) / Double(days)))) } ?? 0.5
            let regular = Double(bought.count) / Double(weeks)
            let size = Double(net) / Double(largest)
            let value = ((kept + regular + size) / 3 * 100).rounded() / 100
            let evidence = "bought in \(bought.count) of \(weeks) weeks"
                + (tight == nil ? "" : "; \(Int((kept * 100).rounded()))% of usual in low-balance weeks")
            ranked.append(Cut(store: first.store, category: first.category, per_month: cents(Double(net) / 100 / Double(months)),
                              value: value, evidence: evidence))
        }
        // Least valued first; on a tie the bigger saving, then the store name, so every run gives the same order.
        return ranked.sorted { ($0.value, -$0.per_month, $0.store) < ($1.value, -$1.per_month, $1.store) }
    }

    /// Monthly amounts added up in whole cents.
    private static func sum(_ cuts: [Cut]) -> Double { cents(cuts.map(\.per_month).reduce(0, +)) }

    /// The tight days, as days back from today (0 is today), or nil with no bank balance.
    /// In each calendar month the tight stretch is the 7 days in a row, inside that month, whose
    /// end-of-day checking balances add up lowest; a tie goes to the earlier stretch, and a month
    /// with under 7 days of data has none. It is per month, not the lowest weeks of all the data,
    /// because balances drift (they rise over the half-year for every persona): the lowest weeks
    /// overall would all be early ones and measure early spending, not spending when money is short.
    /// Each day's closing balance is found by undoing, from today's balance, every posted
    /// transaction after it.
    private static func tightDays(_ db: Database, today: Date, days: Int, daysBack: (String) throws -> Int) throws -> Set<Int>? {
        // The same account simulate_balance and the cash-flow screen use.
        guard let checking = try Row.fetchOne(db, sql: """
            SELECT account_id, ROUND(json_extract(balances, '$.current') * 100) FROM accounts
            WHERE type = 'depository' AND json_extract(balances, '$.current') IS NOT NULL
            ORDER BY subtype = 'checking' DESC, name LIMIT 1
            """) else { return nil }
        // Cents that left (positive) or came into (negative) the account, per day back from today.
        var moved = Array(repeating: 0, count: days)
        for row in try Row.fetchAll(db, sql: "SELECT date, CAST(ROUND(amount * 100) AS INTEGER) FROM transactions WHERE account_id = ? AND NOT pending",
                                    arguments: [checking[0] as String]) {
            let back = try daysBack(row[0])
            if back >= 0 && back < moved.count { moved[back] += row[1] as Int }
        }
        // Walking back a day adds back what left that day: Plaid's positive amount lowered the balance.
        var balance = checking[1] as Int
        var closing = Array(repeating: 0, count: days)
        for back in 0..<days {
            closing[back] = balance
            balance += moved[back]
        }
        // Days grouped by calendar month ("YYYY-MM"), each month's days oldest first.
        let months = Dictionary(grouping: (0..<days).reversed()) { back in
            Simulator.text(Simulator.calendar.date(byAdding: .day, value: -back, to: today)!).prefix(7)
        }
        var tight = Set<Int>()
        for month in months.values where month.count >= 7 {
            // Each start leaves 6 more days in the month; the lowest total wins, then the earlier start.
            let total = { (start: Int) in month[start..<start + 7].map { closing[$0] }.reduce(0, +) }
            let start = (0...month.count - 7).min { (total($0), $0) < (total($1), $1) }!
            tight.formUnion(month[start..<start + 7])
        }
        return tight
    }
}

// MARK: - The savings tool (#19)

extension Tool {
    static let savingsOptions = Tool(
        name: "savings_options",
        description: "Ways to save toward a goal: up to 5 stores to stop spending at, least valued first (bought rarely, "
            + "dropped in low-balance weeks, small). Never bills, rent, loans, tuition or transfers.",
        inputs: [ToolInput(name: "goal_amount", kind: .number, description: "Dollars to save each month, or in total by by_date.", required: true),
                 dateInput("by_date", "Day to have saved goal_amount in total, after today. Leave out for a monthly goal", required: false)],
        run: { input, db in
            var goal = input.number("goal_amount")!
            if let byDate = input.text("by_date") {
                guard let asOf = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'") else {
                    throw ToolError("No data has been loaded.")
                }
                let days = Simulator.calendar.dateComponents([.day], from: try Simulator.date(asOf), to: try Simulator.date(byDate)).day!
                guard days > 0 else { throw ToolError("by_date is not after today.", hint: "Pick a day after \(asOf), or leave it out.") }
                // A goal by a date is spread evenly, a month being 30 days: $300 in 45 days is $200 a month.
                goal = goal * 30 / Double(days)
            }
            // Checked after the spread: a huge goal becomes infinity once turned into cents, and the reply can't hold that.
            guard goal > 0, cents(goal).isFinite else { throw ToolError("Bad value for \"goal_amount\".", hint: "A positive amount in dollars.") }
            return try Savings.plan(db, goalPerMonth: goal)
        })
}
