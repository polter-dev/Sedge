// Runs the question bank through one configuration and saves every answer, with no grading:
//
//   swift run --package-path Packages/SedgeCore sedge-eval --config cloud --split dev
//
// Writes results.jsonl (one line per answer) and manifest.json into the --out folder.
// `--config apple` asks Apple's on-device model instead and needs no key. For the cloud, the
// key comes from the ANTHROPIC_API_KEY environment variable and is never printed.
import Foundation
import SedgeCore

let usage = """
    Usage: sedge-eval [options]
      --config cloud|context|apple
                              which model setup answers: cloud uses the organizer and data
                              tools; context gives the same model every raw transaction in its
                              prompt, with final_answer as its only tool; apple is Apple's
                              on-device model with the data tools
      --model <id>            cloud model to ask (default \(ClaudeBackend.defaultModel))
      --questions <csv>       question bank (default tools/eval/questions.csv)
      --split dev|test|all    which questions (default dev, or all when --ids is given)
      --ids a,b,c             only these question ids
      --repeat N              ask each question N times (default 1)
      --no-graph              organizer without the merchant graph
      --no-reconciliation     organizer without card-payment and transfer matching
      --out <folder>          where to save (default tools/eval/results/<run-id>);
                              run again with the same folder to finish a stopped run
    """

/// Prints a message and stops with a failure code.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

// The repository root, four folders up from this source file.
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
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
if options.config == "context", options.flags != OrganizerFlags() { fail("--config context doesn't use the organizer, so its switches don't apply.") }
if let split = options.split, !["dev", "test", "all"].contains(split) { fail("--split must be dev, test or all.") }
let backend: any ModelBackend
switch options.config {
case "cloud", "context":
    guard let key = ClaudeBackend.apiKey() else { fail("Set ANTHROPIC_API_KEY first (it is in .env).") }
    // Same model and effort for both configs, so the only difference is how the data arrives.
    backend = ClaudeBackend(model: options.model, effort: "medium", apiKey: key, dataTools: options.config != "context")
case "apple":
    // Checked once up front, so a run with Apple Intelligence off stops with the reason
    // instead of saving a hundred identical errors.
    if let reason = AppleBackend.unavailableReason() { fail(reason) }
    backend = AppleBackend()
    options.model = backend.model
default:
    fail("Unknown --config \(options.config). Use cloud, context or apple.")
}

// The run id names the folder: config, flags, model and start time, e.g. cloud-no-graph-claude-sonnet-5-5-20261015-142233.
let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                         timeZone: .current, calendar: .current))
let runID = ([options.config] + (options.flags.useGraph ? [] : ["no-graph"])
             + (options.flags.useReconciliation ? [] : ["no-reconciliation"]) + [options.model, stamp]).joined(separator: "-")
options.out = out ?? repoRoot.appending(path: "tools/eval/results/\(runID)", directoryHint: .isDirectory)

do {
    try await run(options, backend: backend, repoRoot: repoRoot) { line in
        // Progress goes to stderr, which isn't buffered, so each line shows as it happens.
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    print("Saved to \(options.out.path)")
} catch {
    fail("\(error)")
}
