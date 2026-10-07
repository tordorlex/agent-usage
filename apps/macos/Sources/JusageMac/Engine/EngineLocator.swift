import Foundation

/// Resolves the Node binary and the sidecar entry script.
///
/// Two layouts are supported:
///
/// * **Bundled** (`JusageMac.app`): `Contents/Resources/JusageEngine/` holds
///   `index.js` plus a `node` binary, so the app is self-contained.
/// * **Development**: the script is read straight out of the repository
///   (`packages/engine/dist/index.js`), and Node is whatever the developer has
///   on `PATH` — including the user's login shell, because an app started from
///   Finder or Xcode does not inherit it.
struct EngineLocation {
    let nodeURL: URL
    let scriptURL: URL
    let workingDirectory: URL
    /// True when both the runtime and the script ship inside the app bundle.
    let isBundled: Bool

    static let nodeOverrideEnv = "JUSAGE_NODE_BIN"
    static let scriptOverrideEnv = "JUSAGE_ENGINE_SCRIPT"
    static let dataDirEnv = "JUSAGE_DATA_DIR"

    enum LocatorError: LocalizedError {
        case nodeNotFound
        case scriptNotFound([String])

        var errorDescription: String? {
            switch self {
            case .nodeNotFound:
                return """
                未找到 Node.js 运行时。\
                请安装 Node 20+（brew install node），或设置环境变量 \(nodeOverrideEnv) 指向 node 可执行文件。
                """
            case .scriptNotFound(let tried):
                return """
                未找到统计引擎脚本 packages/engine/dist/index.js。\
                请先构建：pnpm --filter @juejin-opensource/jusage-engine build
                已尝试：\(tried.joined(separator: "、"))
                """
            }
        }
    }

    static func resolve() throws -> EngineLocation {
        let env = ProcessInfo.processInfo.environment

        if let bundled = bundledLocation() { return bundled }

        let script = try resolveScript(env: env)
        let node = try resolveNode(env: env)
        return EngineLocation(
            nodeURL: node,
            scriptURL: script,
            workingDirectory: script.deletingLastPathComponent(),
            isBundled: false
        )
    }

    // MARK: - Bundled layout
    //
    // `packages/engine` is deployed with `pnpm deploy` into
    // `Contents/Resources/JusageEngine`, keeping its own `dist/` and
    // `node_modules/` so its relative imports keep working, plus a `node`
    // binary so the app needs nothing installed on the user's machine.

    private static func bundledLocation() -> EngineLocation? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("JusageEngine", isDirectory: true)
        let node = root.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else { return nil }

        let candidates = [
            root.appendingPathComponent("dist/index.js"),
            root.appendingPathComponent("index.js"),
        ]
        guard let script = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return nil }

        return EngineLocation(
            nodeURL: node,
            scriptURL: script,
            workingDirectory: root,
            isBundled: true
        )
    }

    // MARK: - Script discovery

    private static func resolveScript(env: [String: String]) throws -> URL {
        if let override = env[scriptOverrideEnv], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        var tried: [String] = []
        for root in searchRoots(from: env) {
            let candidate = root
                .appendingPathComponent("packages/engine/dist/index.js")
            tried.append(candidate.path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw LocatorError.scriptNotFound(tried)
    }

    /// Walk up from the executable (`.build/debug/JusageMac`) to the repo root,
    /// defined as the directory containing `packages/engine/package.json`.
    private static func searchRoots(from env: [String: String]) -> [URL] {
        var roots: [URL] = []

        if let explicit = env["JUSAGE_REPO_ROOT"], !explicit.isEmpty {
            roots.append(URL(fileURLWithPath: explicit))
        }

        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if directory.path.isEmpty {
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        directory = directory.deletingLastPathComponent()

        for _ in 0..<10 {
            roots.append(directory)
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("packages/engine/package.json").path
            ) {
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        // Also consider the current working directory (Xcode runs use DerivedData).
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return roots
    }

    // MARK: - Node discovery

    private static func resolveNode(env: [String: String]) throws -> URL {
        if let override = env[nodeOverrideEnv], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        var candidates: [URL] = []

        if let path = env["PATH"] {
            for entry in path.split(separator: ":") where !entry.isEmpty {
                candidates.append(URL(fileURLWithPath: String(entry)).appendingPathComponent("node"))
            }
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/node"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/node"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/node"))

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        // Last resort: ask the user's login shell, which knows about version
        // managers (nvm / fnm / volta / vite-plus) that Finder launches miss.
        if let shellPath = loginShellNodePath() {
            return URL(fileURLWithPath: shellPath)
        }

        throw LocatorError.nodeNotFound
    }

    private static func loginShellNodePath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
