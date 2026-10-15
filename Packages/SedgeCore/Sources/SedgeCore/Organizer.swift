import Foundation
import GRDB

/// Turns raw statement names into a merchant graph: cleaned store names, one
/// merchant per store, a category per merchant, refund links and recurring charges.
/// It works only from each transaction's raw `name`, date, amount and account
/// (plus Plaid's category as an optional hint when matching transfers).
public enum Organizer {
    /// Two cleaned names at least this similar (0 to 1, from edit distance) are one store.
    /// 0.8 lets "beanstreet cafe" join "bean street coffee" (0.81) but keeps
    /// "home goods" and "home mortgage" apart. Tuned on maya and daniel only.
    public static let similarityThreshold = 0.8

    /// Word replacements for what similarity can't catch. Kept short on purpose.
    static let aliases = ["amzn": "amazon", "st": "street"]

    /// Card-processor tags in front of the store name: Square ("SQ *"), Toast ("TST*"),
    /// DoorDash ("DD *"), PayPal ("PAYPAL *"), point-of-sale ("POS DEBIT"), and similar.
    /// Any one to three letters before a "*" count as a tag, so unlisted processors work too.
    /// shortcut: a store whose own name is three letters or fewer ("ATT*BILL") loses its
    /// name to what follows the "*"; add it as an exception if real data shows one.
    static let processorPrefix = #"^(?:(?:[a-z]{1,3}|paypal)\s*\*|pos(?:\s+(?:debit|purchase))?\s+)\s*"#

    /// Category keywords, checked in this order; the first list with a whole-word match wins.
    /// Order matters: "amazon prime membership" is a subscription before it is shopping.
    static let categoryKeywords: [(category: String, words: [String])] = [
        ("income", ["payroll", "salary", "direct deposit", "dir dep"]),
        ("housing", ["rent", "mortgage", "apartments", "apartment", "property management", "hoa"]),
        ("utilities", ["utilities", "utility", "electric", "water", "power", "energy"]),
        ("phone_internet", ["comcast", "xfinity", "verizon", "tmobile", "att", "spectrum", "internet", "wireless"]),
        ("insurance", ["insurance", "geico", "progressive", "allstate", "state farm"]),
        ("loans", ["loan", "navient", "sallie mae"]),
        ("subscriptions", ["netflix", "spotify", "hulu", "disney", "prime", "membership", "subscription", "youtube"]),
        ("education", ["tuition", "university", "college", "campus", "bookstore", "books", "school"]),
        ("coffee", ["coffee", "espresso", "starbucks", "dunkin"]),
        ("dining", ["restaurant", "pizza", "grill", "diner", "burger", "taco", "sushi", "kitchen", "doordash", "grubhub", "mcdonalds", "chipotle"]),
        ("groceries", ["grocery", "groceries", "supermarket", "market", "kroger", "safeway", "aldi", "trader joes", "whole foods"]),
        ("gas", ["shell", "chevron", "exxon", "mobil", "bp", "fuel", "gas", "service station"]),
        ("transport", ["transit", "uber", "lyft", "metro", "parking", "toll", "bus", "train"]),
        ("shopping", ["amazon", "target", "walmart", "costco", "home goods", "homegoods", "ebay", "etsy"]),
    ]

    /// A price may move this much between two charges and still be the same bill,
    /// e.g. a subscription going from 15.49 to 17.99 (+16%).
    static let priceChangeAllowance = 0.25

    /// Allowed gaps in days between charges for each cadence. Monthly is wide
    /// because months are 28 to 31 days and "last business day" pay moves around.
    static let cadences: [(name: String, days: ClosedRange<Int>)] = [
        ("weekly", 6...8), ("biweekly", 12...16), ("monthly", 26...35),
    ]

    /// The two sides of a transfer may post up to this many days apart: banks often
    /// show the money arriving a day or two after it left.
    static let transferWindowDays = 3

