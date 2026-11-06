import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelsTab: View {
    private enum ImportTarget {
        case model
        case mmproj(UUID)
        case replace(UUID)
    }

    @EnvironmentObject private var vm: VM
    @State private var picking = false
    @State private var target = ImportTarget.model
    @State private var message: String?
    @State private var deleting: ModelEntry?
    @State private var showDownloads = false

    var body: some View {
        NavigationStack {
            List {
                modelsSection
                memorySection
            }
            .navigationTitle("Modèles")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showDownloads = true
                        } label: {
                            Label("Télécharger depuis Hugging Face", systemImage: "arrow.down.circle")
                        }
                        Button {
                            vm.scanLibrary()
                            message = "Dossier analysé : \(vm.models.count) modèle(s)."
                        } label: {
                            Label("Analyser le dossier Pal", systemImage: "arrow.clockwise")
                        }
                        Button {
                            target = .model
                            picking = true
                        } label: {
                            Label("Ajouter depuis Fichiers", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ajouter un modèle")
                }
            }
            .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
            .refreshable { vm.scanLibrary() }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
                switch result {
                case .failure(let error):
                    message = "Sélection impossible : \(error.localizedDescription)"
                case .success(let url):
                    switch target {
                    case .model:
                        if vm.addModel(url) || vm.importModelCopy(url) {
                            message = "Modèle ajouté."
                        } else {
                            message = vm.status
                        }
                    case .mmproj(let id):
                        vm.addMMProj(url, to: id)
                        message = vm.status
                    case .replace(let id):
                        vm.relinkModel(url, id: id)
                        message = vm.status
                    }
                }
            }
            .alert(
                "Modèles",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog(
                "Supprimer ce modèle du téléphone ?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Supprimer le fichier", role: .destructive) {
                    if let model = deleting { vm.deleteModelFile(model) }
                    deleting = nil
                }
                Button("Annuler", role: .cancel) { deleting = nil }
            } message: {
                Text(deleting?.name ?? "")
            }
        }
    }

    private var modelsSection: some View {
        Section {
            if vm.models.isEmpty {
                Text("Aucun modèle pour l'instant. Dépose un .gguf dans Fichiers › Sur mon iPhone › Pal › Models : il apparaît ici tout seul. Tu peux aussi en télécharger un avec le bouton +.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(vm.models) { model in
                row(model)
            }
        } footer: {
            Text("Les .gguf du dossier Models sont reconnus automatiquement, et un fichier « mmproj » est associé au modèle qui lui correspond. Les .md ou .txt du dossier Skills deviennent des compétences.")
        }
    }

    private var memorySection: some View {
        Section("Mémoire") {
            Button {
                vm.unloadModel()
            } label: {
                Label("Décharger le modèle de la mémoire", systemImage: "eject")
            }
            .disabled(!vm.engine.loaded || vm.generating || vm.loading)
            Text(vm.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isDefault(_ model: ModelEntry) -> Bool {
        vm.prefs.newChatModelID == model.id.uuidString
            || (vm.prefs.launchMode == 2 && vm.prefs.launchModelID == model.id.uuidString)
    }

    private func sizeText(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f Go", Double(mb) / 1024) : "\(mb) Mo"
    }

    private func row(_ model: ModelEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isDefault(model) {
                        Text("Par défaut")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                    }
                }
                HStack(spacing: 6) {
                    Text("GGUF · \(sizeText(model.sizeMB)) · \(model.relPath == nil ? "Lié" : "Dossier")")
                    if model.mmprojName != nil { Text("· mmproj") }
                    if vm.currentID == model.id {
                        Image(systemName: vm.engine.loaded ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(vm.cfg.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Utiliser pour cette discussion") { vm.select(model) }
                Button("Par défaut pour les nouvelles discussions") { vm.setNewChatModel(model) }
                Button("Charger au lancement de l'app") { vm.setLaunchModel(model) }
                Button("Associer un fichier mmproj…") {
                    target = .mmproj(model.id)
                    picking = true
                }
                if model.relPath == nil {
                    Button("Relier à un autre fichier…") {
                        target = .replace(model.id)
                        picking = true
                    }
                    Button("Retirer de la liste", role: .destructive) { vm.remove(model) }
                } else {
                    Button("Supprimer le fichier", role: .destructive) { deleting = model }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.select(model) }
    }
}
