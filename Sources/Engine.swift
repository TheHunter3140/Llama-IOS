import Foundation
import llama

struct GenStats {
    var promptN = 0
    var genN = 0
    var ttft = 0.0
    var genTps = 0.0
    var promptTps = 0.0
}

struct EngineError: LocalizedError {
    let msg: String
    var errorDescription: String? { msg }
}

/// Moteur llama.cpp. Toutes les opérations de modèle/génération doivent être
/// séquentielles : VM empêche le changement de modèle pendant une génération.
final class Engine: @unchecked Sendable {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var messages: [(String, String)] = []
    private var nBatch = 256

    private let cancelLock = NSLock()
    private var cancelRequested = false

    private(set) var nPast = 0
    private(set) var nCtx = 0
    private(set) var info = "—"
    var loaded: Bool { ctx != nil && model != nil && vocab != nil }

    var cancel: Bool {
        get {
            cancelLock.lock()
            defer { cancelLock.unlock() }
            return cancelRequested
        }
        set {
            cancelLock.lock()
            cancelRequested = newValue
            cancelLock.unlock()
        }
    }

    init() {
        llama_backend_init()
    }

    @discardableResult
    func load(path: String, cfg: Cfg) -> Bool {
        unload()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(max(0, cfg.gpuLayers))

        let loadedModel: OpaquePointer? = path.withCString { cPath in
            llama_model_load_from_file(cPath, modelParams)
        }
        guard let loadedModel else { return false }

        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_model_free(loadedModel)
            return false
        }