    /// Whole words in a statement name that say money is moving between accounts.
    static let transferWords: Set<String> = ["payment", "transfer", "xfer", "pmt", "pymt", "autopay"]

    /// Rebuilds the graph from the saved transactions, replacing any earlier result.
    /// `useGraph: false` is the "no graph" ablation: each raw statement name is its own
    /// store, and nothing is linked as recurring or as a refund.
    /// `useReconciliation: false` is the "no reconciliation" ablation: no card payments or
    /// transfers are matched, and every transaction is spending or income by its sign.
    public static func organize(_ database: SedgeDatabase, useGraph: Bool = true, useReconciliation: Bool = true) throws {
        try database.dbQueue.write { db in
            // Only the columns the organizer is allowed to use.
            let lines = try Row.fetchAll(db, sql: """
                SELECT transaction_id, account_id, date, name, amount FROM transactions
                ORDER BY date, transaction_id
                """).map { Line(id: $0[0], account: $0[1], date: $0[2], raw: $0[3], amount: $0[4]) }

            try db.execute(sql: "DELETE FROM edges")
            try db.execute(sql: "DELETE FROM entities")
            try db.execute(sql: "INSERT INTO entities (id, kind, name) SELECT 'account:' || account_id, 'account', name FROM accounts")

            // Which merchant each raw name belongs to, as (entity id, display name).
            let merchantOf = useGraph ? groupedMerchants(lines.map(\.raw)) : rawMerchants(Set(lines.map(\.raw)))
            let byMerchant = Dictionary(grouping: lines) { merchantOf[$0.raw]!.id }

            for (merchantID, merchantLines) in byMerchant {
                try db.execute(sql: "INSERT INTO entities (id, kind, name) VALUES (?, 'merchant', ?)",
                               arguments: [merchantID, merchantOf[merchantLines[0].raw]!.name])
                let category = category(of: merchantLines.map { clean($0.raw).name })
                try db.execute(sql: "INSERT OR IGNORE INTO entities (id, kind, name) VALUES (?, 'category', ?)",
                               arguments: ["category:" + category, category])
                try addEdge(db, merchantID, "in_category", "category:" + category)

                for line in merchantLines {
                    try addEdge(db, line.id, "at_merchant", merchantID)
                    try addEdge(db, line.id, "from_account", "account:" + line.account)
                    try db.execute(sql: "UPDATE transactions SET merchant_id = ? WHERE transaction_id = ?",
                                   arguments: [merchantID, line.id])
                }
                guard useGraph else { continue }

                // A refund points at the latest earlier purchase of the same amount at the same store.
                let purchases = merchantLines.filter { !clean($0.raw).isRefund && $0.amount > 0 }
                for refund in merchantLines where clean(refund.raw).isRefund {
                    if let original = purchases.last(where: { $0.date <= refund.date && abs($0.amount + refund.amount) < 0.005 }) {
                        try addEdge(db, refund.id, "refund_of", original.id)
                    }
                }

                // Money out and money in are separate series: a coffee shop can also be the employer.
                // shortcut: one series per direction per merchant, so a subscription mixed with
                // one-off buys at the same store (e.g. a membership plus orders) isn't found;
                // split by amount band if that shows up in real data.
                let regular = merchantLines.filter { !clean($0.raw).isRefund }
                for series in [regular.filter { $0.amount > 0 }, regular.filter { $0.amount < 0 }] {
                    guard let found = try recurrence(of: series) else { continue }
                    for line in series {
                        try addEdge(db, line.id, "recurring", merchantID,
                                    cadence: found.cadence, typicalAmount: found.typicalAmount, nextDate: found.nextDate)
                    }
                }
            }
            try reconcile(db, useReconciliation: useReconciliation)
        }
    }

