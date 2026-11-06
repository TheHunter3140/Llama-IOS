import SwiftUI
import UIKit
import os
import Darwin

struct Msg: Identifiable, Codable {
    var id = UUID()
    var role: String
    var text: String
    var thinkSeconds: Double? = nil
    var stat: String? = nil
}

struct ModelEntry: Identifiable, Codable {
    var id = UUID(); var name: String; var bookmark: Data; var sizeMB: Int
    var mmproj: Data? = nil; var mmprojName: String? = nil
    var relPath: String? = nil      // chemin relatif dans Documents (modèles du dossier Pal)
    var mmprojRel: String? = nil
}

enum PerfProfile: String, CaseIterable, Identifiable {
    case eco, balanced, performance, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .eco: return "Éco"
        case .balanced: return "Équilibré"
        case .performance: return "Max"
        case .custom: return "Perso"
        }
    }
    var icon: String {
        switch self {
        case .eco: return "leaf.fill"
        case .balanced: return "scale.3d"
        case .performance: return "bolt.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
    var detail: String {
        switch self {
        case .eco: return "Peu de RAM, batterie ménagée. Idéal pour un iPhone XR."
        case .balanced: return "Bon compromis vitesse / mémoire."
        case .performance: return "Contexte long et GPU Metal (expérimental, plus de RAM)."
        case .custom: return "Réglages personnalisés."
        }
    }

    func apply(_ cfg: inout Cfg) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch self {
        case .eco:
            cfg.nCtx = 768; cfg.nBatch = 64; cfg.threads = min(2, cores)
            cfg.gpuLayers = 0; cfg.maxTokens = 192
        case .balanced:
            cfg.nCtx = 1024; cfg.nBatch = 128; cfg.threads = min(3, cores)
            cfg.gpuLayers = 0; cfg.maxTokens = 256
        case .performance:
            cfg.nCtx = 2048; cfg.nBatch = 256; cfg.threads = max(2, min(4, cores - 1))
            cfg.gpuLayers = 99; cfg.maxTokens = 512
        case .custom:
            break
        }
    }

    static func detect(_ cfg: Cfg) -> PerfProfile {
        for profile in [PerfProfile.eco, .balanced, .performance] {
            var probe = cfg
            profile.apply(&probe)
            if probe.nCtx == cfg.nCtx && probe.nBatch == cfg.nBatch && probe.threads == cfg.threads
                && probe.gpuLayers == cfg.gpuLayers && probe.maxTokens == cfg.maxTokens {
                return profile
            }
        }
        return .custom
    }
}

struct Cfg: Codable {
    var temp = 0.7, topP = 0.9, minP = 0.05, repeatPen = 1.1
    var topK = 40, nCtx = 1024, nBatch = 128, threads = 3, gpuLayers = 0, maxTokens = 256
    var system = "Tu es un assistant concis et précis. Réponds dans la langue de l'utilisateur."
    var theme = 0, fontSize = 16.0, accR = 0.0, accG = 0.48, accB = 1.0
    var haptics = true, keepAwake = true
    var accent: Color { Color(red: accR, green: accG, blue: accB) }
    var scheme: ColorScheme? { theme == 1 ? .light : theme == 2 ? .dark : nil }
    mutating func setAccent(_ c: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        accR = r; accG = g; accB = b
    }
}

enum Sys {
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
    static func availMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }
    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "ok"
        case .fair: return "tiède"
        case .serious: return "chaud"
        case .critical: return "critique"
        @unknown default: return "?"
        }
    }
    static var battery: String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = UIDevice.current.batteryLevel
        if l < 0 { return "—" }
        return "\(Int(l * 100)) %" + (UIDevice.current.batteryState == .charging ? " ⚡︎" : "")
    }
    static var disk: String {
        String(format: "%.1f Go", Double(freeDiskBytes()) / 1e9)
    }
    static func freeDiskBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

