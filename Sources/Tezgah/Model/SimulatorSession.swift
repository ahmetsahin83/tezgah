import AppKit
import Observation

/// An iOS Simulator device shown live in a tab, driven by the user and by Claude.
///
/// Everything goes through Xcode's `simctl`; touches, swipes and typing need AXe
/// (github.com/cameroncooke/AXe), which `simctl` has no equivalent for.
@MainActor
@Observable
final class SimulatorSession: Identifiable {
    struct Device: Identifiable, Equatable, Hashable {
        let udid: String
        let name: String
        let runtime: String
        var isBooted: Bool
        var id: String { udid }
        var isPad: Bool { name.localizedCaseInsensitiveContains("iPad") }
    }

    let id = UUID()
    private(set) var devices: [Device] = []
    private(set) var device: Device?
    /// The latest picture of the screen.
    private(set) var frame: NSImage?
    /// Screen size in points, the unit taps and swipes use.
    private(set) var pointSize: CGSize?
    private(set) var isBooting = false
    private(set) var lastError: String?
    private(set) var hasAXe = false
    /// The device's own light / dark setting.
    private(set) var isDark = false
    /// What Claude is doing on the device right now, shown over the screen.
    private(set) var claudeActivity: String?

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var activityClear: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0

    init() {
        Task { await refreshDevices() }
    }

    // MARK: Devices

    func refreshDevices() async {
        hasAXe = await Self.axePath() != nil
        guard let output = try? await Self.simctl(["list", "devices", "available", "-j"]),
              let json = (try? JSONSerialization.jsonObject(with: output.stdout)) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else {
            lastError = "Simülatörler okunamadı. Xcode kurulu mu?"
            return
        }
        var found: [Device] = []
        for (runtime, list) in byRuntime where runtime.contains("iOS") {
            let version = runtime.split(separator: ".").last.map { $0.replacingOccurrences(of: "iOS-", with: "iOS ").replacingOccurrences(of: "-", with: ".") } ?? runtime
            for item in list {
                guard let udid = item["udid"] as? String, let name = item["name"] as? String else { continue }
                found.append(Device(udid: udid, name: name, runtime: version, isBooted: item["state"] as? String == "Booted"))
            }
        }
        // Booted first, then phones before tablets, newest runtime first.
        devices = found.sorted {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            if $0.isPad != $1.isPad { return !$0.isPad }
            if $0.runtime != $1.runtime { return $0.runtime.compare($1.runtime, options: .numeric) == .orderedDescending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if let current = device, let updated = devices.first(where: { $0.udid == current.udid }) {
            device = updated
        } else if device == nil {
            device = devices.first(where: \.isBooted)
        }
        if device?.isBooted == true {
            startLive()
            await readAppearance()
        }
    }

    func find(_ nameOrUDID: String) -> Device? {
        devices.first { $0.udid == nameOrUDID }
            ?? devices.first { $0.name.caseInsensitiveCompare(nameOrUDID) == .orderedSame }
            ?? devices.first { $0.name.localizedCaseInsensitiveContains(nameOrUDID) }
    }

    /// Picks a device and boots it if needed. Returns an error message on failure.
    @discardableResult
    func use(_ device: Device) async -> String? {
        self.device = device
        frame = nil
        pointSize = nil
        lastError = nil
        if !device.isBooted {
            isBooting = true
            defer { isBooting = false }
            do {
                _ = try await Self.simctl(["boot", device.udid], allowFailure: true)
                _ = try await Self.simctl(["bootstatus", device.udid, "-b"])
            } catch {
                lastError = "Açılamadı: \(error.localizedDescription)"
                return lastError
            }
            await refreshDevices()
        }
        // No Simulator app window needed: the device runs headless and Tezgah shows its screen.
        startLive()
        return nil
    }

    func shutdown() async {
        guard let device else { return }
        stopLive()
        _ = try? await Self.simctl(["shutdown", device.udid], allowFailure: true)
        frame = nil
        await refreshDevices()
    }

    // MARK: Live screen

    /// The tab is on screen: keep the picture fresh.
    func addViewer() {
        viewers += 1
        startLive()
    }

    func removeViewer() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { stopLive() }
    }

    private func startLive() {
        guard liveTask == nil, device?.isBooted == true, viewers > 0 else { return }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.captureFrame()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    @discardableResult
    func captureFrame() async -> Data? {
        guard let device, device.isBooted else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-sim-\(device.udid).png")
        guard (try? await Self.simctl(["io", device.udid, "screenshot", "--type=png", file.path])) != nil,
              let data = try? Data(contentsOf: file), let image = NSImage(data: data),
              let rep = image.representations.first else { return nil }
        let pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let scale: CGFloat = device.isPad ? 2 : (pixels.width >= 1000 ? 3 : 2)
        pointSize = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        frame = image
        return data
    }

    /// Waits until the screen stops changing (an app launching, an animation, a theme switch),
    /// so a screenshot shows where things ended up rather than a splash or a transition.
    func waitUntilSettled(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        var previous = await captureFrame()
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(350))
            let current = await captureFrame()
            if let current, current == previous { return }
            previous = current
        }
    }