    /// Sets every transaction's `kind`, and links the two sides of each card payment and
    /// own-account transfer through `linked_transaction_id`. Without this, paying a card
    /// would count the same money twice: once at the store, once as the payment.
    static func reconcile(_ db: Database, useReconciliation: Bool) throws {
        /// One transaction plus the facts about its account that matching needs.
        struct Side {
            let id, account, accountType, accountName, raw: String
            let amount: Double
            let day: Int // days since 1970, so two dates subtract to a gap in days
            let hint: String? // Plaid's detailed category, nil in the fake data
        }
        let sides = try Row.fetchAll(db, sql: """
            SELECT t.transaction_id, t.account_id, a.type, a.name, t.name, t.amount, t.date,
                   json_extract(t.personal_finance_category, '$.detailed')
            FROM transactions t JOIN accounts a USING (account_id)
            ORDER BY t.date, t.transaction_id
            """).map { row in
                let date = try Date((row[6] as String) + "T00:00:00Z", strategy: .iso8601)
                return Side(id: row[0], account: row[1], accountType: row[2], accountName: row[3], raw: row[4],
                            amount: row[5], day: Int(date.timeIntervalSince1970 / 86_400), hint: row[7])
            }

        // Start from the sign: money out is spending, money in is income or, when the
        // name says so, a refund. The ablation stops here, so its refunds count as income.
        var kind: [String: String] = [:], partner: [String: String] = [:]
        for side in sides {
            kind[side.id] = side.amount >= 0 ? "spending" : useReconciliation && clean(side.raw).isRefund ? "refund" : "income"
        }

        if useReconciliation {
            // The name ("PAYMENT CREDIT CARD") or Plaid's category must say it's a transfer,
            // so a paycheck and a store charge that happen to match aren't paired.
            func looksLikeTransfer(_ side: Side) -> Bool {
                if let hint = side.hint, hint.hasPrefix("TRANSFER_") || hint == "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" { return true }
                return !transferWords.isDisjoint(with: side.raw.lowercased().split { !$0.isLetter }.map(String.init))
            }
            let inflows = sides.filter { kind[$0.id] == "income" }
            // Money leaving one account pairs with the same amount arriving in another of this
            // person's accounts (one database is one person) within a few days.
            // The first pass only pairs an outflow with the account its name mentions
            // ("PAYMENT CARD A" with "Card A", "TRANSFER TO SAVINGS" with "Savings"), so another
            // same-amount move that posts on a closer date can't take that inflow. The second
            // pass pairs what is left by closest date. Oldest first, and each side is used once.
            // Names are compared as whole words: " card a " is not inside " card autopay ".
            // The spaces at both ends let a name match at the start or end of the text.
            func wordText(_ text: String) -> String {
                " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
            }
            // Longest first, so "tax savings" is checked before "savings". Of two names the same
            // length, the alphabetically last goes first, so every run picks the same one.
            let accountNames = Set(sides.map { wordText($0.accountName) }).sorted { ($0.count, $0) > ($1.count, $1) }
            // The longest other account the outflow's name mentions. The first match wins, so
            // "TO TAX SAVINGS" names Tax Savings, not Savings. The outflow's own name is cut out
            // when found, so "FROM TAX SAVINGS TO HSA" on Tax Savings names HSA, not Savings.
            func namedAccount(_ out: Side) -> String? {
                var text = wordText(out.raw)
                let own = wordText(out.accountName)
                for name in accountNames where text.contains(name) {
                    if name != own { return name }
                    text = text.replacingOccurrences(of: name, with: " ")
                }
                return nil
            }
            for namedOnly in [true, false] {
                for out in sides where out.amount > 0 && partner[out.id] == nil {
                    let named = namedAccount(out)
                    let candidates = inflows.filter { inflow in
                        partner[inflow.id] == nil && inflow.account != out.account
                            && abs(inflow.amount + out.amount) < 0.005 && abs(inflow.day - out.day) <= transferWindowDays
                            && (looksLikeTransfer(out) || looksLikeTransfer(inflow))
                            && (!namedOnly || wordText(inflow.accountName) == named)
                    }
                    guard let inflow = candidates.min(by: { abs($0.day - out.day) < abs($1.day - out.day) }) else { continue }
                    partner[out.id] = inflow.id
                    partner[inflow.id] = out.id
                    let pairKind = out.accountType == "credit" || inflow.accountType == "credit" ? "card_payment" : "transfer"
                    kind[out.id] = pairKind
                    kind[inflow.id] = pairKind
                }
            }
        }

        for side in sides {
            try db.execute(sql: "UPDATE transactions SET kind = ?, linked_transaction_id = ? WHERE transaction_id = ?",
                           arguments: [kind[side.id], partner[side.id], side.id])
        }
    }

