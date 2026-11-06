import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.backgroundCompletion = completionHandler
        DownloadManager.shared.activate()
    }
}

@main
struct PalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = VM()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vm)
                .environmentObject(vm.speaker)
                .tint(vm.cfg.accent)
                .preferredColorScheme(vm.cfg.scheme)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.scenePhase) private var scenePhase
    @State private var sensors = false
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case models, settings, skills, research, chats, downloads
        var id: String { rawValue }
    }

    private var canSend: Bool {
        !vm.loading && !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sensors {
                    SensorsPanel()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ChatList(onDownload: { activeSheet = .downloads })

                inputBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button { activeSheet = .chats } label: {
                        Image(systemName: "text.bubble")
                    }
                    .accessibilityLabel("Discussions")
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { vm.newChat() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(vm.generating || vm.loading)
                    .accessibilityLabel("Nouvelle discussion")

                    menu

                    Button { activeSheet = .settings } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Réglages")
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .models: ModelsView()
                case .settings: SettingsView()
                case .skills: SkillsView()
                case .research: ResearchView()
                case .chats: ChatsView()
                case .downloads: NavigationStack { DownloadsView() }
                }
            }
            .onChange(of: scenePhase) { phase in
                vm.scenePhaseChanged(phase)
            }
            .onChange(of: vm.requestModelPicker) { requested in
                if requested {
                    vm.requestModelPicker = false
                    activeSheet = .models
                }
            }
        }
    }

    private var header: some View {
        Button { activeSheet = .models } label: {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Text(vm.currentName)
                        .font(.headline)
                        .lineLimit(1)
                    if vm.loading {
                        ProgressView().scaleEffect(0.65)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(vm.loading ? "Chargement du modèle…" : (vm.generating
                    ? String(format: "%.1f t/s", vm.stats.genTps)
                    : vm.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var menu: some View {
        Menu {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { sensors.toggle() }
            } label: {
                Label(sensors ? "Masquer les statistiques" : "Statistiques", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            Button { activeSheet = .research } label: {
                Label("Recherche Web", systemImage: "globe")
            }
            Button { activeSheet = .skills } label: {
                Label("Compétences", systemImage: "sparkles")
            }
            Button { activeSheet = .downloads } label: {
                Label("Télécharger des modèles", systemImage: "arrow.down.circle")
            }
            if vm.engine.loaded {
                Button { vm.unloadModel() } label: {
                    Label("Décharger le modèle", systemImage: "eject")
                }
                .disabled(vm.generating || vm.loading)
            }
            ShareLink(item: vm.exportedMarkdown, subject: Text("Conversation Pal")) {
                Label("Exporter en Markdown", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.messages.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Plus d'options")
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .submitLabel(.send)
                .onSubmit { vm.send() }

            Button {
                vm.generating ? vm.stop() : vm.send()
            } label: {
                Image(systemName: vm.generating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 34))
            }
            .disabled(vm.loading || (!vm.generating && !canSend))
            .accessibilityLabel(vm.generating ? "Arrêter la génération" : "Envoyer")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct ChatList: View {
    @EnvironmentObject private var vm: VM
    let onDownload: () -> Void

    private let suggestions = [
        "Explique-moi simplement ce concept :",
        "Résume ce texte :",
        "Aide-moi à écrire un message poli pour :",
        "Corrige et explique cette erreur de code :"
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if vm.messages.isEmpty && vm.streaming == nil {
                        emptyState
                    }

                    ForEach(vm.messages) { message in
                        Bubble(
                            text: message.text,
                            user: message.role == "user",
                            last: message.id == vm.messages.last?.id
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let response = vm.streaming {
                        Bubble(text: response.isEmpty ? "…" : response, user: false, last: false, actions: false)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding()
                .animation(.easeOut(duration: 0.2), value: vm.messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.streaming) { _ in
                proxy.scrollTo("chat-end", anchor: .bottom)
            }
            .onChange(of: vm.messages.count) { _ in
                withAnimation { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(vm.cfg.accent)
            Text(vm.models.isEmpty ? "Aucun modèle pour l'instant" : "Que veux-tu faire ?")
                .font(.title3.weight(.semibold))

            if vm.models.isEmpty {
                Text("Dépose un fichier .gguf dans Fichiers › Sur mon iPhone › Pal › Models : il est reconnu automatiquement. Tu peux aussi en télécharger un depuis Hugging Face.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Télécharger un modèle") { onDownload() }
                    .buttonStyle(.borderedProminent)
            } else {
                ForEach(suggestions, id: \.self) { text in
                    Button { vm.input = text + " " } label: {
                        Text(text)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 50)
        .padding(.horizontal, 8)
    }
}

struct Bubble: View {
    @EnvironmentObject private var vm: VM
    @EnvironmentObject private var speaker: Speaker
    let text: String
    let user: Bool
    let last: Bool
    var actions = true

    var body: some View {
        HStack(alignment: .bottom) {
            if user { Spacer(minLength: 40) }

            VStack(alignment: user ? .trailing : .leading, spacing: 4) {
                bubble
                if !user && actions && !text.isEmpty {
                    footer
                }
            }

            if !user { Spacer(minLength: 40) }
        }
    }

    private var isSpeaking: Bool { speaker.speakingText == text }

    private func toggleSpeech() {
        if isSpeaking {
            speaker.stop()
        } else {
            speaker.speak(text, voiceID: vm.prefs.ttsVoice, rate: vm.prefs.ttsRate)
        }
    }

    private var bubble: some View {
        MarkdownMessage(text: text)
            .font(.system(size: vm.cfg.fontSize))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                user ? vm.cfg.accent : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .foregroundStyle(user ? Color.white : Color.primary)
            .contextMenu {
                Button("Copier") { UIPasteboard.general.string = text }
                if !user {
                    Button(isSpeaking ? "Arrêter la lecture" : "Lire à voix haute") { toggleSpeech() }
                }
                if last && !user {
                    Button("Régénérer") { vm.regenerate() }
                }
                if user && !vm.generating && vm.messages.last(where: { $0.role == "user" })?.text == text {
                    Button("Modifier") { vm.editLast() }
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button { toggleSpeech() } label: {
                Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2")
            }
            .accessibilityLabel(isSpeaking ? "Arrêter la lecture" : "Lire à voix haute")

            Button { UIPasteboard.general.string = text } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copier")

            if last {
                Button { vm.regenerate() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.generating)
                .accessibilityLabel("Régénérer")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.leading, 6)
    }
}

/// Rendu Markdown natif iOS : titres, emphase, listes simples et liens.
/// Les tableaux et blocs de code complexes restent du texte brut ; ils seront
/// améliorés avec un moteur Markdown dédié dans une prochaine itération.
struct MarkdownMessage: View {
    let text: String

    private var content: AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    var body: some View {
        Text(content)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SensorsPanel: View {
    @EnvironmentObject private var vm: VM

    var body: some View {
        VStack(spacing: 0) {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let stats = vm.stats
            let engine = vm.engine
            let values: [(String, String)] = [
                ("Vitesse", String(format: "%.1f t/s", stats.genTps)),
                ("Prompt", String(format: "%.0f t/s", stats.promptTps)),
                ("1er token", String(format: "%.2f s", stats.ttft)),
                ("Contexte", "\(engine.nPast)/\(engine.nCtx)"),
                ("RAM app", String(format: "%.0f Mo", Sys.footprintMB())),
                ("RAM dispo", String(format: "%.0f Mo", Sys.availMB())),
                ("Thermique", Sys.thermal),
                ("Batterie", Sys.battery),
                ("Éco. énergie", ProcessInfo.processInfo.isLowPowerModeEnabled ? "oui" : "non"),
                ("Disque libre", Sys.disk),
                ("CPU", "\(ProcessInfo.processInfo.activeProcessorCount) cœurs"),
                ("Modèle", engine.info)
            ]

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(values, id: \.0) { item in
                    VStack(spacing: 2) {
                        Text(item.0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.1)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
            }
            .padding(10)
        }
        HStack(spacing: 8) {
            Button("Benchmark") { vm.runBenchmark() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(vm.generating || vm.loading || !vm.engine.loaded)
            Text(vm.benchmark).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .background(.bar)
    }
}


struct ChatsView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    private var sorted: [Conversation] {
        vm.conversations.sorted { $0.updated > $1.updated }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sorted) { chat in
                    Button {
                        vm.openChat(chat.id)
                        dismiss()
                    } label: {
                        row(chat)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            vm.deleteChat(chat.id)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Renommer") {
                            newTitle = chat.title
                            renaming = chat
                        }
                        Button("Supprimer", role: .destructive) { vm.deleteChat(chat.id) }
                    }
                }
            }
            .navigationTitle("Discussions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.newChat()
                        dismiss()
                    } label: {
                        Label("Nouvelle", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .alert(
                "Renommer la discussion",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField("Titre", text: $newTitle)
                Button("OK") {
                    if let chat = renaming { vm.renameChat(chat.id, newTitle) }
                    renaming = nil
                }
                Button("Annuler", role: .cancel) { renaming = nil }
            }
        }
    }

    private func row(_ chat: Conversation) -> some View {
        let modelName = vm.models.first(where: { $0.id == chat.modelID })?.name ?? "Aucun modèle"
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(modelName) · \(chat.messages.count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if chat.id == vm.currentChatID {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(vm.cfg.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
