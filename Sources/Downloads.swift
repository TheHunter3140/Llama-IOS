import SwiftUI
import Foundation

// MARK: - Jeton Hugging Face (Trousseau, avec repli si iOS le refuse)

enum Keychain {
    private static let service = "com.local.pal"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        return UserDefaults.standard.string(forKey: "kc-" + key)
    }

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc-" + key)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: "kc-" + key)
        }
    }
}

// MARK: - Client Hugging Face

enum HFError: LocalizedError {
    case badURL
    case unauthorized
    case notFound
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Adresse invalide."
        case .unauthorized: return "Accès refusé : ce modèle demande une connexion. Ajoute ton jeton Hugging Face (roue dentée) et accepte la licence sur le site."
        case .notFound: return "Dépôt ou fichier introuvable."
        case .http(let code): return "Erreur serveur (\(code))."
        case .network(let message): return "Réseau : \(message)"
        }
    }
}

enum HF {
    struct Hit: Identifiable, Decodable, Hashable {
        let id: String
        let downloads: Int?
        let likes: Int?
    }

    struct RepoFile: Identifiable, Hashable {
        let path: String
        let size: Int64
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var isMMProj: Bool { name.lowercased().contains("mmproj") }
        var quant: String { HF.quantLabel(name) }
    }

    private struct TreeItem: Decodable {
        struct LFS: Decodable { let size: Int64? }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 25
        r.setValue("Pal-iOS", forHTTPHeaderField: "User-Agent")
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private static func fetch(_ url: URL, token: String) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url, token: token))
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: return data
                case 401, 403: throw HFError.unauthorized
                case 404: throw HFError.notFound
                default: throw HFError.http(http.statusCode)
                }
            }
            return data
        } catch let error as HFError {
            throw error
        } catch {
            throw HFError.network(error.localizedDescription)
        }
    }

    static func search(_ query: String, token: String) async throws -> [Hit] {
        guard var comps = URLComponents(string: "https://huggingface.co/api/models") else { throw HFError.badURL }
        comps.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = comps.url else { throw HFError.badURL }
        let data = try await fetch(url, token: token)
        return (try? JSONDecoder().decode([Hit].self, from: data)) ?? []
    }

    static func files(repo: String, token: String) async throws -> [RepoFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            throw HFError.badURL
        }
        let data = try await fetch(url, token: token)
        let items = (try? JSONDecoder().decode([TreeItem].self, from: data)) ?? []
        let ggufs = items.filter { $0.type == "file" && $0.path.lowercased().hasSuffix(".gguf") }
        let mapped = ggufs.map { RepoFile(path: $0.path, size: $0.lfs?.size ?? $0.size ?? 0) }
        return mapped.sorted { $0.size < $1.size }
    }

    static func quantLabel(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        guard let re = try? NSRegularExpression(
            pattern: "(?:IQ|Q)[0-9][A-Za-z0-9_]*|BF16|F16|F32",
            options: [.caseInsensitive]
        ) else { return "" }
        let matches = re.matches(in: base, range: NSRange(base.startIndex..., in: base))
        guard let last = matches.last, let range = Range(last.range, in: base) else { return "" }
        return String(base[range]).uppercased()
    }

    /// « owner/name » ou lien huggingface.co/owner/name[/…]
    static func parseRepo(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "huggingface.co/") { s = String(s[r.upperBound...]) }
        let parts = s.split(separator: "/").map { String($0) }
        guard parts.count >= 2, !parts[0].contains(" "), !parts[1].contains(" ") else { return nil }
        return parts[0] + "/" + parts[1]
    }

    /// Lien direct vers un fichier : …/owner/name/resolve/main/chemin.gguf
    static func parseFileURL(_ input: String) -> (repo: String, path: String)? {
        guard input.contains("huggingface.co/"), let repo = parseRepo(input) else { return nil }
        let clean = input.components(separatedBy: "?").first ?? input
        for marker in ["/resolve/", "/blob/"] {
            if let r = clean.range(of: marker) {
                let comps = String(clean[r.upperBound...]).split(separator: "/").map { String($0) }
                if comps.count >= 2 {
                    let path = comps.dropFirst().joined(separator: "/")
                    if path.lowercased().hasSuffix(".gguf") { return (repo, path) }
                }
            }
        }
        return nil
    }

    /// Estimation grossière : la RAM disponible pour une app iOS est bien inférieure à la RAM totale.
    static func fit(_ size: Int64) -> (text: String, color: Color) {
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        let ratio = Double(size) / max(ram, 1)
        if ratio < 0.30 { return ("adapté à cet iPhone", Color.green) }
        if ratio < 0.45 { return ("limite", Color.orange) }
        return ("trop lourd", Color.red)
    }
}