    /// The columns of one transaction the organizer reads.
    struct Line {
        let id, account, date, raw: String
        let amount: Double
    }

    /// Lowercases a raw statement name and strips what isn't the store's name:
    /// a "REFUND" prefix (reported separately), processor tags, ".com",
    /// descriptors after "*", store numbers and ids, and punctuation.
    /// "SQ *BEAN ST COFFEE" becomes "bean st coffee"; "VALUE-MART #104" becomes "value mart".
    static func clean(_ raw: String) -> (name: String, isRefund: Bool) {
        var text = raw.lowercased()
        let isRefund = text.hasPrefix("refund ")
        if isRefund { text.removeFirst("refund ".count) }
        text = text.replacingOccurrences(of: processorPrefix, with: "", options: .regularExpression)
        // With the processor tag gone, a "*" separates store from descriptor: "TMOBILE*AUTOPAY".
        if let star = text.firstIndex(of: "*") { text = String(text[..<star]) }
        text = text.replacingOccurrences(of: #"\.(com|net|org)\b"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "'", with: "") // "joe's" and "joes" match
        text = text.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        // Store numbers and trailing ids are the words with a digit in them ("104", "x1234").
        let name = text.split(separator: " ").filter { !$0.contains(where: \.isNumber) }.joined(separator: " ")
        // If nothing is left (a name made only of numbers), keep the raw text rather than "".
        return (name.isEmpty ? raw.lowercased() : name, isRefund)
    }

    /// A cleaned name's words with aliases applied: "amzn mktp us" becomes ["amazon", "mktp", "us"].
    static func words(_ cleaned: String) -> [String] {
        cleaned.split(separator: " ").map { aliases[String($0)] ?? String($0) }
    }

    /// The "no graph" ablation: every distinct raw name is its own merchant.
    static func rawMerchants(_ raws: Set<String>) -> [String: (id: String, name: String)] {
        Dictionary(uniqueKeysWithValues: raws.map { ($0, (id: "merchant:" + $0, name: $0)) })
    }

    /// Groups raw names (one per transaction) into merchants. Names that clean to the
    /// same words are one store; then any two stores that `sameStore` accepts are merged,
    /// and so on transitively (union-find), so A~B and B~C put A, B and C together.
    static func groupedMerchants(_ raws: [String]) -> [String: (id: String, name: String)] {
        let keyOf = Dictionary(uniqueKeysWithValues: Set(raws).map { ($0, words(clean($0).name).joined(separator: " ")) })
        let keys = Array(Set(keyOf.values)).sorted()
        var parent = Array(keys.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in keys.indices {
            for j in keys.indices where j > i && sameStore(keys[i], keys[j]) {
                parent[root(j)] = root(i)
            }
        }
        let indexOf = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let groups = Dictionary(grouping: raws) { root(indexOf[keyOf[$0]!]!) }

        var result: [String: (id: String, name: String)] = [:]
        for members in groups.values {
            // Name the merchant after its most common cleaned name; ties go to the shorter.
            // `members` has one entry per transaction, so this counts transactions.
            let counts = Dictionary(grouping: members.map { keyOf[$0]! }) { $0 }.mapValues(\.count)
            // A last tie goes to the alphabetically first name, so every run picks the same
            // one (a Swift Dictionary's order changes from run to run).
            let best = counts.max { a, b in
                a.value != b.value ? a.value < b.value : a.key.count != b.key.count ? a.key.count > b.key.count : a.key > b.key
            }!.key
            for raw in Set(members) { result[raw] = (id: "merchant:" + best, name: best.capitalized) }
        }
        return result
    }

    /// Whether two cleaned, aliased names are the same store. Compared without
    /// spaces, so "valuemart" and "value mart" are equal.
    static func sameStore(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        let shortJoined = short.replacingOccurrences(of: " ", with: "")
        // Whole leading words of the longer name: "shell" and "shell oil",
        // "valuemart" and "value mart grocery". Whole words only, so "shell" isn't "shelby".
        var leading = ""
        for word in long.split(separator: " ") where leading.count < shortJoined.count {
            leading += word
            if leading == shortJoined { return true }
        }
        // Otherwise a near-identical spelling: "beanstreet cafe" and "bean street coffee".
        return similarity(shortJoined, long.replacingOccurrences(of: " ", with: "")) >= similarityThreshold
    }

    /// 1 minus the edit distance (letters inserted, deleted or changed) over the longer length.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard !x.isEmpty, !y.isEmpty else { return x.count == y.count ? 1 : 0 }
        // Classic Levenshtein, one row at a time: row[j] is the distance between x so far and y.prefix(j).
        var row = Array(0...y.count)
        for i in 1...x.count {
            var previousDiagonal = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previousDiagonal + (x[i - 1] == y[j - 1] ? 0 : 1))
                previousDiagonal = above
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// The merchant's category: each transaction's name votes, and the category with
    /// the most votes wins (ties go to the earlier list). "other" when nothing matches.
    /// Voting lets "valuemart grocery" name the category for plain "value mart" too.
    static func category(of cleanedNames: [String]) -> String {
        var votes: [Int: Int] = [:]
        for name in cleanedNames {
            let padded = " " + words(name).joined(separator: " ") + " "
            if let index = categoryKeywords.firstIndex(where: { $0.words.contains { padded.contains(" \($0) ") } }) {
                votes[index, default: 0] += 1
            }
        }
        guard let winner = votes.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }) else { return "other" }
        return categoryKeywords[winner.key].category
    }

