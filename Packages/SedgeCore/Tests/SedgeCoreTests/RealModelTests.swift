import Foundation
import Jinja
import Synchronization
import Testing
@testable import SedgeCore

// The real Qwen3.5-4B weights through the Swift loop, on a Mac with Apple silicon. Off by default
// (it needs the 3 GB weights in the standard Hugging Face cache, from
// `hf download mlx-community/Qwen3.5-4B-MLX-4bit`). `swift test` can't load MLX's Metal library,
// so it runs through xcodebuild, from Packages/SedgeCore:
//   TEST_RUNNER_SEDGE_REAL_MODEL=1 xcodebuild test -scheme SedgeCore -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath ../../build/dd-core -only-testing:SedgeCoreTests/RealModel
// Only maya and daniel are asked. Whether an answer is right is the benchmark's job; this checks
// that the loop runs end to end on the real model and that each dollar answer is a number a tool
// returned during that question, as the system prompt requires.

/// The pinned snapshot in the standard Hugging Face cache.
let cachedWeights = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".cache/huggingface/hub/models--mlx-community--Qwen3.5-4B-MLX-4bit/snapshots/\(QwenModel.revision)")

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SEDGE_REAL_MODEL"] == "1"), .serialized)
struct RealModel {
    @Test func answersFiveQuestionsOnMayaAndDaniel() async throws {
        let model = Logged(inner: try await QwenModel.load(from: cachedWeights))
        // swift-transformers must cut the prompt into the same tokens as the notebook's tokenizer.
        let first = try #require(chat["first_rendered"] as? String)
        #expect(await (model.inner as! QwenModel).tokens(first) == chat["first_tokens"] as? [Int])

        let maya = try organizedPersona("maya"), daniel = try organizedPersona("daniel")
        // The last value says whether the answer is a dollar figure to check against the tools.
        let questions: [(String, SedgeDatabase, Bool)] = [
            ("How much have I spent at Value Mart since January?", maya, true),
            ("How much did I spend on gas this year?", daniel, true),
            ("How much do I owe on Card A right now?", daniel, true),
            ("Do I rent or own my place?", maya, false),
            ("Cancel my Netflix subscription for me.", daniel, false),
        ]
        for (question, database, checked) in questions {
            model.results.withLock { $0 = [] }
            let started = Date.now
            let outcome = await Assistant.run(question, database: database, model: model, askPerson: nil)
            print("REAL MODEL | \(question) | \(outcome) | \(Int(Date.now.timeIntervalSince(started))) s")
            guard case .answer(let answer) = outcome else { Issue.record("No answer for \(question): \(outcome)"); continue }
            guard checked else { continue }
            let reported = try #require(Double(answer.value.filter { $0.isNumber || $0 == "." || $0 == "-" }), "\(answer.value)")
            let returned = model.results.withLock { $0 }.flatMap(numbers)
            #expect(returned.contains(reported), "\(question): \(answer.value) is not a number the tools returned")
        }
    }

    /// The two questions that ended the app on an iPhone (daniel): a question, then the vague
    /// follow-up "is that a lot?", in one chat, through one loaded model, the way Ask runs them.
    /// Prints the memory footprint after loading and after each question.
    @Test func vagueFollowUpOnDaniel() async throws {
        let model = Logged(inner: try await QwenModel.load(from: cachedWeights))
        print("REAL MODEL | loaded | footprint \(footprint())")
        let daniel = try organizedPersona("daniel")
        let askPerson: AskPerson = { clarification in
            print("REAL MODEL |   ask_user:", clarification.question, clarification.options)
            return nil
        }
        for question in ["how much did i spend on gas this year?", "is that a lot?"] {
            let started = Date.now
            let outcome = await Assistant.run(question, database: daniel, model: model, askPerson: askPerson)
            print("REAL MODEL | \(question) | \(outcome) | \(Int(Date.now.timeIntervalSince(started))) s | footprint \(footprint())")
            guard case .answer = outcome else { Issue.record("No answer for \(question): \(outcome)"); continue }
        }
    }

    /// Every number in a tool's JSON result.
    func numbers(_ json: String) -> [Double] {
        func walk(_ value: Any) -> [Double] {
            switch value {
            case let number as NSNumber: [number.doubleValue]
            case let array as [Any]: array.flatMap(walk)
            case let object as [String: Any]: object.values.flatMap(walk)
            default: []
            }
        }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))).map(walk) ?? []
    }
}

/// Passes each turn to the real model, printing every step and the tool result it read, and keeps those results.
final class Logged: AssistantModel {
    let inner: any AssistantModel
    let results = Mutex<[String]>([])
    init(inner: any AssistantModel) { self.inner = inner }

    func reply(to messages: [Value], tools: [Value]) async throws -> String {
        if case .object(let last) = messages.last, last["role"] == "tool", case .string(let result) = last["content"] {
            results.withLock { $0.append(result) }
            print("REAL MODEL |   result:", result.prefix(300))
        }
        let text = try await inner.reply(to: messages, tools: tools)
        print("REAL MODEL |   step:", text.replacingOccurrences(of: "\n", with: " "))
        return text
    }
}

/// This process's physical memory footprint now and at its highest, in MB: the figure iOS ends an app on.
func footprint() -> (now: Int64, peak: Int64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return (Int64(info.phys_footprint) >> 20, info.ledger_phys_footprint_peak >> 20)
}
