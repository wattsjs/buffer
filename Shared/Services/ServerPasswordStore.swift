import Foundation
import Security

nonisolated enum ServerPasswordStore {
    private static let service = "com.wattsjs.buffer.server-password"
    private static let ioQueue = DispatchQueue(label: "com.wattsjs.buffer.keychain", qos: .userInitiated)

    /// Security.framework calls can wait for securityd or an access prompt.
    /// Cancellation cannot interrupt that call; callers must reject stale
    /// results while the serial worker keeps UI/main-actor work responsive.
    static func loadPasswordAsync(for serverID: UUID) async -> String? {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: loadPassword(for: serverID)) }
        }
    }

    static func savePasswordAsync(_ password: String, for serverID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: savePassword(password, for: serverID)) }
        }
    }

    static func deletePasswordAsync(for serverID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: deletePassword(for: serverID)) }
        }
    }

    private static func loadPassword(for serverID: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return password
    }

    @discardableResult
    private static func savePassword(_ password: String, for serverID: UUID) -> Bool {
        let account = serverID.uuidString
        let data = Data(password.utf8)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func deletePassword(for serverID: UUID) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
