// Runs the question bank through one configuration and saves every answer, with no grading:
//
//   swift run --package-path Packages/SedgeCore sedge-eval --config cloud --split dev
//
// Writes results.jsonl (one line per answer) and manifest.json into the --out folder.
// The key comes from the ANTHROPIC_API_KEY environment variable and is never printed.
//
//   swift run --package-path Packages/SedgeCore sedge-eval profile --persona maya
//
// prints one persona's profile facts instead (see `profile` below).
import Foundation
import SedgeCore

let usage = """
    Usage: sedge-eval [options]
      --config cloud          which model setup answers (only "cloud" for now)
      --model <id>            model to ask (default \(ClaudeBackend.defaultModel))
      --questions <csv>       question bank (default tools/eval/questions.csv)
      --split dev|test|all    which questions (default dev, or all when --ids is given)
      --ids a,b,c             only these question ids
      --repeat N              ask each question N times (default 1)
      --no-graph              organizer without the merchant graph
      --no-reconciliation     organizer without card-payment and transfer matching
      --out <folder>          where to save (default tools/eval/results/<run-id>);
                              run again with the same folder to finish a stopped run

    Or: sedge-eval profile --persona <name>   print one persona's profile facts as JSON
    """

/// Prints a message and stops with a failure code.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// The repository root, four folders up from this source file.
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized

// `profile` loads and organizes one fake persona and prints its profile facts as JSON
// (value, confidence, evidence transaction ids and rule), to check against a truth file.
// It needs no key and makes no calls, so it runs before any of the options below.
if CommandLine.arguments.dropFirst().first == "profile" {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3, arguments[1] == "--persona", Persona.all.contains(arguments[2]) else {
        fail("Usage: sedge-eval profile --persona <\(Persona.all.joined(separator: "|"))>")
    }
    let folder = repoRoot.appending(path: "tools/data/\(arguments[2])")
    let database = try SedgeDatabase()
    try Persona.load(accounts: folder.appending(path: "accounts.json"),
                     transactions: folder.appending(path: "transactions.json"), into: database)
    try Organizer.organize(database)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(Profile.facts(in: database)), as: UTF8.self))
    exit(0)
}
var options = Options(questions: repoRoot.appending(path: "tools/eval/questions.csv"), out: URL(filePath: "/"))
var out: URL?

var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
/// The value after an option such as `--model`.
@MainActor func value(_ option: String) -> String {
    guard let value = arguments.next() else { fail("\(option) needs a value.\n\n\(usage)") }
    return value
}
while let argument = arguments.next() {
    switch argument {
    case "--config": options.config = value(argument)
    case "--model": options.model = value(argument)
    case "--questions": options.questions = URL(filePath: value(argument))
    case "--split": options.split = value(argument)
    case "--ids": options.ids = value(argument).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    case "--repeat":
        guard let count = Int(value(argument)), count > 0 else { fail("--repeat needs a whole number above 0.") }
        options.repeats = count
    case "--no-graph": options.flags.useGraph = false
    case "--no-reconciliation": options.flags.useReconciliation = false
    case "--out": out = URL(filePath: value(argument), directoryHint: .isDirectory)
    case "--help", "-h":
        print(usage)
        exit(0)
    default: fail("Unknown option \(argument).\n\n\(usage)")
    }
}
guard options.config == "cloud" else { fail("Unknown --config \(options.config). Only \"cloud\" exists so far.") }
if let split = options.split, !["dev", "test", "all"].contains(split) { fail("--split must be dev, test or all.") }
guard let key = ClaudeBackend.apiKey() else { fail("Set ANTHROPIC_API_KEY first (it is in .env).") }

// The run id names the folder: config, flags, model and start time, e.g. cloud-no-graph-claude-sonnet-5-5-20261015-142233.
let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                         timeZone: .current, calendar: .current))
let runID = ([options.config] + (options.flags.useGraph ? [] : ["no-graph"])
             + (options.flags.useReconciliation ? [] : ["no-reconciliation"]) + [options.model, stamp]).joined(separator: "-")
options.out = out ?? repoRoot.appending(path: "tools/eval/results/\(runID)", directoryHint: .isDirectory)

let backend = ClaudeBackend(model: options.model, effort: "medium", apiKey: key)
do {
    try await run(options, backend: backend, repoRoot: repoRoot) { line in
        // Progress goes to stderr, which isn't buffered, so each line shows as it happens.
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    print("Saved to \(options.out.path)")
} catch {
    fail("\(error)")
}
