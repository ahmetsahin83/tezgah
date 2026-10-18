import SwiftUI

/// Adding or editing a database connection. Suggests what the project's .env files and SQLite files offer.
struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let existing: DatabaseConfig?
    let onSave: (DatabaseConfig, String?) -> Void

    @State private var config: DatabaseConfig
    @State private var password = ""
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var testState: TestState = .idle
    @State private var suggestions: [Suggestion] = []

    enum TestState: Equatable {
        case idle, testing, succeeded, failed(String)
    }

    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let config: DatabaseConfig
        let password: String?
    }

    init(project: Project, existing: DatabaseConfig? = nil, onSave: @escaping (DatabaseConfig, String?) -> Void) {
        self.project = project
        self.existing = existing
        self.onSave = onSave
        _config = State(initialValue: existing ?? DatabaseConfig(name: "", kind: .postgres))
        _password = State(initialValue: existing.flatMap { DatabasePasswords.password(for: $0.id) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Veritabanı Bağlantısı Ekle" : "Bağlantıyı Düzenle")
                .font(.headline)

            if existing == nil, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Projede bulunanlar").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(suggestions) { suggestion in
                        Button {
                            apply(suggestion.config, password: suggestion.password)
                        } label: {
                            HStack {
                                Image(systemName: suggestion.config.kind == .sqlite ? "doc" : "network")
                                Text(suggestion.title)
                                Text(suggestion.detail).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()
            }

            HStack {
                TextField("Bağlantı adresi", text: $urlText, prompt: Text("postgres://kullanıcı:parola@localhost:5432/veritabanı"))
                    .onSubmit(applyURL)
                Button("Doldur", action: applyURL)
                    .disabled(urlText.isEmpty)
            }
            if let urlError {
                Text(urlError).font(.caption).foregroundStyle(.red)
            }

            Form {
                Picker("Tür", selection: $config.kind) {
                    ForEach(DatabaseConfig.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Ad", text: $config.name, prompt: Text(defaultName))
                if config.kind == .sqlite {
                    HStack {
                        TextField("Dosya", text: $config.path, prompt: Text("ör. db/app.sqlite"))
                        Button("Seç…", action: chooseFile)
                    }
                } else {
                    TextField("Sunucu", text: $config.host)
                    TextField("Port", value: $config.port, format: .number.grouping(.never), prompt: Text("\(config.kind.defaultPort ?? 0)"))
                    TextField("Kullanıcı", text: $config.user)
                    SecureField("Parola", text: $password, prompt: Text("Keychain'de saklanır"))
                    TextField("Veritabanı", text: $config.database, prompt: Text(config.kind == .mysql ? "isteğe bağlı" : "varsayılan: kullanıcı adı"))
                    Picker("TLS", selection: $config.tls) {
                        ForEach(DatabaseConfig.TLSMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("SSH tüneli üzerinden bağlan", isOn: usesSSH)
                    if config.ssh != nil {
                        TextField("SSH sunucusu", text: sshBinding(\.host), prompt: Text("ör. bastion.sirket.com ya da ~/.ssh/config takma adı"))
                        TextField("SSH portu", value: sshBinding(\.port), format: .number.grouping(.never), prompt: Text("22"))
                        TextField("SSH kullanıcısı", text: sshBinding(\.user), prompt: Text("isteğe bağlı"))
                        HStack {
                            TextField("Anahtar dosyası", text: sshBinding(\.identityFile), prompt: Text("isteğe bağlı, ör. ~/.ssh/id_ed25519"))
                            Button("Seç…", action: chooseKey)
                        }
                    }
                }
            }
            if config.kind != .sqlite, config.ssh != nil {
                Text("Sunucu ve port, SSH sunucusundan görüldüğü hâliyle yazılır (çoğunlukla localhost). Kimlik doğrulama terminaldeki ssh gibi anahtar ya da ssh-agent ile yapılır; parola sorulamaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                switch testState {
                case .idle: EmptyView()
                case .testing: ProgressView().controlSize(.small)
                case .succeeded: Label("Bağlantı başarılı", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
            }
            .font(.caption)
            .textSelection(.enabled)

            HStack {
                Button("Bağlantıyı Dene", action: test)
                    .disabled(!isComplete || testState == .testing)
                Spacer()
                Button("Vazgeç") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Ekle ve Aç" : "Kaydet") {
                    var saved = config
                    if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = defaultName }
                    onSave(saved, config.kind == .sqlite ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task { loadSuggestions() }
    }

    private var defaultName: String {
        switch config.kind {
        case .sqlite: return config.path.isEmpty ? "SQLite" : (config.path as NSString).lastPathComponent
        case .postgres, .mysql: return config.database.isEmpty ? config.host : config.database
        }
    }

    private var isComplete: Bool {
        if config.kind == .sqlite { return !config.path.isEmpty }
        return !config.host.isEmpty && !config.user.isEmpty && !(config.ssh?.host.isEmpty ?? false)
    }

    private var usesSSH: Binding<Bool> {
        Binding(
            get: { config.ssh != nil },
            set: { config.ssh = $0 ? (config.ssh ?? SSHSettings()) : nil }
        )
    }

    private func sshBinding<Value>(_ keyPath: WritableKeyPath<SSHSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (config.ssh ?? SSHSettings())[keyPath: keyPath] },
            set: {
                var ssh = config.ssh ?? SSHSettings()
                ssh[keyPath: keyPath] = $0
                config.ssh = ssh
            }
        )
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.ssh?.identityFile = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func applyURL() {
        guard let (parsed, parsedPassword) = DatabaseConfig.parse(url: urlText) else {
            urlError = "Adres anlaşılamadı. postgres://, mysql://, mariadb:// ya da sqlite: ile başlamalı."
            return
        }
        urlError = nil
        apply(parsed, password: parsedPassword)
    }

    private func apply(_ parsed: DatabaseConfig, password parsedPassword: String?) {
        var updated = parsed
        updated.id = config.id // editing keeps the identity (and its Keychain entry)
        updated.ssh = config.ssh // a URL says nothing about tunnels
        updated.autoCommit = config.autoCommit
        config = updated
        if let parsedPassword { password = parsedPassword }
        testState = .idle
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = project.url
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let projectPath = project.url.path + "/"
        config.path = url.path.hasPrefix(projectPath) ? String(url.path.dropFirst(projectPath.count)) : url.path
    }

    private func test() {
        testState = .testing
        let config = config
        let password = password
        let projectURL = project.url
        Task {
            do {
                let client = try await DatabaseConnector.connect(config, password: password, projectURL: projectURL)
                _ = try await client.tables()
                await client.close()
                testState = .succeeded
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadSuggestions() {
        var found = DatabaseConfig.fromEnvironmentFiles(in: project.url).map {
            Suggestion(title: $0.config.name, detail: "\($0.source) · \($0.config.summary)", config: $0.config, password: $0.password)
        }
        for path in DatabaseConfig.sqliteFiles(in: project.fileIndex.entries).prefix(10) {
            let config = DatabaseConfig(name: (path as NSString).lastPathComponent, kind: .sqlite, path: path)
            found.append(Suggestion(title: config.name, detail: path, config: config, password: nil))
        }
        let known = Set(project.databases.map { "\($0.kind)|\($0.host)|\($0.effectivePort)|\($0.database)|\($0.path)" })
        suggestions = found.filter { !known.contains("\($0.config.kind)|\($0.config.host)|\($0.config.effectivePort)|\($0.config.database)|\($0.config.path)") }
        Task {
            await project.fileIndex.refresh()
            let paths = DatabaseConfig.sqliteFiles(in: project.fileIndex.entries).prefix(10)
            for path in paths where !suggestions.contains(where: { $0.config.path == path }) && !known.contains(where: { $0.hasSuffix("|\(path)") }) {
                let config = DatabaseConfig(name: (path as NSString).lastPathComponent, kind: .sqlite, path: path)
                suggestions.append(Suggestion(title: config.name, detail: path, config: config, password: nil))
            }
        }
    }
}
