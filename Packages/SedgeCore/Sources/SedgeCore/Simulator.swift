import Foundation
import GRDB

/// Projects every account's balance forward one day at a time from the dataset's today:
/// paychecks, bills and scheduled transfers from the organizer's recurring series, card
/// payments worked out from card balances, and a typical day of everyday spending.
/// It reads only the organized database, so it needs `Organizer.organize` first.
public enum Simulator {
    /// How many days back everyday spending is averaged over. Four whole weeks, so every
    /// weekday counts the same number of times.
    public static let trailingDays = 28

    /// A one-off purchase to try out, such as "$400 on Friday".
    public struct Purchase: Sendable {
        /// Dollars, positive.
        public var amount: Double
        /// "YYYY-MM-DD".
        public var date: String
        public var account: String

        public init(amount: Double, date: String, account: String) {
            self.amount = amount
            self.date = date
            self.account = account
        }
    }

    /// A bill or card payment due on a projected day.
    public struct Bill: Sendable {
        public let name: String
        /// The account the money comes out of.
        public let account: String
        public let amount: Double
    }

    /// One projected day.
    public struct Day: Sendable {
        public let date: String
        /// account_id to its balance at the end of the day. For a card, what it owes.
        public let balances: [String: Double]
        /// Bills and card payments that day. Paychecks and transfers aren't bills.
        public let bills: [Bill]
    }

    /// The `days` days after the dataset's today, oldest first.
    public static func simulate(_ db: Database, days: Int, purchases: [Purchase] = []) throws -> [Day] {
        guard let asOf = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'") else {
            throw ToolError("No data has been loaded.")
        }
        let start = try date(asOf)
        let end = calendar.date(byAdding: .day, value: days, to: start)!

