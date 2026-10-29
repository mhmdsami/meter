import Foundation

/// Catch-all row for providers meter has no dedicated integration for (e.g. a
/// model vendor you are just testing). There is nothing to fetch: the spend is
/// attached by the `other` LocalCostSource from pi's unmapped providers, and the
/// row stays hidden until there is something to show.
enum CatchAll {
    static func fetch(_ instance: ProviderInstance) async throws -> InstanceReading {
        InstanceReading(id: instance.name, type: instance.type, name: instance.name)
    }
}
