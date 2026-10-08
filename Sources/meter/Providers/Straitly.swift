import Foundation

/// Straitly is a model router: it bills per token and now exposes the key's
/// balance (and plan) at /v1/key. Spend itself is captured by the local cost
/// scans and attributed to the vendor of each model, so this row is balance-only.
enum Straitly {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        let key = try Secrets.apiKey(for: instance)
        do {
            let obj = try await HTTP.getJSON(
                URL(string: "https://api.straitly.ai/v1/key")!,
                headers: ["Authorization": "Bearer \(key)"])
            return map(instance: instance, payload: obj)
        } catch ProviderError.http(401, _) {
            throw ProviderError.missingKey("Straitly key rejected — update it or re-run `opencode auth login`")
        }
    }

    static func map(instance: ProviderInstance, payload: Any) -> InstanceReading {
        guard let root = payload as? [String: Any] else {
            return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                                   error: "unexpected /v1/key response")
        }
        var note: String?
        if let available = optNum(root["available_usd"]) {
            note = String(format: "$%.2f left", available)
        }
        if let cap = optNum(root["daily_cap_usd"]) {
            note = (note ?? "") + " · daily cap $" + String(format: "%.0f", cap)
        }
        return InstanceReading(id: instance.name, type: instance.type, name: instance.name,
                               balanceNote: note)
    }
}
