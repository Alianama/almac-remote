// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Feeds a stored password to `ssh` non-interactively via the native SSH_ASKPASS
/// mechanism, instead of requiring the Homebrew-only `sshpass` tool. Works even with
/// a real tty attached (`SSH_ASKPASS_REQUIRE=force`, OpenSSH 8.4+), and keeps the
/// password out of `ps` (env var, not argv).
enum SSHAskpass {
    /// A script (0700) that only auto-answers ssh's own password prompt — never
    /// writes the password itself to disk. With `SSH_ASKPASS_REQUIRE=force`, ssh
    /// routes *every* prompt (including a 2FA/OTP follow-up) through this script,
    /// so blindly echoing the stored secret for all of them would feed the password
    /// back as the 2FA code and fail the login. ssh's password prompt always reads
    /// `user@host's password: `, so match that exact shape and fall through to a
    /// native macOS dialog (osascript) for anything else, letting the user type the
    /// real 2FA code. Caller decides whether to remove the file afterward; it
    /// carries no secret, so a leftover file in the temp dir is harmless.
    static func writeScript() -> String? {
        let path = NSTemporaryDirectory() + "mrng-askpass-\(UUID().uuidString).sh"
        let script = """
        #!/bin/sh
        case "$1" in
          *\\'s\\ password:*) exec echo "$MRNG_SSH_ASKPASS_SECRET" ;;
        esac
        exec osascript \\
          -e 'on run argv' \\
          -e 'display dialog (item 1 of argv) default answer "" with hidden answer with title "Almac Remote"' \\
          -e 'text returned of result' \\
          -e 'end run' \\
          "$1"
        """ + "\n"
        guard (try? script.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
}
