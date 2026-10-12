import Foundation

/// The ssh processes Siphon has started, persisted so that whatever a crash
/// or SIGKILL leaves behind can be found and stopped at the next launch.
///
/// This is the half of child cleanup that needs no wrapper process. A shell
/// supervisor around ssh was tried and rejected: a script that spawns `ssh -D`
/// and kills on EOF is exactly what endpoint security flags, and Defender
/// terminated it. The other half — SIGTERM, SIGINT, SIGHUP — is handled in the
/// app's signal sources, which stop children before exiting.
public final class ChildRegistry {
    private static let key = "sshChildren"
    private let defaults: UserDefaults
    /// Tunnels record from their own queues; without this, two concurrent
    /// read-modify-writes lose one of the children.
    private let lock = NSLock()

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private struct Entry: Codable, Equatable { let pid: Int32; let socksPort: UInt16 }

    private var entries: [Entry] {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.key) }
    }

    public func record(pid: Int32, socksPort: UInt16) {
        lock.lock(); defer { lock.unlock() }
        var list = entries
        list.removeAll { $0.pid == pid }
        list.append(Entry(pid: pid, socksPort: socksPort))
        entries = list
    }

    public func forget(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.pid != pid }
    }

    /// Stop recorded children that are still running *and* still look like
    /// our ssh for that port — the port in the command line is what rules out
    /// an unrelated process that merely inherited a recycled PID. Returns how
    /// many were stopped.
    @discardableResult
    public func reapLeftovers() -> Int {
        lock.lock(); defer { lock.unlock() }
        var reaped = 0
        for entry in entries {
            if Self.commandLine(of: entry.pid)?.contains("-D 127.0.0.1:\(entry.socksPort)") == true {
                kill(entry.pid, SIGTERM)
                reaped += 1
            }
        }
        entries = []
        return reaped
    }

    static func commandLine(of pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
