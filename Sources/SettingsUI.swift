import SwiftUI
import UIKit
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [AVSpeechSynthesisVoice] = []

    private let presets: [(String, String)] = [
        ("Concis", "Tu es un assistant concis et précis. Réponds dans la langue de l'utilisateur."),
        ("Maths", "Tu es un tuteur de mathématiques rigoureux. Donne la formule exacte puis le raisonnement étape par étape, sans inventer."),
        ("Traducteur", "Tu es un traducteur FR↔EN. Traduis fidèlement, sans commentaire."),
        ("Code", "Tu es un expert Python, HTML, CSS et JavaScript. Donne du code correct, commenté et court.")
    ]

    var body: some View {
        NavigationStack {
            Form {
                perfSection
                modelsMemorySection
                voiceSection
                promptSection
                samplingSection
                appearanceSection
                dataSection
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { voices = Speaker.voices() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    // MARK: performance

    private var gpuBinding: Binding<Bool> {
        Binding(
            get: { vm.cfg.gpuLayers > 0 },
            set: { vm.cfg.gpuLayers = $0 ? 99 : 0 }
        )
    }

    private func profileCard(_ profile: PerfProfile) -> some View {
        let selected = PerfProfile.detect(vm.cfg) == profile
        return Button {
            vm.applyProfile(profile)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: profile.icon).font(.title3)
                Text(profile.title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                selected ? vm.cfg.accent.opacity(0.18) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? vm.cfg.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var ramRow: some View {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
        let used = Sys.footprintMB()
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "RAM : %.0f Mo utilisés sur %.0f Mo · disponible pour l'app ≈ %.0f Mo", used, total, Sys.availMB()))
                .font(.caption)
            ProgressView(value: min(used, total), total: total)
        }
    }

    private var perfSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(PerfProfile.allCases) { profile in
                    profileCard(profile)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)

            Text(PerfProfile.detect(vm.cfg).detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: gpuBinding) {
                Label("GPU Metal", systemImage: "cpu")
            }
            Toggle(isOn: $vm.prefs.mmap) {
                Label("Lecture mmap (économise la RAM)", systemImage: "memorychip")
            }
            Toggle(isOn: $vm.prefs.thermalGuard) {
                Label("Protection thermique et batterie", systemImage: "thermometer.medium")
            }
            Picker(selection: $vm.cfg.nCtx) {
                ForEach([512, 768, 1024, 1536, 2048, 3072, 4096], id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            } label: {
                Label("Contexte (tokens)", systemImage: "text.alignleft")
            }
            Stepper(value: $vm.cfg.threads, in: 1...8) {
                Label("Threads : \(vm.cfg.threads)", systemImage: "square.grid.3x3")
            }
            Stepper(value: $vm.cfg.maxTokens, in: 64...2048, step: 64) {
                Label("Réponse max : \(vm.cfg.maxTokens) tokens", systemImage: "text.badge.checkmark")
            }
            ramRow

            if vm.needsReload {
                Button {
                    vm.reload()
                    dismiss()
                } label: {
                    Label("Appliquer et recharger le modèle", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("Le GPU Metal est expérimental sur les iPhone à peu de RAM : désactive-le si le chargement échoue. Contexte, GPU et mmap demandent de recharger le modèle ; les threads s'appliquent au prochain message.")
        }
    }

    // MARK: modèles et mémoire

    private var launchModelBinding: Binding<String> {
        Binding(
            get: { vm.prefs.launchModelID ?? "" },
            set: { vm.prefs.launchModelID = $0.isEmpty ? nil : $0 }
        )
    }

    private var newChatBinding: Binding<String> {
        Binding(
            get: { vm.prefs.newChatModelID ?? "" },
            set: { vm.prefs.newChatModelID = $0.isEmpty ? nil : $0 }
        )
    }

    private var modelsMemorySection: some View {
        Section {
            Picker("Au lancement de l'app", selection: $vm.prefs.launchMode) {
                Text("Ne rien charger (à la demande)").tag(0)
                Text("Recharger le dernier modèle").tag(1)
                Text("Toujours charger le modèle choisi").tag(2)
            }
            if vm.prefs.launchMode == 2 {
                Picker("Modèle de lancement", selection: launchModelBinding) {
                    Text("—").tag("")
                    ForEach(vm.models) { model in
                        Text(model.name).tag(model.id.uuidString)
                    }
                }
            }
            Picker("Nouvelles discussions", selection: newChatBinding) {
                Text("Modèle actuel").tag("")
                ForEach(vm.models) { model in
                    Text(model.name).tag(model.id.uuidString)
                }
            }
            Picker("Décharger si inactif", selection: $vm.prefs.autoUnloadMinutes) {
                Text("Jamais").tag(0)
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
            }
            Toggle("Décharger en arrière-plan", isOn: $vm.prefs.unloadInBackground)
            Button {
                vm.unloadModel()
            } label: {
                Label("Décharger le modèle maintenant", systemImage: "eject")
            }
            .disabled(!vm.engine.loaded || vm.generating || vm.loading)
        } header: {
            Text("Modèles et mémoire")
        } footer: {
            Text("Chaque discussion garde son modèle. Un modèle déchargé libère la RAM et se recharge tout seul à l'envoi du prochain message. « À la demande » garde l'app très légère au démarrage.")
        }
    }

    // MARK: voix

    private var voiceBinding: Binding<String> {
        Binding(
            get: { vm.prefs.ttsVoice ?? "" },
            set: { vm.prefs.ttsVoice = $0.isEmpty ? nil : $0 }
        )
    }

    private var voiceSection: some View {
        Section {
            Toggle("Lire les réponses automatiquement", isOn: $vm.prefs.ttsAuto)
            Picker("Voix", selection: voiceBinding) {
                Text("Automatique").tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text("\(voice.name) (\(Speaker.qualityLabel(voice)))").tag(voice.identifier)
                }
            }
            VStack(alignment: .leading) {
                Text(String(format: "Vitesse : %.2f", vm.prefs.ttsRate)).font(.subheadline)
                Slider(value: $vm.prefs.ttsRate, in: 0.3...0.6, step: 0.01)
            }
            Button {
                vm.speaker.speak("Bonjour, je suis Pal. Voici ma voix.", voiceID: vm.prefs.ttsVoice, rate: vm.prefs.ttsRate)
            } label: {
                Label("Tester la voix", systemImage: "speaker.wave.2")
            }
        } header: {
            Text("Voix (lecture à voix haute)")
        } footer: {
            Text("Pour de meilleures voix : Réglages iOS › Accessibilité › Contenu énoncé › Voix. Dans le chat, touche le haut-parleur sous une réponse pour l'écouter.")
        }
    }

    // MARK: prompt, échantillonnage, apparence, données

    private var promptSection: some View {
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
    }

    private var samplingSection: some View {
        Section("Échantillonnage") {
            sliderRow("temperature", $vm.cfg.temp, 0...2, 0.05)
            sliderRow("top_p", $vm.cfg.topP, 0...1, 0.05)
            sliderRow("min_p", $vm.cfg.minP, 0...0.5, 0.01)
            sliderRow("repeat_penalty", $vm.cfg.repeatPen, 1...1.5, 0.01)
            Stepper("top_k : \(vm.cfg.topK)", value: $vm.cfg.topK, in: 1...200)
        }
    }

    private var appearanceSection: some View {
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
    }

    private var dataSection: some View {
        Section("Données et confidentialité") {
            Text("Les conversations restent stockées localement sur l'iPhone. Les modèles du dossier Pal sont lus sur place ; ceux choisis via le sélecteur sont lus à leur emplacement d'origine (ou copiés en secours).")
                .font(.caption)
            Button("Supprimer cette discussion", role: .destructive) {
                vm.deleteChat(vm.currentChatID)
            }
            .disabled(vm.generating || vm.loading || vm.messages.isEmpty)
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