@MainActor final class VM: ObservableObject {
    let engine = Engine()
    let speaker = Speaker()
    @Published var cfg = Cfg() { didSet { if let d = try? JSONEncoder().encode(cfg) { UD.set(d, forKey: "cfg") } } }
    @Published var prefs = Prefs() { didSet { if let d = try? JSONEncoder().encode(prefs) { UD.set(d, forKey: "prefs") } } }
    @Published var models: [ModelEntry] = []
    @Published var skills: [PalSkill] = PalSkill.defaults
    @Published var conversations: [Conversation] = []
    @Published var currentChatID = UUID()
    @Published var currentID: UUID?
    @Published var messages: [Msg] = []
    @Published var streaming: String?
    @Published var input = ""
    @Published var status = "Aucun modèle"
    @Published var stats = GenStats()
    @Published var loading = false
    @Published var benchmark = ""
    @Published var requestModelPicker = false
    @Published var personas: [Persona] = Persona.defaults
    private var genStart = Date()
    private var thinkEnd: Date?
    private var memWarn = false
    private var pendingSend = false
    private var pendingSignature = ""
    private var loadedSignature = ""
    private var idleTask: Task<Void, Never>?
    var generating: Bool { streaming != nil }
    private var scoped: URL?
    let UD = UserDefaults.standard

