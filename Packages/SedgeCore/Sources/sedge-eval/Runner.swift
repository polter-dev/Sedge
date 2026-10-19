import CryptoKit
import Foundation
import SedgeCore

/// One row of `tools/eval/questions.csv`, keeping only what the runner needs. The
/// `expected`, `truth_sql` and `needs_clarification` columns belong to the grader and are
/// never read here.
struct Question {
    let id, persona, type, split, asOf, text: String
    /// The scripted reply to ask_user, or "" when the person wouldn't answer.
    var clarifyReply = ""
}

/// The organizer's ablation switches, recorded with every answer.
struct OrganizerFlags: Codable, Equatable {
    var useGraph = true
    var useReconciliation = true
}

/// Everything one run is told on the command line.
struct Options {
    var config = "cloud"
    var model = ClaudeBackend.defaultModel
    var questions: URL
    /// nil means "dev", or "all" when `ids` is given, so `--ids` alone finds any question.
    var split: String?
    var ids: [String]?
    var repeats = 1
    var flags = OrganizerFlags()
    /// The run's folder. Its name is the run id.
    var out: URL
}

/// One answer: a line of `results.jsonl`. The grader joins it to `questions.csv` by `id`.
struct ResultLine: Codable {
    var id, persona, type, asOf, config, model: String
    /// Which pass this is, from 1 to `--repeat`.
    var `repeat`: Int
    var flags: OrganizerFlags
    var finalAnswer: FinalAnswer?
    /// The model's last plain text, kept as given even when it is also in `final_answer`.
    var rawText: String
    /// nil when there is an answer; otherwise format_error, refusal, max_tokens, tool_limit,
    /// api_error, or one of the on-device labels (see `AppleBackend.label`): guardrail,
    /// context_window, bad_arguments, tool_error, unsupported_language, unsupported_capability,
    /// unsupported_content, and the transient model_unavailable, rate_limited, busy, timeout.
    var errorType: String?
    var latencySeconds: Double
    var inputTokens: Int
    var outputTokens: Int
    /// Everything about the answer, e.g. `turns` and `split_turns` (turns Apple's backend
    /// spent because calls made together arrived too far apart; 0 normally, always 0 for Claude).
    var trace: Trace
}

/// What made a run, so its numbers can be traced back and compared fairly.
struct Manifest: Codable {
    var runId: String
    var startedAt: String
    /// nil while running, or if the run was stopped before it finished.
    var endedAt: String?
    var gitCommit: String
    /// True when tracked files differed from the commit (results folders aside).
    var gitDirty: Bool
    var macosBuild: String
    var machine: String
    var config: String
    var model: String
    var effort: String?
    /// Every model id the API said answered, which can be more specific than `model`.
    var reportedModels: [String]
    var promptVersion: String
    var promptSha256: String
    var toolSetVersion: String
    var toolSetSha256: String
    var questionsFile: String
    var questionsSha256: String
    var flags: OrganizerFlags
    /// True when ask_user is offered and answered with each question's clarify_reply (and
    /// left unanswered when it has none). The context baseline has no ask_user, so false.
    var clarifyReplies: Bool
    var split: String
    var ids: [String]?
    var `repeat`: Int
    /// Lines in results.jsonl.
    var results: Int

    /// The settings that shape an answer. A folder holds one set only; otherwise a
    /// resumed run would quietly mix two configurations in one results file.
    var settings: [(name: String, value: String)] {
        [("config", config), ("model", model), ("effort", effort ?? "none"),
         ("use_graph", "\(flags.useGraph)"), ("use_reconciliation", "\(flags.useReconciliation)"),
         ("clarify_replies", "\(clarifyReplies)"),
         ("system prompt", promptSha256), ("tool set", toolSetSha256), ("question bank", questionsSha256),
         ("git commit", gitCommit)]
            // The on-device model's version is the OS build, so an OS update changes the model.
            + (config == "apple" ? [("macOS build", macosBuild)] : [])
    }
}

