import SwiftUI

/// ⌘F in a Claude conversation.
struct ClaudeFindBar: View {
    @Bindable var controller: ClaudeConversationController
    let close: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Sohbette ara", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(minWidth: 60, maxWidth: 180)
                .focused($isFocused)
                .onSubmit {
                    controller.step(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                }
                .onExitCommand(perform: close)
            if !controller.query.isEmpty {
                Text(controller.matchCount == 0 ? "Yok" : "\(controller.matchIndex)/\(controller.matchCount)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(controller.matchCount == 0 ? Color.red.opacity(0.8) : .secondary)
                    .fixedSize()
            }
            Divider().frame(height: 14)
            Button { controller.step(-1) } label: { Image(systemName: "chevron.up") }
                .help("Önceki (⇧↩)")
                .accessibilityLabel("Önceki eşleşme")
                .disabled(controller.matchCount == 0)
            Button { controller.step(1) } label: { Image(systemName: "chevron.down") }
                .help("Sonraki (↩ ya da ⌘G)")
                .accessibilityLabel("Sonraki eşleşme")
                .disabled(controller.matchCount == 0)
            Button(action: close) { Image(systemName: "xmark") }
                .help("Kapat (Esc)")
                .accessibilityLabel("Aramayı kapat")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .frame(maxWidth: 380)
        .onAppear { isFocused = true }
        .onChange(of: controller.focusRequest) { isFocused = true }
        .onChange(of: controller.query) { controller.find() }
    }
}