        // Today's balances. An account without one can't be projected, so it is left out.
        var balance: [String: Double] = [:], isCard: [String: Bool] = [:], accountName: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT account_id, type, name, json_extract(balances, '$.current') FROM accounts
            WHERE json_extract(balances, '$.current') IS NOT NULL
            """) {
            balance[row[0]] = row[3]
            isCard[row[0]] = (row[1] as String) == "credit"
            accountName[row[0]] = row[2]
        }
        /// Moves money in Plaid's sign: a positive amount lowers a bank balance and raises what a card owes.
        func apply(_ amount: Double, to account: String) {
            guard let card = isCard[account] else { return }
            balance[account]! += card ? amount : -amount
        }

        // Everyday spending: the last four weeks of spending (less refunds) that isn't part of a
        // recurring series, per account, as an amount per day. Transfers and card payments have
        // their own kinds, so they are left out. With reconciliation off the organizer calls them
        // spending, so they are counted here like any purchase: that is the ablation.
        let windowStart = text(calendar.date(byAdding: .day, value: -trailingDays, to: start)!)
        let daily = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT t.account_id, SUM(t.amount) FROM transactions t
            WHERE t.kind IN ('spending', 'refund') AND NOT t.pending AND t.date > ? AND t.date <= ?
              AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.source = t.transaction_id AND e.kind = 'recurring')
            GROUP BY t.account_id
            """, arguments: [windowStart, asOf]).map { ($0[0] as String, ($0[1] as Double) / Double(trailingDays)) })

        // Recurring series: one per merchant, kind and direction, as `recurring_charges` groups them.
        // Card payments are left out here and worked out from the card balances below.
        // SQLite fills the plain columns from the row with the latest date (because of MAX), so
        // `account_id` is the account the series last used.
        var scheduled: [String: [(name: String, account: String, amount: Double, isBill: Bool)]] = [:]
        // How late a charge can be before its series counts as stopped. It reuses the organizer's
        // transfer matching window (3 days) rather than a separate tuned number; change it here if needed.
        let graceStart = calendar.date(byAdding: .day, value: -Organizer.transferWindowDays, to: start)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        let weeks = ["weekly": 1, "biweekly": 2]
        for row in try Row.fetchAll(db, sql: """
            SELECT m.name, t.kind, t.amount > 0 AS outflow, e.cadence, e.typical_amount,
                   MAX(t.date), t.account_id, GROUP_CONCAT(t.date)
            FROM edges e JOIN transactions t ON t.transaction_id = e.source JOIN entities m ON m.id = e.target
            WHERE e.kind = 'recurring' AND t.kind != 'card_payment'
            GROUP BY e.target, t.kind, outflow
            """) {
            let cadence: String = row[3], outflow: Bool = row[2], kind: String = row[1], typical: Double = row[4]
            guard cadence == "monthly" || weeks[cadence] != nil else { continue }
            let latest = try date(row[5])
            // A monthly series is due on the day of the month of its latest charge in a 31-day month,
            // so a bill on the 31st stays on month end (Feb 28, then Mar 31) even when the latest
            // charge was the Feb 28 one. That's also why the dates are worked out here rather than
            // taken from the organizer's next_expected_date, which is the latest charge plus a month.
            let anchor = (row[7] as String).split(separator: ",").map(String.init).filter(inLongMonth).max() ?? row[5]
            let anchorDay = Int(anchor.suffix(2))!
            for k in 1... {
                // Counted from the latest charge each time (not from the previous projected date).
                var day = weeks[cadence].map { calendar.date(byAdding: .day, value: 7 * $0 * k, to: latest)! }
                    ?? monthDay(anchorDay, monthsAfter: k, latest)
                if day > end { break }
                if day <= start {
                    // Due on or before today and not charged yet. Past the grace the series has
                    // probably stopped; within it the charge is just late, so it is projected tomorrow.
                    if day < graceStart { break }
                    day = tomorrow
                }
                scheduled[text(day), default: []].append(
                    (row[0], row[6], outflow ? typical : -typical, outflow && kind == "spending"))
            }
        }

        // Card payments: each card is paid from the account of its latest matched payment (#4), on the
        // day of the month of its latest payment in a 31-day month (so a Feb 28 payment doesn't turn
        // a 31st into a 28th), and the payment is what the card owed at the last month end, less
        // anything already paid since. That is how the fake banks bill.
        // shortcut: assumes every statement closes on the last day of the month and is paid in full;
        // read Plaid's liabilities (statement date and balance) if real cards need it.
        var plans: [String: (payer: String, day: Int)] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT card.account_id, payer.account_id, card.date
            FROM transactions card JOIN transactions payer ON payer.transaction_id = card.linked_transaction_id
            WHERE card.kind = 'card_payment' AND card.account_id IN (SELECT account_id FROM accounts WHERE type = 'credit')
            ORDER BY card.date
            """) {
            // Later rows overwrite earlier ones; the day only from a 31-day month, unless it's the first.
            let paidOn: String = row[2], earlier = plans[row[0]]
            plans[row[0]] = (row[1], earlier == nil || inLongMonth(paidOn) ? Int(paidOn.suffix(2))! : earlier!.day)
        }
        // The last month end on or before today: the day before the first of the month tomorrow is in.
        let monthEnd = calendar.date(byAdding: .day, value: -1, to: calendar.dateInterval(of: .month, for: tomorrow)!.start)!
        // What each card owed at that month end (today's balance with the charges since undone),
        // and what has been paid on it since.
        var statement: [String: Double] = [:], paid: [String: Double] = [:]
        let since = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
            SELECT account_id, SUM(amount), SUM(CASE WHEN kind = 'card_payment' THEN -amount ELSE 0 END)
            FROM transactions WHERE NOT pending AND date > ? AND date <= ? GROUP BY account_id
            """, arguments: [text(monthEnd), asOf]).map { ($0[0] as String, (charged: $0[1] as Double, paid: $0[2] as Double)) })
        for card in plans.keys where balance[card] != nil {
            statement[card] = balance[card]! - (since[card]?.charged ?? 0)
            paid[card] = since[card]?.paid ?? 0
        }

        var result: [Day] = []
        for offset in 1...days {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = text(day)
            var bills: [Bill] = []
            for (account, amount) in daily { apply(amount, to: account) }
            for item in scheduled[key] ?? [] {
                apply(item.amount, to: item.account)
                if item.isBill { bills.append(Bill(name: item.name, account: item.account, amount: cents(item.amount))) }
            }
            for purchase in purchases where purchase.date == key { apply(purchase.amount, to: purchase.account) }
            // A payment day past the end of a short month (the 31st in April) falls on its last day.
            let monthLength = calendar.range(of: .day, in: .month, for: day)!.count
            let dayOfMonth = calendar.component(.day, from: day)
            for (card, plan) in plans where statement[card] != nil && min(plan.day, monthLength) == dayOfMonth {
                let due = cents(statement[card]! - paid[card]!)
                guard due > 0 else { continue }
                apply(-due, to: card)
                apply(due, to: plan.payer)
                paid[card]! += due
                bills.append(Bill(name: "\(accountName[card]!) payment", account: plan.payer, amount: due))
            }
            // At the end of the month's last day the card's next statement closes.
            if dayOfMonth == monthLength {
                for card in statement.keys {
                    statement[card] = balance[card]
                    paid[card] = 0
                }
            }
            result.append(Day(date: key, balances: balance.mapValues(cents), bills: bills))
        }
        return result
    }

    /// One account on one day of a backtest: what the simulator projected and what really happened.
    public struct BacktestRow: Sendable {
        public let persona, cutoff, account, date: String
        public let projected, actual: Double
    }

    /// Pretends today is `cutoff`: loads only what was known then, organizes it, projects `days`
    /// days, and puts each projected balance next to the real one from the full data.
    /// `folder` holds the persona's `accounts.json` and `transactions.json`.
    public static func backtest(persona: String, folder: URL, cutoff: String, days: Int,
                                useReconciliation: Bool) throws -> [BacktestRow] {
        let last = text(calendar.date(byAdding: .day, value: days, to: try date(cutoff))!)
        guard last <= Persona.asOf else {
            throw ToolError("\(cutoff) plus \(days) days ends after the data does (\(Persona.asOf)).")
        }
        let accountsURL = folder.appending(path: "accounts.json"), transactionsURL = folder.appending(path: "transactions.json")
        let database = try SedgeDatabase()
        try Persona.load(accounts: accountsURL, transactions: transactionsURL, into: database, asOf: cutoff)
        try Organizer.organize(database, useReconciliation: useReconciliation)
        let projection = try database.dbQueue.read { db in try simulate(db, days: days) }

        let (accounts, transactions) = try Persona.read(accounts: accountsURL, transactions: transactionsURL)
        return projection.flatMap { day in
            Persona.balances(accounts, transactions, on: day.date).compactMap { account in
                guard let projected = day.balances[account.account_id], let actual = account.balances.current else { return nil }
                return BacktestRow(persona: persona, cutoff: cutoff, account: account.account_id, date: day.date,
                                   projected: projected, actual: actual)
            }
        }
    }

    /// Dates are calendar days with no time zone, so all date math happens in UTC.
    static let calendar = Organizer.calendar

    static func date(_ text: String) throws -> Date { try Date(text + "T00:00:00Z", strategy: .iso8601) }
    static func text(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

    /// The `day`th of the month `months` after `date`'s month, or that month's last day if it is shorter.
    static func monthDay(_ day: Int, monthsAfter months: Int, _ date: Date) -> Date {
        let first = calendar.date(byAdding: .month, value: months, to: calendar.dateInterval(of: .month, for: date)!.start)!
        let length = calendar.range(of: .day, in: .month, for: first)!.count
        return calendar.date(byAdding: .day, value: min(day, length) - 1, to: first)!
    }

    /// Whether "YYYY-MM-DD" falls in a month with 31 days, where any day of the month can happen.
    static func inLongMonth(_ text: String) -> Bool {
        guard let day = try? date(text) else { return false }
        return calendar.range(of: .day, in: .month, for: day)!.count == 31
    }
}
