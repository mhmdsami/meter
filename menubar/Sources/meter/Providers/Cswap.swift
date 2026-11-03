import Foundation

/// Usage for accounts managed by `claude-swap` (cswap). cswap already polls
/// Anthropic for every account it holds, so meter reads that report instead of
/// touching credentials: no keychain item, no token rotation to follow.
enum Cswap {
    struct Lane: Decodable {
        let pct: Double?
        let resetsAt: String?
    }

    struct Usage: Decodable {
        let fiveHour: Lane?
        let sevenDay: Lane?
    }

    struct Account: Decodable {
        let number: Int
        let email: String?
        let active: Bool
        let usage: Usage?
        let usageStatus: String?
    }

    struct Listing: Decodable {
        let accounts: [Account]
    }

    static let cacheTTL: TimeInterval = 30
    private static var cache: (at: Date, listing: Listing)?
    private static let lock = NSLock()

    private static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func binary(_ instance: ProviderInstance?) -> String? {
        if let configured = instance?.options?["cswap_bin"], !configured.isEmpty {
            return configured
        }
        for path in ["\(home)/.local/bin/cswap", "/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func listing(_ instance: ProviderInstance? = nil) throws -> Listing {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < cacheTTL {
            return cache.listing
        }
        guard let binary = binary(instance) else {
            throw ProviderError.missingKey("cswap not found — install claude-swap or set options.cswap_bin")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["list", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw ProviderError.badResponse("cswap failed to run: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProviderError.badResponse("cswap list exited \(process.terminationStatus)")
        }
        do {
            let listing = try JSONDecoder().decode(Listing.self, from: data)
            cache = (Date(), listing)
            return listing
        } catch {
            throw ProviderError.badResponse("cswap list returned unexpected JSON")
        }
    }

    /// `account` matches the email or the slot number shown by `cswap list`.
    static func reading(_ instance: ProviderInstance, account selector: String) throws -> InstanceReading {
        let listing = try listing(instance)
        let wanted = selector.lowercased()
        guard let account = listing.accounts.first(where: {
            $0.email?.lowercased() == wanted || String($0.number) == wanted
        }) else {
            throw ProviderError.badResponse("cswap has no account '\(selector)'")
        }
        guard let usage = account.usage else {
            throw ProviderError.badResponse("cswap has no usage for \(account.email ?? selector)")
        }
        return map(instance: instance, usage: usage)
    }

    static func map(instance: ProviderInstance, usage: Usage) -> InstanceReading {
        var windows: [UsageWindow] = []
        if let five = usage.fiveHour {
            windows.append(UsageWindow(id: "session", label: "Session",
                                       usedPercent: five.pct, resetsAt: isoDate(five.resetsAt)))
        }
        if let seven = usage.sevenDay {
            windows.append(UsageWindow(id: "weekly", label: "Weekly",
                                       usedPercent: seven.pct, resetsAt: isoDate(seven.resetsAt)))
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name, windows: windows)
    }
}
