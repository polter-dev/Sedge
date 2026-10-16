import Foundation

/// The instructions every model gets before the question. Kept in this one file so a change
/// is easy to see in review; bump `version` whenever the text changes, because every
/// trace records it and results from different versions shouldn't be mixed.
public enum SystemPrompt {
    public static let version = "v1"

    /// `asOf` is the dataset's "today" ("YYYY-MM-DD"), never the device clock, so
    /// "last month" means the same thing on every run.
    public static func text(asOf: String) -> String {
        """
        You answer questions about one person's own bank accounts and spending. Today is \(asOf).

        The tools are your only source of data. Never guess or make up an amount, store, or date. \
        If the tools can't answer the question, say so.

        Read relative dates ("last month", "this year") from today's date. A month runs from its first \
        day to its last. Amounts are US dollars. If a tool returns an error, read its hint, fix the input, \
        and try again. Use at most \(Assistant.maxToolCalls) tool calls.

        Always finish by calling final_answer once, instead of replying in plain text:
        - answer: one plain sentence for the person.
        - value: the main number in the answer (dollars or a count), or null.
        - items: the names, when the question asks for a list, or null.
        - yes_no: true or false for a yes-or-no question, otherwise null.
        - confidence: how sure you are, from 0 to 1, or null.
        """
    }

    /// Bump whenever `contextData`'s wording or columns change, like `version`.
    public static let contextVersion = "context-v1"

    /// Bump whenever `askUser`'s wording changes, like `version`.
    public static let askUserVersion = "ask-user-v1"

    /// Added after `text(asOf:)` when the model has the data tools (and so `ask_user`). The
    /// context baseline doesn't get it, so its prompt is unchanged.
    public static let askUser = """


        Only if the question can be read more than one way and the readings give different answers, \
        call ask_user once before answering, with a short question, two to four short options, and a \
        fact_key naming the fact. Ask instead of answering every reading at once. Don't ask when the tools, \
        get_profile, or the question itself already settle it. If ask_user returns no answer, use the \
        likeliest reading and say which one you used.
        """

    /// What the person already told ask_user, added after `askUser` so the model uses it
    /// instead of guessing or asking again. Empty when nothing is saved, which is always the
    /// case in the eval runner (it resets before each question), so `template` leaves it out.
    static func savedAnswers(_ answers: [(key: String, question: String, answer: String)]) -> String {
        guard !answers.isEmpty else { return "" }
        return "\n\nThe person already answered these questions, so use their answers and don't ask again:\n"
            + answers.map { "- \($0.key) (\($0.question)): \($0.answer)" }.joined(separator: "\n")
    }

    /// The version a trace records: each setup's prompt is the main text plus its own part.
    public static func version(dataTools: Bool) -> String {
        version + "+" + (dataTools ? askUserVersion : contextVersion)
    }

    /// The prompt with placeholders where each question's date and data go, so its hash
    /// changes only when the wording does.
    public static func template(dataTools: Bool) -> String {
        text(asOf: "{as_of}") + (dataTools ? askUser : contextData(accounts: [], transactions: []))
    }

    /// The context-stuffing baseline's data, added after `text(asOf:)`: the raw accounts and
    /// transactions as CSV, with no organizer and no tools in between. The account columns
    /// match what `account_balances` shows, and names are the raw statement names, so the only
    /// difference from the tool-using setup is where the data comes from.
    /// shortcut: pending transactions aren't marked (the fake personas have none); add a
    /// column before running this on live Plaid data.
    public static func contextData(accounts: [Account], transactions: [Transaction]) -> String {
        let names = Dictionary(accounts.map { ($0.account_id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let accountRows = accounts.map { account in
            [account.name, account.subtype ?? account.type, account.balances.current.map { String(format: "%.2f", $0) } ?? ""]
        }
        let transactionRows = transactions.map { [$0.date, $0.name, String(format: "%.2f", $0.amount), names[$0.account_id] ?? $0.account_id] }
        return """


            There are no data tools in this setup. Instead, the person's accounts and every transaction \
            up to today are below as CSV, and they are your only source of data. An amount above zero is \
            money leaving the account; below zero is money coming in. For a credit card, balance is the amount owed.

            Accounts:
            \(csv([["name", "type", "balance"]] + accountRows))

            Transactions:
            \(csv([["date", "name", "amount", "account"]] + transactionRows))
            """
    }

    /// Joins rows into CSV text. A cell holding a comma, quote or line break is quoted, with
    /// any `"` doubled, so a store name like `AMAZON, INC` stays one cell.
    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}
