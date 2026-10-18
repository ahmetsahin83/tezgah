import Darwin
import Foundation

/// A local port forwarded to a database server through `ssh -L`. Uses the system ssh, so keys,
/// ssh-agent and ~/.ssh/config work as they do in a terminal; there is no password prompt.
final class SSHTunnel: @unchecked Sendable {
    let localPort: Int
    private let process: Process

    private init(localPort: Int, process: Process) {
        self.localPort = localPort
        self.process = process
    }

    deinit {
        close()
    }

    static func open(_ settings: SSHSettings, to host: String, port: Int) async throws -> SSHTunnel {
        guard !settings.host.isEmpty else { throw DatabaseError(message: "SSH sunucusu boş.") }
        let localPort = try freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(settings, localPort: localPort, host: host, port: port)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DatabaseError(message: "ssh başlatılamadı: \(error.localizedDescription)")
        }
        let tunnel = SSHTunnel(localPort: localPort, process: process)

        // ssh listens on the local port only after it has logged in.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .filter { !$0.hasPrefix("Warning: Permanently added") }
                    .joined(separator: "\n")
                throw DatabaseError(message: "SSH tüneli açılamadı" + (output.isEmpty ? "." : ":\n\(output)"))
            }
            if canConnect(to: localPort) { return tunnel }
            try await Task.sleep(for: .milliseconds(100))
        }
        tunnel.close()
        throw DatabaseError(message: "SSH tüneli 20 saniyede açılamadı (\(settings.summary)).")
    }

    static func arguments(_ settings: SSHSettings, localPort: Int, host: String, port: Int) -> [String] {
        var arguments = [
            "-N", "-L", "127.0.0.1:\(localPort):\(host):\(port)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "BatchMode=yes", // never wait for a password prompt nobody can see
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
        ]
        if let port = settings.port { arguments += ["-p", String(port)] }
        if !settings.identityFile.isEmpty {
            arguments += ["-i", (settings.identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        arguments.append(settings.user.isEmpty ? settings.host : "\(settings.user)@\(settings.host)")
        return arguments
    }

    func close() {
        if process.isRunning { process.terminate() }
    }

    /// A port nothing listens on right now, picked by the system.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError(message: "Yerel port bulunamadı.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { throw DatabaseError(message: "Yerel port bulunamadı.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func canConnect(to port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
