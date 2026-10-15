import Foundation

/// The four fake people in `tools/data/<persona>/`.
public enum Persona {
    public static let all = ["maya", "daniel", "jordan", "elena"]

    /// "Today" for every fake persona. It isn't in their data files (only in the
    /// grader's answer keys, which the app never reads), so it lives here.
    public static let asOf = "2026-06-30"

    /// Reads one persona's `accounts.json` and `transactions.json` and saves them.
    /// Takes two file URLs because the app finds them in its bundle and the
    /// command-line tool finds them on disk under different names.
    public static func load(accounts accountsURL: URL, transactions transactionsURL: URL, into database: SedgeDatabase) throws {
        let decoder = JSONDecoder()
        let accounts = try decoder.decode([Account].self, from: Data(contentsOf: accountsURL))
        let transactions = try decoder.decode([Transaction].self, from: Data(contentsOf: transactionsURL))
        try database.save(accounts: accounts, transactions: transactions, asOf: asOf)
    }
}