// MARK: - Gestionnaire de téléchargements (session en arrière-plan, pause, reprise, erreurs)

enum DownloadState: String, Codable {
    case queued, downloading, paused, failed, done
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var repo: String
    var remotePath: String
    var filename: String
    var urlString: String
    var total: Int64 = 0
    var received: Int64 = 0
    var state: DownloadState = .queued
    var error: String? = nil
    var retries = 0
    var speed: Double = 0

    var fraction: Double {
        total > 0 ? min(1, Double(received) / Double(total)) : 0
    }
}

final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    static var backgroundCompletion: (() -> Void)?
    private static let sessionID = "com.local.pal.downloads"
    private static let storeKey = "downloads"

    @Published private(set) var items: [DownloadItem] = []
    var onFinished: ((URL) -> Void)?

    private var session: URLSession?
    private var activated = false
    private var lastTick: [UUID: (date: Date, bytes: Int64)] = [:]

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: Self.storeKey),
           let list = try? JSONDecoder().decode([DownloadItem].self, from: d) {
            items = list
        }
    }

    static var hasActiveItems: Bool {
        guard let d = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([DownloadItem].self, from: d) else { return false }
        return list.contains { $0.state == .downloading || $0.state == .queued }
    }

    private static func wifiOnly() -> Bool {
        if let d = UserDefaults.standard.data(forKey: "prefs"),
           let p = try? JSONDecoder().decode(Prefs.self, from: d) {
            return p.wifiOnly
        }
        return true
    }

    // MARK: utilitaires de formatage

    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func etaString(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%.1f h", seconds / 3600)
    }

    // MARK: session

    private func makeSession() -> URLSession {
        if let existing = session { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = created
        return created
    }

    /// Rattache les tâches en cours (après un redémarrage de l'app) et marque les autres en pause.
    func activate() {
        guard !activated else { return }
        activated = true
        let current = makeSession()
        let pending = items.filter { $0.state == .downloading || $0.state == .queued }.map { $0.id }
        guard !pending.isEmpty else { return }
        current.getAllTasks { tasks in
            let live = Set(tasks.compactMap { DownloadManager.itemID($0) })
            DispatchQueue.main.async {
                for id in pending where !live.contains(id) {
                    self.update(id) {
                        $0.state = .paused
                        $0.error = "Interrompu : appuie sur reprendre."
                    }
                }
                self.persist()
            }
        }
    }

    // MARK: données persistantes

    private func persist() {
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: Self.storeKey)
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        items[index] = item
    }

    private func resumeURL(_ id: UUID) -> URL {
        let dir = PalStore.supportDir.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.uuidString + ".resume")
    }
    private func saveResume(_ id: UUID, _ data: Data) { try? data.write(to: resumeURL(id), options: .atomic) }
    private func loadResume(_ id: UUID) -> Data? { try? Data(contentsOf: resumeURL(id)) }
    private func clearResume(_ id: UUID) { try? FileManager.default.removeItem(at: resumeURL(id)) }

    // MARK: actions

    /// Retourne un message d'erreur si le téléchargement ne peut pas démarrer.
    @discardableResult
    func start(repo: String, remotePath: String, size: Int64) -> String? {
        activate()
        let filename = (remotePath as NSString).lastPathComponent
        let dest = PalFolders.models.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            return "« \(filename) » est déjà dans le dossier Models."
        }
        if items.contains(where: { $0.repo == repo && $0.remotePath == remotePath && $0.state != .done }) {
            return "Ce fichier est déjà dans la liste des téléchargements."
        }
        if size > 0 && Sys.freeDiskBytes() < size + 300_000_000 {
            return "Espace insuffisant : il faut environ \(Self.sizeString(size + 300_000_000)) de libre."
        }
        let encoded = remotePath.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        var item = DownloadItem(
            repo: repo,
            remotePath: remotePath,
            filename: filename,
            urlString: "https://huggingface.co/\(repo)/resolve/main/\(encoded)?download=true"
        )
        item.total = size
        items.append(item)
        persist()
        launch(item)
        return nil
    }

    private func launch(_ item: DownloadItem) {
        let current = makeSession()
        let task: URLSessionDownloadTask
        if let data = loadResume(item.id) {
            task = current.downloadTask(withResumeData: data)
        } else {
            guard let url = URL(string: item.urlString) else {
                fail(item.id, "Adresse invalide.", resumable: false)
                return
            }
            var request = URLRequest(url: url)
            request.allowsCellularAccess = !Self.wifiOnly()
            request.setValue("Pal-iOS", forHTTPHeaderField: "User-Agent")
            if let token = Keychain.get("hf-token"), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            task = current.downloadTask(with: request)
        }
        task.taskDescription = item.id.uuidString + "|" + item.filename
        task.resume()
        lastTick[item.id] = (Date(), item.received)
        update(item.id) {
            $0.state = .downloading
            $0.error = nil
        }
        persist()
    }

    func pause(_ id: UUID) {
        guard let current = session else { return }
        // On marque « pause » tout de suite pour ne pas traiter l'annulation comme une erreur.
        update(id) {
            $0.state = .paused
            $0.speed = 0
            $0.error = nil
        }
        persist()
        current.getAllTasks { tasks in
            guard let task = tasks.first(where: { DownloadManager.itemID($0) == id }) as? URLSessionDownloadTask else { return }
            task.cancel(byProducingResumeData: { data in
                DispatchQueue.main.async {
                    if let data = data { self.saveResume(id, data) }
                }
            })
        }
    }

    func resume(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              item.state == .paused || item.state == .failed || item.state == .queued else { return }
        activate()
        update(id) { $0.retries = 0 }
        launch(item)
    }

    func cancel(_ id: UUID) {
        let wasRunning = items.first(where: { $0.id == id })?.state == .downloading
        items.removeAll { $0.id == id }
        clearResume(id)
        persist()
        if wasRunning, let current = session {
            current.getAllTasks { tasks in
                for task in tasks where DownloadManager.itemID(task) == id { task.cancel() }
            }
        }
    }

    private func complete(_ id: UUID, _ dest: URL) {
        clearResume(id)
        update(id) {
            $0.state = .done
            if $0.total > 0 { $0.received = $0.total }
            $0.error = nil
            $0.speed = 0
        }
        persist()
        onFinished?(dest)
    }

    private func fail(_ id: UUID, _ message: String, resumable: Bool) {
        if !resumable { clearResume(id) }
        update(id) {
            $0.state = .failed
            $0.error = message
            $0.speed = 0
        }
        persist()
    }

    // MARK: identification des tâches

    static func itemID(_ task: URLSessionTask) -> UUID? {
        guard let description = task.taskDescription,
              let first = description.split(separator: "|").first else { return nil }
        return UUID(uuidString: String(first))
    }

    static func filename(_ task: URLSessionTask) -> String? {
        guard let description = task.taskDescription,
              let bar = description.firstIndex(of: "|") else { return nil }
        return String(description[description.index(after: bar)...])
    }

    private static func describe(_ error: NSError) -> String {
        switch error.code {
        case NSURLErrorNotConnectedToInternet: return "Pas de connexion Internet."
        case NSURLErrorTimedOut: return "Délai dépassé."
        case NSURLErrorNetworkConnectionLost: return "Connexion perdue."
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Serveur Hugging Face injoignable."
        case NSURLErrorDataNotAllowed: return "Données cellulaires interdites (option Wi-Fi uniquement)."
        default: return error.localizedDescription
        }
    }

    private static func isTransient(_ error: NSError) -> Bool {
        [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
         NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(error.code)
    }

    private static func httpMessage(_ code: Int) -> String {
        switch code {
        case 401, 403: return "Accès refusé : ajoute ton jeton Hugging Face et accepte la licence du modèle sur le site."
        case 404: return "Fichier introuvable sur Hugging Face."
        default: return "Erreur serveur (\(code))."
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = DownloadManager.itemID(downloadTask) else { return }
        DispatchQueue.main.async {
            let now = Date()
            if let tick = self.lastTick[id] {
                let elapsed = now.timeIntervalSince(tick.date)
                if elapsed < 0.5 { return }
                let speed = Double(totalBytesWritten - tick.bytes) / max(elapsed, 0.001)
                self.update(id) {
                    $0.received = totalBytesWritten
                    if totalBytesExpectedToWrite > 0 { $0.total = totalBytesExpectedToWrite }
                    $0.speed = $0.speed == 0 ? max(speed, 0) : ($0.speed * 0.6 + max(speed, 0) * 0.4)
                    $0.state = .downloading
                }
            } else {
                self.update(id) {
                    $0.received = totalBytesWritten
                    if totalBytesExpectedToWrite > 0 { $0.total = totalBytesExpectedToWrite }
                    $0.state = .downloading
                }
            }
            self.lastTick[id] = (now, totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = DownloadManager.itemID(downloadTask),
              let filename = DownloadManager.filename(downloadTask) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = DownloadManager.httpMessage(http.statusCode)
            DispatchQueue.main.async { self.fail(id, message, resumable: false) }
            return
        }

        // Vérifie la signature d'un fichier GGUF ("GGUF" au début).
        if let handle = try? FileHandle(forReadingFrom: location) {
            let magic = handle.readData(ofLength: 4)
            try? handle.close()
            if magic != Data("GGUF".utf8) {
                DispatchQueue.main.async {
                    self.fail(id, "Le fichier reçu n'est pas un GGUF valide.", resumable: false)
                }
                return
            }
        }

        let fm = FileManager.default
        let dest = PalFolders.models.appendingPathComponent(filename)
        do {
            try fm.createDirectory(at: PalFolders.models, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.complete(id, dest) }
        } catch {
            let message = "Enregistrement impossible : " + error.localizedDescription
            DispatchQueue.main.async { self.fail(id, message, resumable: false) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let id = DownloadManager.itemID(task) else { return }
        let ns = error as NSError
        let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async {
            guard let item = self.items.first(where: { $0.id == id }),
                  item.state != .paused, item.state != .done else { return }
            if let data = resumeData { self.saveResume(id, data) }
            if item.retries < 3 && DownloadManager.isTransient(ns) {
                let attempt = item.retries
                self.update(id) {
                    $0.retries += 1
                    $0.state = .queued
                    $0.speed = 0
                    $0.error = "Réseau instable : nouvelle tentative…"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(3 << attempt)) {
                    if let again = self.items.first(where: { $0.id == id }), again.state == .queued {
                        self.launch(again)
                    }
                }
            } else {
                self.fail(id, DownloadManager.describe(ns), resumable: resumeData != nil)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            DownloadManager.backgroundCompletion?()
            DownloadManager.backgroundCompletion = nil
        }
    }
}

// MARK: - Écrans

struct DownloadsView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = DownloadManager.shared
    @State private var query = ""
    @State private var hits: [HF.Hit] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var showSettings = false
    @State private var showRepo = false
    @State private var repoToOpen = ""
    @State private var message: String?

    var body: some View {
        List {
            if !manager.items.isEmpty {
                Section("Téléchargements") {
                    ForEach(manager.items) { item in
                        DownloadRow(item: item, manager: manager)
                    }
                }
            }
            searchSection
            if let errorText = errorText {
                Section { Text(errorText).font(.footnote).foregroundStyle(Color.red) }
            }
            if !hits.isEmpty {
                Section("Résultats (GGUF, par popularité)") {
                    ForEach(hits) { hit in
                        NavigationLink {
                            RepoFilesView(repo: hit.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.id).font(.subheadline).lineLimit(2)
                                Text("\(hit.downloads ?? 0) téléchargements · \(hit.likes ?? 0) ♥")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hugging Face")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Réglages de téléchargement")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }
            }
        }
        .navigationDestination(isPresented: $showRepo) { RepoFilesView(repo: repoToOpen) }
        .sheet(isPresented: $showSettings) { DownloadSettingsView() }
        .task { vm.attachDownloads() }
        .alert(
            "Téléchargement",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var searchSection: some View {
        Section {
            HStack {
                TextField("Nom du modèle ou lien Hugging Face", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                if searching { ProgressView() }
            }
            Button { runSearch() } label: {
                Label("Rechercher", systemImage: "magnifyingglass")
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Chercher un modèle")
        } footer: {
            Text("Tape un nom (ex : gemma 3 1b), colle « auteur/dépôt » ou un lien direct vers un fichier .gguf. Les fichiers vont dans Models et sont reconnus automatiquement.")
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        errorText = nil

        if let direct = HF.parseFileURL(q) {
            message = manager.start(repo: direct.repo, remotePath: direct.path, size: 0)
                ?? "Téléchargement démarré."
            return
        }
        if q.contains("/"), let repo = HF.parseRepo(q) {
            repoToOpen = repo
            showRepo = true
            return
        }

        searching = true
        let token = vm.hfToken
        Task {
            do {
                let result = try await HF.search(q, token: token)
                hits = result
                if result.isEmpty { errorText = "Aucun résultat." }
            } catch {
                errorText = error.localizedDescription
            }
            searching = false
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var manager: DownloadManager
    @EnvironmentObject private var vm: VM

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(item.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                controls
            }
            if item.state != .done {
                ProgressView(value: item.fraction)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
            if item.state == .done {
                Button("Utiliser ce modèle") { vm.useDownloaded(item.filename) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 14) {
            switch item.state {
            case .downloading, .queued:
                Button { manager.pause(item.id) } label: { Image(systemName: "pause.circle.fill") }
                    .accessibilityLabel("Mettre en pause")
            case .paused, .failed:
                Button { manager.resume(item.id) } label: { Image(systemName: "play.circle.fill") }
                    .accessibilityLabel("Reprendre")
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            }
            Button(role: .destructive) { manager.cancel(item.id) } label: {
                Image(systemName: item.state == .done ? "xmark.circle" : "trash")
            }
            .accessibilityLabel(item.state == .done ? "Retirer de la liste" : "Annuler")
        }
        .font(.title3)
        .buttonStyle(.borderless)
    }

    private var detail: String {
        let received = DownloadManager.sizeString(item.received)
        let total = item.total > 0 ? DownloadManager.sizeString(item.total) : "?"
        switch item.state {
        case .queued:
            return item.error ?? "En attente…"
        case .downloading:
            var text = "\(received) / \(total)"
            if item.speed > 0 {
                text += " · " + DownloadManager.sizeString(Int64(item.speed)) + "/s"
                if item.total > item.received {
                    text += " · " + DownloadManager.etaString(Double(item.total - item.received) / item.speed)
                }
            }
            return text
        case .paused:
            return "En pause · \(received) / \(total)"
        case .failed:
            return item.error ?? "Échec du téléchargement."
        case .done:
            return "Terminé · \(total)"
        }
    }
}

struct RepoFilesView: View {
    let repo: String
    @EnvironmentObject private var vm: VM
    @ObservedObject private var manager = DownloadManager.shared
    @State private var files: [HF.RepoFile] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var message: String?

    private var mainFiles: [HF.RepoFile] { files.filter { !$0.isMMProj } }
    private var projectorFiles: [HF.RepoFile] { files.filter { $0.isMMProj } }

    var body: some View {
        List {
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Chargement des fichiers…").font(.footnote)
                }
            }
            if let errorText = errorText {
                Text(errorText).font(.footnote).foregroundStyle(Color.red)
            }
            if !mainFiles.isEmpty {
                Section {
                    ForEach(mainFiles) { file in fileRow(file) }
                } header: {
                    Text("Modèles")
                } footer: {
                    Text("Q4_K_M est un bon compromis qualité / taille. Plus le fichier est gros, plus il faut de RAM.")
                }
            }
            if !projectorFiles.isEmpty {
                Section {
                    ForEach(projectorFiles) { file in fileRow(file) }
                } header: {
                    Text("Vision (mmproj)")
                } footer: {
                    Text("Téléchargé avec le modèle, il est associé automatiquement.")
                }
            }
        }
        .navigationTitle(repo)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(
            "Téléchargement",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            files = try await HF.files(repo: repo, token: vm.hfToken)
            if files.isEmpty { errorText = "Aucun fichier .gguf dans ce dépôt." }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func fileRow(_ file: HF.RepoFile) -> some View {
        let fit = HF.fit(file.size)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if !file.quant.isEmpty {
                        Text(file.quant)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    Text(DownloadManager.sizeString(file.size)).font(.caption).foregroundStyle(.secondary)
                    if !file.isMMProj {
                        Text(fit.text).font(.caption).foregroundStyle(fit.color)
                    }
                }
            }
            Spacer(minLength: 4)
            trailing(file)
        }
    }

    @ViewBuilder private func trailing(_ file: HF.RepoFile) -> some View {
        let installed = FileManager.default.fileExists(
            atPath: PalFolders.models.appendingPathComponent(file.name).path
        )
        let running = manager.items.contains {
            $0.repo == repo && $0.remotePath == file.path && $0.state != .done
        }
        if installed {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        } else if running {
            Image(systemName: "arrow.down.circle.dotted").foregroundStyle(.secondary)
        } else {
            Button {
                message = manager.start(repo: repo, remotePath: file.path, size: file.size)
                    ?? "Téléchargement démarré : suis-le dans la liste Hugging Face."
            } label: {
                Image(systemName: "arrow.down.circle").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Télécharger")
        }
    }
}

struct DownloadSettingsView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("hf_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Jeton Hugging Face (optionnel)")
                } footer: {
                    Text("Nécessaire pour les modèles protégés (Llama, Gemma…). Crée un jeton en lecture sur huggingface.co/settings/tokens, puis accepte la licence du modèle sur sa page.")
                }
                Section {
                    Toggle("Wi-Fi uniquement", isOn: $vm.prefs.wifiOnly)
                } footer: {
                    Text("S'applique aux nouveaux téléchargements. Les fichiers de plusieurs Go consomment beaucoup de données mobiles.")
                }
            }
            .navigationTitle("Téléchargements")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { token = vm.hfToken }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        vm.setHFToken(token)
                        dismiss()
                    }
                }
            }
        }
    }
}
