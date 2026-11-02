// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

/// App-wide skin. `.native` = the current macOS look (default); the rest are
/// the pixel themes from Almac Browser (same palette tokens as its theme.css):
/// thick borders, hard offset shadows, a faint pixel grid behind the panes.
enum AppTheme: String, CaseIterable, Identifiable {
    case native
    // light
    case almac, pastel, gameboy, sakura, lemonade, arctic, paper, peach, lavender
    // dark
    case midnight, horror, gaming, terminal, synthwave, ocean, forest, sunset, coffee, nord, dracula,
         amber, lava, noir, galaxy, cyber, rosepine, cobalt
    var id: String { rawValue }

    var name: String {
        switch self {
        case .native: return "Classic"
        case .gameboy: return "Game Boy"
        case .amber: return "Amber CRT"
        case .rosepine: return "Rosé Pine"
        default: return rawValue.capitalized
        }
    }

    struct Palette {
        let bg, grid, glass, glassStrong, text, muted, border, shadow, active, accent: Color
        let dark: Bool
    }

    /// Tokens as in Almac Browser's theme.css: bg, grid, glass, glass-strong, text, muted,
    /// border, shadow, active, accent ("#rrggbb" / "#rrggbbaa") + the Ghostty theme lending
    /// its ANSI colors to the matching terminal theme ("" = Game Boy greens).
    private var spec: (c: [String], dark: Bool, ansi: String)? {
        switch self {
        case .native: return nil
        case .almac: return (["#7eebd3", "#1111110f", "#fffcf0eb", "#fffdf3", "#111111", "#4b5563", "#111111", "#111111", "#f6ec9f", "#41a6f6"], false, "Catppuccin Latte")
        case .pastel: return (["#ffd9ec", "#783c7814", "#fffafde6", "#fff7fb", "#3b2a4a", "#7a6488", "#5b4370", "#5b4370", "#e9d5ff", "#c084fc"], false, "Rose Pine Dawn")
        case .gameboy: return (["#8bac0f", "#0f380f1f", "#9bbc0f", "#a9c822", "#0f380f", "#306230", "#0f380f", "#0f380f", "#c8dc5c", "#306230"], false, "")
        case .sakura: return (["#ffe4ec", "#b4466414", "#fff5f8e6", "#fffafc", "#4a1f2e", "#9a5a6e", "#4a1f2e", "#d6587f", "#ffc2d4", "#ff5c8a"], false, "Ayu Light")
        case .lemonade: return (["#fff36b", "#5a4a0014", "#fffbe0eb", "#fffdf0", "#2b2200", "#6b5a10", "#2b2200", "#2b2200", "#b8f2a0", "#ff8a00"], false, "One Half Light")
        case .arctic: return (["#dff3ff", "#1e507814", "#f5fbffeb", "#ffffff", "#0f2a44", "#4f6f8f", "#0f2a44", "#0f2a44", "#b9e2ff", "#0a84ff"], false, "Iceberg Light")
        case .paper: return (["#f4ecd8", "#3c2f1a12", "#fbf6eaeb", "#fffaf0", "#2f2516", "#7a6a50", "#2f2516", "#2f2516", "#e8d7a8", "#b5651d"], false, "Flexoki Light")
        case .peach: return (["#ffd3b0", "#7a2e0a14", "#fff3e8eb", "#fff8f2", "#4a2410", "#8a5236", "#4a2410", "#c2410c", "#ffe6a8", "#f97316"], false, "Gruvbox Light")
        case .lavender: return (["#e6dcff", "#3c287814", "#f7f3ffeb", "#fcfaff", "#2e1f5e", "#6a5a9a", "#2e1f5e", "#7c5cff", "#fde68a", "#7c5cff"], false, "Atom One Light")
        case .midnight: return (["#0b1026", "#8ca0ff10", "#141b3a99", "#1c254ee6", "#e6ebff", "#8f9bd0", "#000000", "#000000", "#2a3a80", "#41a6f6"], true, "TokyoNight Night")
        case .horror: return (["#0d0505", "#ff28280d", "#1c0a0ab3", "#280c0ceb", "#f2dede", "#b07b7b", "#000000", "#6b0000", "#82000080", "#ff4d4d"], true, "Oxblood")
        case .gaming: return (["#090014", "#00fff012", "#120624a6", "#1e0a3ae6", "#f0f6ff", "#a58fd8", "#00e5ff", "#ff00c8", "#00e5ff2e", "#00e5ff"], true, "Cyberpunk")
        case .terminal: return (["#020a02", "#33ff660f", "#041406bf", "#061c08eb", "#7dff9a", "#3fae5a", "#1f7a35", "#000000", "#33ff6626", "#33ff66"], true, "Green Phosphor CRT")
        case .synthwave: return (["#1a0b2e", "#ff71ce14", "#2610409e", "#341656e6", "#fff0fb", "#c79bd8", "#000000", "#ff2a6d", "#ff71ce38", "#ff71ce"], true, "Synthwave Everything")
        case .ocean: return (["#04263a", "#4fd1ff10", "#0a3550a6", "#0e4060e6", "#e0f7ff", "#7fb3cc", "#000000", "#00131f", "#0e6a8a", "#2ee6d6"], true, "Material Ocean")
        case .forest: return (["#0f1f14", "#7bd38810", "#16301fa6", "#1c3a26e6", "#e4f5d9", "#8fb39a", "#000000", "#050d07", "#2f6b3a", "#9be15d"], true, "Everforest Dark Hard")
        case .sunset: return (["#2a0f1f", "#ff9e6414", "#3d1530a6", "#4a1a3ae6", "#ffe8d6", "#d79a8a", "#000000", "#ff6b35", "#7a2e3a", "#ff9e44"], true, "Monokai Pro")
        case .coffee: return (["#2b1d14", "#e0b07a10", "#3a281ca6", "#46301fe6", "#f3e3cf", "#b89878", "#000000", "#120a05", "#6b4a2e", "#e0a458"], true, "Gruvbox Dark")
        case .nord: return (["#2e3440", "#d8dee910", "#3b4252b3", "#434c5ee6", "#eceff4", "#a3adbf", "#1d2129", "#1d2129", "#4c566a", "#88c0d0"], true, "Nord")
        case .dracula: return (["#282a36", "#bd93f910", "#343746b3", "#3c3f52e6", "#f8f8f2", "#a4a7c2", "#000000", "#ff79c6", "#44475a", "#bd93f9"], true, "Dracula")
        case .amber: return (["#1a1200", "#ffb00010", "#241a02bf", "#2e2104eb", "#ffb000", "#b07a00", "#6b4a00", "#000000", "#ffb00026", "#ffcc33"], true, "Amber CRT Retro")
        case .lava: return (["#140805", "#ff4d0010", "#24100ab3", "#301409eb", "#ffe2d1", "#c08060", "#000000", "#ff3d00", "#ff4d0033", "#ff6a00"], true, "Gruvbox Dark")
        case .noir: return (["#111111", "#ffffff0d", "#1c1c1cb3", "#262626eb", "#f2f2f2", "#999999", "#000000", "#555555", "#ffffff26", "#ffffff"], true, "Tomorrow Night Bright")
        case .galaxy: return (["#0a0420", "#a78bfa12", "#170c3aa6", "#21124ee6", "#ece6ff", "#a094d0", "#000000", "#6d28d9", "#7c3aed40", "#f472b6"], true, "Catppuccin Mocha")
        case .cyber: return (["#0d0d0d", "#fcee0a10", "#1a1a10b3", "#22220feb", "#fcee0a", "#b3a900", "#fcee0a", "#00f0ff", "#fcee0a26", "#fcee0a"], true, "Batman")
        case .rosepine: return (["#191724", "#ebbcba10", "#1f1d2eb3", "#26233ae6", "#e0def4", "#908caa", "#000000", "#eb6f92", "#403d52", "#ebbcba"], true, "Rose Pine")
        case .cobalt: return (["#193549", "#ffc60010", "#1f4662a6", "#234d6be6", "#ffffff", "#9fb8cc", "#000000", "#0d1f2d", "#2a5a7a", "#ffc600"], true, "Cobalt2")
        }
    }

