import Foundation

// MARK: - Dossiers de Pal (visibles dans Fichiers > Sur mon iPhone > Pal)

enum PalFolders {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var models: URL { documents.appendingPathComponent("Models", isDirectory: true) }
    static var skills: URL { documents.appendingPathComponent("Skills", isDirectory: true) }

    /// Crée les dossiers et un petit fichier d'aide pour que « Pal » apparaisse dans Fichiers.
    static func prepare() {
        let fm = FileManager.default
        for dir in [models, skills] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let note = documents.appendingPathComponent("LISEZMOI.txt")
        if !fm.fileExists(atPath: note.path) {
            let text = """
            Pal : dépose tes fichiers ici.

            Models/  -> modèles .gguf et leur fichier « mmproj » (détectés automatiquement)
            Skills/  -> compétences en .md ou .txt (une consigne par fichier, 64 Ko max)

            Ouvre ensuite Pal : tout est reconnu tout seul.

            """
            try? text.write(to: note, atomically: true, encoding: .utf8)
        }
    }

    static func relativePath(of url: URL) -> String? {
        let base = documents.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    static func url(forRelative rel: String) -> URL {
        documents.appendingPathComponent(rel)
    }
}

enum PalStore {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Pal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var conversationsURL: URL { supportDir.appendingPathComponent("conversations.json") }
    static var legacyChatURL: URL { PalFolders.documents.appendingPathComponent("chat.json") }
}

// MARK: - Données

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title = "Nouvelle discussion"
    var modelID: UUID? = nil
    var messages: [Msg] = []
    var updated = Date()
}

/// Réglages ajoutés après coup. Décodage tolérant : les anciens réglages restent valides.
struct Prefs: Codable, Equatable {
    var mmap = true
    var thermalGuard = true
    var launchMode = 0               // 0 = à la demande, 1 = dernier modèle, 2 = modèle choisi
    var launchModelID: String? = nil
    var newChatModelID: String? = nil
    var autoUnloadMinutes = 10       // 0 = jamais
    var unloadInBackground = true
    var ttsAuto = false
    var ttsVoice: String? = nil
    var ttsRate = 0.5
    var wifiOnly = true

    enum CodingKeys: String, CodingKey {
        case mmap, thermalGuard, launchMode, launchModelID, newChatModelID
        case autoUnloadMinutes, unloadInBackground, ttsAuto, ttsVoice, ttsRate, wifiOnly
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mmap = try c.decodeIfPresent(Bool.self, forKey: .mmap) ?? true
        thermalGuard = try c.decodeIfPresent(Bool.self, forKey: .thermalGuard) ?? true
        launchMode = try c.decodeIfPresent(Int.self, forKey: .launchMode) ?? 0
        launchModelID = try c.decodeIfPresent(String.self, forKey: .launchModelID)
        newChatModelID = try c.decodeIfPresent(String.self, forKey: .newChatModelID)
        autoUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .autoUnloadMinutes) ?? 10
        unloadInBackground = try c.decodeIfPresent(Bool.self, forKey: .unloadInBackground) ?? true
        ttsAuto = try c.decodeIfPresent(Bool.self, forKey: .ttsAuto) ?? false
        ttsVoice = try c.decodeIfPresent(String.self, forKey: .ttsVoice)
        ttsRate = try c.decodeIfPresent(Double.self, forKey: .ttsRate) ?? 0.5
        wifiOnly = try c.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
    }
}

// MARK: - Analyse automatique des dossiers Models et Skills

extension VM {
    func scanLibrary() {
        scanModelFolder()
        scanSkillFolder()
    }

