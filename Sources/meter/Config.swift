import Foundation

struct ProviderInstance: Codable, Identifiable, Equatable {
    var type: String
    var name: String
    var enabled: Bool = true
    var key: String?
    var cookie: String?
    var intervalMinutes: Int?
    /// provider-specific settings (e.g. Cloudflare account_id / gateway_id)
    var options: [String: String]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case type, name, enabled, key, cookie, options
        case intervalMinutes = "interval_minutes"
    }

    init(type: String, name: String, enabled: Bool = true, key: String? = nil,
         cookie: String? = nil, intervalMinutes: Int? = nil, options: [String: String]? = nil) {
        self.type = type
        self.name = name
        self.enabled = enabled
        self.key = key
        self.cookie = cookie
        self.intervalMinutes = intervalMinutes
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        key = try c.decodeIfPresent(String.self, forKey: .key)
        cookie = try c.decodeIfPresent(String.self, forKey: .cookie)
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes)
        options = try c.decodeIfPresent([String: String].self, forKey: .options)
    }
}

struct NotificationSettings: Codable, Equatable {
    var enabled = true
    /// Alert once per window when usage crosses this percentage.
    var windowPercent: Double = 90
    /// Alert once per day when today's estimated spend exceeds this (nil = off).
    var dailySpend: Double?

    enum CodingKeys: String, CodingKey {
        case enabled
        case windowPercent = "window_percent"
        case dailySpend = "daily_spend"
    }
}

struct Config: Codable {
    var intervalMinutes: Int = 5
    var providers: [ProviderInstance] = []
    var notifications = NotificationSettings()
    var configError: String?

    enum CodingKeys: String, CodingKey {
        case intervalMinutes = "interval_minutes"
        case providers
        case notifications
    }

    init(intervalMinutes: Int = 5, providers: [ProviderInstance] = [],
         notifications: NotificationSettings = NotificationSettings(), configError: String? = nil) {
        self.intervalMinutes = intervalMinutes
        self.providers = providers
        self.notifications = notifications
        self.configError = configError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
        providers = try c.decodeIfPresent([ProviderInstance].self, forKey: .providers) ?? []
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
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

    static let opencodeDBURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/opencode.db")

    /// opencode v2 moved credentials out of auth.json into opencode.db's
    /// `credential` table (integration_id → {"type":"key","key":…}). Read that
    /// store; callers fall back to auth.json for pre-v2 installs.
    static func opencodeCredential(_ id: String, dbPath: String = Secrets.opencodeDBURL.path) -> String? {
        let db = ReadOnlyDB(path: dbPath)
        guard let db else { return nil }
        let escaped = id.replacingOccurrences(of: "'", with: "''")
        for row in db.rows("""
            SELECT value FROM credential
            WHERE integration_id = '\(escaped)'
            ORDER BY active DESC, time_updated DESC
            """) {
            guard let text = ReadOnlyDB.text(row["value"]),
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = obj["key"] as? String else { continue }
            return key
        }
        return nil
    }

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
            if let key = opencodeCredential(id) { return key }
            // pre-v2 opencode kept credentials in auth.json
            guard let data = try? Data(contentsOf: opencodeAuthURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = json[id] as? [String: Any],
                  let k = entry["key"] as? String else {
                throw ProviderError.missingKey("no auth:\(id) entry in opencode credentials")
            }
            return k
        }
        if let k = Keychain.generic(service: "meter/\(ref)") { return k }
        throw ProviderError.missingKey("no keychain item meter/\(ref) (security add-generic-password -s meter/\(ref) -a $USER -w)")
    }

    // launchd processes don't inherit ~/.zshrc; fetch the user's real env once via interactive zsh
    private static var shellEnvCache: [String: String]?
    private static let envLock = NSLock()

    /// An `env:` key that is rejected can be a rotation, not a bad value: the
    /// shell env is cached per launch, so drop it and let the retry re-read.
    static func invalidateShellEnv() {
        envLock.lock(); defer { envLock.unlock() }
        shellEnvCache = nil
    }

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
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                guard proc.isRunning else { return }
                proc.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if proc.isRunning { kill(pid, SIGKILL) }
                }
            }
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
