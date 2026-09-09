// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import Security
import LocalAuthentication

/// Optionally stores the master password in the macOS Keychain so it doesn't
/// need retyping every launch, gated behind Touch ID (or the Mac account
/// password) via `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` — the
/// same device-owner check `AppModel.authenticateToUnlock()` already uses for
/// the idle-lock screen.
///
/// The Keychain item itself carries no `SecAccessControl`: that's the
/// OS-enforced way to gate a Keychain secret behind biometry, but it requires
/// a `keychain-access-groups` entitlement tied to a paid Developer ID Team —
/// unavailable here (ad-hoc signed, see BUILD.md's install notes) and fails
/// with errSecMissingEntitlement (-34018) if attempted. So the gate is
/// enforced in-process instead, before the plain item is ever read.
enum MasterPasswordKeychain {
    private static let service = "id.my.alipurnama.AlmacRemote.masterPassword"
    private static let account = "masterPassword"

    /// True if a password is currently saved. No access control on the item,
    /// so this is a plain existence check — never prompts.
    static var isSaved: Bool {
        SecItemCopyMatching(baseQuery() as CFDictionary, nil) == errSecSuccess
    }

    /// Saves `password`, replacing any previously saved one.
    /// `ThisDeviceOnly` keeps it out of iCloud Keychain sync.
    @discardableResult
    static func save(_ password: String) -> Bool {
        delete()
        var query = baseQuery()
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.log("MasterPasswordKeychain.save: SecItemAdd failed status=\(status)")
        }
        return status == errSecSuccess
    }

    /// Prompts Touch ID / the account password, then returns the saved
    /// password — or nil if there isn't one, or authentication failed/was cancelled.
    static func load(reason: String) async -> String? {
        guard isSaved else { return nil }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            AppLog.log("MasterPasswordKeychain.load: device-owner auth unavailable: \(policyError?.localizedDescription ?? "?")")
            return nil
        }
        let authenticated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard authenticated else { return nil }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return password
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
