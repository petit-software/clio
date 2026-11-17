import Foundation
import llama

/// A downloaded language model — one GGUF file — run by llama.cpp on the
/// GPU, to write meeting summaries where Apple's model is not wanted or not
/// there.
///
/// An actor on a dispatch queue of its own: a summary is tens of seconds of
/// synchronous C calls, and on the cooperative pool that is a thread the
/// rest of the app cannot have. Being an actor also makes it one request at
/// a time, which the C API needs — one context, one memory.
///
/// Weights are loaded on the first request and let go after `idleTime`
/// without another: a model is a few gigabytes resident, and summaries come
/// one at the end of a meeting, or a handful in a row from the library.
public actor LocalSummaryModel: SummaryLanguageModel {

    public nonisolated let file: URL
    public nonisolated let name: String
    /// The most context a request may ask for. Not the model's maximum —
    /// these models hold 32k and more — but what this Mac can carry beside
    /// the weights: the KV cache is sized from the context, and
    /// `contextCeiling(ram:)` picks it from the memory there is.
    ///
    /// A ceiling, not a size. Each request gets a context fitted to its own
    /// prompt (`contextSize(forPrompt:)`), so a ten-minute meeting on a big
    /// Mac does not pay for an hour's worth of cache.
    public nonisolated let contextTokens: Int
    /// How long the weights stay loaded after a request. Settings ▸ Model's
    /// "Keep model in memory" sets it: minutes when on, seconds when off.
    public private(set) var idleTime: Duration

    private let queue = DispatchSerialQueue(label: "com.bartbak.clio.summary-model", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    /// The size `context` was made at; zero when there is none.
    private var contextSize = 0
    private var requests = 0
    private var unloadTask: Task<Void, Never>?

    /// `contextTokens` nil means the ceiling for this Mac and this file.
    public init(file: URL, name: String? = nil, contextTokens: Int? = nil,
                idleTime: Duration = .seconds(120)) {
        self.file = file
        self.name = name ?? file.deletingPathExtension().lastPathComponent
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        self.contextTokens = contextTokens
            ?? Self.contextCeiling(weightsBytes: Int64(size))
        self.idleTime = idleTime
    }

    // MARK: Sizing

    /// The ceiling for a model of `weightsBytes` on a Mac with `ram` bytes
    /// of memory. Two limits, and the lower one holds:
    ///
    /// - by the Mac: 8k on 8 GB, 16k up to 16 GB, 32k above — an hour and a
    ///   half of meeting in one request;
    /// - by the model: weights and cache together stay under half the
    ///   memory. The cache is what grows with the context, and it grows
    ///   faster for a bigger model.
    ///
    /// Never under 4k: a model that is on this Mac at all is given enough
    /// to work a piece at a time.
    public static func contextCeiling(
        ram: UInt64 = ProcessInfo.processInfo.physicalMemory,
        weightsBytes: Int64) -> Int {
        let gigabyte: UInt64 = 1 << 30
        let byMac = ram <= 8 * gigabyte ? 8_192 : ram <= 16 * gigabyte ? 16_384 : 32_768
        let room = Double(ram) / 2 - Double(weightsBytes)
        let byModel = Int(room / cacheBytesPerToken(weightsBytes: weightsBytes))
        let stepped = byModel / contextStep * contextStep
        return max(4_096, min(byMac, stepped))
    }

    /// What one token of context costs in cache, estimated from the size of
    /// the weights. Measured on Qwen3 4B (Q4_K_M, 2.5 GB): 143 KB a token —
    /// 585 MB at 4k, 2.9 GB at 20k (`ModelResidency`, contextCost). Scaled
    /// by file size for other models, which is rough — the cache goes with
    /// layers × width, the weights with layers × width² — but lands on 390
    /// to 430 KB for a 12B model, whose arithmetic says 393.
    static func cacheBytesPerToken(weightsBytes: Int64) -> Double {
        max(64_000, Double(weightsBytes) * 5.9e-5)
    }

    /// What every request is given before its prompt is counted: room for
    /// the chat template's own tokens and a margin, so no window is filled
    /// to the last token.
    static let slackTokens = 256
    /// The least an answer is given, and how much more per token of prompt:
    /// a long meeting has more topics, and its summary runs longer.
    static let answerBase = 1_500
    static let answerShare = 0.1
    static let answerMost = 4_000
    /// Contexts are made in steps, so two meetings of nearly the same
    /// length share one.
    static let contextStep = 2_048

    /// Tokens an answer to a prompt of `promptTokens` may run to.
    static func answerTokens(forPrompt promptTokens: Int) -> Int {
        min(answerMost, answerBase + Int(Double(promptTokens) * answerShare))
    }

    /// The context a prompt of `promptTokens` needs, rounded up to a step
    /// and held under `ceiling`. Nil when it does not fit at all.
    static func contextSize(forPrompt promptTokens: Int, ceiling: Int) -> Int? {
        let needed = promptTokens + answerTokens(forPrompt: promptTokens) + slackTokens
        guard needed <= ceiling else { return nil }
        let stepped = (needed + contextStep - 1) / contextStep * contextStep
        return min(stepped, ceiling)
    }

    /// Characters per request: the most prompt the ceiling holds beside its
    /// answer, less the instructions, at a conservative three characters a
    /// token, so a transcript in a language that tokenizes worse than
    /// English still fits. Only for cutting a transcript into pieces — what
    /// a request is given is counted in real tokens.
    public nonisolated var pieceLimit: Int {
        let room = Double(contextTokens - Self.slackTokens - Self.answerBase)
        let prompt = Int(room / (1 + Self.answerShare)) - 600
        return max(1_000, prompt * 3)
    }

    // MARK: Loading

    /// Once per process. llama.cpp logs everything it does to stderr; only
    /// its errors are worth the user's console.
    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            FileHandle.standardError.write(Data(("[llama] " + String(cString: text)).utf8))
        }, nil)
        llama_backend_init()
    }()

    public var isLoaded: Bool { model != nil }

    /// Loads the weights if they are not loaded. Public so a caller can pay
    /// for it at a moment of its choosing — a meeting's end, say, while the
    /// last chunks are still transcribing. The context comes with the first
    /// request, once its prompt has been counted.
    public func load() throws {
        _ = Self.backend
        unloadTask?.cancel()
        unloadTask = nil
        guard model == nil else { return }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999       // everything on the GPU
        guard let model = llama_model_load_from_file(file.path, modelParams) else {
            throw SummaryError.modelFailedToLoad(name)
        }
        self.model = model
    }

    /// A context of `size` tokens: the one there is, if it is that size,
    /// else a new one in its place. Never two at once — the old one's cache
    /// is freed before the new one's is asked for.
    private func context(ofSize size: Int) throws -> OpaquePointer {
        if let context, contextSize == size { return context }
        if let context { llama_free(context) }
        context = nil
        contextSize = 0
        guard let model else { throw SummaryError.unavailable }

        var params = llama_context_default_params()
        params.n_ctx = UInt32(size)
        params.n_batch = 2_048
        params.n_ubatch = 512
        let threads = Int32(max(1, min(8, Self.performanceCores)))
        params.n_threads = threads
        params.n_threads_batch = threads
        params.no_perf = true
        guard let context = llama_init_from_model(model, params) else {
            throw SummaryError.modelFailedToLoad(name)
        }
        self.context = context
        contextSize = size
        return context
    }

    /// The size of the context the last request ran in; zero before one.
    public var currentContextTokens: Int { contextSize }

    /// Changes how long the weights stay loaded after a request. If they are
    /// waiting to be freed now, the wait starts over at the new length.
    public func setIdleTime(_ time: Duration) {
        guard time != idleTime else { return }
        idleTime = time
        if unloadTask != nil { scheduleUnload() }
    }

    /// Frees the weights. Nothing is lost: the next request loads them again.
    public func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        contextSize = 0
        model = nil
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let generation = requests
        unloadTask = Task { [weak self, idleTime] in
            try? await Task.sleep(for: idleTime)
            guard !Task.isCancelled, let self else { return }
            await self.unloadIfIdle(since: generation)
        }
    }

    private func unloadIfIdle(since generation: Int) {
        guard requests == generation else { return }
        unload()
    }

    // MARK: Answering

    public func respond(instructions: String, prompt: String) async throws -> String {
        requests += 1
        defer { scheduleUnload() }
        try load()
        guard let model else { throw SummaryError.unavailable }
        let vocab = llama_model_get_vocab(model)

        let text = Self.chatPrompt(model: model, instructions: instructions, prompt: prompt)
        var tokens = try Self.tokenize(text, vocab: vocab)
        // The prompt counted, not estimated: the context is made to fit it,
        // under the ceiling and under what the model was trained to hold.
        let ceiling = min(contextTokens, Int(llama_model_n_ctx_train(model)))
        guard let size = Self.contextSize(forPrompt: tokens.count, ceiling: ceiling) else {
            throw SummaryError.promptTooLong
        }
        let answerTokens = Self.answerTokens(forPrompt: tokens.count)
        let context = try context(ofSize: size)

        // Each request starts from nothing: no earlier prompt in the cache.
        llama_memory_clear(llama_get_memory(context), true)

        // The prompt, a batch at a time.
        var offset = 0
        while offset < tokens.count {
            let count = min(2_048, tokens.count - offset)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + offset, Int32(count)))
            }
            guard status == 0 else { throw SummaryError.generationFailed }
            offset += count
            try Task.checkCancellation()
        }

        // Nearly greedy: a summary wants the likeliest words, not variety.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))

        var answer = Data()
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<answerTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, true)
            if length > 0 {
                piece.withUnsafeBufferPointer { answer.append(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: Int(length)) }
            }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { break }
            try Task.checkCancellation()
        }
        return String(decoding: answer, as: UTF8.self)
    }

    // MARK: Pieces

    /// The two messages in the model's own chat format. llama.cpp knows the
    /// templates of the models in the catalog (ChatML for Qwen, Gemma's own);
    /// for a model it does not, a plain ChatML rendering is used.
    static func chatPrompt(model: OpaquePointer, instructions: String, prompt: String) -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = [("system", instructions), ("user", prompt)]
        var rendered: String?
        if let template {
            let cStrings = roles.flatMap { [strdup($0.0), strdup($0.1)] }
            defer { cStrings.forEach { free($0) } }
            var messages = stride(from: 0, to: cStrings.count, by: 2).map {
                llama_chat_message(role: UnsafePointer(cStrings[$0]), content: UnsafePointer(cStrings[$0 + 1]))
            }
            var buffer = [CChar](repeating: 0, count: (instructions.utf8.count + prompt.utf8.count) * 2 + 1_024)
            var length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
            if length > Int32(buffer.count) {
                buffer = [CChar](repeating: 0, count: Int(length) + 1)
                length = llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(buffer.count))
            }
            if length > 0 {
                rendered = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return rendered ?? chatML(roles)
    }

    static func chatML(_ messages: [(String, String)]) -> String {
        messages.map { "<|im_start|>\($0.0)\n\($0.1)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
    }

    static func tokenize(_ text: String, vocab: OpaquePointer?) throws -> [llama_token] {
        let utf8 = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        var count = utf8.withUnsafeBufferPointer { bytes in
            llama_tokenize(vocab, UnsafeRawPointer(bytes.baseAddress!).assumingMemoryBound(to: CChar.self),
                           Int32(bytes.count), &tokens, Int32(tokens.count), true, true)
        }
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = utf8.withUnsafeBufferPointer { bytes in
                llama_tokenize(vocab, UnsafeRawPointer(bytes.baseAddress!).assumingMemoryBound(to: CChar.self),
                               Int32(bytes.count), &tokens, Int32(tokens.count), true, true)
            }
        }
        guard count >= 0 else { throw SummaryError.generationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    /// Performance cores, for the CPU side of decoding.
    static var performanceCores: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}
