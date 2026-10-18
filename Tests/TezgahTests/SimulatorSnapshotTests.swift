import AppKit
import Testing
@testable import Tezgah

/// Writes what Claude gets from simulator_screenshot, to look at:
/// `TEZGAH_SIM_SNAPSHOT=<file.png> swift test --filter SimulatorSnapshot` with a simulator booted.
@MainActor
@Suite struct SimulatorSnapshot {
    @Test func claudeScreenshot() async throws {
        guard let output = ProcessInfo.processInfo.environment["TEZGAH_SIM_SNAPSHOT"] else { return }
        let session = SimulatorSession()
        await session.refreshDevices()
        if let bundle = ProcessInfo.processInfo.environment["TEZGAH_SIM_LAUNCH"] { _ = try await session.launch(bundle) }
        let data = try #require(await session.screenshotForClaude(settle: true))
        try data.write(to: URL(fileURLWithPath: output))
    }
}
