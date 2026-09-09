import Foundation

struct ProviderInstance: Codable, Identifiable, Equatable {
    var type: String
    var name: String
    var enabled: Bool = true
    var key: String?
    var cookie: String?
    var intervalMinutes: Int?

    var id: String { name }

    enum CodingKeys: String, CodingKey { case type, name, enabled, key, cookie, intervalMinutes = "interval_minutes" }

    init(type: String, name: String, enabled: Bool = true, key: String? = nil,
         cookie: String? = nil, intervalMinutes: Int? = nil) {
        self.type = type
        self.name = name
        self.enabled = enabled
        self.key = key
        self.cookie = cookie
        self.intervalMinutes = intervalMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        key = try c.decodeIfPresent(String.self, forKey: .key)
        cookie = try c.decodeIfPresent(String.self, forKey: .cookie)
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes)
    }
}

struct Config: Codable {
    var intervalMinutes: Int = 5
    var providers: [ProviderInstance] = []
    var configError: String?

    enum CodingKeys: String, CodingKey {
        case intervalMinutes = "interval_minutes"
        case providers
    }

    init(intervalMinutes: Int = 5, providers: [ProviderInstance] = [], configError: String? = nil) {
        self.intervalMinutes = intervalMinutes
        self.providers = providers
        self.configError = configError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
        providers = try c.decodeIfPresent([ProviderInstance].self, forKey: .providers) ?? []
        configError = nil
    }
}

enum ConfigStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/meter/config.json")

    static func load() -> Config {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let sample = Config(
                intervalMinutes: 5,
                providers: [
                    .init(type: "opencode", name: "OpenCode"),
                    .init(type: "openrouter", name: "OpenRouter"),
                    .init(type: "codex", name: "Codex"),
                    .init(type: "claude", name: "Claude"),
                ])
            write(sample)
            return sample
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            return Config(intervalMinutes: 5, providers: [],
                          configError: "config error: \(error.localizedDescription)")
        }
    }

    static func write(_ config: Config) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: url)
            // chmod 600 in case the config ever holds raw secrets
            chmod(url.path, 0o600)
        }
    }
}

enum Secrets {
    static let opencodeAuthURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")

    /// key semantics:
    /// - "env:NAME"    → process env, falling back to the user's interactive shell env
    /// - "auth:<id>"   → ~/.local/share/opencode/auth.json entry
    /// - otherwise     → keychain item "meter/<value>" (default "meter/<instance name>")
    static func apiKey(for instance: ProviderInstance) throws -> String {
        let ref = instance.key ?? instance.name
        if ref.hasPrefix("env:") {
            let name = String(ref.dropFirst(4))
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty { return v }
            if let v = shellEnv()[name], !v.isEmpty { return v }
            throw ProviderError.missingKey("env \(name) not set (checked launchd env + login shell)")
        }
        if ref.hasPrefix("auth:") {
            let id = String(ref.dropFirst(5))
            guard let data = try? Data(contentsOf: opencodeAuthURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = json[id] as? [String: Any],
                  let k = entry["key"] as? String else {
                throw ProviderError.missingKey("no auth:\(id) entry in opencode auth.json")
            }
            return k
        }
        if let k = Keychain.generic(service: "meter/\(ref)") { return k }
        throw ProviderError.missingKey("no keychain item meter/\(ref) (security add-generic-password -s meter/\(ref) -a $USER -w)")
    }

    // launchd processes don't inherit ~/.zshrc; fetch the user's real env once via interactive zsh
    private static var shellEnvCache: [String: String]?
    private static let envLock = NSLock()

    static func shellEnv() -> [String: String] {
        envLock.lock(); defer { envLock.unlock() }
        if let shellEnvCache { return shellEnvCache }

        var out: [String: String] = [:]
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ic", "command env"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        proc.environment = env
        if (try? proc.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let eq = line.firstIndex(of: "="),
                          line[..<eq].range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { continue }
                    out[String(line[..<eq])] = String(line[line.index(after: eq)...])
                }
            }
        }
        shellEnvCache = out
        return out
    }
}