    var palette: Palette? {
        guard let s = spec else { return nil }
        let c = s.c.map(Color.init(hex:))
        return Palette(bg: c[0], grid: c[1], glass: c[2], glassStrong: c[3], text: c[4], muted: c[5],
                       border: c[6], shadow: c[7], active: c[8], accent: c[9], dark: s.dark)
    }

    /// Terminal theme that goes with this skin ("Implicit" for Classic).
    var terminalThemeName: String { self == .native ? "Implicit" : "Pixel \(name)" }

    /// Built-in "Pixel …" terminal themes (pane bg / text / accent cursor + a fitting
    /// Ghostty theme's ANSI colors), merged into the Ghostty catalog at load.
    static func pixelTerminalThemes(base: [String: TerminalTheme]) -> [String: TerminalTheme] {
        // Game Boy: the four DMG greens only.
        let gameboy = ["0f380f", "306230", "306230", "306230", "0f380f", "306230", "306230", "0f380f",
                       "306230", "0f380f", "0f380f", "0f380f", "0f380f", "0f380f", "0f380f", "0f380f"]
        let rgb = { (hex: String) in String(hex.dropFirst().prefix(6)) }
        var out: [String: TerminalTheme] = [:]
        for theme in allCases {
            guard let s = theme.spec else { continue }
            out[theme.terminalThemeName] = TerminalTheme(
                background: rgb(s.c[0]), foreground: rgb(s.c[4]), cursor: rgb(s.c[9]),
                ansi: s.ansi.isEmpty ? gameboy : (base[s.ansi]?.ansi ?? []), isLight: !s.dark)
        }
        return out
    }
}

