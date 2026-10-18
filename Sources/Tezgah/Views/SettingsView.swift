import SwiftUI

/// Tezgah › Ayarlar (⌘,).
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Genel", systemImage: "gearshape") }
                .tag("general")
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkle") }
                .tag("claude")
            MCPSettings()
                .tabItem { Label("MCP Sunucuları", systemImage: "puzzlepiece.extension") }
                .tag("mcp")
            TelegramSettings()
                .tabItem { Label("Telegram", systemImage: "paperplane") }
                .tag("telegram")
        }
        .frame(width: 560)
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker("Görünüm", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Editör yazı boyutu") {
                Stepper(value: $settings.editorFontSize, in: 10...24, step: 1) {
                    Text("\(Int(settings.editorFontSize)) pt").monospacedDigit()
                }
            }
            LabeledContent("Terminal yazı boyutu") {
                Stepper(value: $settings.terminalFontSize, in: 10...24, step: 1) {
                    Text("\(Int(settings.terminalFontSize)) pt").monospacedDigit()
                }
            }
            Text("Yazı boyutu açık editörlere ve terminallere hemen uygulanır.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}

private struct ClaudeSettings: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Yeni Claude sekmeleri", selection: $settings.claudeOpensAsConversation) {
                    Text("Sohbet görünümünde açılsın").tag(true)
                    Text("Terminal görünümünde açılsın").tag(false)
                }
                Toggle(isOn: $settings.promptSuggestions) {
                    Text("Prompt önerileri")
                    Text("Her turdan sonra ne sorabileceğine dair üç öneri; küçük bir modelle üretilir.")
                }
                Toggle(isOn: $settings.claudeRemoteControl) {
                    Text("Uzaktan erişim")
                    Text("Yeni oturumlar Claude uygulamasından ve claude.ai/code'dan takip edilip yanıtlanabilir. Oturum bu Mac'te çalışır; açıkken Mac uykuya geçmez. Tek bir oturumda durum çubuğundaki 📡 ile de açılır.")
                }
            }
            Section {
                Toggle(isOn: $settings.tezgahTools) {
                    Text("Tezgah araçları")
                    Text("Claude tarayıcı önizlemesini, simülatörü, panoyu, veritabanlarını ve terminalleri kullanabilir. Yeni oturumlarda geçerli olur.")
                }
            } footer: {
                Text("Veri değiştiren veritabanı komutları her zaman onayını ister.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: Binding(get: { settings.agentsSkipPermissions }, set: setSkipPermissions)) {
                    Text("Ajanlar onay istemesin")
                    Text("Claude ve Codex hiçbir komut ya da düzenleme için izin sormaz; orkestra ve lider ajanın işleri sende takılmadan yürür. Gözden geçirenler yine dosya düzenleyemez. Yeni oturumlarda geçerli olur.")
                }
            } footer: {
                Text("Claude Code tam yetkiyle ilk açılışta kendi uyarısını bir kez gösterir; o sekmede kabul etmen gerekir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }

    private func setSkipPermissions(_ on: Bool) {
        guard on else {
            settings.agentsSkipPermissions = false
            return
        }
        Task {
            let confirmed = await ConfirmSheet.ask(
                title: "Ajanlar onay istemeden çalışsın mı?",
                message: "Claude --dangerously-skip-permissions, Codex --dangerously-bypass-approvals-and-sandbox ile açılır. Komutlar bu Mac'te senin hesabınla, sınırsız çalışır: worktree dışındaki dosyaları silebilir, push atabilir, ağa erişebilir. Yalnızca güvendiğin projelerde kullan.",
                confirm: "Aç"
            )
            if confirmed { settings.agentsSkipPermissions = true }
        }
    }
}

/// Pairing Tezgah with a Telegram bot of the user's own.
private struct TelegramSettings: View {
    @Environment(WorkspaceStore.self) private var store
    @Bindable private var settings = AppSettings.shared
    @State private var token = ""

    var body: some View {
        let bot = store.telegram
        Form {
            Section {
                switch bot.state {
                case .off:
                    tokenField
                    Button("Bağlan") { connect(bot) }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case .connecting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Bağlanıyor…")
                    }
                case .pairing(let code, let name):
                    LabeledContent("Eşleştirme kodu") {
                        Text(code)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("Telegram'da \(name) botuna bu kodu yaz. Bot yalnızca kodu gönderen hesabı dinler.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Bağlantıyı Kapat", role: .destructive) { bot.disconnect() }
                case .paired(let chat, let name):
                    LabeledContent("Durum") {
                        Label("\(name) · \(chat) ile eşleşti", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    HStack {
                        Button("Eşleşmeyi Kaldır") { bot.unpair() }
                            .help("Yeni bir kodla başka (ya da aynı) hesabı eşleştir")
                        Button("Bağlantıyı Kapat", role: .destructive) { bot.disconnect() }
                            .help("Token'ı ve eşleşmeyi siler")
                    }
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    tokenField
                    HStack {
                        Button("Yeniden Dene") { bot.retry() }
                        Button("Yeni Token ile Bağlan") { connect(bot) }
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text("Telegram botu")
            } footer: {
                Text("1. Telegram'da @BotFather'a /newbot yaz ve botuna bir ad ver.\n2. Verdiği token'ı buraya yapıştır; Keychain'de saklanır.\n3. Çıkan kodu bota gönder.\n\nTezgah bota kendisi bağlanır, sunucu gerekmez; Mac açık ve Tezgah çalışıyor olmalı. Mesajlarda yalnızca özet olur: kod, diff ve veritabanı sonuçları gönderilmez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: $settings.telegramKeepsAwake) {
                    Text("Bot eşleşmişken Mac uyumasın")
                    Text("Uyuyan Mac Telegram'daki mesajları duymaz; ekran yine kapanabilir.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }

    private var tokenField: some View {
        SecureField("Bot token'ı", text: $token, prompt: Text("123456789:AA…"))
    }

    private func connect(_ bot: TelegramBot) {
        bot.connect(token: token)
        token = ""
    }
}

private struct MCPSettings: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var servers: [MCPServers.Server] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var isAdding = false
    @State private var draft = Draft()

    struct Draft {
        var name = ""
        var isHTTP = true
        var target = ""
        var scope = MCPServers.Scope.user
        var extra = ""
    }

    private var folder: URL { store.activeProject?.url ?? FileManager.default.homeDirectoryForCurrentUser }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code'un MCP sunucuları")
                        .font(.headline)
                    Text(store.activeProject.map { "Proje: \($0.name)" } ?? "Proje seçili değil; yalnız genel sunucular")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Yenile ve bağlantıları kontrol et")
                .accessibilityLabel("Yenile ve bağlantıları kontrol et")
                Button("Ekle…") {
                    draft = Draft()
                    isAdding = true
                }
            }

            List {
                if servers.isEmpty && !isLoading {
                    Text("Henüz MCP sunucusu yok.")
                        .foregroundStyle(.secondary)
                }
                ForEach(servers) { server in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(server.isConnected ? Color.green : server.needsAuth ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.system(size: 12.5, weight: .medium))
                            Text(server.target)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(server.isConnected ? "Bağlı" : server.needsAuth ? "Giriş gerekli" : "Bağlanamadı")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if server.isAccountConnector {
                            Text("claude.ai").font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Button(role: .destructive) {
                                Task { await remove(server) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Kaldır")
                            .accessibilityLabel("Kaldır")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(height: 240)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Buradaki sunucular Tezgah'taki ve terminaldeki bütün Claude oturumlarında geçerli. Değişiklikler yeni oturumlarda etkin olur. claude.ai sunucuları hesabından yönetilir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .task { await reload() }
        .sheet(isPresented: $isAdding) { addSheet }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MCP sunucusu ekle").font(.headline)
            HStack(spacing: 6) {
                Text("Hazır:").font(.caption).foregroundStyle(.secondary)
                ForEach(MCPServers.presets) { preset in
                    Button(preset.name) {
                        draft.name = preset.name
                        draft.isHTTP = preset.isHTTP
                        draft.target = preset.target
                        draft.extra = preset.name == "github" ? "Authorization: Bearer <GITHUB_TOKEN>" : ""
                    }
                    .controlSize(.small)
                    .help(preset.detail)
                }
            }
            Form {
                TextField("Ad", text: $draft.name)
                Picker("Tür", selection: $draft.isHTTP) {
                    Text("HTTP (adres)").tag(true)
                    Text("Komut (stdio)").tag(false)
                }
                .pickerStyle(.segmented)
                TextField(draft.isHTTP ? "Adres" : "Komut", text: $draft.target, prompt: Text(draft.isHTTP ? "https://…/mcp" : "npx -y paket-adi"))
                TextField(draft.isHTTP ? "Başlık (isteğe bağlı)" : "Ortam değişkeni (isteğe bağlı)", text: $draft.extra,
                          prompt: Text(draft.isHTTP ? "Authorization: Bearer …" : "API_KEY=…"))
                Picker("Kapsam", selection: $draft.scope) {
                    ForEach(MCPServers.Scope.allCases) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Vazgeç") { isAdding = false }
                    .keyboardShortcut(.cancelAction)
                Button("Ekle") {
                    let current = draft
                    isAdding = false
                    Task { await add(current) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await MCPServers.list(in: folder)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(_ draft: Draft) async {
        isLoading = true
        do {
            try await MCPServers.add(
                name: draft.name.trimmingCharacters(in: .whitespaces), target: draft.target.trimmingCharacters(in: .whitespaces),
                isHTTP: draft.isHTTP, scope: draft.scope,
                headers: draft.isHTTP ? [draft.extra] : [], environment: draft.isHTTP ? [] : [draft.extra], in: folder
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    private func remove(_ server: MCPServers.Server) async {
        guard await ConfirmSheet.ask(title: "“\(server.name)” kaldırılsın mı?", message: server.target, confirm: "Kaldır") else { return }
        isLoading = true
        do {
            try await MCPServers.remove(server.name, in: folder)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }
}
