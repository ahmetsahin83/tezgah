import SwiftUI

/// Edits a project's orchestra team: the developer, any number of reviewers, the judge.
struct OrchestraTeamView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project
    let close: () -> Void
    @State private var team: OrchestraTeam
    @State private var codexModels: [AgentModels.Model] = []

    init(project: Project, close: @escaping () -> Void) {
        self.project = project
        self.close = close
        _team = State(initialValue: project.orchestraTeam)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Orkestra Ekibi")
                    .font(.system(size: 15, weight: .semibold))
                Text("“Orkestrayla Başlat” denen kartı önce planlayıcı planlar, geliştirici planı kendi dalında uygular, gözden geçirenler plana göre bakar, karar verici son kararı verir. Onaylanan iş kendiliğinden birleştirilir.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 6)

            Form {
                Section {
                    Toggle("Önce planla", isOn: $team.plans)
                    memberRow($team.planner, showsFocus: false)
                        .disabled(!team.plans)
                } header: {
                    Text("Planlayıcı")
                } footer: {
                    Text(team.plans
                         ? "Kartı okuyup kodu tarar (hiçbir dosyayı değiştirmez) ve bir plan çıkarır: yaklaşım, “bitti” ölçütleri, işe katkı fikirleri. Plan geliştiriciye gider, gözden geçirenler işi bu ölçütlere göre kontrol eder. Büyük fikirler bu karta katılmaz; koşu sayfasında öneri olarak bekler."
                         : "Kapalıyken kart doğrudan geliştiriciye gider.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Section("Geliştirici") {
                    memberRow($team.developer, showsFocus: false)
                }
                Section {
                    ForEach($team.reviewers) { $member in
                        memberRow($member, showsFocus: true) {
                            team.reviewers.removeAll { $0.id == member.id }
                        }
                    }
                    if team.reviewers.isEmpty {
                        Text("Gözden geçiren yok: geliştirici commit'leyince iş doğrudan birleştirilir.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        team.reviewers.append(OrchestraTeam.Member(provider: team.reviewers.last?.provider ?? .codex))
                    } label: {
                        Label("Gözden Geçiren Ekle", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Gözden geçirenler")
                }
                Section {
                    memberRow($team.judge, showsFocus: false)
                        .disabled(team.reviewers.count < 2)
                } header: {
                    Text("Karar verici")
                } footer: {
                    Text(team.reviewers.count < 2
                         ? "Birden çok gözden geçiren olduğunda hepsinin değerlendirmesini tartıp son kararı verir. Tek gözden geçirenin kararı doğrudan geçerlidir."
                         : "Gözden geçirenlerin değerlendirmelerini tartıp son kararı verir.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Stepper(value: $team.maxRounds, in: OrchestraTeam.roundLimits) {
                        Text(team.maxRounds == 0 ? "Tur sınırı yok" : "En fazla \(team.maxRounds) tur")
                    }
                } footer: {
                    Text("Değişiklik istendikçe notlar geliştiriciye gider. Sınır dolarsa orkestra durur ve sana haber verir; “Devam Et” o kartı sınırsız sürdürür. 0: sınır yok, gözden geçirenler onaylayana kadar sürer (adımların süre sınırları yine geçerli).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Section {
                    limitStepper("Planlama", $team.planMinutes)
                    limitStepper("Geliştirme", $team.developMinutes)
                    limitStepper("Gözden geçirme ve karar", $team.reviewMinutes)
                } header: {
                    Text("Süre sınırları")
                } footer: {
                    Text("Bir adım bu süreyi geçerse kart takılmış sayılır: ajanın turu kesilir, sana haber verilir, sıra sonraki karta geçer. 0 sınır yok demek.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Birleşince push'la", isOn: $team.pushesAfterMerge)
                } footer: {
                    Text("Onaylanan her iş birleştirildikten sonra projede açık olan dal uzak depoya gönderilir; zorla push yapılmaz. Push edilemezse haber verilir, birleştirme yerelde kalır ve sıra sürer. Dala gelen her push canlıya çıkıyorsa (CI/CD) bunu açma.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Vazgeç", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Kaydet") {
                    store.setOrchestraTeam(team, for: project)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 780)
        .task { codexModels = await AgentModels.codexModels() }
    }

    private func memberRow(
        _ member: Binding<OrchestraTeam.Member>, showsFocus: Bool, remove: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Picker("Ajan", selection: Binding(
                get: { member.wrappedValue.provider },
                set: { provider in
                    guard provider != member.wrappedValue.provider else { return }
                    member.wrappedValue.provider = provider
                    member.wrappedValue.model = nil // models and thinking levels differ between agents
                    member.wrappedValue.effort = nil
                }
            )) {
                ForEach(AgentProvider.allCases, id: \.self) { provider in
                    Label(provider.displayName, systemImage: provider.symbol).tag(provider)
                }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Model", selection: Binding(
                get: { member.wrappedValue.model },
                set: { model in
                    member.wrappedValue.model = model
                    // A level the new model doesn't take goes back to its default.
                    if let effort = member.wrappedValue.effort, !efforts(for: member.wrappedValue).contains(effort) {
                        member.wrappedValue.effort = nil
                    }
                }
            )) {
                Text("Varsayılan model").tag(String?.none)
                ForEach(models(for: member.wrappedValue), id: \.id) { model in
                    Text(model.name).tag(String?.some(model.id))
                }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Düşünme", selection: member.effort) {
                Text("Varsayılan düşünme").tag(String?.none)
                ForEach(efforts(for: member.wrappedValue), id: \.self) { level in
                    Text(AgentModels.effortTitle(level)).tag(String?.some(level))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Düşünme seviyesi: yükseldikçe daha dikkatli ama daha yavaş çalışır ve limitten daha çok harcar")

            if showsFocus {
                TextField("Odak", text: member.focus, prompt: Text("Odak (ör. güvenlik, testler)"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer()
            }

            if let remove {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Gözden geçireni çıkar")
            }
        }
    }

    private func limitStepper(_ step: String, _ minutes: Binding<Int>) -> some View {
        Stepper(value: minutes, in: OrchestraTeam.minuteLimits, step: 15) {
            Text(minutes.wrappedValue == 0 ? "\(step): sınır yok" : "\(step): en fazla \(minutes.wrappedValue) dakika")
        }
    }

    /// The thinking levels the member's model takes.
    private func efforts(for member: OrchestraTeam.Member) -> [String] {
        AgentModels.efforts(for: member, codexModels: codexModels)
    }

    /// The agent's models, plus one picked earlier that is no longer listed.
    private func models(for member: OrchestraTeam.Member) -> [AgentModels.Model] {
        var models = member.provider == .codex ? codexModels : AgentModels.claude
        if let current = member.model, !models.contains(where: { $0.id == current }) {
            models.append(AgentModels.Model(id: current, name: current))
        }
        return models
    }
}
