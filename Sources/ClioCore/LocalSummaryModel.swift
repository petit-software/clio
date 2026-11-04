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
    /// Tokens of context asked of the model. Not its maximum — these models
    /// hold 32k and more — but what the KV cache is sized for: about a
    /// gigabyte at this size for a 4B model, which an 8 GB Mac can carry
    /// beside the weights.
    public nonisolated let contextTokens: Int
    /// How long the weights stay loaded after a request. Settings ▸ Model's
    /// "Keep model in memory" sets it: minutes when on, seconds when off.
    public private(set) var idleTime: Duration

    private let queue = DispatchSerialQueue(label: "com.bartbak.clio.summary-model", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var requests = 0
    private var unloadTask: Task<Void, Never>?

    public init(file: URL, name: String? = nil, contextTokens: Int = 8_192,
                idleTime: Duration = .seconds(120)) {
        self.file = file
        self.name = name ?? file.deletingPathExtension().lastPathComponent
        self.contextTokens = contextTokens
        self.idleTime = idleTime
    }

    /// Characters per request: the context less what the instructions and
    /// the answer need, at a conservative three characters a token, so a
    /// transcript in a language that tokenizes worse than English still fits.
    public nonisolated var pieceLimit: Int {
        max(1_000, (contextTokens - answerTokens - 600) * 3)
    }

    /// The most a summary is allowed to run on.
    nonisolated let answerTokens = 1_500

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

    public var isLoaded: Bool { context != nil }

    /// Loads the weights if they are not loaded. Public so a caller can pay
    /// for it at a moment of its choosing — a meeting's end, say, while the
    /// last chunks are still transcribing.
    public func load() throws {
        _ = Self.backend
        unloadTask?.cancel()
        unloadTask = nil
        guard context == nil else { return }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999       // everything on the GPU
        guard let model = llama_model_load_from_file(file.path, modelParams) else {
            throw SummaryError.modelFailedToLoad(name)
        }

        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextTokens)
        params.n_batch = 2_048
        params.n_ubatch = 512
        let threads = Int32(max(1, min(8, Self.performanceCores)))
        params.n_threads = threads
        params.n_threads_batch = threads
        params.no_perf = true
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw SummaryError.modelFailedToLoad(name)
        }
        self.model = model
        self.context = context
    }

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
        guard let model, let context else { throw SummaryError.unavailable }
        let vocab = llama_model_get_vocab(model)

        let text = Self.chatPrompt(model: model, instructions: instructions, prompt: prompt)
        var tokens = try Self.tokenize(text, vocab: vocab)
        guard tokens.count + answerTokens <= contextTokens else { throw SummaryError.promptTooLong }

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
