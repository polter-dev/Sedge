import GRDB

/// The person's answers about their own accounts and transactions: "Is this account yours?",
/// "Does this look familiar?" and a transaction's category. They are saved in the dataset's
/// own database file, nothing rebuilds them, and passing nil clears one. `account_balances`
/// and `find_transactions` report them, and a category answer moves that transaction's
/// spending to the new category.
public enum Answers {
    /// Whose account it is. "Later" is no answer, so it is saved as nil.
    public enum Owner: String, Sendable { case mine, shared }

    /// Whether the person recognizes a transaction.
    public enum Familiar: String, Sendable { case yes, notSure = "not_sure" }

    /// Why an answer couldn't be saved.
    public enum Failure: Error, Equatable {
        /// No account or transaction has this id.
        case notFound(String)
        /// Not one of the categories the organizer uses.
        case unknownCategory(String)
    }

    /// Saves (or with nil, clears) whether an account is the person's own or shared.
    public static func setOwner(_ owner: Owner?, account id: String, in database: SedgeDatabase) throws {
        try update("UPDATE accounts SET owner = ? WHERE account_id = ?", owner?.rawValue, id, in: database)
    }

    /// Saves (or with nil, clears) whether a transaction looks familiar.
    public static func setFamiliar(_ familiar: Familiar?, transaction id: String, in database: SedgeDatabase) throws {
        try update("UPDATE transactions SET familiar = ? WHERE transaction_id = ?", familiar?.rawValue, id, in: database)
    }

    /// Puts one transaction in another category (e.g. "groceries"), or with nil puts it back in
    /// its store's category. Only the organizer's categories are allowed, so the tools' category
    /// input can always find it.
    public static func setCategory(_ category: String?, transaction id: String, in database: SedgeDatabase) throws {
        if let category, !categoryNames.contains(category) { throw Failure.unknownCategory(category) }
        try update("UPDATE transactions SET category_override = ? WHERE transaction_id = ?", category, id, in: database)
    }

    /// Sets one answer (`sql` takes the value, then the id) and fails if no row has that id,
    /// so a wrong id isn't silently ignored.
    private static func update(_ sql: String, _ value: String?, _ id: String, in database: SedgeDatabase) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: sql, arguments: [value, id])
            if db.changesCount == 0 { throw Failure.notFound(id) }
        }
    }
}