    private func ggufFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.filter { $0.pathExtension.lowercased() == "gguf" }
    }

    private func isProjector(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().contains("mmproj")
    }

    private func coreName(_ stem: String) -> String {
        var t = stem.lowercased()
        for token in ["mmproj", "-f16", "-f32", "-bf16", "_f16", "_f32", "_bf16"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        return String(t.filter { $0.isLetter || $0.isNumber })
    }

    private func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            if x == y { n += 1 } else { break }
        }
        return n
    }

    private func bestProjector(for modelURL: URL, among projectors: [URL], modelsInFolder: Int) -> URL? {
        guard !projectors.isEmpty else { return nil }
        if projectors.count == 1 && modelsInFolder == 1 { return projectors[0] }
        let modelCore = coreName(modelURL.deletingPathExtension().lastPathComponent)
        var best: URL?
        var bestScore = 0
        for projector in projectors {
            let core = coreName(projector.deletingPathExtension().lastPathComponent)
            let score = commonPrefix(modelCore, core)
            if score > bestScore {
                bestScore = score
                best = projector
            }
        }
        return bestScore >= 5 ? best : nil
    }

    func scanModelFolder() {
        let fm = FileManager.default
        var files = ggufFiles(in: PalFolders.models)
        files += ggufFiles(in: PalFolders.documents)
        let projectors = files.filter { isProjector($0) }
        let mains = files.filter { !isProjector($0) }
        var changed = false

        // 1) nouveaux modèles
        for url in mains {
            guard let rel = PalFolders.relativePath(of: url) else { continue }
            let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_048_576
            if let index = models.firstIndex(where: { $0.relPath == rel }) {
                if models[index].sizeMB != size {
                    models[index].sizeMB = size
                    changed = true
                }
            } else {
                models.append(ModelEntry(
                    name: url.deletingPathExtension().lastPathComponent,
                    bookmark: Data(),
                    sizeMB: size,
                    relPath: rel
                ))
                changed = true
            }
        }

        // 2) modèles du dossier dont le fichier a disparu
        let before = models.count
        let activeID = currentID
        models.removeAll { entry in
            guard let rel = entry.relPath else { return false }
            if entry.id == activeID { return false }
            return !fm.fileExists(atPath: PalFolders.url(forRelative: rel).path)
        }
        if models.count != before { changed = true }

        // 3) association automatique des fichiers mmproj
        for index in models.indices {
            guard let rel = models[index].relPath else { continue }
            let modelURL = PalFolders.url(forRelative: rel)
            let folder = modelURL.deletingLastPathComponent().standardizedFileURL.path
            let sameFolderProjectors = projectors.filter {
                $0.deletingLastPathComponent().standardizedFileURL.path == folder
            }
            let sameFolderModels = mains.filter {
                $0.deletingLastPathComponent().standardizedFileURL.path == folder
            }.count
            let match = bestProjector(for: modelURL, among: sameFolderProjectors, modelsInFolder: sameFolderModels)
            let newRel = match.flatMap { PalFolders.relativePath(of: $0) }
            if models[index].mmprojRel != newRel {
                models[index].mmprojRel = newRel
                models[index].mmprojName = match?.lastPathComponent
                changed = true
            }
        }

        if changed { saveModels() }
    }

    func scanSkillFolder() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: PalFolders.skills,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let files = items.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
        var seen = Set<String>()
        var changed = false

        for url in files {
            guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let id = "file:" + url.lastPathComponent
            seen.insert(id)

            let heading = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.hasPrefix("# ") })
            let title = heading.map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
            let name = String(title.prefix(60))
            let body = String(text.prefix(12000))

            if let index = skills.firstIndex(where: { $0.id == id }) {
                if skills[index].instructions != body || skills[index].name != name {
                    skills[index].instructions = body
                    skills[index].name = name
                    changed = true
                }
            } else {
                skills.append(PalSkill(
                    id: id,
                    name: name,
                    description: "Dossier Skills · " + url.lastPathComponent,
                    instructions: body,
                    enabled: false,
                    isBuiltIn: false
                ))
                changed = true
            }
        }

        let before = skills.count
        skills.removeAll { $0.id.hasPrefix("file:") && !seen.contains($0.id) }
        if skills.count != before { changed = true }
        if changed { saveSkills() }
    }
}
