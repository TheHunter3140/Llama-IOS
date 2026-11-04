import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct PalApp: App {
    @StateObject private var vm = VM()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vm)
                .tint(vm.cfg.accent)
                .preferredColorScheme(vm.cfg.scheme)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var vm: VM
    @State private var sensors = false
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case models, settings, skills, research
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sensors {
                    SensorsPanel()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ChatList()

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
                    .disabled(vm.loading || (!vm.generating && !vm.engine.loaded))
                    .accessibilityLabel(vm.generating ? "Arrêter la génération" : "Envoyer")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { activeSheet = .models } label: {
                        VStack(spacing: 0) {
                            Text(vm.currentName)
                                .font(.headline)
                                .lineLimit(1)
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

                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { sensors.toggle() }
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .accessibilityLabel("Statistiques")
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { vm.newChat() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(vm.generating)
                    .accessibilityLabel("Nouvelle conversation")

                    ShareLink(item: vm.exportedMarkdown, subject: Text("Conversation Pal")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(vm.messages.isEmpty)
                    .accessibilityLabel("Exporter la conversation en Markdown")

                    Button { activeSheet = .research } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel("Recherche Web")

                    Button { activeSheet = .skills } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("Compétences Pal")

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
                }
            }
        }
    }
}

struct ChatList: View {
    @EnvironmentObject private var vm: VM

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if vm.messages.isEmpty && vm.streaming == nil {
                        Text(vm.models.isEmpty
                             ? "Touche le titre pour ajouter un modèle .gguf"
                             : "Écris un message pour commencer")
                            .foregroundStyle(.secondary)
                            .padding(.top, 80)
                    }

                    ForEach(vm.messages) { message in
                        Bubble(
                            text: message.text,
                            user: message.role == "user",
                            last: message.id == vm.messages.last?.id
                        )
                    }

                    if let response = vm.streaming {
                        Bubble(text: response.isEmpty ? "…" : response, user: false, last: false)
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.streaming) { _ in
                withAnimation { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: vm.messages.count) { _ in
                withAnimation { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
        }
    }
}

struct Bubble: View {
    @EnvironmentObject private var vm: VM
    let text: String
    let user: Bool
    let last: Bool