extension Color {
    /// "#rrggbb" or "#rrggbbaa".
    init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        let hasAlpha = hex.count == 9
        let rgb = hasAlpha ? v >> 8 : v
        self.init(.sRGB, red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255, opacity: hasAlpha ? Double(v & 0xff) / 255 : 1)
    }
}

/// Pane background for pixel themes: flat color + the 24pt grid from Almac Browser.
struct PixelBackground: View {
    let palette: AppTheme.Palette
    var body: some View {
        palette.bg.overlay(
            Canvas { ctx, size in
                var path = Path()
                for x in stride(from: 0, through: size.width, by: 24) { path.addRect(CGRect(x: x, y: 0, width: 1, height: size.height)) }
                for y in stride(from: 0, through: size.height, by: 24) { path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
                ctx.fill(path, with: .color(palette.grid))
            }
        )
        .ignoresSafeArea()
    }
}

extension View {
    /// Pixel card: fill + 2pt border + hard 3pt offset shadow. No-op for the native theme.
    @ViewBuilder func pixelBox(_ p: AppTheme.Palette?, fill: Color? = nil, radius: CGFloat = 6, lift: CGFloat = 3) -> some View {
        if let p {
            self
                .background(RoundedRectangle(cornerRadius: radius).fill(fill ?? p.glassStrong))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(p.border, lineWidth: 2))
                .background(RoundedRectangle(cornerRadius: radius).fill(p.shadow).offset(x: lift, y: lift))
        } else {
            self
        }
    }

    /// Whole-window skin: accent, light/dark and text color follow the palette.
    @ViewBuilder func appThemed(_ p: AppTheme.Palette?) -> some View {
        if let p {
            self.tint(p.accent)
                .foregroundStyle(p.text)
                .preferredColorScheme(p.dark ? .dark : .light)
                .toolbarBackground(p.bg, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            self
        }
    }
}

/// Theme grid for Settings › Appearance: every card previews its own palette.
struct AppThemePicker: View {
    @Binding var selection: AppTheme
    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                Button { selection = theme } label: { card(theme) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
    }

    private func card(_ theme: AppTheme) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(p?.glass ?? Color(nsColor: .controlBackgroundColor))
                    .frame(width: 22)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(p?.glassStrong ?? Color(nsColor: .windowBackgroundColor))
                    RoundedRectangle(cornerRadius: 3).fill(p?.active ?? Color.accentColor.opacity(0.3))
                }
            }
            .frame(height: 34)
            Text(theme.name)
                .font(.system(size: 10, weight: .bold, design: p == nil ? .default : .monospaced))
                .foregroundStyle(p?.text ?? .primary)
        }
        .padding(6)
        .background(p.map { AnyView(PixelBackground(palette: $0)) } ?? AnyView(Color(nsColor: .underPageBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(p?.border ?? Color.secondary.opacity(0.4), lineWidth: p == nil ? 1 : 2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: selection == theme ? 3 : 0).padding(-4))
    }
}
