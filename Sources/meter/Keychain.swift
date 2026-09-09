import Foundation
import Security

enum Keychain {
    struct Item {
        let account: String
        let secret: String
    }

    // Foreign items (Claude/Zed) rotate their own ACLs; re-reading every refresh
    // re-triggers SecurityAgent prompts. One read per launch per item.
    private static var cache: [String: Item?] = [:]
    private static let lock = NSLock()

    static func invalidateGeneric(service: String) { invalidate(genericKey(service)) }
    static func invalidateInternet(server: String) { invalidate(internetKey(server)) }

    static func generic(service: String) -> String? {
        lookup(genericKey(service), query: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])?.secret
    }

    static func internet(server: String) -> Item? {
        lookup(internetKey(server), query: [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
        ])
    }

    private static func genericKey(_ service: String) -> String { "generic:" + service }
    private static func internetKey(_ server: String) -> String { "internet:" + server }

    private static func invalidate(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: key)
    }

    private static func lookup(_ key: String, query: [String: Any]) -> Item? {
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }

        var full = query
        full[kSecReturnData as String] = true
        full[kSecReturnAttributes as String] = true
        full[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        var item: Item?
        if SecItemCopyMatching(full as CFDictionary, &out) == errSecSuccess,
           let dict = out as? [String: Any],
           let data = dict[kSecValueData as String] as? Data,
           let secret = String(data: data, encoding: .utf8) {
            item = Item(account: dict[kSecAttrAccount as String] as? String ?? "", secret: secret)
        }

        lock.lock()
        // cache successes only — a failed read (ACL prompt denied after a rotation)
        // must be retried on the next refresh, not sticky for the process lifetime
        if let item { cache[key] = item }
        lock.unlock()
        return item
    }
}
