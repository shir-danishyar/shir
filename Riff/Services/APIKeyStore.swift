import Foundation
import Observation
import Security

/// Holds the user's YouTube Data API key in the keychain.
///
/// It goes in the keychain rather than UserDefaults because the key is a
/// billable credential tied to their Google Cloud project — a plist backed up
/// in the clear is the wrong place for it.
@MainActor
@Observable
final class APIKeyStore {
    private let service = "com.shirhussain.riff.youtube"
    private let account = "dataAPIKey"

    private(set) var key: String?

    var hasKey: Bool { !(key ?? "").isEmpty }

    init() {
        key = readFromKeychain()
    }

    func save(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
        key = trimmed
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        key = nil
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
