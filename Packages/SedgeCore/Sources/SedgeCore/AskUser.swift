import Foundation
import GRDB

/// A clarifying question the model asked with `ask_user`, and what came back.
public struct Clarification: Codable, Sendable, Equatable {
    public var question: String
    /// The quick replies the person can tap.
    public var options: [String]
    /// The fact being asked about, cleaned to snake_case, e.g. "food_includes_groceries".
    /// Answers are saved under it, so the same fact is asked about only once.
    public var factKey: String
    /// The reply, or nil when nobody answered.
    public var answer: String?
    /// True when a saved answer or a profile correction replied, so the person wasn't asked.
    public var answeredFromMemory: Bool
}

/// How the person is reached: shown the question, and their reply handed back (nil if they
/// skip it). The app shows a card and waits for a tap; the eval runner replies from the
/// question bank's `clarify_reply`.
public typealias AskPerson = @Sendable (Clarification) async -> String?

/// The `ask_user` tool. It isn't one of the read-only `Tool`s: it waits for the person, and
/// it saves their answer in `saved_answers` so the same question is never asked twice.
public enum AskUser {
    public static let toolName = "ask_user"

    /// Claude's definition of the tool. Strict mode doesn't allow list-length limits, so the
    /// two-to-four rule is in the description and `run` checks it.
    public static var claudeSchema: [String: Any] {
        [
            "name": toolName,
            "description": "Ask the person one short question, only when their answer would change the result. "
                + "Returns their answer, which may be one they gave before, or a note if they didn't answer.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "One short question for the person."],
                    "options": ["type": "array", "items": ["type": "string"],
                                "description": "Two to four short replies the person can tap."],
                    "fact_key": ["type": "string",
                                 // No example key here: the model tends to copy one as is.
                                 "description": "The fact being asked, as a short snake_case name. "
                                     + "The answer is saved under it, so use the same key for the same fact."],
                ] as [String: Any],
                "required": ["question", "options", "fact_key"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    /// Answers one `ask_user` call: from memory if the fact is already known, otherwise by
    /// asking the person and saving what they say. Returns the tool's JSON result and, for a
    /// good call, what happened, for the trace.
    static func run(_ input: Data, database: SedgeDatabase, askPerson: AskPerson?) async -> (content: String, clarification: Clarification?) {
        struct Input: Decodable { let question: String; let options: [String]; let fact_key: String }
        // A nil field is left out of the JSON, so a fresh answer is just {"answer": ...}.
        struct Answer: Encodable { let answer: String; let answered_from_memory: Bool? }
        guard let input = try? JSONDecoder().decode(Input.self, from: input) else {
            return (Tool.json(ToolError("Bad ask_user input.", hint: "Send question, options and fact_key.")), nil)
        }
        let question = input.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = input.options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let key = factKey(input.fact_key)
        guard !question.isEmpty else { return (Tool.json(ToolError("Missing question.", hint: "One short question.")), nil) }
        guard (2...4).contains(options.count) else {
            return (Tool.json(ToolError("Bad value for \"options\".", hint: "Two to four short replies.")), nil)
        }
        guard !key.isEmpty else { return (Tool.json(ToolError("Bad value for \"fact_key\".", hint: "A snake_case name, e.g. housing_type.")), nil) }

        var clarification = Clarification(question: question, options: options, factKey: key, answer: nil, answeredFromMemory: false)
        do {
            if let known = try await database.dbQueue.read({ db in try remembered(key, db) }) {
                clarification.answer = known
                clarification.answeredFromMemory = true
                return (Tool.json(Answer(answer: known, answered_from_memory: true)), clarification)
            }
            guard let reply = await askPerson?(clarification) else {
                // Not saved: a skipped question may be asked again next time.
                return (#"{"note":"The person didn't answer. Use the likeliest reading and say which one you used."}"#, clarification)
            }
            clarification.answer = reply
            try save(clarification, in: database)
            return (Tool.json(Answer(answer: reply, answered_from_memory: nil)), clarification)
        } catch {
            return (Tool.json(ToolError("ask_user failed: \(error)")), nil)
        }
    }

    /// Lowercase words joined by "_", so "Housing type" and "housing_type" are one fact.
    static func factKey(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "_")
    }

    /// A saved answer for `key`, or else the person's profile corrections that cover it: one
    /// whose kind is the key or starts it ("housing" covers "housing_type"), or whose id is
    /// the key. Corrections come back as their JSON values.
    static func remembered(_ key: String, _ db: Database) throws -> String? {
        if let saved = try String.fetchOne(db, sql: "SELECT answer FROM saved_answers WHERE fact_key = ?", arguments: [key]) {
            return saved
        }
        let values = try Profile.Correction.order(Column("id")).fetchAll(db)
            .filter { covers(kind: $0.kind, id: $0.id, key: key) }
            .map(\.value)
        return values.isEmpty ? nil : Tool.json(values)
    }

    /// True when a profile correction with this kind and id answers questions saved under
    /// `key`. Public so the app's Saved answers menu can say which correction an answer used.
    public static func covers(kind: String, id: String, key: String) -> Bool {
        key == kind || key.hasPrefix(kind + "_") || key == factKey(id)
    }

    /// Saves (or replaces) the answer for its fact. The date is the dataset's today, never
    /// the device clock, like every other date in the database.
    static func save(_ clarification: Clarification, in database: SedgeDatabase) throws {
        try database.dbQueue.write { db in
            let today = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'") ?? ""
            try db.execute(sql: """
                INSERT INTO saved_answers (fact_key, question, answer, date) VALUES (?, ?, ?, ?)
                ON CONFLICT(fact_key) DO UPDATE SET question = excluded.question, answer = excluded.answer, date = excluded.date
                """, arguments: [clarification.factKey, clarification.question, clarification.answer, today])
        }
    }

    /// Every saved answer as (fact_key, question, answer), in key order.
    public static func saved(_ database: SedgeDatabase) throws -> [(key: String, question: String, answer: String)] {
        try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT fact_key, question, answer FROM saved_answers ORDER BY fact_key").map { ($0[0], $0[1], $0[2]) }
        }
    }

    /// Replaces the saved answer for `key` with the person's own wording (Saved answers menu).
    public static func change(_ key: String, to answer: String, in database: SedgeDatabase) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "UPDATE saved_answers SET answer = ? WHERE fact_key = ?", arguments: [answer, key])
        }
    }

    /// Forgets one saved answer, so its question is asked again next time.
    public static func forget(_ key: String, in database: SedgeDatabase) throws {
        try database.dbQueue.write { db in try db.execute(sql: "DELETE FROM saved_answers WHERE fact_key = ?", arguments: [key]) }
    }

    /// Forgets every saved answer, so each question may be asked again (the app's
    /// "Reset saved questions", and the eval runner before each question).
    public static func reset(_ database: SedgeDatabase) throws {
        try database.dbQueue.write { db in try db.execute(sql: "DELETE FROM saved_answers") }
    }
}
