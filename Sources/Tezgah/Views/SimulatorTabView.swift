import SwiftUI

/// An iOS Simulator device, live: pick and boot a device, watch the screen, tap and swipe on it.
/// Claude drives the same device through Tezgah's simulator tools.
struct SimulatorTabView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let session: SimulatorSession
    let project: Project
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .top) {
                (colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.93))
                content
                if let activity = session.claudeActivity {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.claudeAccent)
                            .symbolEffect(.pulse)
                        Text(activity).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.claudeAccent.opacity(0.45)))
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.claudeActivity)
            if !session.hasAXe, session.device?.isBooted == true {
                axeBanner
            }
        }
        .onAppear { session.addViewer() }
        .onDisappear { session.removeViewer() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(session.devices) { device in
                    Button {
                        Task { await session.use(device) }
                    } label: {
                        Label("\(device.name) · \(device.runtime)", systemImage: device.isBooted ? "power.circle.fill" : (device.isPad ? "ipad" : "iphone"))
                    }
                }
                Divider()
                Button("Listeyi Yenile") { Task { await session.refreshDevices() } }
            } label: {
                Label(session.device.map { "\($0.name) · \($0.runtime)" } ?? "Cihaz seç", systemImage: session.device?.isPad == true ? "ipad" : "iphone")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if session.isBooting {
                ProgressView().controlSize(.small)
                Text("Açılıyor…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if session.device?.isBooted == true {
                Group {
                    iconButton("house", help: "Ana ekran") { Task { try? await session.pressButton("home") } }
                        .disabled(!session.hasAXe)
                    iconButton(session.isDark ? "sun.max" : "moon", help: session.isDark ? "Cihazı açık görünüme al" : "Cihazı koyu görünüme al") {
                        Task { try? await session.setAppearance(dark: !session.isDark) }
                    }
                    iconButton("camera", help: "Ekran görüntüsünü kopyala") {
                        Task {
                            guard let data = await session.screenshotForClaude(), let image = NSImage(data: data) else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                        }
                    }
                    iconButton("power", help: "Cihazı kapat") { Task { await session.shutdown() } }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Screen

    @ViewBuilder
    private var content: some View {
        if let frame = session.frame, let points = session.pointSize, session.device?.isBooted == true {
            GeometryReader { geometry in
                let fit = min((geometry.size.width - 48) / points.width, (geometry.size.height - 48) / points.height, 1.2)
                let size = CGSize(width: points.width * fit, height: points.height * fit)
                let corner = (session.device?.isPad == true ? 18 : 44) * fit
                Image(nsImage: frame)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .padding(7 * fit)
                    .background(RoundedRectangle(cornerRadius: corner + 7 * fit, style: .continuous).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: corner + 7 * fit, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 8)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in if dragStart == nil { dragStart = value.startLocation } }
                            .onEnded { value in
                                let start = point(value.startLocation, inside: size, fit: fit)
                                let end = point(value.location, inside: size, fit: fit)
                                dragStart = nil
                                Task {
                                    if hypot(end.x - start.x, end.y - start.y) < 8 {
                                        try? await session.tap(x: start.x, y: start.y)
                                    } else {
                                        try? await session.swipe(from: start, to: end)
                                    }
                                    await session.captureFrame()
                                }
                            }
                    )
                    .help(session.hasAXe ? "Tıkla: dokun, sürükle: kaydır" : "Dokunmak için AXe gerekli")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if session.device?.isBooted == true {
            ProgressView()
        } else {
            emptyState
        }
    }

    /// From a point in the shown image to device points.
    private func point(_ location: CGPoint, inside size: CGSize, fit: CGFloat) -> CGPoint {
        CGPoint(x: min(max(location.x, 0), size.width) / fit, y: min(max(location.y, 0), size.height) / fit)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color(hex: 0x3FB950))
            Text("iOS Simülatörü")
                .font(.system(size: 17, weight: .semibold))
            Text("Bir cihaz seç. Uygulamanı burada çalıştır; Claude da aynı cihazı açıp dokunarak test edebilir.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let error = session.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                ForEach(session.devices.prefix(3)) { device in
                    Button {
                        Task { await session.use(device) }
                    } label: {
                        Label(device.name, systemImage: device.isPad ? "ipad" : "iphone")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .disabled(session.isBooting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var axeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .foregroundStyle(.secondary)
            Text("Dokunma, kaydırma ve yazma için AXe gerekli (Homebrew ile kurulur).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("AXe'yi Kur") { store.installAXe() }
                .controlSize(.small)
            Button("Kurdum, Kontrol Et") { Task { await session.refreshDevices() } }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
