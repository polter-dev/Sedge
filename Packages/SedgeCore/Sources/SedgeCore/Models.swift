import GRDB

// The property names match Plaid's JSON keys and the database columns exactly
// (snake_case), so one type decodes Plaid, decodes the fake personas, and saves
// to SQLite with no renaming in between.

/// One bank account, shaped like Plaid's account object.
public struct Account: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "accounts"

    public var account_id: String
    public var name: String
    public var official_name: String?
    public var mask: String?
    public var type: String
    public var subtype: String?
    /// GRDB stores this nested value as JSON text in one column.
    /// In SQL: `json_extract(balances, '$.current')`.
    public var balances: Balances
}

/// Plaid's balance block for an account. Any field can be missing.
public struct Balances: Codable, Equatable, Sendable {
    public var current: Double?
    public var available: Double?
    public var limit: Double?
    public var iso_currency_code: String?
    public var unofficial_currency_code: String?
}

/// One bank transaction, shaped like Plaid's transaction object.
/// Plaid's sign convention: positive `amount` is money leaving the account.
public struct Transaction: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transactions"

    public var transaction_id: String
    public var account_id: String
    /// "YYYY-MM-DD". Kept as text because SQLite compares these strings in date order.
    public var date: String
    public var name: String
    public var amount: Double
    public var iso_currency_code: String?
    public var pending: Bool
    /// On a posted transaction, the id of the pending copy it replaces.
    public var pending_transaction_id: String?

    // Plaid's own cleaned-up name and category. Kept only as the baseline the
    // organizer is compared against: the organizer must never read these two.
    // The fake personas don't have them, so they are nil there.
    public var merchant_name: String?
    /// Stored as JSON text, like `Account.balances`.
    public var personal_finance_category: PersonalFinanceCategory?

    public var id: String { transaction_id }
}

/// Plaid's category label, e.g. primary "FOOD_AND_DRINK", detailed "FOOD_AND_DRINK_COFFEE".
public struct PersonalFinanceCategory: Codable, Equatable, Sendable {
    public var primary: String
    public var detailed: String
    public var confidence_level: String?
}
