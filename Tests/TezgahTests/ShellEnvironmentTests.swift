import Foundation
import Testing
@testable import Tezgah

@Suite struct ShellEnvironmentTests {
    @Test func resolvesLoginShellPath() async {
        let start = Date()
        let environment = await ShellEnvironment.shared.environment()
        let elapsed = Date().timeIntervalSince(start)
        // The 5 second timeout means resolution failed and fell back to the app's own environment.
        #expect(elapsed < 4.5)
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
    }
}
