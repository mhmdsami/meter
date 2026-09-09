import Foundation

enum VercelGateway {
    // Spend comes from the fx CLI's local generation log. Balance needs a gateway
    // API key (vcp_…): fx's OAuth session token is scoped to the Vercel API and
    // /v1/credits rejects it with 401. A missing key drops the balance, not the row.
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        var reading = InstanceReading(id: instance.name, type: instance.type, name: instance.name)
        if let key = try? Secrets.apiKey(for: instance) {
            let obj = try await HTTP.getJSON(
                URL(string: "https://ai-gateway.vercel.sh/v1/credits")!,
                headers: ["Authorization": "Bearer \(key)"])
            if let root = obj as? [String: Any],
               let balance = Double(root["balance"] as? String ?? "") {
                reading.balanceNote = String(format: "$%.2f left", balance)
            }
        }
        return reading
    }
}
