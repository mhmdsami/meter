import Foundation

enum OpenRouter {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        let key = try Secrets.apiKey(for: instance)
        let auth = ["Authorization": "Bearer \(key)"]
        async let creditsResp = HTTP.getJSON(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: auth)
        async let keyResp = HTTP.getJSON(URL(string: "https://openrouter.ai/api/v1/key")!, headers: auth)

        var balanceNote: String?
        var spendToday: Double?
        var windows: [UsageWindow] = []

        if let obj = try? await creditsResp as? [String: Any],
           let data = obj["data"] as? [String: Any],
           let total = optNum(data["total_credits"]),
           let used = optNum(data["total_usage"]) {
            balanceNote = String(format: "$%.2f left", total - used)
        }

        if let obj = try? await keyResp as? [String: Any],
           let data = obj["data"] as? [String: Any] {
            spendToday = optNum(data["usage_daily"])
            // configured spending cap (distinct from the prepaid balance);
            // matched to its reset period — usage is cumulative otherwise
            if let limit = optNum(data["limit"]), limit > 0 {
                let reset = (data["limit_reset"] as? String) ?? ""
                let windowed: Double
                switch reset {
                case "daily": windowed = optNum(data["usage_daily"]) ?? 0
                case "weekly": windowed = optNum(data["usage_weekly"]) ?? 0
                case "monthly": windowed = optNum(data["usage_monthly"]) ?? 0
                default: windowed = optNum(data["usage"]) ?? 0
                }
                let remaining = optNum(data["limit_remaining"]) ?? limit
                windows.append(UsageWindow(
                    id: "cap", label: "Cap",
                    usedPercent: min(100, (limit - remaining) / limit * 100),
                    note: String(format: "$%.2f of $%.0f%s", min(windowed, limit), limit,
                                 reset.isEmpty ? "" : ", " + reset)))
            }
        }

        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               windows: windows, balanceNote: balanceNote, spendToday: spendToday)
    }
}
