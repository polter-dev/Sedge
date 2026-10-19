import Foundation
import GRDB

/// Facts about the person worked out from their own transactions, with no setup questions:
/// where income comes from, rent or mortgage, tuition, loans, and what accounts they have.
/// Built from the organizer's output (merchants, categories, recurring series, and each
/// transaction's kind, so transfers and card payments are never income or bills).
/// `Organizer.organize` rebuilds it, so it is fresh after every sync. Corrections the person
/// makes are kept in their own table and always win over what was worked out.
public enum Profile {
    /// One fact, with the transactions it was found from and the name of the rule that found it.
    public struct Fact: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
        public static let databaseTableName = "profile_facts"

        /// The kind plus what it is about, e.g. "income:merchant:bean street coffee payroll".
        public var id: String
        /// income, housing, tuition, loan or account.
        public var kind: String
        /// GRDB stores this nested value as JSON text in one column, like `Account.balances`.
        public var value: Value
        /// 0 to 1: how sure the rule is. A correction from the person is 1.
        public var confidence: Double
        /// Transaction ids, stored as a JSON array.
        public var evidence: [String]
        public var rule: String
    }

    /// What a fact says. Only the fields that fit its kind are filled; nil fields are left out of JSON.
    public struct Value: Codable, Equatable, Sendable {
        /// The payer, landlord, school, lender or account.
        public var name: String
        /// rent or mortgage; auto, student, installment or other (loans); an account's type.
        public var type: String?
        /// A typical single payment, in dollars.
        public var amount: Double?
        /// weekly, biweekly, monthly or irregular.
        public var schedule: String?
        /// The day of the month a monthly payment usually lands.
        public var day: Int?
        /// Income only: everything from this source divided by the months in the data.
        public var monthly_average: Double?
        /// Tuition only: everything paid in the data.
        public var total: Double?

        public init(name: String, type: String? = nil, amount: Double? = nil, schedule: String? = nil,
                    day: Int? = nil, monthly_average: Double? = nil, total: Double? = nil) {
            (self.name, self.type, self.amount, self.schedule) = (name, type, amount, schedule)
            (self.day, self.monthly_average, self.total) = (day, monthly_average, total)
        }
    }

    /// A fact the person set themselves. It replaces the worked-out fact with the same id,
    /// or adds a new one, and survives every rebuild because rebuilds never touch this table.
    struct Correction: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "profile_corrections"
        var id: String
        var kind: String
        var value: Value
    }

    /// Saves the person's own version of a fact (`id` from an existing fact, or a new one).
    public static func correct(id: String, kind: String, value: Value, in database: SedgeDatabase) throws {
        try database.dbQueue.write { db in try Correction(id: id, kind: kind, value: value).upsert(db) }
    }

    /// Drops the person's correction, so the worked-out fact (if any) shows again and the
    /// questions it was answering are asked again.
    public static func removeCorrection(id: String, in database: SedgeDatabase) throws {
        _ = try database.dbQueue.write { db in try Correction.deleteOne(db, key: id) }
    }

    /// Every fact with corrections applied, in the order `kinds` lists them.
    public static func facts(in database: SedgeDatabase) throws -> [Fact] {
        try database.dbQueue.read { db in try facts(db) }
    }

    static let kinds = ["income", "housing", "tuition", "loan", "account"]

    static func facts(_ db: Database) throws -> [Fact] {
        let corrections = try Correction.fetchAll(db)
        let corrected = Set(corrections.map(\.id))
        let all = corrections.map { Fact(id: $0.id, kind: $0.kind, value: $0.value, confidence: 1, evidence: [], rule: "user_correction") }
            + (try Fact.fetchAll(db)).filter { !corrected.contains($0.id) }
        // An unknown kind (a correction #15 might add) sorts last instead of crashing.
        return all.sorted { (kinds.firstIndex(of: $0.kind) ?? kinds.count, $0.id) < (kinds.firstIndex(of: $1.kind) ?? kinds.count, $1.id) }
    }

    /// Replaces every worked-out fact. Called inside `Organizer.organize`'s write.
    static func rebuild(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM profile_facts")
        for fact in try infer(db) { try fact.insert(db) }
    }

    // MARK: - The rules

    // Confidences are fixed per rule: a series that repeats on a cadence is near-certain;
    // a pattern found from size or repetition alone is a decent guess.
    static let seriesConfidence = 0.95, keywordConfidence = 0.9, guessConfidence = 0.6

    /// Words that make a housing bill rent rather than mortgage.
    static let rentWords = ["rent", "apartment", "apartments", "property management", "lease", "leasing"]
    static let tuitionWords = ["tuition", "bursar"]
    /// Buy-now-pay-later lenders, which the organizer's "loans" category doesn't know.
    static let installmentWords = ["affirm", "klarna", "afterpay", "installment"]
    static let loanTypes: [(type: String, words: [String])] = [
        ("installment", installmentWords),
        ("auto", ["auto", "car", "vehicle"]),
        ("student", ["student", "navient", "sallie", "nelnet", "mohela"]),
    ]
    /// One education charge at least this big is probably tuition, not books or fees.
    /// shortcut: a fixed dollar line; revisit if a real bookstore or fee charge crosses it.
    static let tuitionMinimum = 1000.0

    /// One posted spending or income transaction with what the organizer found about it.
    struct Line: Decodable, FetchableRecord {
        let id, date, raw, kind, merchant, store: String
        let amount: Double
        let category: String?
        /// Set only when the organizer put this transaction in a recurring series.
        let cadence: String?
        let typical: Double?
    }

    static func infer(_ db: Database) throws -> [Fact] {
        let lines = try Line.fetchAll(db, sql: """
            SELECT t.transaction_id AS id, t.date, t.name AS raw, t.kind, t.merchant_id AS merchant, m.name AS store,
                   t.amount, c.target AS category, r.cadence, r.typical_amount AS typical
            FROM transactions t JOIN entities m ON m.id = t.merchant_id
            LEFT JOIN edges c ON c.kind = 'in_category' AND c.source = t.merchant_id
            LEFT JOIN edges r ON r.kind = 'recurring' AND r.source = t.transaction_id
            WHERE t.kind IN ('spending', 'income') AND NOT t.pending
            ORDER BY t.date, t.transaction_id
            """)
        // Months the data covers, for monthly averages. Counted from the data, not the clock.
        // shortcut: a partial first or last month counts as a whole one, so data starting mid-month
        // averages low; count days instead if real Plaid data shows it.
        let months = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT substr(date, 1, 7)) FROM transactions WHERE NOT pending") ?? 0

        var facts: [Fact] = []
        // One group per merchant and direction, sorted so every run lists facts the same way.
        let groups = Dictionary(grouping: lines) { $0.kind + "|" + $0.merchant }
        for key in groups.keys.sorted() {
            let group = groups[key]!, first = group[0]
            // Every cleaned name at this merchant as padded words, so " rent " matches the whole
            // word only. " | " between names keeps a phrase from spanning two names.
            let text = " " + Set(group.map { Organizer.words(Organizer.clean($0.raw).name).joined(separator: " ") })
                .sorted().joined(separator: " | ") + " "
            func says(_ words: [String]) -> Bool { words.contains { text.contains(" \($0) ") } }
            // The organizer finds at most one series per merchant and direction, so any member carries it.
            let series = group.first { $0.cadence != nil }
            let inSeries = group.filter { $0.cadence != nil }
            let amounts = group.map { abs($0.amount) }
            func fact(_ kind: String, _ value: Value, _ confidence: Double, _ evidence: [Line], _ rule: String) {
                facts.append(Fact(id: kind + ":" + first.merchant, kind: kind, value: value,
                                  confidence: confidence, evidence: evidence.map(\.id), rule: rule))
            }

            if first.kind == "income" {
                let average = months > 0 ? cents(amounts.reduce(0, +) / Double(months)) : nil
                if let series {
                    fact("income", Value(name: first.store, amount: cents(series.typical!), schedule: series.cadence,
                                         monthly_average: average), seriesConfidence, inSeries, "recurring_deposit")
                } else if Set(group.map { $0.date.prefix(7) }).count >= 3 {
                    // Deposits from one payer in three or more months, but not on a cadence or not
                    // a steady amount: gig or commission pay.
                    fact("income", Value(name: first.store, amount: cents(median(amounts)), schedule: "irregular",
                                         monthly_average: average), guessConfidence, group, "repeated_deposits")
                }
                continue
            }

            if first.category == "category:housing", let series {
                // HOA dues are housing too but are neither rent nor a mortgage, so they are skipped.
                guard let type = says(["mortgage"]) ? "mortgage" : says(rentWords) ? "rent" : nil else { continue }
                fact("housing", Value(name: first.store, type: type, amount: cents(series.typical!), schedule: series.cadence,
                                      day: series.cadence == "monthly" ? usualDay(inSeries) : nil),
                     keywordConfidence, inSeries, "recurring_housing_bill")
            } else if says(tuitionWords) || first.category == "category:education" && amounts.max()! >= tuitionMinimum {
                let named = says(tuitionWords)
                let paid = named ? group : group.filter { abs($0.amount) >= tuitionMinimum }
                let paidAmounts = paid.map { abs($0.amount) }
                // Tuition is paid per term, a cadence the organizer doesn't detect, so it is usually irregular.
                fact("tuition", Value(name: first.store, amount: cents(median(paidAmounts)), schedule: series?.cadence ?? "irregular",
                                      total: cents(paidAmounts.reduce(0, +))),
                     named ? keywordConfidence : guessConfidence, paid, named ? "tuition_payment" : "large_education_charge")
            } else if first.category == "category:loans" || says(installmentWords) {
                let type = loanTypes.first { says($0.words) }?.type ?? "other"
                if let series {
                    fact("loan", Value(name: first.store, type: type, amount: cents(series.typical!), schedule: series.cadence,
                                       day: series.cadence == "monthly" ? usualDay(inSeries) : nil),
                         keywordConfidence, inSeries, "recurring_loan_payment")
                } else if group.count >= 2 {
                    fact("loan", Value(name: first.store, type: type, amount: cents(median(amounts)), schedule: "irregular"),
                         guessConfidence, group, "repeated_loan_payments")
                }
            }
        }

        // Account types come straight from the bank's account list, so they are certain.
        for row in try Row.fetchAll(db, sql: "SELECT account_id, name, COALESCE(subtype, type) FROM accounts ORDER BY account_id") {
            facts.append(Fact(id: "account:" + (row[0] as String), kind: "account", value: Value(name: row[1], type: row[2]),
                              confidence: 1, evidence: [], rule: "account_list"))
        }
        return facts
    }

    /// The middle value (the upper middle for an even count). `values` is never empty here.
    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// The most common day of the month among the charges; a tie goes to the earlier day.
    static func usualDay(_ lines: [Line]) -> Int {
        let counts = Dictionary(grouping: lines.map { Int($0.date.suffix(2))! }) { $0 }.mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
    }
}

// MARK: - The profile tool (added after the frozen six)

extension Tool {
    static let getProfile = Tool(
        name: "get_profile",
        description: "What is known about the person: income (source, typical amount, schedule, monthly average), "
            + "rent or mortgage, tuition, loans, and account types. Each fact has a confidence from 0 to 1.",
        inputs: [],
        run: { _, db in
            // Evidence ids and fact ids are left out to keep the answer short.
            struct Item: Encodable { let kind: String; let value: Profile.Value; let confidence: Double; let rule: String }
            struct Result: Encodable { let facts: [Item]; let total_count: Int? }
            let facts = try Profile.facts(db)
            return Result(facts: facts.prefix(maxRows).map { Item(kind: $0.kind, value: $0.value, confidence: $0.confidence, rule: $0.rule) },
                          total_count: facts.count > maxRows ? facts.count : nil)
        })
}
