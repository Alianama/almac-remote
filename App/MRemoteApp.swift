// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

@main
struct MRemoteApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var lang = LanguageManager.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // Faster tooltips (macOS default is around 2 seconds).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
        // SwiftUI's Settings scene refuses manual resize; we use a Window(id:)
        // for preferences instead. Disable automatic window tabbing so the
        // preferences window can't be merged into a tab group (must be in init,
        // applicationDidFinishLaunching is too late).
        NSWindow.allowsAutomaticWindowTabbing = false
        // Load OpenSSL's legacy provider so NTLM (MD4) works for RDP against
        // non-AD Windows hosts — otherwise NLA fails with a misleading
        // "transport failed". Must run before the first connection.
        RDPClient.initCrypto()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(lang)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(t("Menu.About")) { AboutPanel.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button(t("Settings.Title")) { openWindow(id: "preferences") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(t("Menu.HelpWindow")) { HelpWindow.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button(t("Menu.NewFile")) { model.newDocumentPanel() }
                    .keyboardShortcut("n")
                Button(t("Menu.OpenFile")) { model.openFilePanel() }
                    .keyboardShortcut("o")
                Divider()
                Button(t("Menu.NewLocalTerminal")) { model.openLocalTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button(t("Menu.CloseFile")) { model.closeDocument() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.doc == nil)
            }
            CommandGroup(after: .toolbar) {
                Button(t("Menu.ZoomIn")) { model.zoomTerminal(+1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button(t("Menu.ZoomOut")) { model.zoomTerminal(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button(t("Terminal.SplitRight")) { model.splitSelectedSession(direction: .horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.canSplitSelectedSession(direction: .horizontal))
                Button(t("Terminal.SplitDown")) { model.splitSelectedSession(direction: .vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.canSplitSelectedSession(direction: .vertical))
            }
            CommandMenu(t("AskAI.Menu")) {
                Button { model.showAskAI.toggle() } label: { Label(t("AskAI.Title"), systemImage: "sparkles") }
                    .keyboardShortcut("l", modifiers: .command)
            }
            CommandMenu(t("Logs.Menu")) {
                Button { openWindow(id: "logs") } label: { Label(t("Logs.Show"), systemImage: "doc.text.magnifyingglass") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu(t("Security.Menu")) {
                Button { model.lockNow() } label: { Label(t("Security.LockNow"), systemImage: "lock.fill") }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!model.lockEnabled || model.isLocked)
                Divider()
                Toggle(isOn: $model.lockEnabled) { Label(t("Security.LockWhenIdle"), systemImage: "lock.badge.clock") }
                Picker(selection: $model.idleLockMinutes) {
                    Text(t("Security.1Minute")).tag(1.0)
                    Text(t("Security.5Minutes")).tag(5.0)
                    Text(t("Security.15Minutes")).tag(15.0)
                    Text(t("Security.30Minutes")).tag(30.0)
                } label: { Label(t("Security.IdleTimeout"), systemImage: "timer") }
                .disabled(!model.lockEnabled)
                Divider()
                Button { model.beginChangeMasterPassword() } label: {
                    Label(t("Security.ChangeMasterPassword"), systemImage: "key.fill")
                }
            }
        }

        // A real Window (not the Settings scene) so it can be resized manually.
        Window(t("Settings.Title"), id: "preferences") {
            SettingsView()
                .environmentObject(model)
                .environmentObject(lang)
        }
        .windowResizability(.contentMinSize)

        Window(t("Authenticator.Title"), id: "authenticator") {
            AuthenticatorWindowView()
                .environmentObject(model)
                .environmentObject(lang)
        }
        .windowResizability(.contentMinSize)

        Window(t("Logs.Title"), id: "logs") {
            LogsWindowView()
        }
        .windowResizability(.contentMinSize)
    }
}

struct SettingsView: View {
    // Observe so all tab labels re-evaluate t(...) on language change.
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label(t("Settings.Appearance"), systemImage: "paintbrush") }
            ToolsSettings()
                .tabItem { Label(t("Settings.Tools"), systemImage: "wrench.and.screwdriver") }
            AISettings()
                .tabItem { Label(t("Settings.AI"), systemImage: "sparkles") }
            LanguageSettings()
                .tabItem { Label(t("Settings.Language"), systemImage: "globe") }
        }
        // Min + ideal only (no max) so the preferences Window can be dragged
        // freely larger; .windowResizability(.contentMinSize) on the scene keeps
        // the min. The grouped Forms scroll inside each tab.
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 600)
        .id(lang.choice) // force SwiftUI to rebuild tab item labels on switch
    }
}

struct AppearanceSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section(t("Settings.Appearance")) {
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.UIFontSize"), Int(model.uiFontSize)))
                    Slider(value: $model.uiFontSize, in: 10...22, step: 1)
                }
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.TerminalFontSize"), Int(model.terminalFontSize)))
                    Slider(value: $model.terminalFontSize, in: 8...28, step: 1)
                }
                Picker(t("Settings.CursorBlink"), selection: $model.cursorBlinkSpeed) {
                    ForEach(CursorBlinkSpeed.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                Toggle(t("Settings.UpdateTabTitleFromTerminal"), isOn: $model.updateTabTitleFromTerminal)
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.RowHeight"), Int(model.rowHeight)))
                    Slider(value: $model.rowHeight, in: 16...44, step: 1)
                }
                VStack(alignment: .leading) {
                    Text(String(format: t("Settings.TerminalScrollback"), Int(model.terminalScrollback)))
                    Slider(value: $model.terminalScrollback, in: 500...50_000, step: 500)
                }
                Toggle(t("Settings.ShowProtocol"), isOn: $model.showProtocol)
                Toggle(t("Settings.CloseTabOnDisconnect"), isOn: $model.closeTabOnDisconnect)
                Toggle(t("Settings.RestoreSessions"), isOn: $model.restoreSessions)
                Toggle(t("Settings.ShowPasswordPlain"), isOn: $model.showPasswordPlain)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(t("Settings.DiagnosticLogging"), isOn: $model.diagnosticLogging)
                    if model.diagnosticLogging {
                        HStack {
                            Text(t("Settings.DiagnosticLoggingNote"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(t("Settings.RevealLog")) {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppModel.logDirectory.path)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolsSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Settings.ToolsMacros"))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach($model.externalTools) { $tool in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(t("Settings.ToolNamePlaceholder"), text: $tool.name)
                            Button(role: .destructive) { model.deleteTool(tool) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                        TextField(t("Settings.ToolCommandPlaceholder"), text: $tool.commandLine)
                            .font(.system(.callout, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
            Button { model.addTool() } label: { Label(t("Settings.ToolAdd"), systemImage: "plus") }
        }
        .padding()
    }
}

struct AISettings: View {
    @State private var selectedProvider: AIProvider = .claude
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedProvider) {
                ForEach(AIProvider.allCases) { p in Text(p.displayName).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 14)
            .padding(.bottom, 6)
            AIProviderSettingsView(provider: selectedProvider)
                .id(selectedProvider) // reset per-provider @State (new-model fields) on tab switch
        }
    }
}

/// Setup / Models / Environment for one AI CLI provider — the "practical
/// subset" of Claudian's per-provider config: no Skills/Subagents/MCP here,
/// since those need a project/vault concept this app doesn't have.
struct AIProviderSettingsView: View {
    @EnvironmentObject var model: AppModel
    let provider: AIProvider
    @State private var newModelID: String = ""
    @State private var newModelAlias: String = ""
    @State private var discovered: [AIModelEntry] = []
    @State private var discoveryMessage: String?

    private var installed: Bool { AIAssistant.binaryPath(for: provider) != nil }
    private var enabled: Bool { model.aiEnabledProviders.contains(provider) }

    var body: some View {
        Form {
            Section(t("Settings.AISetup")) {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { on in
                        if on { model.aiEnabledProviders.insert(provider) }
                        else if model.aiEnabledProviders.count > 1 { model.aiEnabledProviders.remove(provider) }
                    }
                )) {
                    HStack(spacing: 4) {
                        Text(String(format: t("Settings.AIEnable"), provider.displayName))
                        if !installed {
                            Text("(\(t("AskAI.NotFound")))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text(t("Settings.AICLIPath")).frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                    TextField(AIAssistant.binaryPath(for: provider) ?? provider.rawValue, text: Binding(
                        get: { model.aiCLIPath(for: provider) },
                        set: { model.setAICLIPath($0, for: provider) }
                    )).textFieldStyle(.roundedBorder)
                }
                Text(t("Settings.AICLIPathNote")).font(.caption2).foregroundStyle(.secondary)
            }

            if enabled {
                Section(t("Settings.AIModels")) {
                    HStack {
                        Button { discover() } label: {
                            Label(t("Settings.AIDiscover"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        Spacer()
                    }
                    if let discoveryMessage {
                        Text(discoveryMessage).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(newlyDiscovered) { entry in
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName)
                                Text(entry.modelID).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { addDiscovered(entry) } label: { Image(systemName: "plus.circle") }
                                .buttonStyle(.borderless)
                                .help(t("Settings.AIAddModel"))
                        }
                    }
                    if !model.models(for: provider).isEmpty || !newlyDiscovered.isEmpty {
                        Divider()
                    }
                    ForEach(model.models(for: provider)) { entry in
                        HStack {
                            Button {
                                model.setDefaultModel(entry.modelID, for: provider)
                            } label: {
                                Image(systemName: model.defaultModelID(for: provider) == entry.modelID ? "star.fill" : "star")
                                    .foregroundStyle(model.defaultModelID(for: provider) == entry.modelID ? .yellow : .secondary)
                            }.buttonStyle(.plain).help(t("Settings.AISetDefault"))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.displayName)
                                if !entry.alias.isEmpty {
                                    Text(entry.modelID).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) { removeModel(entry) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField(t("Settings.AIModelIDPlaceholder"), text: $newModelID)
                            .textFieldStyle(.roundedBorder)
                        TextField(t("Settings.AIModelAliasPlaceholder"), text: $newModelAlias)
                            .textFieldStyle(.roundedBorder)
                        Button { addModel() } label: { Image(systemName: "plus") }
                            .disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(t("Settings.AIModelsNote")).font(.caption2).foregroundStyle(.secondary)
                }

                Section(t("Settings.AIEnvironment")) {
                    Text(t("Settings.AIEnvironmentNote")).font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { model.aiEnvironmentText(for: provider) },
                        set: { model.setAIEnvironmentText($0, for: provider) }
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Discovered models not already in this provider's configured list.
    private var newlyDiscovered: [AIModelEntry] {
        let existing = Set(model.models(for: provider).map(\.modelID))
        return discovered.filter { !existing.contains($0.modelID) }
    }

    private func discover() {
        switch AIModelDiscovery.discover(for: provider) {
        case .success(let entries):
            discovered = entries
            discoveryMessage = nil
        case .failure(let error):
            discovered = []
            discoveryMessage = error.message
        }
    }

    private func addDiscovered(_ entry: AIModelEntry) {
        var list = model.models(for: provider)
        guard !list.contains(where: { $0.modelID == entry.modelID }) else { return }
        list.append(entry)
        model.setModels(list, for: provider)
    }

    private func addModel() {
        let id = newModelID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        var list = model.models(for: provider)
        list.append(AIModelEntry(modelID: id, alias: newModelAlias.trimmingCharacters(in: .whitespaces)))
        model.setModels(list, for: provider)
        newModelID = ""
        newModelAlias = ""
    }

    private func removeModel(_ entry: AIModelEntry) {
        model.setModels(model.models(for: provider).filter { $0.id != entry.id }, for: provider)
        if model.defaultModelID(for: provider) == entry.modelID {
            model.setDefaultModel("", for: provider)
        }
    }
}

struct LanguageSettings: View {
    @EnvironmentObject var lang: LanguageManager
    var body: some View {
        Form {
            Section(t("Settings.Language")) {
                Picker(t("Settings.LanguagePicker"), selection: $lang.choice) {
                    ForEach(LanguageManager.Choice.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)
                Text(t("Settings.LanguageNote"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