    init() {
        PalFolders.prepare()
        if let d = UD.data(forKey: "cfg"), let c = try? JSONDecoder().decode(Cfg.self, from: d) { cfg = c }
        if let d = UD.data(forKey: "prefs"), let p = try? JSONDecoder().decode(Prefs.self, from: d) { prefs = p }
        if let d = UD.data(forKey: "models"), let m = try? JSONDecoder().decode([ModelEntry].self, from: d) { models = m }
        if let d = UD.data(forKey: "skills"), let saved = try? JSONDecoder().decode([PalSkill].self, from: d) { skills = saved }
        if let d = UD.data(forKey: "personas"), let saved = try? JSONDecoder().decode([Persona].self, from: d), !saved.isEmpty { personas = saved }
        loadConversations()
        scanLibrary()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.generating else { return }
                self.unloadModel(reason: "Déchargé (mémoire faible)")
            }
        }
        chooseLaunchModel()
        if DownloadManager.hasActiveItems { attachDownloads() }
    }

    var currentName: String { models.first { $0.id == currentID }?.name ?? "Pal" }

    var fontDesign: Font.Design {
        switch prefs.fontDesign {
        case 1: return .rounded
        case 2: return .serif
        case 3: return .monospaced
        default: return .default
        }
    }

    /// Vrai si le modèle courant produit une phase de réflexion (DeepSeek R1, Qwen3, QwQ…).
    var modelThinks: Bool {
        let name = currentName.lowercased()
        return ["r1", "think", "qwq", "qwen3", "reason"].contains { name.contains($0) }
    }

    // MARK: personnages (prompts système nommés)

    var currentPersona: Persona? {
        guard let id = conversations.first(where: { $0.id == currentChatID })?.personaID else { return nil }
        return personas.first { $0.id == id }
    }

    private func savePersonas() {
        if let d = try? JSONEncoder().encode(personas) { UD.set(d, forKey: "personas") }
    }

    func savePersona(_ persona: Persona) {
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = persona.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        var updated = persona
        updated.name = String(name.prefix(40))
        updated.prompt = String(prompt.prefix(4000))
        if let index = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[index] = updated
        } else {
            personas.append(updated)
        }
        savePersonas()
        engine.restore(system: effectiveSystemPrompt, history: messages)
    }

    func deletePersona(_ id: String) {
        personas.removeAll { $0.id == id && !$0.builtIn }
        for index in conversations.indices where conversations[index].personaID == id {
            conversations[index].personaID = nil
        }
        savePersonas()
        saveConversations()
    }

    func setPersona(_ id: String?) {
        guard let index = conversations.firstIndex(where: { $0.id == currentChatID }) else { return }
        conversations[index].personaID = id
        saveConversations()
        engine.restore(system: effectiveSystemPrompt, history: messages)
    }
    func saveModels() { if let d = try? JSONEncoder().encode(models) { UD.set(d, forKey: "models") } }
    func saveSkills() { if let d = try? JSONEncoder().encode(skills) { UD.set(d, forKey: "skills") } }

    // MARK: conversations

    private static func makeTitle(_ msgs: [Msg]) -> String {
        guard let first = msgs.first(where: { $0.role == "user" }) else { return "Nouvelle discussion" }
        let line = first.text.components(separatedBy: .newlines).first ?? first.text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Nouvelle discussion" : String(t.prefix(44))
    }

    private func loadConversations() {
        if let d = try? Data(contentsOf: PalStore.conversationsURL),
           let list = try? JSONDecoder().decode([Conversation].self, from: d), !list.isEmpty {
            conversations = list
        } else if let d = try? Data(contentsOf: PalStore.legacyChatURL),
                  let old = try? JSONDecoder().decode([Msg].self, from: d), !old.isEmpty {
            var c = Conversation()
            c.messages = old
            c.title = VM.makeTitle(old)
            conversations = [c]
        } else {
            conversations = [Conversation()]
        }
        let latest = conversations.max(by: { $0.updated < $1.updated }) ?? conversations[0]
        currentChatID = latest.id
        messages = latest.messages
    }

    private func syncCurrent() {
        guard let i = conversations.firstIndex(where: { $0.id == currentChatID }) else { return }
        let changed = conversations[i].messages.count != messages.count
            || conversations[i].messages.last?.text != messages.last?.text
        conversations[i].messages = messages
        if conversations[i].title == "Nouvelle discussion" {
            conversations[i].title = VM.makeTitle(messages)
        }
        if changed { conversations[i].updated = Date() }
    }

    func saveConversations() {
        syncCurrent()
        if let d = try? JSONEncoder().encode(conversations) {
            try? d.write(to: PalStore.conversationsURL, options: .atomic)
        }
    }

    private func saveChat() { saveConversations() }

    private func newChatModel() -> ModelEntry? {
        guard let id = prefs.newChatModelID else { return nil }
        return models.first { $0.id.uuidString == id }
    }

    /// Change le modèle courant sans le charger : il se chargera au prochain envoi.
    private func applyChatModel(_ id: UUID?) {
        guard !generating, !loading, let id, id != currentID,
              let entry = models.first(where: { $0.id == id }) else { return }
        if engine.loaded { unloadModel(reason: "Déchargé") }
        currentID = id
        UD.set(id.uuidString, forKey: "last")
        status = "\(entry.name) · se charge à l'envoi"
    }

    func newChat() {
        guard !generating, !loading else { return }
        speaker.stop()
        if !messages.isEmpty {
            saveConversations()
            var chat = Conversation()
            chat.modelID = newChatModel()?.id ?? currentID
            conversations.insert(chat, at: 0)
            currentChatID = chat.id
            messages = []
            saveConversations()
        }
        if let target = newChatModel() { applyChatModel(target.id) }
        engine.restore(system: effectiveSystemPrompt, history: [])
    }

    func openChat(_ id: UUID) {
        guard !generating, !loading, id != currentChatID,
              let target = conversations.first(where: { $0.id == id }) else { return }
        speaker.stop()
        saveConversations()
        currentChatID = id
        messages = target.messages
        applyChatModel(target.modelID)
        engine.restore(system: effectiveSystemPrompt, history: messages)
    }

    func deleteChat(_ id: UUID) {
        guard !generating, !loading else { return }
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty { conversations = [Conversation()] }
        if id == currentChatID {
            let next = conversations.max(by: { $0.updated < $1.updated }) ?? conversations[0]
            currentChatID = next.id
            messages = next.messages
            applyChatModel(next.modelID)
            engine.restore(system: effectiveSystemPrompt, history: messages)
        }
        saveConversations()
    }

    func renameChat(_ id: UUID, _ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].title = String(clean.prefix(60))
        saveConversations()
    }

    // MARK: prompt système et compétences

    var effectiveSystemPrompt: String {
        let base = currentPersona?.prompt ?? cfg.system
        let enabled = skills.filter(\.enabled)
        guard !enabled.isEmpty else { return base }
        let skillText = enabled.map { skill in
            "SKILL: \(skill.name)\n\(skill.instructions)"
        }.joined(separator: "\n\n")
        // Limite la surcharge de contexte sur les appareils à mémoire réduite.
        let bounded = String(skillText.prefix(9000))
        return base + "\n\nCompétences activées (instructions de l'utilisateur) :\n" +
            bounded + "\n\nApplique ces compétences si elles sont pertinentes. Ne prétends pas avoir exécuté une action ou consulté une source si ce n'est pas le cas."
    }

    func setSkillEnabled(_ id: String, enabled: Bool) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].enabled = enabled
        saveSkills()
    }

    func importSkill(_ url: URL) {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Skill invalide : fichier UTF-8 requis, 64 Ko maximum"
            return
        }
        let firstHeading = text.components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ") })
        let name = firstHeading.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            ?? url.deletingPathExtension().lastPathComponent
        let skill = PalSkill(
            id: UUID().uuidString,
            name: String(name.prefix(60)),
            description: "Compétence importée",
            instructions: String(text.prefix(12000)),
            enabled: true,
            isBuiltIn: false
        )
        skills.append(skill)
        saveSkills()
        status = "Compétence ajoutée : \(skill.name)"
    }

    func addSkill(name: String, description: String, instructions: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanInstructions.isEmpty,
              cleanInstructions.utf8.count <= 12_000 else {
            status = "Nom et instructions requis (12 Ko maximum)"
            return
        }
        skills.append(PalSkill(
            id: UUID().uuidString,
            name: String(cleanName.prefix(60)),
            description: String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)),
            instructions: cleanInstructions,
            enabled: true,
            isBuiltIn: false
        ))
        saveSkills()
        status = "Compétence créée : " + cleanName
    }

    func deleteSkill(_ id: String) {
        skills.removeAll { $0.id == id && !$0.isBuiltIn }
        saveSkills()
    }

    func insertResearchContext(_ context: String) {
        input = context
    }

    private func tap() { if cfg.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }

    // MARK: Hugging Face

    var hfToken: String { Keychain.get("hf-token") ?? "" }

    func setHFToken(_ token: String) {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: "hf-token")
        objectWillChange.send()
    }

    func attachDownloads() {
        let manager = DownloadManager.shared
        manager.onFinished = { [weak self] url in
            Task { @MainActor in self?.downloadFinished(url) }
        }
        manager.activate()
    }

    private func downloadFinished(_ url: URL) {
        scanLibrary()
        status = "Téléchargé : " + url.deletingPathExtension().lastPathComponent
    }

    func useDownloaded(_ filename: String) {
        scanLibrary()
        if let entry = models.first(where: { $0.relPath == "Models/" + filename || $0.relPath == filename }) {
            select(entry)
        }
    }

    // MARK: modèles (dossier Pal, ou lus en place via signet)

    private func bookmark(_ url: URL) -> (Data, Int)? {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        let isAppOwned = url.standardizedFileURL.path.hasPrefix(home)
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        // Ne jamais mémoriser un chemin externe si iOS n'a pas accordé le scope.
        guard didStartAccess || isAppOwned else { return nil }
        guard let data = try? url.bookmarkData() else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (data, size / 1_048_576)
    }

    @discardableResult
    func addModel(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else {
            status = "Choisis un fichier .gguf (fichier reçu : \(url.lastPathComponent))"
            return false
        }
        guard let result = bookmark(url) else {
            status = "Impossible d'enregistrer l'accès au fichier"
            return false
        }
        let entry = ModelEntry(
            name: url.deletingPathExtension().lastPathComponent,
            bookmark: result.0,
            sizeMB: result.1
        )
        models.append(entry)
        saveModels()
        select(entry)
        return true
    }

    /// Plan B : copie le GGUF dans Documents/Models (dossier de Pal) puis le détecte.
    @discardableResult
    func importModelCopy(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "gguf" else {
            status = "Choisis un fichier .gguf (fichier reçu : \(url.lastPathComponent))"
            return false
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: PalFolders.models, withIntermediateDirectories: true)
            let dest = PalFolders.models.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            scanLibrary()
            if let rel = PalFolders.relativePath(of: dest),
               let entry = models.first(where: { $0.relPath == rel }) {
                select(entry)
                return true
            }
            return false
        } catch {
            status = "Copie impossible : \(error.localizedDescription)"
            return false
        }
    }

    func addMMProj(_ url: URL, to id: UUID) {
        guard url.pathExtension.lowercased() == "gguf",
              let result = bookmark(url),
              let index = models.firstIndex(where: { $0.id == id }) else {
            status = "Fichier mmproj inaccessible ou invalide"
            return
        }
        models[index].mmproj = result.0
        models[index].mmprojName = url.lastPathComponent
        saveModels()
        status = "mmproj associé (analyse d'image à implémenter)"
    }

    /// Remplace le signet d'un modèle sans copier le fichier dans le conteneur Pal.
    func relinkModel(_ url: URL, id: UUID) {
        guard url.pathExtension.lowercased() == "gguf",
              let result = bookmark(url),
              let index = models.firstIndex(where: { $0.id == id }) else {
            status = "Impossible de relier ce fichier GGUF"
            return
        }
        let wasCurrent = currentID == id
        models[index].bookmark = result.0
        models[index].sizeMB = result.1
        models[index].name = url.deletingPathExtension().lastPathComponent
        saveModels()
        status = "Fichier relié sans copie"
        if wasCurrent { select(models[index]) }
    }

    /// Texte Markdown exportable depuis la feuille de partage iOS.
    var exportedMarkdown: String {
        var output = "# Conversation avec Pal\n\n"
        if let entry = models.first(where: { $0.id == currentID }) {
            output += "_Modèle : \(entry.name)_\n\n"
        }
        for message in messages {
            output += "## \(message.role == "user" ? "Vous" : "Pal")\n\n\(message.text)\n\n---\n\n"
        }
        return output
    }

    // MARK: performance

    private func signature() -> String {
        "\(cfg.nCtx)/\(cfg.nBatch)/\(cfg.gpuLayers)/\(prefs.mmap)"
    }

    var needsReload: Bool {
        engine.loaded && !loadedSignature.isEmpty && loadedSignature != signature()
    }

    func applyProfile(_ profile: PerfProfile) {
        guard !loading, !generating, profile != .custom else { return }
        var updated = cfg
        profile.apply(&updated)
        cfg = updated
    }

    private func effectiveThreads() -> Int {
        var n = max(1, min(cfg.threads, ProcessInfo.processInfo.activeProcessorCount))
        guard prefs.thermalGuard else { return n }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: n = max(1, n / 2)
        case .fair: n = max(1, n - 1)
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { n = max(1, n - 1) }
        return n
    }

    // MARK: modèle par défaut, déchargement automatique

    func setLaunchModel(_ entry: ModelEntry) {
        prefs.launchMode = 2
        prefs.launchModelID = entry.id.uuidString
    }

    func setNewChatModel(_ entry: ModelEntry?) {
        prefs.newChatModelID = entry?.id.uuidString
    }

    private func chooseLaunchModel() {
        var candidate: ModelEntry?
        if prefs.launchMode == 2 {
            candidate = models.first { $0.id.uuidString == prefs.launchModelID }
        }
        if candidate == nil, let chatModel = conversations.first(where: { $0.id == currentChatID })?.modelID {
            candidate = models.first { $0.id == chatModel }
        }
        if candidate == nil, let saved = UD.string(forKey: "last") {
            candidate = models.first { $0.id.uuidString == saved }
        }
        guard let chosen = candidate else { return }
        if prefs.launchMode == 0 {
            currentID = chosen.id
            status = "\(chosen.name) · se charge à l'envoi"
        } else {
            select(chosen, assign: false)
        }
    }

    func unloadModel(reason: String = "Déchargé") {
        guard !generating, !loading else { return }
        idleTask?.cancel()
        engine.unload()
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        loadedSignature = ""
        status = "\(reason) · se recharge à l'envoi"
        objectWillChange.send()
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let minutes = prefs.autoUnloadMinutes
        guard minutes > 0, engine.loaded else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.unloadModel(reason: "Déchargé (inactif)")
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            scanLibrary()
        case .background:
            if prefs.unloadInBackground && !generating && !loading && engine.loaded {
                unloadModel(reason: "Déchargé (arrière-plan)")
            }
        default:
            break
        }
    }

    func remove(_ entry: ModelEntry) {
        if entry.id == currentID {
            engine.unload()
            scoped?.stopAccessingSecurityScopedResource()
            scoped = nil
            currentID = nil
            status = "Aucun modèle"
        }
        models.removeAll { $0.id == entry.id }
        saveModels()
    }

    /// Supprime le fichier d'un modèle du dossier Pal (libère l'espace).
    func deleteModelFile(_ entry: ModelEntry) {
        if entry.id == currentID {
            unloadModel(reason: "Déchargé")
            currentID = nil
            status = "Aucun modèle"
        }
        if let rel = entry.relPath {
            try? FileManager.default.removeItem(at: PalFolders.url(forRelative: rel))
        }
        models.removeAll { $0.id == entry.id }
        saveModels()
    }

    func select(_ entry: ModelEntry, assign: Bool = true) {
        guard !generating, !loading else { return }
        idleTask?.cancel()
        let url: URL
        var didStartAccess = false
        var stale = false

        if let rel = entry.relPath {
            url = PalFolders.url(forRelative: rel)
        } else {
            guard let resolved = try? URL(
                resolvingBookmarkData: entry.bookmark,
                bookmarkDataIsStale: &stale
            ) else {
                status = "Signet invalide : réimporte le fichier GGUF"
                pendingSend = false
                return
            }
            url = resolved
            didStartAccess = resolved.startAccessingSecurityScopedResource()
            let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
            let isAppOwned = resolved.standardizedFileURL.path.hasPrefix(home)
            guard didStartAccess || isAppOwned else {
                status = "iOS n'a pas accordé l'accès au fichier : réimporte-le depuis Fichiers"
                pendingSend = false
                return
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            status = "Fichier introuvable ou non téléchargé dans Fichiers"
            pendingSend = false
            return
        }

        scoped?.stopAccessingSecurityScopedResource()
        scoped = didStartAccess ? url : nil

        if stale, let refreshed = try? url.bookmarkData() {
            if let index = models.firstIndex(where: { $0.id == entry.id }) {
                models[index].bookmark = refreshed
                saveModels()
            }
        }

        currentID = entry.id
        if assign, let i = conversations.firstIndex(where: { $0.id == currentChatID }) {
            conversations[i].modelID = entry.id
            saveConversations()
        }
        UD.set(entry.id.uuidString, forKey: "last")
        status = "Chargement…"
        loading = true
        pendingSignature = signature()

        memWarn = !engine.loaded && Double(entry.sizeMB) * 1.1 > Sys.availMB()
        let config = cfg
        let useMmap = prefs.mmap
        let modelEngine = engine
        let modelPath = url.path
        Task.detached(priority: .userInitiated) {
            let success = modelEngine.load(path: modelPath, cfg: config, mmap: useMmap)
            await self.loaded(success)
        }
    }

    func reload() {
        if let entry = models.first(where: { $0.id == currentID }) {
            select(entry, assign: false)
        }
    }

    private func loaded(_ success: Bool) {
        loading = false
        if success {
            loadedSignature = pendingSignature
            engine.restore(system: effectiveSystemPrompt, history: messages)
            status = "\(engine.info) · prêt" + (memWarn ? " · ⚠︎ RAM juste" : "")
            scheduleIdleUnload()
            if pendingSend {
                pendingSend = false
                send()
            }
        } else {
            pendingSend = false
            status = "Échec du chargement : GGUF invalide, mémoire insuffisante ou fichier inaccessible"
        }
    }

    // MARK: chat

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating, !loading else { return }

        // Modèle déchargé : on le recharge automatiquement puis on envoie.
        if !engine.loaded {
            guard let entry = models.first(where: { $0.id == currentID }) ?? models.first else {
                status = "Ajoute d'abord un modèle"
                requestModelPicker = true
                return
            }
            pendingSend = true
            select(entry, assign: currentID == nil)
            if !loading { pendingSend = false }
            return
        }

        idleTask?.cancel()
        input = ""; engine.restore(system: effectiveSystemPrompt, history: messages); messages.append(Msg(role: "user", text: text)); streaming = ""; tap()
        speaker.stop()
        genStart = Date()
        thinkEnd = nil
        UIApplication.shared.isIdleTimerDisabled = cfg.keepAwake
        let c = cfg, e = engine, threadCount = effectiveThreads()
        Task.detached {
            e.setThreads(threadCount)
            var acc = "", last = Date()
            do {
                let st = try e.generate(user: text, cfg: c) { p in
                    acc += p
                    if Date().timeIntervalSince(last) > 0.05 {
                        last = Date(); let snap = acc
                        Task { @MainActor in
                            if self.streaming != nil {
                                self.streaming = snap
                                if self.thinkEnd == nil && snap.contains("</think>") { self.thinkEnd = Date() }
                            }
                        }
                    }
                }
                await self.finish(acc, st, nil)
            } catch { await self.finish(acc, nil, (error as? EngineError)?.msg ?? "Erreur") }
        }
    }

    private func finish(_ text: String, _ st: GenStats?, _ err: String?) {
        if let st {
            stats = st
            if thinkEnd == nil && text.contains("</think>") { thinkEnd = Date() }
            let seconds = thinkEnd.map { $0.timeIntervalSince(genStart) }
            let perToken = st.genTps > 0 ? 1000 / st.genTps : 0
            let line = String(format: "%.0f ms/token · %.1f tokens/s · 1er token %.1f s", perToken, st.genTps, st.ttft)
            messages.append(Msg(role: "assistant", text: text, thinkSeconds: seconds, stat: line))
        }
        if let err {
            status = err
            engine.restore(system: effectiveSystemPrompt, history: messages)
        } else if st != nil {
            status = "\(engine.info) · prêt"
        }
        streaming = nil; saveChat(); tap()
        UIApplication.shared.isIdleTimerDisabled = false
        scheduleIdleUnload()
        if st != nil, err == nil, prefs.ttsAuto, !text.isEmpty {
            speaker.speak(text, voiceID: prefs.ttsVoice, rate: prefs.ttsRate)
        }
    }

    func stop() { engine.cancel = true }

    func regenerate() {
        guard !generating, messages.count >= 2, messages.last?.role == "assistant" else { return }
        messages.removeLast()
        input = messages.removeLast().text
        engine.restore(system: effectiveSystemPrompt, history: messages)
        send()
    }

    /// Modifier le dernier message utilisateur : il revient dans le champ de saisie.
    func editLast() {
        guard !generating, !loading, let i = messages.lastIndex(where: { $0.role == "user" }) else { return }
        input = messages[i].text
        messages.removeSubrange(i...)
        saveChat()
        engine.restore(system: effectiveSystemPrompt, history: messages)
    }

    /// Benchmark court et reproductible (prompt fixe, température 0, 64 tokens).
    func runBenchmark() {
        guard !generating, !loading, engine.loaded else { return }
        loading = true
        benchmark = "Benchmark en cours…"
        var c = cfg; c.temp = 0; c.maxTokens = 64
        let e = engine, saved = messages, sys = effectiveSystemPrompt
        Task.detached(priority: .userInitiated) {
            e.restore(system: "", history: [])
            let r = try? e.generate(user: "Explique en quelques phrases comment fonctionne un moteur à explosion.", cfg: c) { _ in }
            await self.finishBenchmark(r, saved, sys)
        }
    }
    private func finishBenchmark(_ r: GenStats?, _ saved: [Msg], _ sys: String) {
        engine.restore(system: sys, history: saved)
        loading = false
        if let r {
            benchmark = String(format: "pp %.0f t/s · tg %.1f t/s · 1er token %.2f s · RAM %.0f Mo", r.promptTps, r.genTps, r.ttft, Sys.footprintMB())
        } else { benchmark = "Benchmark échoué" }
    }
}