/// A problem with the input or the results folder, shown to the person as is.
struct EvalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Splits CSV text into rows of cells, the way Python's csv module writes them: a quoted
/// cell may hold commas, line breaks and doubled quotes (`""` stands for one `"`).
func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if quoted {
            if character != "\"" {
                cell.append(character)
            } else if index + 1 < characters.count, characters[index + 1] == "\"" {
                cell.append("\"")
                index += 1
            } else {
                quoted = false
            }
        } else if character == "\"" {
            quoted = true
        } else if character == "," {
            row.append(cell)
            cell = ""
        } else if character == "\n" || character == "\r\n" { // Swift reads "\r\n" as one character
            row.append(cell)
            rows.append(row)
            row = []
            cell = ""
        } else {
            cell.append(character)
        }
        index += 1
    }
    if !cell.isEmpty || !row.isEmpty { rows.append(row + [cell]) }
    return rows
}

/// Reads the question bank. A blank `as_of` means the data's own last day.
func loadQuestions(_ data: Data) throws -> [Question] {
    let rows = parseCSV(String(decoding: data, as: UTF8.self))
    let header = rows.first ?? []
    let column = Dictionary(header.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    for name in ["id", "persona", "type", "split", "as_of", "question"] where column[name] == nil {
        throw EvalError("questions file has no \"\(name)\" column")
    }
    return try rows.dropFirst().filter { $0 != [""] }.map { row in
        // A missing optional column (clarify_reply in an older file) reads as empty.
        func cell(_ name: String) -> String { column[name].map { $0 < row.count ? row[$0] : "" } ?? "" }
        let question = Question(id: cell("id"), persona: cell("persona"), type: cell("type"), split: cell("split"),
                                asOf: cell("as_of").isEmpty ? Persona.asOf : cell("as_of"), text: cell("question"),
                                clarifyReply: cell("clarify_reply"))
        guard Persona.all.contains(question.persona) else { throw EvalError("\(question.id): unknown persona \"\(question.persona)\"") }
        // Dates are compared as text, which only works in this exact shape.
        guard question.asOf.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { throw EvalError("\(question.id): as_of must be YYYY-MM-DD") }
        return question
    }
}

/// The questions this run asks, in file order.
func select(_ questions: [Question], split: String, ids: [String]?) throws -> [Question] {
    if let ids {
        let unknown = Set(ids).subtracting(questions.map(\.id))
        guard unknown.isEmpty else { throw EvalError("no question with id " + unknown.sorted().joined(separator: ", ")) }
    }
    let chosen = questions.filter { (split == "all" || $0.split == split) && (ids?.contains($0.id) ?? true) }
    guard !chosen.isEmpty else { throw EvalError("no questions match --split \(split)") }
    return chosen
}

/// A fresh in-memory database holding one persona as it stood on `asOf`, organized with
/// this run's switches, or left raw when `flags` is nil. `dataFolder` is `tools/data`.
func prepareDatabase(persona: String, asOf: String, dataFolder: URL, flags: OrganizerFlags?) throws -> SedgeDatabase {
    let folder = dataFolder.appending(path: persona)
    let database = try SedgeDatabase()
    try Persona.load(accounts: folder.appending(path: "accounts.json"),
                     transactions: folder.appending(path: "transactions.json"), into: database, asOf: asOf)
    if let flags { try Organizer.organize(database, useGraph: flags.useGraph, useReconciliation: flags.useReconciliation) }
    return database
}

/// Sorts a trace's outcome into one word the grader can count.
func errorType(_ trace: Trace) -> String? {
    if trace.finalAnswer != nil { return nil }
    if trace.formatError { return "format_error" }
    // The backends start these errors with their label, e.g. "refusal: cyber".
    let labels = ["refusal", "guardrail", "context_window", "bad_arguments", "tool_error",
                  "unsupported_language", "unsupported_capability", "unsupported_content"] + retriedErrorTypes
    if let label = labels.first(where: { trace.error?.hasPrefix($0 + ":") == true }) { return label }
    if trace.error == "max_tokens" || trace.error == "tool_limit" { return trace.error }
    return "api_error"
}

/// Runs every chosen question `repeats` times and appends one line per answer to
/// `results.jsonl` as soon as it arrives. Answers already in the file are skipped, so a
/// stopped run picks up where it left off when started again with the same `out`.
func run(_ options: Options, backend: any ModelBackend, repoRoot: URL, log: (String) -> Void) async throws {
    let questionsData = try Data(contentsOf: options.questions)
    let split = options.split ?? (options.ids == nil ? "dev" : "all")
    let questions = try select(loadQuestions(questionsData), split: split, ids: options.ids)

    try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
    let resultsURL = options.out.appending(path: "results.jsonl")
    let manifestURL = options.out.appending(path: "manifest.json")
    let saved = try readFinished(resultsURL)
    var finished = saved.finished, reportedModels = saved.models

    // The context-stuffing baseline reads raw transactions from its prompt: no organizer, no data tools.
    let dataTools = options.config != "context"
    if let claude = backend as? ClaudeBackend, claude.dataTools != dataTools {
        throw EvalError("--config \(options.config) needs a backend made with dataTools: \(dataTools)")
    }
    let toolSet = try JSONSerialization.data(withJSONObject: ClaudeBackend.tools(dataTools: dataTools), options: .sortedKeys)
    var manifest = Manifest(
        runId: options.out.lastPathComponent, startedAt: Date.now.ISO8601Format(), endedAt: nil,
        gitCommit: git(["rev-parse", "HEAD"], in: repoRoot) ?? "unknown",
        // The results folders are excluded so a run's own output doesn't mark the code as changed.
        gitDirty: git(["status", "--porcelain", "--", ".", ":!tools/eval/results"], in: repoRoot)?.isEmpty == false,
        macosBuild: ProcessInfo.processInfo.operatingSystemVersionString,
        machine: sysctl("hw.model") + ", " + sysctl("machdep.cpu.brand_string"),
        config: options.config, model: backend.model, effort: backend.effort, reportedModels: [],
        promptVersion: SystemPrompt.version(dataTools: dataTools),
        promptSha256: sha256(Data(SystemPrompt.template(dataTools: dataTools).utf8)),
        toolSetVersion: Tool.version, toolSetSha256: sha256(toolSet),
        questionsFile: options.questions.path, questionsSha256: sha256(questionsData),
        flags: options.flags, clarifyReplies: dataTools, split: split, ids: options.ids, repeat: options.repeats, results: finished.count)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    if let old = try? decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL)) {
        let changed = zip(old.settings, manifest.settings).filter { $0.value != $1.value }.map { $0.0.name }
        guard changed.isEmpty else {
            throw EvalError("\(options.out.path) holds results made with a different \(changed.joined(separator: ", ")). Use a new --out.")
        }
        manifest.startedAt = old.startedAt
    } else if !finished.isEmpty || saved.dropped > 0 {
        // Without the old manifest there is nothing to compare against, so any setting could differ.
        throw EvalError("\(options.out.path) holds results but its manifest.json is missing or can't be read. Use a new --out.")
    }
    // Only now, with the settings known to match, may the old results file change.
    if saved.dropped > 0 {
        try saved.kept.write(to: resultsURL, options: .atomic)
        log("Asking \(saved.dropped) answer(s) again: cut off by a stop, or a temporary error.")
    }
    try write(manifest, to: manifestURL)

    if !FileManager.default.fileExists(atPath: resultsURL.path) { try Data().write(to: resultsURL) }
    let file = try FileHandle(forWritingTo: resultsURL)
    defer { try? file.close() }
    try file.seekToEnd()

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Questions about the same persona and day share one organized database. Tools only read
    // it; ask_user writes saved_answers, which is cleared before each question below.
    var databases: [String: SedgeDatabase] = [:]
    let total = questions.count * options.repeats
    var count = 0
    for pass in 1...options.repeats {
        for question in questions {
            count += 1
            let label = "[\(count)/\(total)] \(question.id) #\(pass)"
            if finished.contains("\(question.id)#\(pass)") {
                log("\(label) already done")
                continue
            }
            let key = question.persona + " " + question.asOf
            let database = try databases[key] ?? prepareDatabase(persona: question.persona, asOf: question.asOf,
                                                                 dataFolder: repoRoot.appending(path: "tools/data"),
                                                                 flags: dataTools ? options.flags : nil)
            databases[key] = database

            // The database is shared, so answers saved by an earlier question (or pass) are
            // forgotten first: each question must ask for itself, in any order.
            try AskUser.reset(database)
            let reply = question.clarifyReply
            let trace = await Assistant(backend: backend, database: database, dataTools: dataTools,
                                        askPerson: { _ in reply.isEmpty ? nil : reply }).ask(question.text)
            let line = ResultLine(id: question.id, persona: question.persona, type: question.type, asOf: question.asOf,
                                  config: options.config, model: backend.model, repeat: pass, flags: options.flags,
                                  finalAnswer: trace.finalAnswer, rawText: trace.text, errorType: errorType(trace),
                                  latencySeconds: trace.latencySeconds, inputTokens: trace.inputTokens,
                                  outputTokens: trace.outputTokens, trace: trace)
            // One write per line, so a run killed mid-question loses only that question.
            try file.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
            finished.insert("\(question.id)#\(pass)")
            if let model = trace.reportedModel { reportedModels.insert(model) }
            log("\(label) \(line.errorType ?? "ok") \(String(format: "%.1f", trace.latencySeconds))s "
                + "\(trace.inputTokens) in / \(trace.outputTokens) out"
                + (trace.askedUser ? ", asked " + trace.clarifications.map(\.factKey).joined(separator: ", ") : ""))
        }
    }
    manifest.endedAt = Date.now.ISO8601Format()
    manifest.reportedModels = reportedModels.sorted()
    manifest.results = finished.count
    try write(manifest, to: manifestURL)
}

