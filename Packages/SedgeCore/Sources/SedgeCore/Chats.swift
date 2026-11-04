import Foundation
import GRDB

/// The Ask screen's saved chats, kept in the open dataset's own database file so Previous chats
/// can list them and a chat can be reopened and continued. Only the screen reads them: nothing
/// here hands old turns to whatever answers questions.
public enum Chats {
    /// One saved chat, as Previous chats lists it.
    public struct Chat: Identifiable, Equatable, Sendable, Decodable, FetchableRecord {
        public let id: Int64
        /// The chat's first question, shortened.
        public let title: String
        public let created: Date
        /// When the last turn was saved. Previous chats shows this date and sorts by it.
        public let updated: Date
    }

    /// One question and its answer, in the order they were asked.
    public struct Turn: Equatable, Sendable, Decodable, FetchableRecord {
        public let question: String
        /// The screen's own encoding of the answer (JSON), or nil if no answer came.
        public let answer: String?
    }

    /// Saves one turn. With `chat` nil it starts a new chat titled by this question and returns
    /// its id; otherwise it adds the turn to that chat and returns the same id. `date` is only a
    /// label for Previous chats, so the screen passes the clock's time.
    @discardableResult
    public static func append(question: String, answer: String?, to chat: Int64?, at date: Date,
                              in database: SedgeDatabase) throws -> Int64 {
        // One write transaction, so a chat is never saved without its first turn.
        try database.dbQueue.write { db in
            let id: Int64
            if let chat {
                try db.execute(sql: "UPDATE chats SET updated = ? WHERE id = ?", arguments: [date, chat])
                id = chat
            } else {
                try db.execute(sql: "INSERT INTO chats (title, created, updated) VALUES (?, ?, ?)",
                               arguments: [title(for: question), date, date])
                id = db.lastInsertedRowID
            }
            try db.execute(sql: "INSERT INTO chat_turns (chat_id, question, answer) VALUES (?, ?, ?)",
                           arguments: [id, question, answer])
            return id
        }
    }

    /// Every saved chat, the most recently used first.
    public static func list(in database: SedgeDatabase) throws -> [Chat] {
        try database.dbQueue.read { db in
            // Ties (two saves in the same instant) go to the newer chat.
            try Chat.fetchAll(db, sql: "SELECT id, title, created, updated FROM chats ORDER BY updated DESC, id DESC")
        }
    }

    /// One chat's turns, oldest first.
    public static func turns(of chat: Int64, in database: SedgeDatabase) throws -> [Turn] {
        try database.dbQueue.read { db in
            try Turn.fetchAll(db, sql: "SELECT question, answer FROM chat_turns WHERE chat_id = ? ORDER BY id",
                              arguments: [chat])
        }
    }

    /// Deletes a chat and, through the table's cascade, its turns.
    public static func delete(_ chat: Int64, in database: SedgeDatabase) throws {
        try database.dbQueue.write { db in try db.execute(sql: "DELETE FROM chats WHERE id = ?", arguments: [chat]) }
    }

    /// A chat's title: its first question, cut at a word boundary to about 40 characters.
    static func title(for question: String) -> String {
        let words = question.split(separator: " ")
        var title = ""
        for word in words {
            if !title.isEmpty, title.count + 1 + word.count > 40 { return title + "…" }
            title += title.isEmpty ? String(word) : " " + word
        }
        return title
    }
}
