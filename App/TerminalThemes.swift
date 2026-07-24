// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit
import SwiftTerm

/// A terminal color scheme: 16 ANSI colors + background/foreground/cursor.
/// `isLight` groups it in the picker; it plays no role in rendering.
struct TerminalTheme: Codable, Equatable {
    var background: String   // hex "RRGGBB"
    var foreground: String
    var cursor: String
    var ansi: [String]       // 16 ANSI colors
    var isLight: Bool = false
}

enum TerminalThemes {
    /// Built-in catalog, ported from Ghostty's bundled themes
    /// (https://github.com/ghostty-org/ghostty, themes sourced from
    /// https://github.com/mbadolato/iTerm2-Color-Schemes).
    static let all: [String: TerminalTheme] = loadBundled()

    /// User-created themes (start from a built-in, tweak, save as new).
    /// Set once by `AppModel` from its persisted `customThemes`.
    static var custom: [String: TerminalTheme] = [:]

    /// "Implicit" (Default) = SwiftTerm's stock theme, always first.
    static var names: [String] {
        ["Implicit"] + Set(all.keys).union(custom.keys).sorted()
    }

    /// Custom overrides a built-in of the same name.
    static func theme(named name: String) -> TerminalTheme? {
        custom[name] ?? all[name]
    }

    private static func loadBundled() -> [String: TerminalTheme] {
        guard let url = Bundle.main.url(forResource: "GhosttyThemes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: TerminalTheme].self, from: data)
        else { return [:] }
        return decoded
    }

    // SwiftTerm's default ANSI palette (for restoring the "Implicit" theme).
    private static let defaultPalette = [
        "000000", "990001", "00a603", "999900", "0300b2", "b200b2", "00a5b2", "bfbfbf",
        "8a898a", "e50001", "00d800", "e5e500", "0700fe", "e500e5", "00e5e5", "e5e5e5",
    ]
    // Default colors captured once (bg/fg/cursor are not derivable from the palette).
    private static var defaultBg: NSColor?
    private static var defaultFg: NSColor?
    private static var defaultCaret: NSColor?

    static func apply(_ name: String, to term: LocalProcessTerminalView) {
        // Capture the default colors before any modification (once).
        if defaultBg == nil {
            defaultBg = term.nativeBackgroundColor
            defaultFg = term.nativeForegroundColor
            defaultCaret = term.caretColor
        }

        guard name != "Implicit", let theme = theme(named: name) else {
            term.installColors(defaultPalette.map(swiftTermColor))
            if let bg = defaultBg { term.nativeBackgroundColor = bg }
            if let fg = defaultFg { term.nativeForegroundColor = fg }
            if let c = defaultCaret { term.caretColor = c }
            term.needsDisplay = true
            return
        }

        if theme.ansi.count == 16 {
            term.installColors(theme.ansi.map(swiftTermColor))
        }
        term.nativeBackgroundColor = nsColor(theme.background)
        term.nativeForegroundColor = nsColor(theme.foreground)
        term.caretColor = nsColor(theme.cursor)
        term.needsDisplay = true
    }

    private static func bytes(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    }

    static func swiftTermColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = bytes(hex)
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = bytes(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Inverse of `nsColor(_:)`, for saving a `ColorPicker`-chosen color back to hex.
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = UInt8((c.redComponent * 255).rounded())
        let g = UInt8((c.greenComponent * 255).rounded())
        let b = UInt8((c.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