    /// Whether a series of charges (one merchant, one direction, oldest first) repeats on a
    /// cadence with a steady price. Needs three charges so there are two gaps to agree.
    static func recurrence(of series: [Line]) throws -> (cadence: String, typicalAmount: Double, nextDate: String)? {
        guard series.count >= 3 else { return nil }
        let dates = try series.map { try Date($0.date + "T00:00:00Z", strategy: .iso8601) }
        let gaps = zip(dates, dates.dropFirst()).map { calendar.dateComponents([.day], from: $0, to: $1).day! }
        guard let cadence = cadences.first(where: { c in gaps.allSatisfy { c.days.contains($0) } }) else { return nil }
        let amounts = series.map { abs($0.amount) }
        let steady = zip(amounts, amounts.dropFirst()).allSatisfy { abs($0 - $1) <= priceChangeAllowance * max($0, $1) }
        guard steady else { return nil }
        // The middle of the last three charges: after a price change it is the new price.
        let typical = amounts.suffix(3).sorted()[1]
        let next = cadence.name == "monthly"
            ? calendar.date(byAdding: .month, value: 1, to: dates.last!)!
            : calendar.date(byAdding: .day, value: cadence.name == "weekly" ? 7 : 14, to: dates.last!)!
        return (cadence.name, typical, next.formatted(.iso8601.year().month().day()))
    }

    /// Dates are calendar days with no time zone, so all date math happens in UTC.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    static func addEdge(_ db: Database, _ source: String, _ kind: String, _ target: String,
                        cadence: String? = nil, typicalAmount: Double? = nil, nextDate: String? = nil) throws {
        try db.execute(
            sql: "INSERT INTO edges (source, kind, target, cadence, typical_amount, next_expected_date) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [source, kind, target, cadence, typicalAmount, nextDate])
    }
}
