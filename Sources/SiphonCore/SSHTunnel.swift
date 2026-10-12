import Foundation
import Network

/// One `ssh -N -D` process, kept alive.
///
/// Readiness is decided by connecting to the local SOCKS port — ssh binds it
/// only once authentication has succeeded, so an open port means a working
/// tunnel, and nothing about ssh's output needs parsing. Policy mirrors
/// tunnelmux: probe for up to `connectTimeout` after launch, health-check every
/// 45 s, retry 8 s after a failure, and give up after three consecutive
/// failures until asked again.
public final class SSHTunnel {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        /// Will retry; `reason` is ssh's own words where it gave any.
        case reconnecting(reason: String, attempt: Int)
        /// Stopped trying. `retry()` starts over.
        case gaveUp(reason: String)
    }

    /// Tunnelmux's values. Instance properties so tests can shorten them.
    public var connectTimeout: TimeInterval = 15
    public var healthInterval: TimeInterval = 45
    public var reconnectDelay: TimeInterval = 8
    public var maxRetries = 3

    public let target: String
    public let socksPort: UInt16
    public private(set) var state: State = .idle { didSet { if state != oldValue { notify() } } }
    public private(set) var connectedSince: Date?
    /// Fired on the main queue.
    public var onChange: (() -> Void)?

    private let sshPath: String
    private let queue = DispatchQueue(label: "siphon.ssh")
    private var process: Process?
    /// Held open for the supervisor's stdin; closing it — which the kernel
    /// does for us if this process dies any way at all — makes ssh exit.
    private var leash: Pipe?
    private var stderr = Data()
    private var retries = 0
    private var wanted = false
    private var pending: DispatchWorkItem?

    public init(target: String, socksPort: UInt16, sshPath: String = "/usr/bin/ssh") {
        self.target = target
        self.socksPort = socksPort
        self.sshPath = sshPath
    }

    deinit { terminate() }

    /// ssh's command line. Host keys are checked against the user's own
    /// known_hosts — unlike tunnelmux, which disabled verification. BatchMode
    /// means an unknown host or a needed password fails fast and visibly
    /// instead of hanging a menu bar app on a prompt nobody can see.
    public var arguments: [String] {
        ["-N", "-D", "127.0.0.1:\(socksPort)",
         "-o", "BatchMode=yes",
         "-o", "ExitOnForwardFailure=yes",
         "-o", "ConnectTimeout=\(Int(connectTimeout))",
         "-o", "ServerAliveInterval=10",
         "-o", "ServerAliveCountMax=3",
         target]
    }

    /// ssh runs under this shell script rather than directly. A menu bar app
    /// gets no applicationWillTerminate on SIGTERM or a crash, so a plain child
    /// would be orphaned with its tunnel still up. The script keeps ssh alive
    /// only as long as its stdin stays open: the app holds the write end and
    /// never writes; when the app dies the pipe closes, `read` sees EOF and ssh
    /// is killed. ssh's own exit status is passed through so a tunnel that
    /// dies on its own is still reported as such.
    ///
    /// The leash is kept on descriptor 3: POSIX gives a backgrounded `( … ) &`
    /// stdin from /dev/null, so a watcher reading fd 0 would see EOF at once
    /// and kill ssh on the spot. ssh itself gets /dev/null — it must not read
    /// the leash either.
    public static let supervisorScript = [
        "exec 3<&0",
        "\"$@\" 0</dev/null & pid=$!",
        "( while IFS= read -r _ 0<&3; do :; done; kill \"$pid\" 2>/dev/null ) & watcher=$!",
        "trap 'kill \"$pid\" \"$watcher\" 2>/dev/null' TERM INT HUP",
        "wait \"$pid\"; status=$?",
        "kill \"$watcher\" 2>/dev/null",
        "exit $status",
    ].joined(separator: "\n")

    public func start() { queue.async { [self] in wanted = true; retries = 0; launch() } }
    public func stop() { queue.async { [self] in wanted = false; pending?.cancel(); terminate(); state = .idle } }
    public func retry() { start() }
    /// The network moved: a live ssh session is probably dead or soon will be.
    public func restart() { queue.async { [self] in guard wanted else { return }; retries = 0; terminate(); launch() } }

    // MARK: - Lifecycle (all on `queue`)

    private func launch() {
        pending?.cancel()
        terminate()
        state = .connecting
        stderr = Data()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.supervisorScript, "siphon-ssh", sshPath] + arguments
        let leash = Pipe()
        p.standardInput = leash
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.queue.async { self?.stderr.append(d); if (self?.stderr.count ?? 0) > 4096 { self?.stderr = self!.stderr.suffix(4096) } }
        }
        p.terminationHandler = { [weak self] proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            self?.queue.async { self?.exited(proc) }
        }
        // Identity is set before run(): a child that exits at once fires its
        // termination handler before run() returns, and the handler must still
        // recognise it as the current process.
        process = p
        self.leash = leash
        do { try p.run() } catch {
            process = nil; self.leash = nil
            failed("could not run ssh: \(error.localizedDescription)"); return
        }
        probeUntilReady(deadline: Date().addingTimeInterval(connectTimeout))
    }

    private func probeUntilReady(deadline: Date) {
        guard wanted, process != nil, state == .connecting else { return }
        Self.portOpen(socksPort, queue: queue) { [weak self] open in
            guard let self, wanted, state == .connecting else { return }
            if open {
                retries = 0; connectedSince = Date(); state = .connected
                scheduleHealthCheck()
            } else if Date() >= deadline {
                failed("SOCKS port did not open within \(Int(connectTimeout)) s")
            } else {
                schedule(after: 1) { [weak self] in self?.probeUntilReady(deadline: deadline) }
            }
        }
    }

    private func scheduleHealthCheck() {
        schedule(after: healthInterval) { [weak self] in
            guard let self, wanted, state == .connected else { return }
            Self.portOpen(socksPort, queue: queue) { [weak self] open in
                guard let self, wanted, state == .connected else { return }
                if open { scheduleHealthCheck() } else { failed("SOCKS port stopped answering") }
            }
        }
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }   // an old instance we already replaced
        process = nil
        guard wanted else { return }
        // ssh writes CRLF when stderr was a tty on its side; keep only the
        // last meaningful line, stripped.
        let reason = String(decoding: stderr, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        failed(reason?.isEmpty == false ? reason! : "ssh exited (\(proc.terminationStatus))")
    }

    private func failed(_ reason: String) {
        terminate()
        connectedSince = nil
        retries += 1
        guard retries <= maxRetries else { state = .gaveUp(reason: reason); return }
        state = .reconnecting(reason: reason, attempt: retries)
        schedule(after: reconnectDelay) { [weak self] in
            guard let self, wanted else { return }
            launch()
        }
    }

    private func terminate() {
        pending?.cancel()
        guard let p = process else { return }
        process = nil
        // Closing the leash is enough on its own; the signal just makes it quick.
        try? leash?.fileHandleForWriting.close()
        leash = nil
        if p.isRunning { p.terminate() }
    }

    private func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: body)
        pending = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func notify() { DispatchQueue.main.async { [onChange] in onChange?() } }

    /// TCP connect to the local port, 3 s budget.
    static func portOpen(_ port: UInt16, queue: DispatchQueue, completion: @escaping (Bool) -> Void) {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var done = false
        func finish(_ ok: Bool) { guard !done else { return }; done = true; c.cancel(); completion(ok) }
        queue.asyncAfter(deadline: .now() + 3) { finish(false) }
        c.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        c.start(queue: queue)
    }
}
