import Darwin
import Foundation

/// Looks at other processes: what a terminal is running and where its shell is.
enum ProcessInspector {
    /// The short name of a process, e.g. "npm" or "vim".
    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The working directory of a process, e.g. the folder a shell has `cd`'d into.
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// The process group in the foreground of a pseudo-terminal, given its controlling side.
    static func foregroundGroup(ofTerminal fd: Int32) -> pid_t? {
        guard fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }
}
