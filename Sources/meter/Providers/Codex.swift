import Foundation

enum Codex {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // HTTP first (no process spawn); any auth failure falls back to the CLI,
        // which owns token refresh — matching Codex CLI's own lifecycle.
        if let auth = try? CodexAuth.load() {
            do {
                return map(instance: instance, usage: try await usage(token: auth.accessToken))
            } catch {
                return try await cliRPC(instance: instance)
            }
        }
        return try await cliRPC(instance: instance)
    }

    // MARK: - auth.json

    struct Auth {
        let accessToken: String
    }

    enum CodexAuth {
        static var url: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json")
        }

        // No refresh flow: a stale token surfaces "run codex login"; the CLI rotates auth.json on its own runs.
        static func load() throws -> Auth {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String else {
                throw ProviderError.badResponse("no access_token in ~/.codex/auth.json — run `codex login`")
            }
            return Auth(accessToken: access)
        }
    }

    // MARK: - usage API

    static func usage(token: String) async throws -> [String: Any] {
        do {
            let obj = try await HTTP.getJSON(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                headers: ["Authorization": "Bearer \(token)"])
            return obj as? [String: Any] ?? [:]
        } catch ProviderError.http(401, _) {
            throw ProviderError.badResponse("token stale — run `codex login`")
        }
    }

    static func map(instance: ProviderInstance, usage obj: [String: Any]) -> InstanceReading {
        var windows: [UsageWindow] = []
        if let rateLimit = obj["rate_limit"] as? [String: Any] {
            if let p = rateLimit["primary_window"] as? [String: Any] {
                windows.append(window(id: "session", label: "Session", lane: p))
            }
            if let s = rateLimit["secondary_window"] as? [String: Any] {
                windows.append(window(id: "weekly", label: "Weekly", lane: s))
            }
        }
        // model-specific limits (e.g. Codex Spark) arrive as additional_rate_limits[]
        if let extras = obj["additional_rate_limits"] as? [[String: Any]] {
            for extra in extras {
                guard let id = extra["limit_id"] as? String else { continue }
                let name = (extra["limit_name"] as? String) ?? id
                if let p = extra["primary_window"] as? [String: Any] {
                    windows.append(window(id: id, label: String(name.prefix(12)), lane: p))
                }
            }
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name, windows: windows)
    }

    static func window(id: String, label: String, lane: [String: Any]) -> UsageWindow {
        UsageWindow(id: id, label: label,
                    usedPercent: optNum(lane["used_percent"]),
                    resetsAt: optNum(lane["reset_at"]).map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: - CLI RPC fallback (`codex app-server`; the CLI owns token refresh)

    static func cliRPC(instance: ProviderInstance) async throws -> InstanceReading {
        guard let codex = findCodex() else {
            throw ProviderError.badResponse("no access_token in ~/.codex/auth.json and no codex CLI on PATH — run `codex login`")
        }
        let proc = Process()
        let inPipe = Pipe(), outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: codex)
        proc.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw ProviderError.badResponse("codex app-server failed to launch: \(error.localizedDescription)")
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            proc.terminate()
        }
        defer {
            watchdog.cancel()
            inPipe.fileHandleForWriting.closeFile()
            proc.terminate()
        }

        let request = { (id: Int, method: String, params: [String: Any]) in
            try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
        let hello = try request(1, "initialize", ["clientInfo": ["name": "meter", "title": "meter", "version": "1.0"]])
        try inPipe.fileHandleForWriting.write(contentsOf: hello + Data("\n".utf8))
        let limits = try request(2, "account/rateLimits/read", [:])
        try inPipe.fileHandleForWriting.write(contentsOf: limits + Data("\n".utf8))

        // accumulate stdout until the id:2 response shows up; watchdog breaks the blocking read
        var buffer = ""
        while true {
            let data = outPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer += String(data: data, encoding: .utf8) ?? ""
            for line in buffer.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      obj["id"] as? Int == 2 else { continue }
                guard let result = obj["result"] as? [String: Any] else {
                    throw ProviderError.badResponse("codex app-server returned no rateLimits result")
                }
                return try mapRPC(instance: instance, result: result)
            }
            buffer = buffer.contains("\n") ? "" : buffer
        }
        throw ProviderError.badResponse("codex app-server gave no rateLimits response")
    }

    static func findCodex() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("codex").path
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    static func mapRPC(instance: ProviderInstance, result: [String: Any]) throws -> InstanceReading {
        guard let limits = result["rateLimits"] as? [String: Any] else {
            throw ProviderError.badResponse("codex app-server rateLimits missing")
        }
        var windows: [UsageWindow] = []
        for (id, label) in [("primary", "Session"), ("secondary", "Weekly")] {
            guard let lane = limits[id] as? [String: Any],
                  let used = optNum(lane["usedPercent"]) else { continue }
            windows.append(UsageWindow(id: id, label: label, usedPercent: used,
                                       resetsAt: optNum(lane["resetsAt"]).map(Date.init(timeIntervalSince1970:))))
        }
        var note: String?
        if let credits = limits["rateLimitResetCredits"] as? [String: Any],
           let count = optNum(credits["availableCount"]), count > 0 {
            note = String(format: "%@ reset credits", count == floor(count) ? String(Int(count)) : String(count))
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               windows: windows, balanceNote: note)
    }
}
