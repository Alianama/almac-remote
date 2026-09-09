// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import Security
import LocalAuthentication

/// Optionally stores the master password in the macOS Keychain, gated behind
/// Touch ID (or the account password as fallback) via `SecAccessControl` —
/// so unlocking a custom-protected file/vault doesn't require retyping it
/// every launch. Opt-in only (see `MasterPasswordSheet`'s checkbox); nothing
/// is ever written here without the access-control gate attached.
enum MasterPasswordKeychain {
    private static let service = "id.my.alipurnama.AlmacRemote.masterPassword"
    private static let account = "masterPassword"

    /// True if a password is currently saved. Metadata-only query (no
    /// `kSecReturnData`), so this never triggers a Touch ID prompt.
    static var isSaved: Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Saves `password`, replacing any previously saved one. `.userPresence`
    /// (Touch ID or the Mac account password, same as `authenticateToUnlock`'s
    /// device-owner check) is required to ever read it back; `ThisDeviceOnly`
    /// keeps it out of iCloud Keychain sync.
    @discardableResult
    static func save(_ password: String) -> Bool {
        delete()
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil
        ) else { return false }
        var query = baseQuery()
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessControl as String] = access
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Prompts Touch ID (or the account password) and returns the saved
    /// password, or nil if there isn't one, or authentication failed/was cancelled.
    static func load(reason: String) async -> String? {
        let context = LAContext()
        context.localizedReason = reason
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data,
                      let password = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: password)
            }
        }
    }

    static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
