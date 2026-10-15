// The evaluation command line.
//
//   swift run --package-path Packages/SedgeCore sedge-eval profile --persona maya
//
// `profile` loads and organizes one fake persona and prints its profile facts as JSON
// (value, confidence, evidence transaction ids and rule), to check against a truth file.
import Foundation
import SedgeCore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, arguments[0] == "profile", arguments[1] == "--persona", Persona.all.contains(arguments[2]) else {
    print("Usage: sedge-eval profile --persona <\(Persona.all.joined(separator: "|"))>")
    exit(2)
}

// The persona files live in tools/data, four folders up from this source file.
let folder = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../../tools/data/\(arguments[2])").standardized
let database = try SedgeDatabase()
try Persona.load(accounts: folder.appending(path: "accounts.json"),
                 transactions: folder.appending(path: "transactions.json"), into: database)
try Organizer.organize(database)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
print(String(decoding: try encoder.encode(Profile.facts(in: database)), as: UTF8.self))
