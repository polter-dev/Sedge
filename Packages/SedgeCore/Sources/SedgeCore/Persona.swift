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
    /// An earlier `asOf` pretends today is that day: later transactions are left out and
    /// each balance is wound back to what it was at the end of that day.
    public static func load(accounts accountsURL: URL, transactions transactionsURL: URL, into database: SedgeDatabase,
                            asOf: String = asOf) throws {
        let (accounts, transactions) = try read(accounts: accountsURL, transactions: transactionsURL)
        try database.save(accounts: balances(accounts, transactions, on: asOf),
                          transactions: transactions.filter { $0.date <= asOf }, asOf: asOf)
    }

    static func read(accounts accountsURL: URL, transactions transactionsURL: URL) throws -> ([Account], [Transaction]) {
        let decoder = JSONDecoder()
        return (try decoder.decode([Account].self, from: Data(contentsOf: accountsURL)),
                try decoder.decode([Transaction].self, from: Data(contentsOf: transactionsURL)))
    }

    /// The accounts with each balance as it stood at the end of `date`, found by undoing every
    /// posted transaction after it. The files' balances are as of `Persona.asOf`.
    /// Plaid's sign: a positive amount lowered a bank balance and raised what a card owes.
    static func balances(_ accounts: [Account], _ transactions: [Transaction], on date: String) -> [Account] {
        accounts.map { account in
            var account = account
            let later = transactions.filter { $0.account_id == account.account_id && $0.date > date && !$0.pending }
            // Summed in whole cents so many small undos don't drift.
            let cents = later.map { ($0.amount * 100).rounded() }.reduce(0, +)
            if let current = account.balances.current {
                let undone = account.type == "credit" ? current * 100 - cents : current * 100 + cents
                account.balances.current = undone.rounded() / 100
            }
            return account
        }
    }
}
