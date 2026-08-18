// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Lightweight always-on event log (app/window activation, terminal focus
/// reclaim, process exits) written to `AppModel.logDirectory`, separate from
/// the FreeRDP debug log so the two don't interleave. Backs the "Logs" menu —
/// exists so users can self-diagnose intermittent issues (e.g. focus loss
/// after backgrounding) instead of having to reproduce them for a developer.
enum AppLog {
    /// Same directory as `AppModel.logDirectory` (~/Library/Logs/AlmacRemote),
    /// recomputed here rather than referenced — `AppModel` is `@MainActor` and
    /// this logger must be callable from background delegate callbacks too.
    static let logDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AlmacRemote", isDirectory: true)
    static let fileURL = logDirectory.appendingPathComponent("app.log")
    /// Keep the file from growing unbounded across long sessions.
    private static let maxFileBytes = 1_000_000

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > maxFileBytes {
            try? data.write(to: fileURL) // start over rather than trim in place
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func tail(maxBytes: Int = 200_000) -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        let clipped = data.count > maxBytes ? data.suffix(maxBytes) : data
        return String(data: clipped, encoding: .utf8) ?? ""
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
