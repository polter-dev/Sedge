import Foundation
import Jinja
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Qwen3.5-4B (4-bit), the on-device model, run with MLX the way the benchmark notebook's
/// `mlx_turn` runs it: the model's own chat template with thinking off, greedy sampling
/// (temperature 0), at most 512 new tokens, stopping as soon as one tool call is complete.
/// Everything runs on the device: once the files are in the folder, nothing goes over the network.
public final class QwenModel: AssistantModel {
    /// The weights the benchmark measured, pinned to the commit in its Hugging Face cache.
    public static let repo = "mlx-community/Qwen3.5-4B-MLX-4bit"
    public static let revision = "32f3e8ecf65426fc3306969496342d504bfa13f3"
    /// The files the model needs, with their sizes in bytes (for the download's percent).
    public static let files: KeyValuePairs<String, Int64> = [
        "config.json": 3_366,
        "tokenizer_config.json": 1_139,
        "chat_template.jinja": 7_756,
        "tokenizer.json": 19_989_343,
        "model.safetensors": 3_034_300_695,
    ]
    /// The notebook's `LOCAL_MAX_TOKENS`.
    static let maxTokens = 512
    /// The notebook's `TEST_TEMPERATURE`: greedy, so the same question gets the same answer.
    static let temperature: Float = 0
    /// The longest prompt plus reply this app lets the model take on. The notebook set none (its Mac
    /// never ran out); a phone has far less memory, so a longer chat counts as a context overflow.
    static let contextLimit = 16_384

    let container: ModelContainer
    let template: Template

    private init(container: ModelContainer, template: Template) {
        self.container = container
        self.template = template
    }

    /// Loads the model from a folder holding `files`.
    public static func load(from folder: URL) async throws -> QwenModel {
        // A small buffer cache keeps memory down on a phone; MLX would otherwise hold freed buffers for reuse.
        Memory.cacheLimit = 20 * 1024 * 1024
        let container = try await loadModelContainer(from: folder, using: TokenizerLoader())
        let source = try String(contentsOf: folder.appending(path: "chat_template.jinja"), encoding: .utf8)
        return QwenModel(container: container, template: try template(source))
    }

    /// The chat template compiled with the settings Hugging Face's transformers uses.
    static func template(_ source: String) throws -> Template {
        try Template(source, with: .init(lstripBlocks: true, trimBlocks: true))
    }

    /// The prompt text, as `tokenizer.apply_chat_template(..., add_generation_prompt=True, enable_thinking=False)`.
    static func render(_ template: Template, messages: [Value], tools: [Value]) throws -> String {
        try template.render(["messages": .array(messages), "tools": .array(tools),
                             "add_generation_prompt": .boolean(true), "enable_thinking": .boolean(false)])
    }

    /// The tokens a prompt becomes, so a test can compare them with the notebook's tokenizer.
    func tokens(_ prompt: String) async -> [Int] {
        await container.perform { $0.tokenizer.encode(text: prompt, addSpecialTokens: true) }
    }

    public func reply(to messages: [Value], tools: [Value]) async throws -> String {
        let prompt = try Self.render(template, messages: messages, tools: tools)
        return try await container.perform { context in
            let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: true)
            guard tokens.count + Self.maxTokens <= Self.contextLimit else { throw ModelCrash.context }
            // mlx_lm stops at the tokenizer's end token (<|im_end|>) only.
            let stop = context.tokenizer.eosToken.flatMap(context.tokenizer.convertTokenToId)
            var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model,
                                             parameters: GenerateParameters(maxTokens: Self.maxTokens, temperature: Self.temperature))
            var output: [Int] = []
            var text = ""
            while let token = iterator.next(), token != stop {
                output.append(token)
                text = context.tokenizer.decode(tokenIds: output, skipSpecialTokens: false)
                if Assistant.isComplete(text) { return text } // one call per step, so stop here
            }
            if output.count >= Self.maxTokens { throw ModelCrash.maxTokens }
            return text
        }
    }
}

/// Loads the tokenizer with swift-transformers and hands it to MLX in MLX's own tokenizer shape.
private struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }

    struct Bridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        }
    }
}
