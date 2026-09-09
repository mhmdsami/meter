import Foundation

enum Amp {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        // CLI first: `amp usage` carries the Free daily meter and subscription pools
        if let amp = findAmp() {
            do { return try cliReading(amp, instance) } catch { /* fall through to RPC */ }
        }
        let key = try token(for: instance)
        let body = try JSONSerialization.data(withJSONObject: ["method": "userDisplayBalanceInfo", "params": [:]])
        let resp = try await HTTP.request(
            URL(string: "https://ampcode.com/api/internal")!,
            method: "POST",
            headers: ["Authorization": "Bearer \(key)", "Content-Type": "application/json"],
            body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let text = result["displayText"] as? String else {
            throw ProviderError.badResponse("no displayText from amp RPC")
        }

        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               balanceNote: parseBalance(text))
    }

    // MARK: - CLI (`amp usage`)

    static func findAmp() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/.local/bin/amp", "/opt/homebrew/bin/amp", "/usr/local/bin/amp"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("amp").path
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    static func cliReading(_ path: String, _ instance: ProviderInstance) throws -> InstanceReading {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["usage"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        // a hung CLI would block the whole fetch fan-out (readDataToEndOfFile has
        // no timeout); kill it and fall back to the balance RPC
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if proc.isRunning { proc.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.badResponse("amp usage gave no output")
        }
        return try parseCLI(text, instance)
    }

    /// Parses `amp usage` display text; newer CLIs wrap labels in `**bold**` markers.
    /// Throws when no usage lines match, so the caller can fall back to the RPC.
    static func parseCLI(_ raw: String, _ instance: ProviderInstance) throws -> InstanceReading {
        let text = raw.replacingOccurrences(of: "**", with: "")
        var windows: [UsageWindow] = []
        var balance: String?
        for line in text.split(separator: "\n") {
            let line = String(line)
            if let cap = captures(#"Amp Free:\s*(\d+)%\s*remaining"#, line),
               let pct = Double(cap[0]) {
                windows.append(UsageWindow(id: "free", label: "Free",
                                           usedPercent: 100 - pct, note: "resets daily"))
            } else if let cap = captures(#"Amp ([\w ]+?) Subscription:\s*(\d+)% other usage and (\d+)% orb usage remaining(?:\s*-\s*resets upon renewal (.*))?"#, line),
                       let other = Double(cap[1]), let orb = Double(cap[2]) {
                let reset = cap.count > 3 ? cap[3] : nil
                windows.append(UsageWindow(id: "other", label: String(cap[0].prefix(9)),
                                           usedPercent: 100 - other, note: reset.map { "renews \($0)" }))
                windows.append(UsageWindow(id: "orb", label: "Orb",
                                           usedPercent: 100 - orb, note: reset.map { "renews \($0)" }))
            } else if let cap = captures(#"Individual credits:\s*\$([0-9][0-9,]*(?:\.[0-9]+)?) remaining"#, line) {
                let amount = cap[0].replacingOccurrences(of: ",", with: "")
                if let dollars = Double(amount) {
                    balance = String(format: "$%.2f left", dollars)
                }
            }
        }
        guard !windows.isEmpty || balance != nil else {
            throw ProviderError.badResponse("no usage lines in amp usage output")
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               windows: windows, balanceNote: balance)
    }

    private static func captures(_ pattern: String, _ line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }

    // The RPC exposes no structured balance fields, only prose; guarded by fixture tests.
    static func parseBalance(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
        // "Individual credits: $20 remaining (set up auto-reload ...) - https://..."
        if let line = lines.first(where: { $0.contains("remaining") }),
           let range = line.range(of: #"\$[0-9][0-9,]*(?:\.[0-9]+)?"#, options: .regularExpression) {
            return String(line[range]) + " left"
        }
        return lines.first(where: { !$0.isEmpty })
    }

    static var secretsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/amp/secrets.json")
    }

    static func token(for instance: ProviderInstance) throws -> String {
        if instance.key == nil,
           let data = try? Data(contentsOf: secretsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = json["apiKey@https://ampcode.com/"] as? String {
            return key
        }
        return try Secrets.apiKey(for: instance)
    }
}
