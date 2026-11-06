import SwiftUI
import UIKit

// MARK: - Application

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

/// Garde le geste « glisser depuis le bord » pour revenir en arrière malgré le bouton retour personnalisé.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

// MARK: - Onglets

enum PalTab: Int, CaseIterable, Identifiable {
    case chats, personas, models, settings
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .chats: return "Discussions"
        case .personas: return "Personnages"
        case .models: return "Modèles"
        case .settings: return "Réglages"
        }
    }

    var icon: String {
        switch self {
        case .chats: return "bubble.left"
        case .personas: return "person"
        case .models: return "cpu"
        case .settings: return "gearshape"
        }
    }
}

enum ChatRoute: Hashable { case chat }

struct RootView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = PalTab.chats
    @State private var path = NavigationPath()

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .chats: ChatsTab(path: $path)
                case .personas: PersonasTab(onStart: start)
                case .models: ModelsTab()
                case .settings: SettingsTab()
                }
            }

            if path.isEmpty || tab != .chats {
                FloatingTabBar(selection: $tab)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: path.isEmpty)
        .onChange(of: scenePhase) { phase in
            vm.scenePhaseChanged(phase)
        }
        .onChange(of: vm.requestModelPicker) { requested in
            if requested {
                vm.requestModelPicker = false
                path = NavigationPath()
                tab = .models
            }
        }
    }

    private func start(_ persona: Persona) {
        guard !vm.generating, !vm.loading else { return }
        vm.newChat()
        vm.setPersona(persona.id)
        tab = .chats
        path.append(ChatRoute.chat)
    }
}

struct FloatingTabBar: View {
    @EnvironmentObject private var vm: VM
    @Binding var selection: PalTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PalTab.allCases) { tab in
                Button {
                    if vm.cfg.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    withAnimation(.easeOut(duration: 0.15)) { selection = tab }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 20))
                        Text(tab.title).font(.system(size: 10))
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selection == tab ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 24)
    }
}

// MARK: - Discussions

struct ChatAvatar: View {
    let title: String
    let emoji: String?
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(red: 0.45, green: 0.48, blue: 0.72), Color(red: 0.32, green: 0.35, blue: 0.58)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            if let emoji = emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 22))
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 46, height: 46)
    }
}

