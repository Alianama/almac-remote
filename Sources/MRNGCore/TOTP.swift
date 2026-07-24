// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import CryptoKit

/// RFC 6238 TOTP (Google Authenticator-compatible): HOTP over a 30s time
/// counter, HMAC-SHA1, 6 digits. Secret is the standard Base32 string shown
/// under a QR code / "enter setup key manually" flow.
public enum TOTP {
    public static func code(secretBase32: String, date: Date = Date(), period: Int = 30, digits: Int = 6) -> String? {
        guard let key = base32Decode(secretBase32), !key.isEmpty else { return nil }
        let counter = UInt64(date.timeIntervalSince1970 / Double(period))
        let counterData = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: SymmetricKey(data: key))
        let bytes = Array(hmac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let truncated = bytes[offset..<offset + 4]
        var number: UInt32 = 0
        for byte in truncated { number = (number << 8) | UInt32(byte) }
        number &= 0x7fffffff
        let mod = UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)d", number % mod)
    }

    /// Seconds left in the current `period`-second window, for a countdown UI.
    public static func secondsRemaining(date: Date = Date(), period: Int = 30) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func base32Decode(_ input: String) -> Data? {
        let cleaned = input.uppercased().filter { $0 != "=" && !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }
        var bits = 0
        var value: UInt64 = 0
        var output = [UInt8]()
        for char in cleaned {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | UInt64(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((value >> UInt64(bits)) & 0xff))
            }
        }
        return Data(output)
    }
}
