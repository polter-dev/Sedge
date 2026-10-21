import Foundation
import GRDB
import Synchronization
import Testing
@testable import SedgeCore

// ask_user called directly: asked once, saved, and answered from memory after the database
// file is opened again, the way the app opens it at launch.

let askFood = #"{"question": "Should food include groceries?", "options": ["Yes, groceries too", "No, eating out only"], "fact_key": "Food includes groceries"}"#

/// A person who always taps `reply`, and counts how often they were asked.
final class Person: Sendable {
    let reply: String?
    let asked = Mutex(0)
    init(_ reply: String?) { self.reply = reply }
    var ask: AskPerson { { _ in self.asked.withLock { $0 += 1 }; return self.reply } }
}

/// Runs one `ask_user` call with the given JSON input.
func ask(_ database: SedgeDatabase, _ person: Person, input: String = askFood) async -> (content: String, clarification: Clarification?) {
    await AskUser.run(Data(input.utf8), database: database, askPerson: person.ask)
}

@Test func askedOnceThenAnsweredFromMemoryAfterReopening() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "sedge-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    func launch() throws -> SedgeDatabase {
        let database = try SedgeDatabase(path: path)
        try loadPersona("maya", into: database)
        try Organizer.organize(database)
        return database
    }

    let person = Person("Yes, groceries too")
    let first = await ask(try launch(), person)
    #expect(first.clarification == Clarification(question: "Should food include groceries?", options: ["Yes, groceries too", "No, eating out only"],
                                                 factKey: "food_includes_groceries", answer: "Yes, groceries too", answeredFromMemory: false))
    #expect(first.content == #"{"answer":"Yes, groceries too"}"#)
    #expect(person.asked.withLock { $0 } == 1)

    // "Restart": a fresh connection to the same file, reloaded and organized again.
    let database = try launch()
    let again = await ask(database, person)
    #expect(person.asked.withLock { $0 } == 1)
    #expect(again.clarification?.answeredFromMemory == true)
    #expect(again.content == #"{"answer":"Yes, groceries too","answered_from_memory":true}"#)
    let date = try await database.dbQueue.read { try String.fetchOne($0, sql: "SELECT date FROM saved_answers") }
    #expect(date == Persona.asOf)

    // After a reset the person is asked again.
    try AskUser.reset(database)
    _ = await ask(database, person)
    #expect(person.asked.withLock { $0 } == 2)
}

@Test func skippedQuestionIsNotSaved() async throws {
    let database = try organizedPersona("maya")
    let skipped = await ask(database, Person(nil))
    #expect(skipped.clarification != nil && skipped.clarification?.answer == nil)
    #expect(skipped.content.contains("didn't answer") && !skipped.content.contains("\"error\""))
    #expect(try await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM saved_answers") } == 0)
}

@Test func badAskGoesBackAsAnErrorWithoutAsking() async throws {
    let person = Person("Yes")
    let oneOption = #"{"question": "Food?", "options": ["Yes"], "fact_key": "food"}"#
    let bad = await ask(try organizedPersona("maya"), person, input: oneOption)
    #expect(bad.clarification == nil)
    #expect(bad.content.contains(#""error":"Bad value for \"options\".""#))
    #expect(person.asked.withLock { $0 } == 0)
}

@Test func profileCorrectionAnswersWithoutAsking() async throws {
    let database = try organizedPersona("maya")
    let mine = Profile.Value(name: "Oakwood Apartments", type: "rent", amount: 650, schedule: "monthly")
    try Profile.correct(id: "housing:mine", kind: "housing", value: mine, in: database)
    let person = Person("Mortgage")
    let housing = #"{"question": "Do you rent or own?", "options": ["Rent", "Mortgage"], "fact_key": "housing_type"}"#
    let answered = await ask(database, person, input: housing)
    #expect(person.asked.withLock { $0 } == 0)
    #expect(answered.clarification?.answeredFromMemory == true)
    #expect(answered.clarification?.answer?.contains("\"type\":\"rent\"") == true)
}

@Test func changedAnswerIsUsedAndForgottenOneIsAskedAgain() async throws {
    let database = try organizedPersona("maya")
    let person = Person("Yes, groceries too")
    _ = await ask(database, person)
    try AskUser.change("food_includes_groceries", to: "No, eating out only", in: database)
    let changed = await ask(database, person)
    #expect(changed.clarification?.answer == "No, eating out only")
    #expect(person.asked.withLock { $0 } == 1)

    try AskUser.forget("food_includes_groceries", in: database)
    _ = await ask(database, person)
    #expect(person.asked.withLock { $0 } == 2)
}

@Test func removedCorrectionNoLongerAnswers() async throws {
    let database = try organizedPersona("maya")
    try Profile.correct(id: "housing:mine", kind: "housing", value: Profile.Value(name: "Oakwood", type: "rent"), in: database)
    #expect(AskUser.covers(kind: "housing", id: "housing:mine", key: "housing_type"))
    #expect(!AskUser.covers(kind: "housing", id: "housing:mine", key: "housingtype"))
    try Profile.removeCorrection(id: "housing:mine", in: database)
    let person = Person("Rent")
    let housing = #"{"question": "Do you rent or own?", "options": ["Rent", "Mortgage"], "fact_key": "housing_type"}"#
    _ = await ask(database, person, input: housing)
    #expect(person.asked.withLock { $0 } == 1)
}
