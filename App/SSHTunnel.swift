// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import Darwin
import MRNGCore

/// A background `ssh -N -L` port-forward through a jump host, kept alive for
/// as long as a session needs it (RDP/SSH/Telnet/HTTP all connect to
/// `127.0.0.1:localPort` instead of the real target once this is ready).
final class SSHTunnel {
    let localPort: Int
    private let process: Process

    /// Starts the tunnel process immediately (spawn only — use `waitUntilReady()`
    /// before connecting the real session). Returns nil if no free local port
    /// could be found or the process failed to launch.
    init?(proxy: ProxyJumpTarget, proxyPassword: String, targetHost: String, targetPort: Int) {
        guard let port = SSHTunnel.freeLocalPort() else { return nil }
        localPort = port

        let target = proxy.user.isEmpty ? proxy.host : "\(proxy.user)@\(proxy.host)"
        let sshArgs = [
            "-N", "-L", "\(port):\(targetHost):\(targetPort)",
            "-p", "\(proxy.port)",
            "-o", "UserKnownHostsFile=\(TerminalContainer.appKnownHostsPath())",
            "-o", "StrictHostKeyChecking=accept-new",
            target,
        ]
        let p = Process()
        if !proxyPassword.isEmpty, let sshpass = TerminalContainer.sshpassPath() {
            p.executableURL = URL(fileURLWithPath: sshpass)
            p.arguments = ["-p", proxyPassword, "/usr/bin/ssh"] + sshArgs
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = sshArgs
        }
        do {
            try p.run()
        } catch {
            return nil
        }
        process = p
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Polls `127.0.0.1:localPort` until it accepts a TCP connection, or times out.
    func waitUntilReady(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false } // ssh exited early (auth failure, bad host, ...)
            if SSHTunnel.canConnect(port: localPort) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // ponytail: bind-then-close-then-let-ssh-rebind has a small TOCTOU race
    // window if something else grabs the port first — acceptable for a local
    // dev tool; move to passing an already-bound fd to ssh if that ever bites.
    private static func freeLocalPort() -> Int? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &out) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard getResult == 0 else { return nil }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
