import Foundation
import Security

/// Keeps Digital IDs in the Keychain, on this iPhone only (not synced to iCloud).
@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var ids: [StoredID] = []

    private let service = "com.joonselim.PassportReader.digital-id"

    init() {
        load()
    }

    /// Reads all saved IDs, oldest first.
    func load() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else {
            ids = []
            return
        }
        ids = rows.compactMap { ($0[kSecValueData as String] as? Data).flatMap { try? JSONDecoder().decode(StoredID.self, from: $0) } }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// Saves a new ID.
    func add(_ id: StoredID) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(id),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        ids.append(id)
    }

    /// Deletes an ID. Its device key blob goes with it, so the ID can no longer be presented.
    func remove(_ id: StoredID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        ids.removeAll { $0.id == id.id }
    }
}
