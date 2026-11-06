import SwiftUI

struct Persona: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var emoji: String?
    var builtIn: Bool

    static let defaults: [Persona] = [
        Persona(id: "builtin-concis", name: "Concis",
                prompt: "Tu es un assistant concis et précis. Réponds dans la langue de l'utilisateur.",
                emoji: "💬", builtIn: true),
        Persona(id: "builtin-maths", name: "Maths",
                prompt: "Tu es un tuteur de mathématiques rigoureux. Donne la formule exacte puis le raisonnement étape par étape, sans inventer. Écris les formules en LaTeX entre $ et $.",
                emoji: "📐", builtIn: true),
        Persona(id: "builtin-traducteur", name: "Traducteur",
                prompt: "Tu es un traducteur FR↔EN. Traduis fidèlement, sans commentaire.",
                emoji: "🌍", builtIn: true),
        Persona(id: "builtin-code", name: "Code",
                prompt: "Tu es un expert Python, HTML, CSS et JavaScript. Donne du code correct, commenté et court.",
                emoji: "💻", builtIn: true)
    ]
}

struct PersonaAvatar: View {
    let persona: Persona
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(red: 0.45, green: 0.48, blue: 0.72), Color(red: 0.32, green: 0.35, blue: 0.58)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            if let emoji = persona.emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 22))
            } else {
                Text(String(persona.name.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 46, height: 46)
    }
}

struct PersonasTab: View {
    @EnvironmentObject private var vm: VM
    let onStart: (Persona) -> Void
    @State private var editing: Persona?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.personas) { persona in
                    Button { onStart(persona) } label: { row(persona) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if !persona.builtIn {
                                Button(role: .destructive) {
                                    vm.deletePersona(persona.id)
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            Button("Modifier") { editing = persona }
                            if !persona.builtIn {
                                Button("Supprimer", role: .destructive) { vm.deletePersona(persona.id) }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Personnages")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Créer un personnage")
                }
            }
            .sheet(item: $editing) { persona in PersonaEditor(persona: persona) }
            .sheet(isPresented: $creating) {
                PersonaEditor(persona: Persona(id: UUID().uuidString, name: "", prompt: "", emoji: "✨", builtIn: false))
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 72) }
        }
    }

    private func row(_ persona: Persona) -> some View {
        HStack(spacing: 14) {
            PersonaAvatar(persona: persona)
            VStack(alignment: .leading, spacing: 3) {
                Text(persona.name).font(.body.weight(.medium))
                Text(persona.prompt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PersonaEditor: View {
    @EnvironmentObject private var vm: VM
    @Environment(\.dismiss) private var dismiss
    let persona: Persona
    @State private var name: String
    @State private var emoji: String
    @State private var prompt: String

    init(persona: Persona) {
        self.persona = persona
        _name = State(initialValue: persona.name)
        _emoji = State(initialValue: persona.emoji ?? "")
        _prompt = State(initialValue: persona.prompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identité") {
                    TextField("Nom", text: $name)
                    TextField("Emoji (facultatif)", text: $emoji)
                }
                Section {
                    TextEditor(text: $prompt).frame(minHeight: 160)
                } header: {
                    Text("Consignes")
                } footer: {
                    Text("Ces consignes remplacent le prompt système pour les discussions de ce personnage.")
                }
            }
            .navigationTitle(persona.name.isEmpty ? "Nouveau personnage" : "Modifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        vm.savePersona(Persona(
                            id: persona.id,
                            name: name,
                            prompt: prompt,
                            emoji: emoji.isEmpty ? nil : String(emoji.prefix(2)),
                            builtIn: persona.builtIn
                        ))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
