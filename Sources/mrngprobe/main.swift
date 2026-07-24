// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import MRNGCore

guard CommandLine.arguments.count > 1 else {
    print("Usage: mrngprobe <path-to-confCons.xml>")
    exit(1)
}
let path = CommandLine.arguments[1]

do {
    let doc = try ConfConsParser.parse(fileURL: URL(fileURLWithPath: path))
    print("=== confCons \(doc.confVersion) | \(doc.encryptionEngine)/\(doc.blockCipherMode) | KDF \(doc.kdfIterations) ===")

    let all = doc.allNodes()
    let containers = all.filter { $0.isContainer }
    let connections = all.filter { !$0.isContainer }
    print("Nodes: \(all.count) | folders: \(containers.count) | connections: \(connections.count) | roots: \(doc.roots.count)")

    var byProto: [String: Int] = [:]
    for c in connections { byProto[c.protocolType, default: 0] += 1 }
    print("Protocols:", byProto.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

    // Validate the master password against the Protected attribute.
    let pw = MRNGCrypto.defaultPassword
    let ok = MRNGCrypto.passwordIsCorrect(protectedBase64: doc.protected, password: pw, iterations: doc.kdfIterations)
    print("Master password '\(pw)': \(ok ? "correct" : "WRONG")")

    // How many passwords decrypt successfully (without printing them)?
    let withPw = connections.filter { !$0.encryptedPassword.isEmpty }
    let decryptOK = withPw.filter { MRNGCrypto.decrypt(base64: $0.encryptedPassword, password: pw, iterations: doc.kdfIterations) != nil }
    print("Encrypted passwords: \(withPw.count) | successfully decrypted: \(decryptOK.count)")

    // Sample SSH connection with resolved fields (password masked).
    if let ssh = connections.first(where: { $0.protocolType.hasPrefix("SSH") && !$0.hostname.isEmpty }) {
        let hasPw = !ssh.encryptedPassword.isEmpty
        print("SSH sample: name=\"\(ssh.name)\" host=\(ssh.hostname):\(ssh.port) user=\(ssh.username) pwd=\(hasPw ? "***" : "(none)")")
    }

    // Encryption round-trip test.
    let secret = "Test!Password#123"
    let enc = MRNGCrypto.encrypt(plaintext: secret, password: pw, iterations: doc.kdfIterations)
    let dec = MRNGCrypto.decrypt(base64: enc, password: pw, iterations: doc.kdfIterations)
    print("Encrypt round-trip: \(dec == secret ? "OK" : "FAILED (\(dec ?? "nil"))")")

    // Serializer round-trip test: serialize -> re-parse -> compare.
    let xml = ConfConsSerializer.serialize(doc)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mrng_roundtrip.xml")
    try xml.write(to: tmp, atomically: true, encoding: .utf8)
    let doc2 = try ConfConsParser.parse(fileURL: tmp)
    let n2 = doc2.allNodes()
    print("Serialize round-trip: nodes \(all.count) -> \(n2.count) | connections \(connections.count) -> \(n2.filter{!$0.isContainer}.count) | \(all.count == n2.count ? "OK" : "DIFFERS")")
    // Make sure an encrypted password is still decryptable after the round-trip.
    if let p = doc2.allNodes().first(where: { !$0.encryptedPassword.isEmpty }) {
        let ok = MRNGCrypto.decrypt(base64: p.encryptedPassword, password: pw, iterations: doc2.kdfIterations) != nil
        print("Password preserved after serialize: \(ok ? "OK" : "FAILED")")
    }

    // TOTP self-check: "MZXW6YTBOI======" is the well-known RFC 4648 Base32
    // encoding of "foobar" — just needs to decode + produce a stable 6-digit
    // code, and reject a non-Base32 secret.
    let totpCode = TOTP.code(secretBase32: "MZXW6YTBOI======")
    let totpOK = totpCode != nil && totpCode?.count == 6 && totpCode!.allSatisfy(\.isNumber)
        && totpCode == TOTP.code(secretBase32: "MZXW6YTBOI======")
    print("TOTP code generation: \(totpOK ? "OK (\(totpCode!))" : "FAILED")")
    print("TOTP invalid secret rejected: \(TOTP.code(secretBase32: "not-base32!!!") == nil ? "OK" : "FAILED")")

    // SSH local-forward parsing self-check: blank lines and "#" comments must
    // be dropped, real rules kept in order.
    let fwdNode = MRNGNode(id: "test", name: "fwd-test", isContainer: false, attributes: [
        "SSHLocalForwards": "3389:10.54.18.110:3389\n\n# comment\n8081:10.62.70.69:8081\n  \n3389:10.54.18.99:3389",
    ])
    let expectedForwards = ["3389:10.54.18.110:3389", "8081:10.62.70.69:8081", "3389:10.54.18.99:3389"]
    print("SSH local-forward parsing: \(fwdNode.sshLocalForwards == expectedForwards ? "OK" : "FAILED (\(fwdNode.sshLocalForwards))")")

    // ProxyJump "user@host[:port]" parsing self-check.
    let p1 = ProxyJumpTarget("user@10.54.18.42")
    let p2 = ProxyJumpTarget("user@10.54.18.42:2222")
    let p3 = ProxyJumpTarget("10.54.18.42")
    let p4 = ProxyJumpTarget("")
    let proxyOK = p1?.user == "user" && p1?.host == "10.54.18.42" && p1?.port == 22
        && p2?.port == 2222
        && p3?.user == "" && p3?.host == "10.54.18.42"
        && p4 == nil
    print("ProxyJump parsing: \(proxyOK ? "OK" : "FAILED")")
} catch {
    print("Parse error: \(error)")
    exit(1)
}
