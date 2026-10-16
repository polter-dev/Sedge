// Asks one question about one fake persona and prints the full trace as JSON.
//
//   swift run --package-path Packages/SedgeCore sedge-ask maya "How much did I spend at Netflix from January through June?"
//
// Optional third and fourth arguments pick the model and effort, e.g. `claude-opus-5-5 high`.
// The key comes from the ANTHROPIC_API_KEY environment variable and is never printed.
import Foundation
import SedgeCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, Persona.all.contains(arguments[0]) else {
    print("Usage: sedge-ask <\(Persona.all.joined(separator: "|"))> \"<question>\" [model] [effort]")
    exit(2)
}
guard let key = ClaudeBackend.apiKey() else {
    print("Set ANTHROPIC_API_KEY first (it is in .env).")
    exit(1)
}

// The persona files live in tools/data, four folders up from this source file.
let folder = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../../tools/data/\(arguments[0])").standardized
let database = try SedgeDatabase()
try Persona.load(accounts: folder.appending(path: "accounts.json"),
                 transactions: folder.appending(path: "transactions.json"), into: database)
try Organizer.organize(database)

let backend = ClaudeBackend(model: arguments.count > 2 ? arguments[2] : ClaudeBackend.defaultModel,
                            effort: arguments.count > 3 ? arguments[3] : "medium", apiKey: key)
let trace = await Assistant(backend: backend, database: database).ask(arguments[1])

let encoder = JSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
print(String(decoding: try encoder.encode(trace), as: UTF8.self))
