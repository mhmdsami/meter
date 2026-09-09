import Foundation

enum Antigravity {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // reuse a live agy between refreshes instead of paying the ~12s cold start
        // every poll; reaped after idle. ponytail: single warm session — one account.
        if takeWarm() {
            do {
                let obj = try await quota(port: warm!.port)
                return map(instance: instance, summary: obj)
            } catch {
                reapWarm()
            }
        }
        let probe = try await probe()
        keepWarm(probe)
        let obj = try await quota(port: probe.port)
        return map(instance: instance, summary: obj)
    }

    private static let warmLock = NSLock()
    private static var warm: (port: Int, pid: pid_t, masterFD: Int32, lastUsed: Date)?
    private static let warmIdle: TimeInterval = 240

    private static func takeWarm() -> Bool {
        warmLock.lock(); defer { warmLock.unlock() }
        guard let w = warm, Date().timeIntervalSince(w.lastUsed) < warmIdle else { return false }
        warm?.lastUsed = Date()
        return true
    }

    private static func keepWarm(_ probe: (port: Int, pid: pid_t, masterFD: Int32)) {
        warmLock.lock(); warm = (probe.port, probe.pid, probe.masterFD, Date()); warmLock.unlock()
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            reapIdle()
        }
    }

    private static func reapIdle() {
        warmLock.lock()
        guard let w = warm, Date().timeIntervalSince(w.lastUsed) >= warmIdle else {
            warmLock.unlock(); return
        }
        warm = nil
        warmLock.unlock()
        kill(-w.pid, SIGTERM)
        close(w.masterFD)
    }

    private static func reapWarm() {
        warmLock.lock()
        let w = warm
        warm = nil
        warmLock.unlock()
        if let w {
            kill(-w.pid, SIGTERM)
            close(w.masterFD)
        }
    }

    // MARK: - agy lifecycle

    static func findAgy() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("agy").path
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Spawns `agy` under a PTY (it's a bubbletea TUI that refuses to run without a TTY),
    /// as a session leader with a controlling terminal — matching how an interactive
    /// terminal runs it (Foundation's Process can't setsid/TIOCSCTTY).
    static func probe() async throws -> (port: Int, pid: pid_t, masterFD: Int32) {
        guard let agy = findAgy() else {
            throw ProviderError.badResponse("agy not found — brew install --cask antigravity-cli, then run `agy` once and sign in")
        }
        let (pid, masterFD) = try forkAgy(executable: agy)

        // Fixed 12s readiness budget; agy needs a few seconds for keyring auth on cold start
        let deadline = Date().addingTimeInterval(12)
        var sawExit = false
        while Date() < deadline {
            if let port = listeningPort() { return (port, pid, masterFD) }
            if waitpid(pid, nil, WNOHANG) != 0 { sawExit = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if !sawExit { kill(-pid, SIGTERM) }
        close(masterFD)
        throw ProviderError.badResponse("agy started but no local server port appeared within 12s — is it signed in?")
    }

    /// Minimal PTY spawn: child is a session leader whose first tty open becomes its
    /// controlling terminal (BSD semantics), so agy believes it runs interactively.
    static func forkAgy(executable: String) throws -> (pid_t, Int32) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
            if master >= 0 { close(master) }
            throw ProviderError.badResponse("posix_openpt failed")
        }
        var name = [CChar](repeating: 0, count: 128)
        guard ptsname_r(master, &name, 128) == 0 else {
            close(master)
            throw ProviderError.badResponse("ptsname failed")
        }
        let slavePath = String(cString: name)
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)

        // drain master so the TUI never blocks on a full buffer
        let drainQueue = DispatchQueue(label: "agy-pty-drain")
        drainQueue.async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }
            }
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, &argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        for p in argv where p != nil { free(p) }
        guard rc == 0 else {
            close(master)
            throw ProviderError.badResponse("posix_spawn failed: \(rc)")
        }
        return (pid, master)
    }

    /// The quota server runs in agy's language_server CHILD process — matching the agy pid
    /// finds nothing. Scan all listeners by command name instead.
    static func listeningPort() -> Int? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count >= 9 else { continue }
            let command = parts[0]
            guard command.contains("agy") || command.contains("language_server") else { continue }
            if let port = Int(parts[8].split(separator: ":").last ?? "") {
                return port
            }
        }
        return nil
    }

    // MARK: - quota

    static func quota(port: Int) async throws -> [String: Any] {
        let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")!
        let body = try JSONSerialization.data(withJSONObject: [
            "ideName": "antigravity", "extensionName": "antigravity", "locale": "en", "ideVersion": "unknown",
        ])
        // cold keyring auth can briefly 500 while the server warms up
        var lastError: Error = ProviderError.badResponse("no attempts")
        for _ in 0..<8 {
            do {
                let data = try await InsecureLoopback.request(url, body: body)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ProviderError.badResponse("agy quota response not JSON")
                }
                return obj
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw lastError
    }

    static func map(instance: ProviderInstance, summary obj: [String: Any]) -> InstanceReading {
        // connect protocol may report errors in-body with HTTP 200
        if let code = obj["code"] as? String, code != "ok" {
            let msg = (obj["message"] as? String) ?? "unknown agy error"
            return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                                   error: "agy: \(msg)")
        }
        var windows: [UsageWindow] = []
        if let response = obj["response"] as? [String: Any],
           let groups = response["groups"] as? [[String: Any]] {
            for group in groups {
                let name = (group["displayName"] as? String) ?? "Quota"
                var worst: Double?
                var reset: Date?
                for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                    // agy 1.1.22: remainingFraction directly on the bucket; older docs: under .remaining
                    var frac = optNum(bucket["remainingFraction"])
                    if frac == nil, let rem = bucket["remaining"] as? [String: Any] {
                        frac = optNum(rem["remainingFraction"])
                    }
                    guard let f = frac else { continue }
                    worst = min(worst ?? 1, f)
                    if let iso = bucket["resetTime"] as? String { reset = isoDate(iso) }
                }
                if let frac = worst {
                    let label: String
                    switch name {
                    case let n where n.contains("Claude"): label = "Claude+GPT"
                    case let n where n.contains("Gemini"): label = "Gemini"
                    default: label = String(name.prefix(9))
                    }
                    windows.append(UsageWindow(id: name, label: label,
                                               usedPercent: (1 - frac) * 100, resetsAt: reset))
                }
            }
        } else {
            let snippet = String(describing: obj).prefix(150)
            return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                                   error: "agy payload: \(snippet)")
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name, windows: windows)
    }
}

enum InsecureLoopback {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        let delegate = LoopbackTrust()
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }()

    static func request(_ url: URL, body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let status = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError.http(status, String(data: data.prefix(150), encoding: .utf8) ?? "")
        }
        return data
    }

    private final class LoopbackTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard let trust = challenge.protectionSpace.serverTrust,
                  challenge.protectionSpace.host == "127.0.0.1" || challenge.protectionSpace.host == "localhost" else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
