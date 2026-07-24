// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// Small color preview for a theme: background fill, a few ANSI dots, an "Aa"
/// sample in the foreground color. `nil` theme = "Implicit" (system default).
struct ThemeSwatchView: View {
    let theme: TerminalTheme?

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(theme.map { Color(TerminalThemes.nsColor($0.background)) } ?? Color(NSColor.textBackgroundColor))
            .overlay(alignment: .topLeading) {
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.map { Color(TerminalThemes.nsColor($0.foreground)) } ?? Color.primary)
                    .padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    ForEach(Array((theme?.ansi.prefix(6) ?? []).enumerated()), id: \.offset) { _, hex in
                        Circle().fill(Color(TerminalThemes.nsColor(hex))).frame(width: 7, height: 7)
                    }
                }
                .padding(4)
            }
    }
}

/// Searchable grid of every terminal theme (Ghostty-sourced built-ins + user
/// custom ones), grouped Custom / Dark / Light. Tap to select, right-click a
/// theme to customize (start a new one from it) or delete a custom one.
struct ThemePickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var customizeBaseName = ""
    @State private var customizeTheme: TerminalTheme?

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)]

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }
    private var customNames: [String] { model.customThemes.keys.sorted().filter(matches) }
    private var darkNames: [String] { TerminalThemes.all.filter { !$0.value.isLight }.keys.sorted().filter(matches) }
    private var lightNames: [String] { TerminalThemes.all.filter { $0.value.isLight }.keys.sorted().filter(matches) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("Theme.PickerTitle")).font(.headline)
                Spacer()
                Button(t("Common.Close")) { dismiss() }
            }
            .padding()
            Divider()
            TextField(t("Theme.SearchPlaceholder"), text: $search)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if matches("Implicit") {
                        section(title: t("Settings.TerminalTheme"), names: ["Implicit"])
                    }
                    if !customNames.isEmpty { section(title: t("Theme.SectionCustom"), names: customNames) }
                    if !darkNames.isEmpty { section(title: t("Theme.SectionDark"), names: darkNames) }
                    if !lightNames.isEmpty { section(title: t("Theme.SectionLight"), names: lightNames) }
                }
                .padding(12)
            }
        }
        .frame(width: 640, height: 560)
        .sheet(item: Binding(
            get: { customizeTheme.map { IdentifiedTheme(name: customizeBaseName, theme: $0) } },
            set: { customizeTheme = $0?.theme }
        )) { item in
            ThemeCustomizeSheet(baseName: item.name, theme: item.theme)
                .environmentObject(model)
        }
    }

    @ViewBuilder private func section(title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold().foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(names, id: \.self) { name in card(name) }
            }
        }
    }

    private func card(_ name: String) -> some View {
        let theme = name == "Implicit" ? nil : TerminalThemes.theme(named: name)
        let isSelected = model.terminalTheme == name
        return VStack(spacing: 4) {
            ThemeSwatchView(theme: theme)
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            Text(name).font(.caption2).lineLimit(1).truncationMode(.middle)
        }
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.terminalTheme = name }
        .contextMenu {
            if let theme {
                Button(t("Theme.Customize")) {
                    customizeBaseName = name
                    customizeTheme = theme
                }
            }
            if model.customThemes[name] != nil {
                Button(t("Theme.Delete"), role: .destructive) { model.deleteCustomTheme(name) }
            }
        }
    }
}

/// Wraps a `TerminalTheme` with the name it's based on, just so `.sheet(item:)`
/// (which needs `Identifiable`) can carry both in one optional binding.
private struct IdentifiedTheme: Identifiable {
    let name: String
    let theme: TerminalTheme
    var id: String { name }
}

/// Start from a template's colors, tweak any of them, save as a new named theme.
struct ThemeCustomizeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let baseName: String
    @State private var theme: TerminalTheme
    @State private var name: String

    init(baseName: String, theme: TerminalTheme) {
        self.baseName = baseName
        _theme = State(initialValue: theme)
        _name = State(initialValue: baseName + " Custom")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Theme.CustomizeTitle")).font(.headline)
            TextField(t("Theme.NameField"), text: $name).textFieldStyle(.roundedBorder)

            HStack(spacing: 24) {
                colorField(t("Theme.Background"), $theme.background)
                colorField(t("Theme.Foreground"), $theme.foreground)
                colorField(t("Theme.Cursor"), $theme.cursor)
                Spacer()
                ThemeSwatchView(theme: theme).frame(width: 80, height: 44)
            }

            Text(t("Theme.AnsiColors")).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                ForEach(0..<16, id: \.self) { i in
                    ColorPicker("", selection: Binding(
                        get: { Color(TerminalThemes.nsColor(theme.ansi[i])) },
                        set: { theme.ansi[i] = TerminalThemes.hex(NSColor($0)) }
                    )).labelsHidden()
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(t("Editor.Discard")) { dismiss() }
                Button(t("Theme.Save")) {
                    model.saveCustomTheme(name: name, theme)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }

    private func colorField(_ label: String, _ hex: Binding<String>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(TerminalThemes.nsColor(hex.wrappedValue)) },
                set: { hex.wrappedValue = TerminalThemes.hex(NSColor($0)) }
            )).labelsHidden()
        }
    }
}
