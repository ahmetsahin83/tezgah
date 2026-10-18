import SwiftUI

/// Asks for a shell command to add to the project and run.
struct AddCommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (ProjectCommand) -> Void
    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Komut Ekle")
                .font(.headline)
            Form {
                TextField("Komut", text: $command, prompt: Text("ör. docker compose up"))
                TextField("Ad", text: $name, prompt: Text("isteğe bağlı"))
            }
            Text("Komut projenin klasöründe, yeni bir terminal sekmesinde çalışır.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ekle ve Çalıştır") {
                    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onAdd(ProjectCommand(name: title.isEmpty ? trimmed : title, command: trimmed, source: nil))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
