import SwiftUI
import WebKit

/// A web preview: address bar, device sizes, and a console drawer. Claude drives the same page
/// through Tezgah's browser tools, and the user watches it happen here.
struct BrowserTabView: View {
    @Bindable var session: BrowserSession
    @State private var address = ""
    @State private var isEditingAddress = false
    @State private var showsConsole = false
    @FocusState private var isAddressFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .topTrailing) {
                page
                if let activity = session.claudeActivity {
                    ClaudeActivityPill(text: activity)
                        .padding(10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.claudeActivity)
            if showsConsole {
                Divider()
                ConsoleDrawer(session: session)
                    .frame(height: 190)
                    .transition(.move(edge: .bottom))
            }
        }
        .onAppear {
            address = session.url?.absoluteString ?? ""
            if session.url == nil { isAddressFocused = true }
        }
        .onChange(of: session.url) {
            if !isAddressFocused { address = session.url?.absoluteString ?? "" }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolbarButton("chevron.left", help: "Geri", disabled: !session.canGoBack) { session.goBack() }
            toolbarButton("chevron.right", help: "İleri", disabled: !session.canGoForward) { session.goForward() }
            toolbarButton(session.isLoading ? "xmark" : "arrow.clockwise", help: session.isLoading ? "Durdur" : "Yenile (⌘R)", disabled: session.url == nil) {
                session.isLoading ? session.stop() : session.reload()
            }
            addressField
            viewportMenu
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showsConsole.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                    if session.errorCount > 0 {
                        Text("\(session.errorCount)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                }
                .frame(minWidth: 26, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(showsConsole ? Color.primary.opacity(0.1) : .clear))
            }
            .buttonStyle(.borderless)
            .help("Konsol: loglar, hatalar ve başarısız istekler")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: lockSymbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Adres ya da localhost:3000", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isAddressFocused)
                .onSubmit {
                    if let url = BrowserSession.url(from: address) {
                        session.open(url)
                        isAddressFocused = false
                    }
                }
            if session.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isAddressFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
        }
    }

    private var lockSymbol: String {
        guard let url = session.url else { return "magnifyingglass" }
        if url.isFileURL { return "doc" }
        return url.scheme == "https" ? "lock.fill" : "network"
    }

    private var viewportMenu: some View {
        Menu {
            Picker("Görünüm", selection: $session.viewport) {
                Label("Esnek", systemImage: "arrow.up.left.and.arrow.down.right").tag(BrowserSession.Viewport?.none)
                Divider()
                ForEach(BrowserSession.Viewport.presets, id: \.self) { preset in
                    Text("\(preset.name)  \(Int(preset.width))×\(Int(preset.height))").tag(BrowserSession.Viewport?.some(preset))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: session.viewport == nil ? "rectangle.on.rectangle" : (session.viewport!.width < 500 ? "iphone" : session.viewport!.width < 1000 ? "ipad" : "laptopcomputer"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(session.viewport.map { "\($0.name) \(Int($0.width))×\(Int($0.height))" } ?? "Görünüm boyutu")
        .accessibilityLabel(session.viewport.map { "\($0.name) \(Int($0.width))×\(Int($0.height))" } ?? "Görünüm boyutu")
    }

    private func toolbarButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Page

    @ViewBuilder
    private var page: some View {
        if session.url == nil && !session.isLoading {
            emptyState
        } else if let viewport = session.viewport {
            ScrollView([.horizontal, .vertical]) {
                WebViewHost(webView: session.webView)
                    .frame(width: viewport.width, height: viewport.height)
                    .clipShape(RoundedRectangle(cornerRadius: viewport.width < 500 ? 28 : 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: viewport.width < 500 ? 28 : 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.18), radius: 18, y: 6)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.93))
        } else {
            WebViewHost(webView: session.webView)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(hex: 0x4C8DF6))
            Text("Önizleme")
                .font(.system(size: 17, weight: .semibold))
            Text("Bir adres yaz ya da yerel sunucuna bağlan. Claude da bu sayfayı açıp inceleyebilir.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                ForEach(["localhost:3000", "localhost:5173", "localhost:8080", "localhost:4000"], id: \.self) { address in
                    Button(address) {
                        self.address = address
                        if let url = BrowserSession.url(from: address) { session.open(url) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// "Claude · Tıklıyor: Kaydet" over the page while a tool acts on it.
private struct ClaudeActivityPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.claudeAccent)
                .symbolEffect(.pulse)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.claudeAccent.opacity(0.45)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

private struct ConsoleDrawer: View {
    let session: BrowserSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Konsol")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(session.logs.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Temizle") { session.clearLogs() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .disabled(session.logs.isEmpty)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            Divider()
            if session.logs.isEmpty {
                Text("Henüz kayıt yok")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(session.logs) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                    }
                    .onChange(of: session.logs.count) {
                        if let last = session.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ entry: BrowserSession.LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(entry.level))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(entry.level))
                .frame(width: 14)
            Text(entry.message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(entry.level == .error || entry.level == .network ? color(entry.level) : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(entry.level == .error || entry.level == .network ? Color.red.opacity(0.06) : entry.level == .warn ? Color.yellow.opacity(0.07) : .clear)
    }

    private func symbol(_ level: BrowserSession.LogEntry.Level) -> String {
        switch level {
        case .error: "xmark.octagon.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .network: "wifi.exclamationmark"
        case .info: "info.circle.fill"
        case .log: "chevron.right"
        }
    }

    private func color(_ level: BrowserSession.LogEntry.Level) -> Color {
        switch level {
        case .error, .network: .red
        case .warn: .orange
        case .info: .blue
        case .log: .secondary
        }
    }
}
