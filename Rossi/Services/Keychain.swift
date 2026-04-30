//
//  Keychain.swift — типобезопасная обёртка над Security framework.
//
//  Используется для хранения:
//   • accessToken (JWT)  — короткоживущий, восстанавливаемый, но удобно
//                           иметь в Keychain а не в UserDefaults
//   • refreshToken       — backup для случаев когда HTTP-cookie сбросился
//

import Foundation
import Security

enum KeychainKey: String {
    case accessToken  = "ru.rossihelp.app.accessToken"
    case refreshToken = "ru.rossihelp.app.refreshToken"
    case savedUsername = "ru.rossihelp.app.savedUsername"
}

enum Keychain {
    @discardableResult
    static func set(_ value: String, for key: KeychainKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        // accessibleAfterFirstUnlock — токен переживает рестарт телефона,
        // но недоступен пока пользователь не разблокировал устройство.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    @discardableResult
    static func remove(_ key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func clearAll() {
        remove(.accessToken)
        remove(.refreshToken)
        remove(.savedUsername)
    }
}
