// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Feeds a stored password to `ssh` non-interactively via the native SSH_ASKPASS
/// mechanism, instead of requiring the Homebrew-only `sshpass` tool. Works even with
/// a real tty attached (`SSH_ASKPASS_REQUIRE=force`, OpenSSH 8.4+), and keeps the
/// password out of `ps` (env var, not argv).
enum SSHAskpass {
    /// A one-line script (0700) that echoes `MRNG_SSH_ASKPASS_SECRET` — never writes
    /// the password itself to disk. Caller decides whether to remove it afterward;
    /// it carries no secret, so a leftover file in the temp dir is harmless.
    static func writeScript() -> String? {
        let path = NSTemporaryDirectory() + "mrng-askpass-\(UUID().uuidString).sh"
        let script = "#!/bin/sh\nexec echo \"$MRNG_SSH_ASKPASS_SECRET\"\n"
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
}
