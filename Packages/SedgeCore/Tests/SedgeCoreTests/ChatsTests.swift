import Foundation
import GRDB
import Testing
@testable import SedgeCore

/// Saving, listing, loading, continuing and deleting chats, in a throwaway database file that is
/// opened again partway through to show the chats really were saved.
@Test func chatsAreSavedListedLoadedAppendedAndDeleted() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("chats-\(UUID()).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var database = try SedgeDatabase(path: path)
    let monday = Date(timeIntervalSince1970: 1_800_000_000)
    let tuesday = monday.addingTimeInterval(86_400)

    // Save: a nil chat starts a new one titled by its first question.
    let food = try Chats.append(question: "Have I been overspending on food?", answer: #"{"lead":"More than usual."}"#,
                                to: nil, at: monday, in: database)
    let netflix = try Chats.append(question: "How much did I spend at Netflix this year?", answer: nil,
                                   to: nil, at: tuesday, in: database)
    #expect(food != netflix)

    // List: newest first, and still there after opening the file again.
    database = try SedgeDatabase(path: path)
    #expect(try Chats.list(in: database).map(\.title) == ["How much did I spend at Netflix this…",
                                                          "Have I been overspending on food?"])

    // Append: continuing the older chat adds a turn and moves it to the top.
    let later = tuesday.addingTimeInterval(60)
    #expect(try Chats.append(question: "What about coffee?", answer: #"{"lead":"Less."}"#, to: food, at: later, in: database) == food)
    let chats = try Chats.list(in: database)
    #expect(chats.map(\.id) == [food, netflix])
    #expect(chats[0].created == monday && chats[0].updated == later)
    #expect(chats.map(\.questions) == [2, 1])

    // Load: the turns come back in the order they were asked, answers as saved.
    #expect(try Chats.turns(of: food, in: database) == [
        Chats.Turn(question: "Have I been overspending on food?", answer: #"{"lead":"More than usual."}"#),
        Chats.Turn(question: "What about coffee?", answer: #"{"lead":"Less."}"#),
    ])
    #expect(try Chats.turns(of: netflix, in: database) == [
        Chats.Turn(question: "How much did I spend at Netflix this year?", answer: nil)])

    // Delete: the chat and its turns go; the other chat stays.
    try Chats.delete(food, in: database)
    #expect(try Chats.list(in: database).map(\.id) == [netflix])
    #expect(try Chats.turns(of: food, in: database).isEmpty)
    #expect(try database.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_turns") } == 1)
}

/// A long first question is cut at a word boundary; a short one is kept whole.
@Test func chatTitleIsTheFirstQuestionShortened() {
    #expect(Chats.title(for: "What about coffee?") == "What about coffee?")
    #expect(Chats.title(for: "How much did I spend on rent and utilities in May and June?")
            == "How much did I spend on rent and…")
}

/// A file saved before chats existed (at `v7`, with an account nickname) opens at `v8`:
/// the chat tables appear and the nickname is still there.
@Test func fileAtNicknameVersionUpgradesToChats() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("v7-\(UUID()).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    do {
        let old = try DatabaseQueue(path: path)
        try SedgeDatabase.migrator.migrate(old, upTo: "v7")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (account_id, name, type, balances, nickname)
                VALUES ('a1', 'Checking', 'depository', '{}', 'Everyday')
                """)
        }
    } // the old connection closes here, so the file is opened fresh below
    let database = try SedgeDatabase(path: path)
    #expect(try database.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT nickname FROM accounts") } == "Everyday")
    #expect(try database.dbQueue.read { db in try db.tableExists("chats") && db.tableExists("chat_turns") })
    #expect(try Chats.append(question: "Hi?", answer: nil, to: nil, at: Date(timeIntervalSince1970: 0), in: database) > 0)
}