    /// The screen at one pixel per point, so coordinates in it are what taps take.
    func screenshotForClaude(settle: Bool = false) async -> Data? {
        if settle { await waitUntilSettled() }
        guard let data = await captureFrame(), let image = NSImage(data: data), let size = pointSize else { return nil }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return data }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? data
    }

    func showActivity(_ text: String) {
        claudeActivity = text
        activityClear?.cancel()
        activityClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.claudeActivity = nil
        }
    }

    // MARK: Apps

    func install(_ appPath: String) async throws {
        guard let device else { throw SimulatorError.noDevice }
        _ = try await Self.simctl(["install", device.udid, appPath])
    }

    func launch(_ bundleID: String) async throws -> String {
        guard let device else { throw SimulatorError.noDevice }
        _ = try? await Self.simctl(["terminate", device.udid, bundleID], allowFailure: true)
        let output = try await Self.simctl(["launch", device.udid, bundleID])
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openURL(_ url: String) async throws {
        guard let device else { throw SimulatorError.noDevice }
        _ = try await Self.simctl(["openurl", device.udid, url])
    }

    func setAppearance(dark: Bool) async throws {
        guard let device else { throw SimulatorError.noDevice }
        _ = try await Self.simctl(["ui", device.udid, "appearance", dark ? "dark" : "light"])
        isDark = dark
    }

    private func readAppearance() async {
        guard let device, device.isBooted,
              let output = try? await Self.simctl(["ui", device.udid, "appearance"], allowFailure: true) else { return }
        isDark = output.text.trimmingCharacters(in: .whitespacesAndNewlines) == "dark"
    }

    /// Recent log lines, optionally only from one process.
    func logs(process: String?, seconds: Int) async throws -> String {
        guard let device else { throw SimulatorError.noDevice }
        var args = ["spawn", device.udid, "log", "show", "--last", "\(max(1, min(seconds, 600)))s", "--style", "compact"]
        if let process, !process.isEmpty {
            args += ["--predicate", "process == \"\(process.replacingOccurrences(of: "\"", with: ""))\""]
        }
        let output = try await Self.simctl(args)
        let lines = output.text.split(separator: "\n").suffix(150)
        return lines.isEmpty ? "No log lines." : lines.joined(separator: "\n")
    }

    // MARK: Touch (AXe)

    func tap(x: Double, y: Double) async throws {
        try await axe(["tap", "-x", Self.number(x), "-y", Self.number(y)])
    }

    func swipe(from start: CGPoint, to end: CGPoint) async throws {
        try await axe(["swipe", "--start-x", Self.number(start.x), "--start-y", Self.number(start.y),
                       "--end-x", Self.number(end.x), "--end-y", Self.number(end.y)])
    }

    func type(_ text: String) async throws {
        try await axe(["type", text])
    }

    func pressButton(_ button: String) async throws {
        try await axe(["button", button])
    }

    /// The accessibility tree: labels, roles and frames of what is on screen.
    func describeUI() async throws -> String {
        try await axe(["describe-ui"])
    }

    @discardableResult
    private func axe(_ args: [String]) async throws -> String {
        guard let device else { throw SimulatorError.noDevice }
        guard let path = await Self.axePath() else { throw SimulatorError.noAXe }
        let output = try await Self.run(path, args + ["--udid", device.udid])
        return output.text
    }

    private static func number(_ value: Double) -> String { String(Int(value.rounded())) }
    private static func number(_ value: CGFloat) -> String { String(Int(value.rounded())) }

    // MARK: Processes

    struct Output {
        let stdout: Data
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    enum SimulatorError: LocalizedError {
        case noDevice, noAXe, failed(String)
        var errorDescription: String? {
            switch self {
            case .noDevice: "No simulator selected. Call simulator_boot first."
            case .noAXe: "Tapping, swiping and typing need AXe. Ask the user to click “AXe'yi Kur” in Tezgah's device tab (brew install cameroncooke/axe/axe)."
            case .failed(let message): message
            }
        }
    }

    static func simctl(_ args: [String], allowFailure: Bool = false) async throws -> Output {
        // Calling simctl directly saves xcrun's lookup, about two thirds of a screenshot's time.
        if let path = await SimctlPath.shared.path() {
            return try await run(path, args, allowFailure: allowFailure)
        }
        return try await run("/usr/bin/xcrun", ["simctl"] + args, allowFailure: allowFailure)
    }

    static func axePath() async -> String? {
        let candidates = ["/opt/homebrew/bin/axe", "/usr/local/bin/axe"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let path = await ShellEnvironment.shared.environment()["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/axe" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ executable: String, _ args: [String], allowFailure: Bool = false) async throws -> Output {
        let environment = await ShellEnvironment.shared.environment()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.environment = environment
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0, !allowFailure {
                    let message = String(decoding: err.isEmpty ? out : err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: SimulatorError.failed(message.isEmpty ? "exit \(process.terminationStatus)" : message))
                } else {
                    continuation.resume(returning: Output(stdout: out))
                }
            }
        }
    }
}

private actor SimctlPath {
    static let shared = SimctlPath()
    private var resolved: String??

    func path() async -> String? {
        if let resolved { return resolved }
        let found = try? await SimulatorSession.run("/usr/bin/xcrun", ["-f", "simctl"])
        let path = found?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        resolved = .some(usable)
        return usable
    }
}
