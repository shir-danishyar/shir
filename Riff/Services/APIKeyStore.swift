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
    fileprivate static let service = "com.shirhussain.riff.youtube"
    fileprivate static let account = "dataAPIKey"

    private(set) var key: String?

    var hasKey: Bool { !(key ?? "").isEmpty }

    init() {
        key = Self.readFromKeychain()
    }

    func save(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        var query = Self.baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
        key = trimmed
    }

    func clear() {
        SecItemDelete(Self.baseQuery() as CFDictionary)
        key = nil
    }

    /// Reads the key straight from the keychain, from any thread.
    ///
    /// This exists because `YouTubeSearchClient` calls its key provider from a
    /// background async context. The provider used to be
    /// `MainActor.assumeIsolated { store.key }`, which asserts and kills the
    /// process the moment a search runs off the main actor — every search
    /// crashed the app, and no test caught it because none had ever typed a
    /// query.
    ///
    /// `SecItemCopyMatching` is thread-safe, so going to the keychain each time
    /// is both correct and simpler than mirroring the value behind a lock. It
    /// also keeps the "paste a key in Settings and search immediately" behaviour
    /// the provider closure was written for.
    nonisolated static func currentKey() -> String? {
        readFromKeychain()
    }

    // nonisolated because `currentKey()` reaches it from a background context;
    // the class is @MainActor, so members are main-actor isolated by default.
    fileprivate nonisolated static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    fileprivate nonisolated static func readFromKeychain() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
