import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var importMessage: String?
    @State private var deleting: ModelEntry?

    var body: some View {
        NavigationStack {
            List {
                modelsSection
                addSection
                memorySection
            }
            .navigationTitle("Modèles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .refreshable { vm.scanLibrary() }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
                switch result {
                case .failure(let error):
                    importMessage = "Sélection impossible : \(error.localizedDescription)"
                case .success(let url):
                    switch target {
                    case .model:
                        if vm.addModel(url) || vm.importModelCopy(url) {
                            dismiss()
                        } else {
                            importMessage = vm.status
                        }
                    case .mmproj(let id):
                        vm.addMMProj(url, to: id)
                        importMessage = vm.status
                    case .replace(let id):
                        vm.relinkModel(url, id: id)
                        importMessage = vm.status
                    }
                }
            }
            .alert(
                "Modèles",
                isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
            .confirmationDialog(
                "Supprimer ce modèle du téléphone ?",
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if !$0 { deleting = nil } }
                ),
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

    // MARK: sections

    private var modelsSection: some View {
        Section {
            if vm.models.isEmpty {
                Text("Aucun modèle pour l'instant. Dépose un .gguf dans Fichiers › Sur mon iPhone › Pal › Models : il apparaît ici tout seul. Tu peux aussi en télécharger un.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(vm.models) { model in
                row(model)
            }
        } header: {
            Text("Mes modèles")
        }
    }

    private var addSection: some View {
        Section {
            NavigationLink {
                DownloadsView()
            } label: {
                Label("Télécharger depuis Hugging Face", systemImage: "arrow.down.circle")
            }
            Button {
                vm.scanLibrary()
                importMessage = "Dossier analysé : \(vm.models.count) modèle(s) et \(vm.skills.filter { $0.id.hasPrefix("file:") }.count) compétence(s) du dossier."
            } label: {
                Label("Analyser le dossier Pal", systemImage: "arrow.clockwise")
            }
            Button {
                target = .model
                picking = true
            } label: {
                Label("Ajouter depuis Fichiers (sélecteur)", systemImage: "folder")
            }
        } header: {
            Text("Ajouter un modèle")
        } footer: {
            Text("Méthode 1 (automatique) : glisse tes fichiers dans Fichiers › Sur mon iPhone › Pal › Models. Les .gguf sont reconnus et un fichier « mmproj » est associé au modèle qui lui correspond. Les .md ou .txt placés dans « Skills » deviennent des compétences. Méthode 2 : le sélecteur ci-dessus, qui lit le fichier sans le copier (ou le copie en secours).")
        }
    }

    private var memorySection: some View {
        Section {
            Button {
                vm.unloadModel()
            } label: {
                Label("Décharger le modèle de la mémoire", systemImage: "eject")
            }
            .disabled(!vm.engine.loaded || vm.generating || vm.loading)
            Text(vm.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Mémoire")
        }
    }

    // MARK: ligne de modèle

    private func chip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }

    private func row(_ model: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer()
                if vm.currentID == model.id {
                    Image(systemName: vm.engine.loaded ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(vm.cfg.accent)
                }
            }
            HStack(spacing: 6) {
                Text("\(model.sizeMB) Mo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.mmprojName != nil { chip("mmproj", "eye") }
                if vm.prefs.launchMode == 2 && vm.prefs.launchModelID == model.id.uuidString {
                    chip("lancement", "power")
                }
                if vm.prefs.newChatModelID == model.id.uuidString {
                    chip("nouvelles", "plus.bubble")
                }
                if model.relPath == nil { chip("Fichiers", "folder") }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            vm.select(model)
            dismiss()
        }
        .contextMenu {
            Button("Utiliser pour cette discussion") {
                vm.select(model)
                dismiss()
            }
            Button("Charger au lancement de l'app") { vm.setLaunchModel(model) }
            Button("Par défaut pour les nouvelles discussions") { vm.setNewChatModel(model) }
            Button("Associer un fichier mmproj…") {
                target = .mmproj(model.id)
                picking = true
            }
            if model.relPath == nil {
                Button("Relier à un autre fichier…") {
                    target = .replace(model.id)
                    picking = true
                }
            }
        }
        .swipeActions {
            if model.relPath != nil {
                Button(role: .destructive) {
                    deleting = model
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    vm.remove(model)
                } label: {
                    Label("Retirer", systemImage: "minus.circle")
                }
            }
        }
    }
}
