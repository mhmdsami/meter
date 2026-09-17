import Foundation

enum Pi {
    // Spend comes from local pi/OMP session logs, attached by Providers; the agent
    // exposes no usage API of its own.
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        InstanceReading(id: instance.name, type: instance.type, name: instance.name)
    }
}