struct ChatsTab: View {
    @EnvironmentObject private var vm: VM
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    private var chats: [Conversation] {
        let all = vm.conversations
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updated > $1.updated }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { chat in
            chat.title.localizedCaseInsensitiveContains(q)
                || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(chats) { chat in
                    Button {
                        vm.openChat(chat.id)
                        path.append(ChatRoute.chat)
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
            .listStyle(.plain)
            .overlay {
                if chats.isEmpty {
                    Text(query.isEmpty ? "Aucune discussion.\nTouche + pour commencer." : "Aucun résultat.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Rechercher des discussions")
            .navigationTitle("Pal")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.newChat()
                        path.append(ChatRoute.chat)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nouvelle discussion")
                }
            }
            .navigationDestination(for: ChatRoute.self) { _ in ChatScreen() }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
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

    private func preview(_ chat: Conversation) -> String {
        guard let last = chat.messages.last else { return "" }
        let answer = ThinkSplit.parse(last.text, modelThinks: false, streaming: false).answer
        let flat = answer.replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(120))
    }

    private func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Hier" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    private func row(_ chat: Conversation) -> some View {
        let emoji = vm.personas.first(where: { $0.id == chat.personaID })?.emoji
        return HStack(spacing: 14) {
            ChatAvatar(title: chat.title, emoji: emoji)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(chat.title).font(.body.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(dateText(chat.updated)).font(.caption).foregroundStyle(.secondary)
                }
                Text(preview(chat))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Chat

enum ChatSheet: String, Identifiable {
    case menu, actions, models, personas, skills, research
    var id: String { rawValue }
}

struct ChatScreen: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ChatSheet?
    @State private var showStats = false
    @State private var searching = false
    @State private var searchText = ""
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    private var title: String {
        vm.conversations.first(where: { $0.id == vm.currentChatID })?.title ?? "Discussion"
    }

    var body: some View {
        VStack(spacing: 0) {
            if searching { searchBar }
            if showStats {
                SensorsPanel()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ChatList(filter: searching ? searchText : "", onDownload: { vm.requestModelPicker = true })
            InputCard(onModel: { sheet = .models }, onPlus: { sheet = .actions })
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Retour aux discussions")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showStats.toggle() }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                }
                .accessibilityLabel("Statistiques et benchmark")
                Button { sheet = .menu } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Options de la discussion")
            }
        }
        .sheet(item: $sheet) { current in sheetContent(current) }
        .alert("Renommer la discussion", isPresented: $renaming) {
            TextField("Titre", text: $newTitle)
            Button("OK") { vm.renameChat(vm.currentChatID, newTitle) }
            Button("Annuler", role: .cancel) {}
        }
        .confirmationDialog("Supprimer cette discussion ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                vm.deleteChat(vm.currentChatID)
                dismiss()
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher dans la discussion", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Fermer") {
                searchText = ""
                withAnimation { searching = false }
            }
            .font(.subheadline)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func sheetContent(_ current: ChatSheet) -> some View {
        switch current {
        case .menu:
            ChatMenuSheet(
                onNew: {
                    sheet = nil
                    vm.newChat()
                },
                onRename: {
                    newTitle = title
                    sheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { renaming = true }
                },
                onSearch: {
                    sheet = nil
                    withAnimation { searching = true }
                },
                onDelete: {
                    sheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { confirmDelete = true }
                }
            )
        case .actions:
            ActionsSheet(onPick: { next in sheet = next })
        case .models:
            ModelPickerSheet()
        case .personas:
            PersonaPickerSheet()
        case .skills:
            SkillsView()
        case .research:
            ResearchView()
        }
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = Color.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ChatMenuSheet: View {
    let onNew: () -> Void
    let onRename: () -> Void
    let onSearch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ActionRow(icon: "plus", title: "Nouvelle discussion", action: onNew)
            ActionRow(icon: "pencil", title: "Renommer la conversation", action: onRename)
            ActionRow(icon: "magnifyingglass", title: "Rechercher", action: onSearch)
            ActionRow(icon: "trash", title: "Supprimer", tint: Color.red, action: onDelete)
        }
        .padding(20)
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
    }
}

struct ActionsSheet: View {
    @EnvironmentObject private var vm: VM
    let onPick: (ChatSheet) -> Void

    private var thinkLabel: String {
        ["Repliée", "Visible", "Masquée"][min(max(vm.prefs.thinkDisplay, 0), 2)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Plus d'actions")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, 4)
                ActionRow(
                    icon: "person",
                    title: "Personnage",
                    subtitle: vm.currentPersona?.name ?? "Aucun personnage sélectionné",
                    action: { onPick(.personas) }
                )
                ActionRow(
                    icon: "cpu",
                    title: "Modèle",
                    subtitle: vm.currentName,
                    action: { onPick(.models) }
                )
                ActionRow(
                    icon: "lightbulb",
                    title: "Affichage de la réflexion",
                    subtitle: thinkLabel,
                    action: { vm.prefs.thinkDisplay = (vm.prefs.thinkDisplay + 1) % 3 }
                )
                ActionRow(
                    icon: "sparkles",
                    title: "Compétences",
                    subtitle: "Consignes activables",
                    action: { onPick(.skills) }
                )
                ActionRow(
                    icon: "globe",
                    title: "Recherche Web",
                    subtitle: "Ajoute des sources à la question",
                    action: { onPick(.research) }
                )
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ModelPickerSheet: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vm.models.isEmpty {
                    Text("Aucun modèle. Ajoute-en un dans l'onglet Modèles.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.models) { model in
                    Button {
                        vm.select(model)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).font(.body).lineLimit(2)
                                Text("\(model.sizeMB) Mo").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if vm.currentID == model.id {
                                Image(systemName: vm.engine.loaded ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(vm.cfg.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if vm.engine.loaded {
                    Button {
                        vm.unloadModel()
                        dismiss()
                    } label: {
                        Label("Décharger le modèle", systemImage: "eject")
                    }
                    .disabled(vm.generating || vm.loading)
                }
            }
            .navigationTitle("Modèle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PersonaPickerSheet: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    vm.setPersona(nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Aucun (prompt système par défaut)")
                        Spacer()
                        if vm.currentPersona == nil {
                            Image(systemName: "checkmark").foregroundStyle(vm.cfg.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                ForEach(vm.personas) { persona in
                    Button {
                        vm.setPersona(persona.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PersonaAvatar(persona: persona)
                            Text(persona.name)
                            Spacer()
                            if vm.currentPersona?.id == persona.id {
                                Image(systemName: "checkmark").foregroundStyle(vm.cfg.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Personnage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct InputCard: View {
    @EnvironmentObject private var vm: VM
    let onModel: () -> Void
    let onPlus: () -> Void

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Posez votre question en toute confidentialité", text: $vm.input, axis: .vertical)
                .lineLimit(1...6)
                .font(.system(size: vm.cfg.fontSize, design: vm.fontDesign))
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                Button(action: onModel) {
                    HStack(spacing: 6) {
                        if vm.loading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "cpu").font(.system(size: 13))
                        }
                        Text(vm.currentName)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .frame(maxWidth: 230)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choisir le modèle")

                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plus d'actions")

                Spacer(minLength: 0)

                Button {
                    vm.generating ? vm.stop() : vm.send()
                } label: {
                    Image(systemName: vm.generating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(vm.loading || (!vm.generating && !canSend))
                .opacity(vm.loading || (!vm.generating && !canSend) ? 0.4 : 1)
                .accessibilityLabel(vm.generating ? "Arrêter la génération" : "Envoyer")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct ChatList: View {
    @EnvironmentObject private var vm: VM
    let filter: String
    let onDownload: () -> Void

    private let suggestions = [
        "Explique-moi simplement ce concept :",
        "Résume ce texte :",
        "Aide-moi à écrire un message poli pour :",
        "Corrige et explique cette erreur de code :"
    ]

    private var shown: [Msg] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return vm.messages }
        return vm.messages.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if vm.messages.isEmpty && vm.streaming == nil {
                        emptyState
                    }
                    ForEach(shown) { message in
                        MessageView(
                            message: message,
                            isLast: message.id == vm.messages.last?.id,
                            streaming: false
                        )
                    }
                    if let live = vm.streaming {
                        MessageView(
                            message: Msg(role: "assistant", text: live),
                            isLast: false,
                            streaming: true
                        )
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.streaming) { _ in
                proxy.scrollTo("chat-end", anchor: .bottom)
            }
            .onChange(of: vm.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("chat-end", anchor: .bottom) }
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
                Button("Aller aux modèles") { onDownload() }
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