    var body: some View {
        HStack {
            if user { Spacer(minLength: 40) }

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
                    if last && !user {
                        Button("Régénérer") { vm.regenerate() }
                    }
                    if user && !vm.generating && vm.messages.last(where: { $0.role == "user" })?.text == text {
                        Button("Modifier") { vm.editLast() }
                    }
                }

            if !user { Spacer(minLength: 40) }
        }
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

struct ModelsView: View {
    private enum ImportTarget {
        case model
        case mmproj(UUID)
        case replace(UUID)
    }

    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var target = ImportTarget.model

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.models) { model in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(model.name)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if vm.currentID == model.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text("\(model.sizeMB) Mo" + (model.mmprojName.map { " · mmproj : \($0)" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.select(model)
                        dismiss()
                    }
                    .contextMenu {
                        Button("Relier / remplacer le fichier GGUF") {
                            target = .replace(model.id)
                            picking = true
                        }
                        Button("Associer un mmproj (vision)") {
                            target = .mmproj(model.id)
                            picking = true
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            vm.remove(model)
                        } label: {
                            Label("Retirer", systemImage: "trash")
                        }
                    }
                }

                Section(footer: Text(
                    "Les GGUF restent dans Fichiers : Pal conserve un signet au lieu de copier les gros modèles. " +
                    "L'association mmproj est enregistrée, mais l'analyse d'images n'est pas encore implémentée."
                )) {
                    Button("Ajouter un modèle .gguf") {
                        target = .model
                        picking = true
                    }
                }
            }
            .navigationTitle("Modèles")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                switch target {
                case .model:
                    vm.addModel(url)
                    dismiss()
                case .mmproj(let id):
                    vm.addMMProj(url, to: id)
                case .replace(let id):
                    vm.relinkModel(url, id: id)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss

    private let presets: [(String, String)] = [
        ("Concis", "Tu es un assistant concis et précis. Réponds dans la langue de l'utilisateur."),
        ("Maths", "Tu es un tuteur de mathématiques rigoureux. Donne la formule exacte puis le raisonnement étape par étape, sans inventer."),
        ("Traducteur", "Tu es un traducteur FR↔EN. Traduis fidèlement, sans commentaire."),
        ("Code", "Tu es un expert Python, HTML, CSS et JavaScript. Donne du code correct, commenté et court.")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    header: Text("Prompt système"),
                    footer: Text("S'applique au prochain message après rechargement du modèle.")
                ) {
                    TextEditor(text: $vm.cfg.system)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Instructions système personnalisées")
                    Menu("Préréglages") {
                        ForEach(presets, id: \.0) { preset in
                            Button(preset.0) { vm.cfg.system = preset.1 }
                        }
                    }
                }

                Section("Profil iPhone / ressources") {
                    Button("Économie mémoire (XR conseillé)") {
                        vm.applyDevicePreset(.economy)
                    }
                    Button("Équilibré") {
                        vm.applyDevicePreset(.balanced)
                    }
                    Text("Ces profils privilégient la stabilité. Le GPU Metal reste désactivé par défaut ; teste son activation modèle par modèle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Échantillonnage") {
                    sliderRow("temperature", $vm.cfg.temp, 0...2, 0.05)
                    sliderRow("top_p", $vm.cfg.topP, 0...1, 0.05)
                    sliderRow("min_p", $vm.cfg.minP, 0...0.5, 0.01)
                    sliderRow("repeat_penalty", $vm.cfg.repeatPen, 1...1.5, 0.01)
                    Stepper("top_k : \(vm.cfg.topK)", value: $vm.cfg.topK, in: 1...200)
                    Stepper("max tokens : \(vm.cfg.maxTokens)", value: $vm.cfg.maxTokens, in: 64...2048, step: 64)
                }

                Section(header: Text("Modèle (rechargement requis)")) {
                    Stepper("n_ctx : \(vm.cfg.nCtx)", value: $vm.cfg.nCtx, in: 512...4096, step: 512)
                    Stepper("n_batch : \(vm.cfg.nBatch)", value: $vm.cfg.nBatch, in: 32...512, step: 32)
                    Stepper("threads : \(vm.cfg.threads)", value: $vm.cfg.threads, in: 1...8)
                    Stepper("couches GPU (Metal) : \(vm.cfg.gpuLayers)", value: $vm.cfg.gpuLayers, in: 0...99, step: 4)
                    Button("Appliquer et recharger") {
                        vm.reload()
                        dismiss()
                    }
                }

                Section("Apparence") {
                    Picker("Thème", selection: $vm.cfg.theme) {
                        Text("Auto").tag(0)
                        Text("Clair").tag(1)
                        Text("Sombre").tag(2)
                    }
                    .pickerStyle(.segmented)

                    ColorPicker(
                        "Couleur d'accent",
                        selection: Binding(
                            get: { vm.cfg.accent },
                            set: { vm.cfg.setAccent($0) }
                        )
                    )
                    sliderRow("Taille du texte", $vm.cfg.fontSize, 12...24, 1)
                    Toggle("Retour haptique", isOn: $vm.cfg.haptics)
                    Toggle("Écran allumé pendant la génération", isOn: $vm.cfg.keepAwake)
                }

                Section("Données et confidentialité") {
                    Text("Les modèles GGUF sélectionnés depuis Fichiers sont lus à leur emplacement d'origine : Pal ne les duplique pas dans son conteneur. Les conversations restent stockées localement sur l'iPhone.")
                        .font(.caption)
                    Button("Effacer la conversation actuelle", role: .destructive) {
                        vm.newChat()
                    }
                    .disabled(vm.generating || vm.messages.isEmpty)
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    private func sliderRow(
        _ name: String,
        _ value: Binding<Double>,
        _ range: ClosedRange<Double>,
        _ step: Double
    ) -> some View {
        VStack(alignment: .leading) {
            Text("\(name) : \(String(format: "%.2f", value.wrappedValue))")
                .font(.subheadline)
            Slider(value: value, in: range, step: step)
        }
    }
}