        var contextParams = llama_context_default_params()
        let contextSize = max(512, cfg.nCtx)
        let batchSize = max(32, min(cfg.nBatch, contextSize))
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(batchSize)
        contextParams.n_ubatch = min(contextParams.n_ubatch, contextParams.n_batch)
        let threadCount = max(1, min(cfg.threads, ProcessInfo.processInfo.activeProcessorCount))
        contextParams.n_threads = Int32(threadCount)
        contextParams.n_threads_batch = Int32(threadCount)

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            return false
        }

        model = loadedModel
        vocab = loadedVocab
        ctx = loadedContext
        nBatch = batchSize
        nCtx = Int(llama_n_ctx(loadedContext))
        nPast = 0
        info = String(
            format: "%.1fB · %.2f Go",
            Double(llama_model_n_params(loadedModel)) / 1_000_000_000,
            Double(llama_model_size(loadedModel)) / 1_000_000_000
        )
        return true
    }

    func unload() {
        if let context = ctx { llama_free(context) }
        if let loadedModel = model { llama_model_free(loadedModel) }
        ctx = nil
        model = nil
        vocab = nil
        messages.removeAll(keepingCapacity: false)
        nPast = 0
        nCtx = 0
        info = "—"
    }

    /// Recharge l'historique visible dans l'application. Le cache KV est vidé :
    /// le prochain prompt sera reconstruit depuis l'historique complet.
    func restore(system: String, history: [Msg]) {
        messages = (system.isEmpty ? [] : [("system", system)])
            + history.map { ($0.role, $0.text) }
        nPast = 0
        if let context = ctx {
            llama_memory_clear(llama_get_memory(context), true)
        }
    }

    func generate(user: String, cfg: Cfg, onToken: (String) -> Void) throws -> GenStats {
        guard let context = ctx, let vocabulary = vocab, model != nil else {
            throw EngineError(msg: "Aucun modèle chargé")
        }

        cancel = false
        messages.append(("user", user))

        // Pour fiabiliser la conversation, on reconstruit le prompt complet à
        // chaque tour au lieu de découper le template sur un nombre d'octets.
        let prompt = format(messages, addAssistantPrefix: true)
        guard !prompt.isEmpty else {
            messages.removeLast()
            throw EngineError(msg: "Impossible de formater le prompt du modèle")
        }

        let tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else {
            messages.removeLast()
            throw EngineError(msg: "Échec de la tokenisation du prompt")
        }
        guard tokens.count + 1 < nCtx else {
            messages.removeLast()
            throw EngineError(msg: "Contexte trop petit : réduis l'historique ou augmente n_ctx")
        }

        // La mémoire est réinitialisée avant de réévaluer tout l'historique.
        llama_memory_clear(llama_get_memory(context), true)
        nPast = 0

        var samplerParams = llama_sampler_chain_default_params()
        samplerParams.no_perf = true
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            messages.removeLast()
            throw EngineError(msg: "Impossible d'initialiser l'échantillonneur")
        }
        defer { llama_sampler_free(sampler) }

        if cfg.temp <= 0 {
            guard let greedy = llama_sampler_init_greedy() else {
                messages.removeLast()
                throw EngineError(msg: "Échantillonneur greedy indisponible")
            }
            llama_sampler_chain_add(sampler, greedy)
        } else {
            let penalty = llama_sampler_init_penalties(
                64, Float(cfg.repeatPen), 0, 0
            )
            let topK = llama_sampler_init_top_k(Int32(max(1, cfg.topK)))
            let topP = llama_sampler_init_top_p(Float(cfg.topP), 1)
            let minP = llama_sampler_init_min_p(Float(cfg.minP), 1)
            let temperature = llama_sampler_init_temp(Float(cfg.temp))
            let distribution = llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max))

            guard let penalty, let topK, let topP, let minP,
                  let temperature, let distribution else {
                messages.removeLast()
                throw EngineError(msg: "Impossible de configurer l'échantillonnage")
            }
            llama_sampler_chain_add(sampler, penalty)
            llama_sampler_chain_add(sampler, topK)
            llama_sampler_chain_add(sampler, topP)
            llama_sampler_chain_add(sampler, minP)
            llama_sampler_chain_add(sampler, temperature)
            llama_sampler_chain_add(sampler, distribution)
        }

        var stats = GenStats()
        stats.promptN = tokens.count
        let promptStart = Date()
        guard decode(tokens) else {
            messages.removeLast()
            throw EngineError(msg: "Échec du décodage du prompt (mémoire ou contexte insuffisant)")
        }
        let generationStart = Date()
        stats.promptTps = Double(tokens.count) / max(generationStart.timeIntervalSince(promptStart), 0.001)

        var output = ""
        var pendingBytes: [UInt8] = []
        let tokenLimit = max(1, cfg.maxTokens)

        while stats.genN < tokenLimit && nPast < nCtx && !cancel {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }

            pendingBytes.append(contentsOf: piece(token, vocabulary: vocabulary))
            if let text = String(bytes: pendingBytes, encoding: .utf8) {
                output += text
                onToken(text)
                pendingBytes.removeAll(keepingCapacity: true)
            }

            guard decode([token]) else { break }
            stats.genN += 1
            if stats.genN == 1 {
                stats.ttft = Date().timeIntervalSince(promptStart)
            }
        }

        if !pendingBytes.isEmpty {
            let tail = String(decoding: pendingBytes, as: UTF8.self)
            output += tail
            onToken(tail)
        }

        stats.genTps = Double(stats.genN) / max(Date().timeIntervalSince(generationStart), 0.001)
        messages.append(("assistant", output))
        return stats
    }

    // MARK: - llama.cpp helpers

    private func decode(_ tokens: [llama_token]) -> Bool {
        guard let context = ctx, !tokens.isEmpty else { return false }
        var offset = 0

        while offset < tokens.count {
            let count = min(nBatch, tokens.count - offset)
            var chunk = Array(tokens[offset..<(offset + count)])
            let result = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return llama_decode(context, llama_batch_get_one(base, Int32(count)))
            }
            guard result == 0 else { return false }
            offset += count
            nPast += count
        }
        return true
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        guard let vocabulary = vocab else { return [] }
        let byteCount = text.utf8.count
        guard byteCount <= Int(Int32.max) - 16 else { return [] }

        var capacity = max(32, byteCount + 16)
        for _ in 0..<3 {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let count = text.withCString { cText in
                tokens.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return Int32(-1) }
                    return llama_tokenize(
                        vocabulary, cText, Int32(byteCount), base,
                        Int32(capacity), addSpecial, true
                    )
                }
            }
            if count >= 0 { return Array(tokens.prefix(Int(count))) }
            if count == Int32.min { return [] }
            capacity = Int(-count) + 8
        }
        return []
    }

    private func piece(_ token: llama_token, vocabulary: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            return llama_token_to_piece(vocabulary, token, base, Int32(pointer.count), 0, false)
        }

        if count < 0 {
            let required = Int(-count)
            buffer = [CChar](repeating: 0, count: required)
            count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return 0 }
                return llama_token_to_piece(vocabulary, token, base, Int32(pointer.count), 0, false)
            }
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func format(_ sourceMessages: [(String, String)], addAssistantPrefix: Bool) -> String {
        guard let loadedModel = model else { return "" }

        let allocated = sourceMessages.map { role, content in
            let rolePointer = role.withCString { strdup($0)! }
            let contentPointer = content.withCString { strdup($0)! }
            return (rolePointer, contentPointer)
        }
        defer {
            allocated.forEach { role, content in
                free(role)
                free(content)
            }
        }

        let chat = allocated.map { role, content in
            llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content))
        }

        let template = llama_model_chat_template(loadedModel, nil)
            .map { String(cString: $0) } ?? "chatml"

        func apply(_ templateName: String) -> String? {
            let messageBytes = sourceMessages.reduce(0) { $0 + $1.1.utf8.count }
            var capacity = max(4096, messageBytes * 2 + 512)

            for _ in 0..<3 {
                var output = [CChar](repeating: 0, count: capacity)
                let written = templateName.withCString { cTemplate in
                    chat.withUnsafeBufferPointer { chatBuffer in
                        output.withUnsafeMutableBufferPointer { outputBuffer in
                            llama_chat_apply_template(
                                cTemplate,
                                chatBuffer.baseAddress,
                                chatBuffer.count,
                                addAssistantPrefix,
                                outputBuffer.baseAddress,
                                Int32(capacity)
                            )
                        }
                    }
                }

                if written >= 0 && Int(written) < capacity {
                    return String(decoding: output.prefix(Int(written)).map {
                        UInt8(bitPattern: $0)
                    }, as: UTF8.self)
                }
                if written > 0 {
                    capacity = Int(written) + 1
                } else {
                    return nil
                }
            }
            return nil
        }

        if let formatted = apply(template) { return formatted }
        if template != "chatml", let formatted = apply("chatml") { return formatted }

        // Dernier recours pour les modèles sans template reconnu.
        var fallback = ""
        for (role, content) in sourceMessages {
            fallback += "### \(role.uppercased())\n\(content)\n\n"
        }
        if addAssistantPrefix { fallback += "### ASSISTANT\n" }
        return fallback
    }
}