/// Error types that say nothing about the question or the model, so resume asks them again:
/// `api_error` (network, rate limit, spending cap) and the on-device model being off, not
/// ready, rate limited, busy or timed out. Question-dependent failures such as
/// `unsupported_language` are not here: re-asking could repeat forever or hide a failure.
let retriedErrorTypes = ["api_error", "model_unavailable", "rate_limited", "busy", "timeout"]

/// The answers already saved, as "id#repeat", the model ids they report, and how many lines
/// were dropped so they are asked again: a last line cut off by a killed run, and answers with
/// one of the `retriedErrorTypes`. Every other line, model mistakes included, stays as it is in
/// `kept`, the file's new contents. Nothing is written here: the caller checks the settings first.
func readFinished(_ url: URL) throws -> (finished: Set<String>, models: Set<String>, dropped: Int, kept: Data) {
    guard let data = try? Data(contentsOf: url) else { return ([], [], 0, Data()) }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    // After the last newline: nothing, or the cut-off line of a killed run.
    var dropped = lines.popLast()?.isEmpty == false ? 1 : 0
    var kept = Data(), finished: Set<String> = [], models: Set<String> = []
    for (number, line) in lines.enumerated() {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? String, let pass = object["repeat"] as? Int else {
            throw EvalError("line \(number + 1) of \(url.path) can't be read")
        }
        if retriedErrorTypes.contains(object["error_type"] as? String ?? "") {
            dropped += 1
            continue
        }
        kept += line + Data("\n".utf8)
        finished.insert("\(id)#\(pass)")
        if let model = (object["trace"] as? [String: Any])?["reported_model"] as? String { models.insert(model) }
    }
    return (finished, models, dropped, kept)
}

func write(_ manifest: Manifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: url, options: .atomic)
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Runs git in the repository and returns its trimmed output, or nil if git failed.
func git(_ arguments: [String], in root: URL) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

/// A text value from the kernel's system information, e.g. "hw.model" gives "Mac16,1".
func sysctl(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [UInt8](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}
