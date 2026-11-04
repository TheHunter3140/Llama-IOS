import SwiftUI
import UIKit
import os
import Darwin

struct Msg: Identifiable, Codable { var id = UUID(); var role: String; var text: String }
struct ModelEntry: Identifiable, Codable {
    var id = UUID(); var name: String; var bookmark: Data; var sizeMB: Int
    var mmproj: Data? = nil; var mmprojName: String? = nil
}

enum DevicePreset: String, CaseIterable, Identifiable {
    case economy, balanced, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .economy: return "Économie mémoire"
        case .balanced: return "Équilibré"
        case .custom: return "Personnalisé"
        }
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
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return String(format: "%.1f Go", Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9)
    }
}

@MainActor final class VM: ObservableObject {
    let engine = Engine()
    @Published var cfg = Cfg() { didSet { if let d = try? JSONEncoder().encode(cfg) { UD.set(d, forKey: "cfg") } } }
    @Published var models: [ModelEntry] = []
    @Published var skills: [PalSkill] = PalSkill.defaults
    @Published var currentID: UUID?
    @Published var messages: [Msg] = []
    @Published var streaming: String?
    @Published var input = ""
    @Published var status = "Aucun modèle"
    @Published var stats = GenStats()
    @Published var loading = false
    @Published var benchmark = ""
    private var memWarn = false
    var generating: Bool { streaming != nil }
    private var scoped: URL?
    private let UD = UserDefaults.standard
    private var chatURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("chat.json") }

    init() {
        if let d = UD.data(forKey: "cfg"), let c = try? JSONDecoder().decode(Cfg.self, from: d) { cfg = c }
        if let d = UD.data(forKey: "models"), let m = try? JSONDecoder().decode([ModelEntry].self, from: d) { models = m }
        if let d = UD.data(forKey: "skills"), let saved = try? JSONDecoder().decode([PalSkill].self, from: d) { skills = saved }
        if let d = try? Data(contentsOf: chatURL), let m = try? JSONDecoder().decode([Msg].self, from: d) { messages = m }
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.generating else { return }
                self.engine.unload(); self.status = "Déchargé (mémoire faible)"
            }
        }
        if let s = UD.string(forKey: "last"), let e = models.first(where: { $0.id.uuidString == s }) { select(e) }
    }

    var currentName: String { models.first { $0.id == currentID }?.name ?? "Pal" }
    private func saveModels() { if let d = try? JSONEncoder().encode(models) { UD.set(d, forKey: "models") } }
    private func saveSkills() { if let d = try? JSONEncoder().encode(skills) { UD.set(d, forKey: "skills") } }

    var effectiveSystemPrompt: String {
        let enabled = skills.filter(\.enabled)
        guard !enabled.isEmpty else { return cfg.system }
        let skillText = enabled.map { skill in
            "SKILL: \(skill.name)\n\(skill.instructions)"
        }.joined(separator: "\n\n")
        // Limite la surcharge de contexte sur les appareils à mémoire réduite.
        let bounded = String(skillText.prefix(9000))
        return cfg.system + "\n\nCompétences activées (instructions de l'utilisateur) :\n" +
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
    private func saveChat() { if let d = try? JSONEncoder().encode(messages) { try? d.write(to: chatURL) } }
    private func tap() { if cfg.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }

    // MARK: modèles (lus en place via bookmark, jamais copiés)
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

    func addModel(_ url: URL) {
        guard url.pathExtension.lowercased() == "gguf" else {
            status = "Choisis un fichier .gguf"
            return
        }
        guard let result = bookmark(url) else {
            status = "Impossible d'enregistrer l'accès au fichier"
            return
        }
        let entry = ModelEntry(
            name: url.deletingPathExtension().lastPathComponent,
            bookmark: result.0,
            sizeMB: result.1
        )
        models.append(entry)
        saveModels()
        select(entry)
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

    func applyDevicePreset(_ preset: DevicePreset) {
        guard !loading, !generating else { return }
        switch preset {
        case .economy:
            cfg.nCtx = 768; cfg.nBatch = 64; cfg.threads = 2
            cfg.gpuLayers = 0; cfg.maxTokens = 192
        case .balanced:
            cfg.nCtx = 1024; cfg.nBatch = 128; cfg.threads = 3
            cfg.gpuLayers = 0; cfg.maxTokens = 256
        case .custom:
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

    func select(_ entry: ModelEntry) {
        guard !generating, !loading else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark,
            bookmarkDataIsStale: &stale
        ) else {
            status = "Signet invalide : réimporte le fichier GGUF"
            return
        }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        let isAppOwned = url.standardizedFileURL.path.hasPrefix(home)
        guard didStartAccess || isAppOwned else {
            status = "iOS n'a pas accordé l'accès au fichier : réimporte-le depuis Fichiers"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            status = "Fichier introuvable ou non téléchargé dans Fichiers"
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
        UD.set(entry.id.uuidString, forKey: "last")
        status = "Chargement…"
        loading = true

        memWarn = !engine.loaded && Double(entry.sizeMB) * 1.1 > Sys.availMB()
        let config = cfg
        let modelEngine = engine
        let modelPath = url.path
        Task.detached(priority: .userInitiated) {
            let success = modelEngine.load(path: modelPath, cfg: config)
            await self.loaded(success)
        }
    }

    func reload() {
        if let entry = models.first(where: { $0.id == currentID }) {
            select(entry)
        }
    }

    private func loaded(_ success: Bool) {
        loading = false
        if success {
            engine.restore(system: effectiveSystemPrompt, history: messages)
            status = "\(engine.info) · prêt" + (memWarn ? " · ⚠︎ RAM juste" : "")
        } else {
            status = "Échec du chargement : GGUF invalide, mémoire insuffisante ou fichier inaccessible"
        }
    }

    // MARK: chat
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating, engine.loaded else { return }
        input = ""; engine.restore(system: effectiveSystemPrompt, history: messages); messages.append(Msg(role: "user", text: text)); streaming = ""; tap()
        UIApplication.shared.isIdleTimerDisabled = cfg.keepAwake
        let c = cfg, e = engine
        Task.detached {
            var acc = "", last = Date()
            do {
                let st = try e.generate(user: text, cfg: c) { p in
                    acc += p
                    if Date().timeIntervalSince(last) > 0.05 {
                        last = Date(); let snap = acc
                        Task { @MainActor in if self.streaming != nil { self.streaming = snap } }
                    }
                }
                await self.finish(acc, st, nil)
            } catch { await self.finish(acc, nil, (error as? EngineError)?.msg ?? "Erreur") }
        }
    }
    private func finish(_ text: String, _ st: GenStats?, _ err: String?) {
        if let st { stats = st; messages.append(Msg(role: "assistant", text: text)) }
        if let err {
            status = err
            engine.restore(system: effectiveSystemPrompt, history: messages)
        } else if st != nil {
            status = "\(engine.info) · prêt"
        }
        streaming = nil; saveChat(); tap()
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func stop() { engine.cancel = true }
    func newChat() {
        guard !generating else { return }
        messages = []; saveChat(); engine.restore(system: effectiveSystemPrompt, history: [])
    }
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
