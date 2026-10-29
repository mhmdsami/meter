import Foundation

enum OpenRouter {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        let key = try Secrets.apiKey(for: instance)
        let auth = ["Authorization": "Bearer \(key)"]
        async let creditsResp = HTTP.getJSON(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: auth)
        async let keyResp = HTTP.getJSON(URL(string: "https://openrouter.ai/api/v1/key")!, headers: auth)

        var balanceNote: String?
        var spendToday: Double?

        if let obj = try? await creditsResp as? [String: Any],
           let data = obj["data"] as? [String: Any],
           let total = optNum(data["total_credits"]),
           let used = optNum(data["total_usage"]) {
            balanceNote = String(format: "$%.2f left", total - used)
        }

        if let obj = try? await keyResp as? [String: Any],
           let data = obj["data"] as? [String: Any] {
            spendToday = optNum(data["usage_daily"])
        }

        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               balanceNote: balanceNote, spendToday: spendToday)
    }
}
