import Foundation
import GRDB

/// The local SQLite database: one file holding one person's accounts and transactions.
public struct SedgeDatabase: Sendable {
    /// GRDB's connection. Other SedgeCore code reads with `dbQueue.read { }`.
    public let dbQueue: DatabaseQueue

    /// Opens (or creates) the database file at `path` and brings its tables up to date.
    public init(path: String) throws {
        try self.init(DatabaseQueue(path: path))
    }

    /// A throwaway database that lives only in memory, for tests and one-off runs.
    public init() throws {
        try self.init(DatabaseQueue())
    }

    private init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// Each migration runs once per file, in order. To change a table later,
    /// add a new migration instead of editing an old one, so existing files upgrade.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "accounts") { t in
                t.primaryKey("account_id", .text)
                t.column("name", .text).notNull()
                t.column("official_name", .text)
                t.column("mask", .text)
                t.column("type", .text).notNull()
                t.column("subtype", .text)
                t.column("balances", .text).notNull()
            }
            try db.create(table: "transactions") { t in
                t.primaryKey("transaction_id", .text)
                t.column("account_id", .text).notNull().indexed().references("accounts")
                t.column("date", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("amount", .double).notNull()
                t.column("iso_currency_code", .text)
                t.column("pending", .boolean).notNull()
                t.column("pending_transaction_id", .text)
                t.column("merchant_name", .text)
                t.column("personal_finance_category", .text)
            }
            // Small key/value facts about the dataset. Today it holds only `as_of`.
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        // The merchant graph, written by `Organizer`. Nodes are merchants, accounts
        // and categories; edges connect transactions and nodes. Ids are readable text
        // such as "merchant:value mart" or "account:maya-card".
        migrator.registerMigration("v2") { db in
            try db.create(table: "entities") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull() // merchant, account or category
                t.column("name", .text).notNull()
            }
            try db.create(table: "edges") { t in
                t.column("source", .text).notNull().indexed()
                // at_merchant, from_account, refund_of (source and target are transactions),
                // in_category (merchant to category) or recurring (transaction to merchant).
                t.column("kind", .text).notNull()
                t.column("target", .text).notNull().indexed()
                // Filled only on recurring edges.
                t.column("cadence", .text)
                t.column("typical_amount", .double)
                t.column("next_expected_date", .text)
            }
            // A copy of the at_merchant edge, so "spending at X" is one indexed lookup.
            // It isn't part of `Transaction`, so re-saving Plaid data leaves it alone.
            try db.alter(table: "transactions") { t in t.add(column: "merchant_id", .text) }
            try db.create(indexOn: "transactions", columns: ["merchant_id"])
        }
        return migrator
    }

    /// Saves accounts and transactions. Safe to call again with the same data:
    /// rows are matched by id and updated in place, so the row count doesn't grow.
    /// `asOf` is the dataset's "today" ("YYYY-MM-DD"); nothing here reads the system clock.
    public func save(accounts: [Account], transactions: [Transaction], asOf: String) throws {
        // One write transaction: either everything is saved or nothing is.
        try dbQueue.write { db in
            for account in accounts { try account.upsert(db) }
            for transaction in transactions { try transaction.upsert(db) }
            // When a pending charge posts, Plaid sends the posted copy under a new id
            // and points `pending_transaction_id` at the old one. Drop the pending copy
            // so the charge isn't counted twice. Running this after all the upserts
            // also covers the pending copy arriving after the posted one.
            try db.execute(sql: """
                DELETE FROM transactions
                WHERE pending AND transaction_id IN (
                    SELECT pending_transaction_id FROM transactions
                    WHERE NOT pending AND pending_transaction_id IS NOT NULL)
                """)
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('as_of', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [asOf])
        }
    }

    /// Every saved transaction, newest first.
    public func allTransactions() throws -> [Transaction] {
        try dbQueue.read { db in
            try Transaction.order(Column("date").desc, Column("transaction_id")).fetchAll(db)
        }
    }

    /// The dataset's "today", or nil if nothing has been saved yet.
    public func asOf() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'as_of'")
        }
    }
}
