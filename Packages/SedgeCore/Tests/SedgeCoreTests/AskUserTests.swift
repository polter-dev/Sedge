import Foundation
import GRDB
import Synchronization
import Testing
@testable import SedgeCore

// ask_user with the scripted model: asked once, saved, and answered from memory after the
// database file is opened again, the way the app opens it at launch.

let askFood = #"{"question": "Should food include groceries?", "options": ["Yes, groceries too", "No, eating out only"], "fact_key": "Food includes groceries"}"#

/// A person who always taps `reply`, and counts how often they were asked.
final class Person: Sendable {
    let reply: String?
    let asked = Mutex(0)
    init(_ reply: String?) { self.reply = reply }
    var ask: AskPerson { { _ in self.asked.withLock { $0 += 1 }; return self.reply } }
}

/// One question that asks first, then answers.
func askThenAnswer(_ ask: String = askFood) -> ScriptedBackend {
    ScriptedBackend([calling([("ask_user", ask)]), calling([("final_answer", answer100)])])
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
    let first = await Assistant(backend: askThenAnswer(), database: try launch(), askPerson: person.ask).ask("Food last month?")
    #expect(first.askedUser && first.finalAnswer != nil)
    #expect(first.clarifications == [Clarification(question: "Should food include groceries?", options: ["Yes, groceries too", "No, eating out only"],
                                                  factKey: "food_includes_groceries", answer: "Yes, groceries too", answeredFromMemory: false)])
    #expect(first.toolCalls[0].result == #"{"answer":"Yes, groceries too"}"#)
    #expect(person.asked.withLock { $0 } == 1)

    // "Restart": a fresh connection to the same file, reloaded and organized again.
    let backend = askThenAnswer(), database = try launch()
    let again = await Assistant(backend: backend, database: database, askPerson: person.ask).ask("Food last month?")
    #expect(person.asked.withLock { $0 } == 1)
    #expect(again.askedUser && again.clarifications.first?.answeredFromMemory == true)
    // The saved answer is also in the prompt, so the model needn't call ask_user at all.
    #expect(await backend.systems[0].hasSuffix("\n- food_includes_groceries (Should food include groceries?): Yes, groceries too"))
    guard case .toolResults(let results) = await backend.received[1].last else { Issue.record("no tool results"); return }
    #expect(results[0].content == #"{"answer":"Yes, groceries too","answered_from_memory":true}"# && !results[0].isError)
    let date = try await database.dbQueue.read { try String.fetchOne($0, sql: "SELECT date FROM saved_answers") }
    #expect(date == Persona.asOf)

    // After a reset the person is asked again.
    try AskUser.reset(database)
    _ = await Assistant(backend: askThenAnswer(), database: database, askPerson: person.ask).ask("Food last month?")
    #expect(person.asked.withLock { $0 } == 2)
}

@Test func skippedQuestionIsNotSaved() async throws {
    let database = try organizedPersona("maya")
    let trace = await Assistant(backend: askThenAnswer(), database: database, askPerson: Person(nil).ask).ask("?")
    #expect(trace.askedUser && trace.clarifications.first?.answer == nil)
    #expect(trace.toolCalls[0].valid && trace.toolCalls[0].result.contains("didn't answer"))
    #expect(try await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM saved_answers") } == 0)
}

@Test func badAskGoesBackAsAnErrorWithoutAsking() async throws {
    let person = Person("Yes")
    let oneOption = #"{"question": "Food?", "options": ["Yes"], "fact_key": "food"}"#
    let trace = await Assistant(backend: askThenAnswer(oneOption), database: try organizedPersona("maya"), askPerson: person.ask).ask("?")
    #expect(!trace.askedUser && trace.clarifications.isEmpty)
    #expect(trace.toolCalls[0].error == "Bad value for \"options\".")
    #expect(person.asked.withLock { $0 } == 0)
}

@Test func profileCorrectionAnswersWithoutAsking() async throws {
    let database = try organizedPersona("maya")
    let mine = Profile.Value(name: "Oakwood Apartments", type: "rent", amount: 650, schedule: "monthly")
    try Profile.correct(id: "housing:mine", kind: "housing", value: mine, in: database)
    let person = Person("Mortgage")
    let ask = #"{"question": "Do you rent or own?", "options": ["Rent", "Mortgage"], "fact_key": "housing_type"}"#
    let trace = await Assistant(backend: askThenAnswer(ask), database: database, askPerson: person.ask).ask("?")
    #expect(person.asked.withLock { $0 } == 0)
    #expect(trace.clarifications.first?.answeredFromMemory == true)
    #expect(trace.clarifications.first?.answer?.contains("\"type\":\"rent\"") == true)
}
