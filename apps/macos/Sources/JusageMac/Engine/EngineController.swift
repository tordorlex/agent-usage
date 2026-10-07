import Foundation
import Observation

/// Owns the Node statistics sidecar: locates it, spawns it, waits for the
/// stdout handshake, watches it, and shuts it down with the app.
///
/// The handshake line is the frozen contract with `packages/engine`:
/// `{"type":"engine-ready","host":…,"port":…,"pid":…,"dataDir":…,"version":…}`
@MainActor
@Observable
final class EngineController {
    enum Phase: Equatable {
        case idle
        case starting
        case running(port: Int)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .idle
    /// Resolved endpoint for `LocalAPIClient`, only valid in `.running`.
    private(set) var host: String = "127.0.0.1"
    private(set) var port: Int = 0
    private(set) var engineVersion: String = ""
    private(set) var dataDir: URL
    /// Rolling tail of child stderr, surfaced in the UI when startup fails.
    private(set) var diagnostics: [String] = []

    /// When true the engine asks for `--take-owner`, stopping whichever runtime
    /// (CLI or the old Electron app) currently owns `tud.pid` so it alone
    /// collects. Left off by default: with another runtime alive the engine
    /// joins as an observer and simply reads the shared `~/.ai-usage` queue,
    /// which is the non-destructive default while both apps still exist.
    var takesOwnership = false

    /// Called once the sidecar is listening. The app wires its API client here.
    var onReady: ((_ host: String, _ port: Int) -> Void)?
    /// Called when the sidecar stops or fails, so the UI can drop stale data.
    var onUnavailable: ((_ reason: String) -> Void)?

    private var process: Process?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stdinPipe: Pipe?
    private var restartAttempts = 0
    private var isStopping = false
    private let maxDiagnosticLines = 200
    private let maxRestartAttempts = 3

    static let readyLinePrefix = "{\"type\":\"engine-ready\""

    init(dataDir: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        if let override = dataDir {
            self.dataDir = override
        } else if let raw = env[EngineLocation.dataDirEnv], !raw.isEmpty {
            self.dataDir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            self.dataDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ai-usage", isDirectory: true)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        isStopping = false
        phase = .starting
        diagnostics = []

        let location: EngineLocation
        do {
            location = try EngineLocation.resolve()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        do {
            try spawn(location: location)
        } catch {
            phase = .failed("启动统计引擎失败：\(error.localizedDescription)")
        }
    }

    /// User-initiated restart: resets the crash-loop counter.
    func restart() {
        restartAttempts = 0
        stop()
        start()
    }

    func stop() {
        isStopping = true
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        // Closing stdin is the sidecar's cue that its parent is gone.
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        phase = .idle
    }

    // MARK: - Spawn

    private func spawn(location: EngineLocation) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = location.nodeURL
        process.currentDirectoryURL = location.workingDirectory
        var arguments = [
            location.scriptURL.path,
            "--data-dir", dataDir.path,
            "--host", "127.0.0.1",
            "--port", "0",
        ]
        if takesOwnership { arguments.append("--take-owner") }
        process.arguments = arguments
        process.environment = Self.childEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status: status)
            }
        }

        try process.run()
        self.process = process
        self.stdinPipe = stdin

        // Keep stdin open for the lifetime of the child; closing it later is
        // the shutdown signal.
        _ = stdin.fileHandleForReading

        readHandshake(from: stdout.fileHandleForReading)
        readDiagnostics(from: stderr.fileHandleForReading)
    }

    private static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // A Finder/Xcode launch has a minimal PATH; the engine shells out to
        // `git` and `sqlite3`, which live in the system directories.
        let fallback = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = existing + ":" + fallback
        } else {
            env["PATH"] = fallback
        }
        return env
    }

    // MARK: - Handshake + diagnostics

    private func readHandshake(from handle: FileHandle) {
        stdoutTask = Task { @MainActor [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let self else { return }
                    self.consume(stdoutLine: line)
                }
            } catch {
                // Pipe closed: termination handling reports the reason.
            }
        }
    }

    private func consume(stdoutLine line: String) {
        guard line.hasPrefix("{") else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "engine-ready":
            host = object["host"] as? String ?? "127.0.0.1"
            port = (object["port"] as? NSNumber)?.intValue ?? 0
            engineVersion = object["version"] as? String ?? ""
            if let reported = object["dataDir"] as? String, !reported.isEmpty {
                dataDir = URL(fileURLWithPath: reported)
            }
            guard port > 0 else {
                let message = "统计引擎未返回有效端口"
                phase = .failed(message)
                onUnavailable?(message)
                return
            }
            restartAttempts = 0
            phase = .running(port: port)
            onReady?(host, port)
        case "engine-error":
            let message = object["message"] as? String ?? "统计引擎启动失败"
            phase = .failed(message)
            onUnavailable?(message)
        default:
            break
        }
    }

    private func readDiagnostics(from handle: FileHandle) {
        stderrTask = Task { @MainActor [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let self else { return }
                    self.appendDiagnostic(line)
                }
            } catch {
                // Pipe closed.
            }
        }
    }

    private func appendDiagnostic(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        diagnostics.append(trimmed)
        if diagnostics.count > maxDiagnosticLines {
            diagnostics.removeFirst(diagnostics.count - maxDiagnosticLines)
        }
    }

    // MARK: - Termination

    private func handleTermination(status: Int32) {
        process = nil
        stdinPipe = nil

        if isStopping {
            phase = .idle
            onUnavailable?("统计引擎已停止")
            return
        }

        if case .failed = phase { return }

        // An unexpected exit before the handshake usually means a build or
        // configuration problem; report stderr rather than looping.
        if case .starting = phase {
            let detail = diagnostics.suffix(6).joined(separator: "\n")
            let message = detail.isEmpty
                ? "统计引擎启动后立即退出（exit \(status)）"
                : "统计引擎启动失败（exit \(status)）：\n\(detail)"
            phase = .failed(message)
            onUnavailable?(message)
            return
        }

        guard restartAttempts < maxRestartAttempts else {
            let message = "统计引擎反复退出，已停止重试。请查看运行日志。"
            phase = .failed(message)
            onUnavailable?(message)
            return
        }
        restartAttempts += 1
        phase = .starting
        onUnavailable?("统计引擎正在重启")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.isStopping else { return }
            self.start()
        }
    }

    // MARK: - Introspection

    var diagnosticsText: String {
        diagnostics.suffix(40).joined(separator: "\n")
    }
}
