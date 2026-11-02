// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

func copyStringToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Persistent trailing chat panel (toggled with ⌘L) — shells out to a
/// locally installed, already-logged-in AI CLI (Claude Code / Codex /
/// Gemini). No API key is ever stored by this app; auth is whatever
/// account that CLI is already logged into (each supports a free-tier
/// account). Holds several conversation threads (`model.aiChatSessions`,
/// persisted), switchable from the history popover.
struct AskAIPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var input: String = ""
    @State private var isRunning = false
    @State private var showSessionSwitcher = false
    /// Empty = use that provider's configured default (Settings > AI).
    @State private var selectedModelID: String = ""
    @State private var attachedFile: AttachedFile?
    /// Send the focused terminal's recent output along with the question.
    @State private var includeTerminal = false
    @State private var currentHandle: AIAskHandle?
    /// Set right before cancelling, so the in-flight Task's completion
    /// silently discards the terminated process's result instead of posting
    /// a confusing "error" bubble for something the user asked to stop.
    @State private var isCancelling = false

    private struct AttachedFile {
        let name: String
        let path: String
        let content: String
        let truncated: Bool
    }

    /// Cap on attached-file text folded into the prompt — this is a Q&A
    /// box shelling out to a restricted, read-only CLI call, not a full
    /// agent session, so there's no benefit to sending more than a CLI
    /// would reasonably need to answer a question about the file.
    private static let maxAttachedFileChars = 200_000

    private var enabledProviders: [AIProvider] {
        AIProvider.allCases.filter { model.aiEnabledProviders.contains($0) }
    }
    private var messages: [AIChatMessage] { model.activeAIChatSession?.messages ?? [] }
    /// Once a session has a message, its provider is locked to whichever CLI
    /// answered the first one — each holds its own conversation context via
    /// `--resume`/`-s`, so switching CLIs mid-thread would silently start a
    /// second, disconnected conversation under the same chat title. A brand
    /// new (empty) session has no lock yet, so any provider can still be picked.
    private var lockedProvider: AIProvider? { messages.first?.provider }
    private var effectiveProvider: AIProvider { lockedProvider ?? model.aiProvider }

    private var fullTranscriptText: String {
        messages.map { msg in
            let label: String
            switch msg.role {
            case .user: label = "You"
            case .assistant: label = msg.provider?.displayName ?? "AI"
            case .error: label = "Error"
            }
            return "\(label):\n\(msg.text)"
        }.joined(separator: "\n\n")
    }

    /// One shared radius so bubbles/input/chips/code blocks read as one
    /// consistent shape language instead of a mix of different roundings.
    private static let cornerRadius: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if messages.isEmpty && !isRunning {
                emptyState
            } else {
                history
            }
            Divider()
            inputArea
        }
        .frame(width: model.askAIPanelWidth)
        // Matches the connection sidebar's own background exactly — that's a
        // system ".sidebar" vibrancy material NavigationSplitView applies
        // automatically to its leading column, not a plain solid color, so a
        // flat Color(NSColor.windowBackgroundColor) here looked visibly
        // different even though both were "dark".
        .background {
            if let p = model.themePalette { PixelBackground(palette: p).overlay(p.glass) } else { SidebarMaterialView() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("AskAI.Title")).font(model.themePalette == nil ? .headline : .system(.headline, design: .monospaced))
            Spacer()
            // A real drag-selection spanning every message bubble isn't
            // available in SwiftUI (each bubble is its own isolated
            // `.textSelection` scope, same as why single-message copy needed
            // its own button) — this copies the whole visible conversation
            // in one click instead, which is the reliable way to get it all.
            Button { copyStringToPasteboard(fullTranscriptText) } label: { Image(systemName: "text.badge.checkmark") }
                .buttonStyle(.borderless)
                .help(t("AskAI.CopyAll"))
                .disabled(messages.isEmpty)
            Button { model.newAIChatSession() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help(t("AskAI.NewSession"))
            Button { showSessionSwitcher = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
                .help(t("AskAI.Sessions"))
                .popover(isPresented: $showSessionSwitcher) { sessionSwitcher }
            Button { model.showAskAI = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(t("Common.Close"))
        }
        .padding(10)
    }

    /// Composer footer, below the input box — provider/model picker, attach,
    /// and Ask, all on one bar (mirrors Claude Code's own bottom-of-composer
    /// status bar: model selector + context info in a single row).
    private var composerFooter: some View {
        HStack(spacing: 6) {
            Button { pickFile() } label: { Image(systemName: "paperclip") }
                .buttonStyle(.plain)
                .help(t("AskAI.AttachFile"))
            if model.activeTerminalTitle != nil {
                Button { includeTerminal.toggle() } label: { Image(systemName: "terminal") }
                    .buttonStyle(.plain)
                    .foregroundStyle(includeTerminal ? Color.accentColor : .primary)
                    .help(t("AskAI.TerminalContext"))
            }
            // Explicit width caps (not .fixedSize()) — a menu-style Picker
            // otherwise sizes itself to its WIDEST row across every item,
            // not just the current selection, which was overflowing this
            // panel's width and crowding the Ask button against it.
            Picker("", selection: Binding(
                get: { effectiveProvider },
                set: { if lockedProvider == nil { model.aiProvider = $0 } }
            )) {
                ForEach(enabledProviders) { p in
                    Text(p.displayName).lineLimit(1).tag(p)
                }
            }
            .labelsHidden()
            .frame(width: 108)
            .disabled(lockedProvider != nil)
            .help(lockedProvider != nil ? t("AskAI.ProviderLocked")
                  : (AIAssistant.binaryPath(for: effectiveProvider) != nil ? "" : t("AskAI.NotFound")))
            .onChange(of: effectiveProvider) { _, _ in selectedModelID = "" }
            if !model.models(for: effectiveProvider).isEmpty {
                Picker("", selection: $selectedModelID) {
                    Text(t("Settings.AIModelPlaceholder")).lineLimit(1).tag("")
                    ForEach(model.models(for: effectiveProvider)) { entry in
                        Text(entry.displayName).lineLimit(1).tag(entry.modelID)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
            }
            Spacer(minLength: 4)
            if isRunning {
                Button { stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help(t("AskAI.Stop"))
            } else {
                // Enter alone sends (see ComposerTextView); this is just the
                // mouse-driven equivalent, so no keyboard shortcut duplicated here.
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    .disabled(!canSend)
                    .help(t("AskAI.Ask"))
            }
        }
    }

    private func stop() {
        isCancelling = true
        currentHandle?.cancel()
        isRunning = false
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    private var sessionSwitcher: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.aiChatSessions.isEmpty {
                Text(t("AskAI.NoSessions"))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14)
            } else {
                List {
                    ForEach(model.aiChatSessions) { session in
                        Button {
                            model.activeAIChatSessionID = session.id
                            showSessionSwitcher = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title.isEmpty ? t("AskAI.NewSession") : session.title)
                                        .lineLimit(1)
                                        .fontWeight(session.id == model.activeAIChatSessionID ? .semibold : .regular)
                                    Text(session.updatedAt, style: .relative)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.id == model.activeAIChatSessionID {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { model.deleteAIChatSession(session.id) } label: {
                                Label(t("AskAI.DeleteSession"), systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(model.aiChatSessions.count) * 44 + 8, 320))
            }
        }
        .frame(width: 260)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Color.accentColor)
            Text(t("AskAI.Welcome")).font(.title3.bold())
            Text(t("AskAI.Hint")).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["AskAI.Suggest1", "AskAI.Suggest2", "AskAI.Suggest3"], id: \.self) { key in
                    Button {
                        input = t(key)
                        if model.activeTerminalTitle != nil, key != "AskAI.Suggest2" { includeTerminal = true }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lightbulb").foregroundStyle(.secondary)
                            Text(t(key)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).stroke(Color.secondary.opacity(0.2)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack (not LazyVStack) on purpose — a lazy stack can
                // tear down and recreate rows as they scroll in/out, which was
                // resetting text selection mid-drag. Chat history here is never
                // large enough to need lazy loading.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { msg in
                        bubble(msg).id(msg.id.uuidString)
                    }
                    if isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(t("AskAI.Asking")).font(.caption).foregroundStyle(.secondary)
                        }
                        .id("running")
                    }
                }
                .padding(10)
            }
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: isRunning) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let targetID = isRunning ? "running" : messages.last?.id.uuidString
        guard let targetID else { return }
        if animated {
            withAnimation { proxy.scrollTo(targetID, anchor: .bottom) }
        } else {
            proxy.scrollTo(targetID, anchor: .bottom)
        }
    }

    @ViewBuilder private func bubble(_ msg: AIChatMessage) -> some View {
        switch msg.role {
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                Label(t("AskAI.You"), systemImage: "person.crop.circle.fill")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                MarkdownMessageView(text: msg.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).stroke(Color.accentColor.opacity(0.35)))
                    .pixelBox(model.themePalette, fill: model.themePalette?.active)
                    // Right-click always copies the full message, even where
                    // drag-select-then-⌘C fights the composer for first responder.
                    .contextMenu {
                        Button(t("AskAI.CopyResponse")) { copyToClipboard(msg.text) }
                        Button(t("AskAI.EditResend")) { input = msg.text }
                    }
            }
        case .assistant:
            // Copilot-chat style: no bubble, full width, provider header + action footer.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    Text(msg.provider?.displayName ?? "AI").font(.caption.bold())
                    Text(msg.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                MarkdownMessageView(text: msg.text)
                    .contextMenu {
                        Button(t("AskAI.CopyResponse")) { copyToClipboard(msg.text) }
                    }
                HStack(spacing: 10) {
                    Button { copyToClipboard(msg.text) } label: { Image(systemName: "doc.on.doc") }
                        .help(t("AskAI.CopyResponse"))
                    if msg.id == messages.last?.id, let prompt = messages.last(where: { $0.role == .user })?.text {
                        Button { input = prompt } label: { Image(systemName: "arrow.uturn.backward") }
                            .help(t("AskAI.EditResend"))
                    }
                    if let usage = msg.usage, usage.usedTokens != nil || usage.costUSD != nil {
                        usageCaption(usage)
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .error:
            Label {
                Text(msg.text).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .contextMenu {
                Button(t("AskAI.CopyResponse")) { copyToClipboard(msg.text) }
            }
        }
    }

    /// Real numbers a CLI actually reported for that turn — never estimated.
    private func usageCaption(_ usage: AIUsageStats) -> some View {
        var parts: [String] = []
        if let used = usage.usedTokens {
            if let pct = usage.percentOfContext {
                parts.append(String(format: "%@ tok (%.1f%% ctx)", Self.formatCount(used), pct))
            } else {
                parts.append("\(Self.formatCount(used)) tok")
            }
        }
        if let cost = usage.costUSD, cost > 0 {
            parts.append(String(format: "$%.4f", cost))
        }
        if let ms = usage.durationMs {
            parts.append(String(format: "%.1fs", Double(ms) / 1000))
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func copyToClipboard(_ text: String) {
        copyStringToPasteboard(text)
    }

    private static func formatCount(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: - Input

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachedFile {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.caption)
                    Text(attachedFile.name).font(.caption).lineLimit(1)
                    if attachedFile.truncated {
                        Text(t("AskAI.FileTruncated")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { self.attachedFile = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
            if includeTerminal, let title = model.activeTerminalTitle {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.caption)
                    Text(String(format: t("AskAI.TerminalChip"), title)).font(.caption).lineLimit(1)
                    Spacer()
                    Button { includeTerminal = false } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
            // One unified rounded container — text field and the model/attach/send
            // footer share a single border, matching a Claude-Code-style composer,
            // instead of two separately-boxed pieces stacked on top of each other.
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text(t("AskAI.InputPlaceholder"))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(text: $input, onSubmit: send)
                        .frame(height: 72)
                }
                composerFooter
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).stroke(Color.secondary.opacity(0.3)))
            .pixelBox(model.themePalette, fill: model.themePalette?.glassStrong)
        }
        .padding(10)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            attachedFile = AttachedFile(name: url.lastPathComponent, path: url.path,
                                         content: "", truncated: false)
            return
        }
        let truncated = raw.count > Self.maxAttachedFileChars
        let content = truncated ? String(raw.prefix(Self.maxAttachedFileChars)) : raw
        attachedFile = AttachedFile(name: url.lastPathComponent, path: url.path, content: content, truncated: truncated)
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isRunning else { return }
        input = ""
        let file = attachedFile
        attachedFile = nil
        let provider = effectiveProvider
        let sessionID = model.ensureActiveAIChatSession()
        let terminalTitle = includeTerminal ? model.activeTerminalTitle : nil
        let terminalOutput = terminalTitle != nil ? model.activeTerminalOutput() : nil
        includeTerminal = false
        var displayText = file.map { "\(q)\n\n📎 \($0.name)" } ?? q
        if let terminalTitle { displayText += "\n\n🖥 \(terminalTitle)" }
        model.appendAIChatMessage(AIChatMessage(role: .user, text: displayText, provider: provider), toSession: sessionID)
        // The file's content only goes to the CLI, not the chat bubble — keeps
        // the visible transcript readable while still giving the model the text.
        var sendPrompt = q
        if let file {
            sendPrompt = "<file path=\"\(file.path)\">\n\(file.content)\n</file>\n\n\(sendPrompt)"
        }
        if let terminalTitle, let terminalOutput {
            sendPrompt = "<terminal session=\"\(terminalTitle)\">\n\(terminalOutput)\n</terminal>\n\n\(sendPrompt)"
        }
        isRunning = true
        isCancelling = false
        let modelOverride = selectedModelID.isEmpty ? model.defaultModelID(for: provider) : selectedModelID
        let cliPath = model.aiCLIPath(for: provider)
        let extraEnv = model.aiEnvironment(for: provider)
        let handle = AIAskHandle()
        currentHandle = handle
        // Continues that provider's own conversation for this chat thread
        // (nil on the very first turn, or a brand-new "New chat") instead of
        // starting fresh every message.
        let resumeToken = model.providerSessionToken(for: provider, sessionID: sessionID)
        Task {
            let result = await AIAssistant.ask(provider, prompt: sendPrompt, model: modelOverride,
                                                cliPath: cliPath.isEmpty ? nil : cliPath, extraEnv: extraEnv,
                                                resumeToken: resumeToken, handle: handle)
            await MainActor.run {
                currentHandle = nil
                isRunning = false
                guard !isCancelling else {
                    isCancelling = false
                    return
                }
                switch result {
                case .success(let answer):
                    model.setProviderSessionToken(answer.sessionToken, for: provider, sessionID: sessionID)
                    model.appendAIChatMessage(
                        AIChatMessage(role: .assistant, text: answer.text, provider: provider, usage: answer.usage),
                        toSession: sessionID)
                case .failure(let err):
                    model.appendAIChatMessage(AIChatMessage(role: .error, text: err.message, provider: provider), toSession: sessionID)
                }
            }
        }
    }
}

/// Renders chat markdown block by block (headings, lists, task lists, quotes,
/// tables, rules, fenced code) — native `AttributedString(markdown:)` for the
/// inline parts, no external Markdown package. Code blocks get Copy plus
/// Insert / Run into the focused terminal, Copilot-chat style.
struct MarkdownMessageView: View {
    @EnvironmentObject var model: AppModel
    let text: String

    enum Block: Equatable {
        case paragraph(String)
        case heading(Int, String)
        case listItem(indent: Int, marker: String, checked: Bool?, text: String)
        case quote(String)
        case code(String?, String)
        case table([String], [[String]])
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.renderInline(s)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(Self.renderInline(s))
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
                .textSelection(.enabled)
        case .listItem(let indent, let marker, let checked, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                } else {
                    Text(marker).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(Self.renderInline(s)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let s):
            Text(Self.renderInline(s))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3) }
        case .code(let lang, let code):
            codeBlock(lang: lang, code: code)
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    // MARK: Parsing

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if trimmed.hasPrefix("```") {
                flush()
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1 // closing fence (or past the end if the reply was cut off)
                blocks.append(.code(lang.isEmpty ? nil : lang, code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let m = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(m.1.count, String(m.2)))
            } else if trimmed.wholeMatch(of: /([-*_])\s*(\1\s*){2,}/) != nil {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                if !para.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let m = line.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                let indent = m.1.replacingOccurrences(of: "\t", with: "  ").count / 2
                var body = String(m.3)
                var checked: Bool?
                if let task = body.firstMatch(of: /^\[([ xX])\]\s+(.*)$/) {
                    checked = task.1 != " "
                    body = String(task.2)
                }
                let marker = m.2.first?.isNumber == true ? String(m.2) : "•"
                blocks.append(.listItem(indent: indent, marker: marker, checked: checked, text: body))
            } else if trimmed.hasPrefix("|"), i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).wholeMatch(of: /\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?/) != nil {
                flush()
                let header = cells(trimmed)
                i += 1 // separator row
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                blocks.append(.table(header, rows))
            } else {
                if !quote.isEmpty { flush() }
                para.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderInline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    // MARK: Pieces

    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, c in
                    Text(Self.renderInline(c)).bold()
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<header.count, id: \.self) { col in
                        Text(Self.renderInline(col < row.count ? row[col] : "")).textSelection(.enabled)
                    }
                }
            }
        }
        .font(.callout)
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private static let shellLangs: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "fish",
                                                  "powershell", "ps1", "pwsh", "cmd", "bat"]

    @ViewBuilder private func codeBlock(lang: String?, code: String) -> some View {
        let canRun = model.activeTerminalTitle != nil && Self.shellLangs.contains((lang ?? "").lowercased())
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(lang ?? "code").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if canRun {
                    Button { model.sendToActiveTerminal(code, execute: false) } label: {
                        Image(systemName: "text.insert")
                    }
                    .help(t("AskAI.Insert"))
                    Button { model.sendToActiveTerminal(code, execute: true) } label: {
                        Label(t("AskAI.RunShort"), systemImage: "play.fill")
                    }
                    .help(t("AskAI.Run"))
                }
                // A dedicated copy button per code block — dragging a selection
                // inside the block is unreliable, this always works.
                Button { copyStringToPasteboard(code) } label: { Image(systemName: "doc.on.doc") }
                    .help(t("AskAI.CopyResponse"))
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))
            // Wrap instead of horizontal-scroll: a competing horizontal drag
            // gesture was hiding the text mid-selection.
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .pixelBox(model.themePalette, fill: model.themePalette?.glassStrong, lift: 2)
    }
}

/// A borderless multi-line text view where plain Return sends (via
/// `onSubmit`) and Shift+Return inserts a newline — SwiftUI's `TextEditor`
/// has no way to distinguish the two, so this wraps `NSTextView` directly.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitOnEnterTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SubmitOnEnterTextView else { return }
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}

private final class SubmitOnEnterTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76 // Return / numpad Enter
        if isReturnKey, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

/// The exact vibrancy macOS gives a `NavigationSplitView`'s sidebar column —
/// used so the Ask AI panel's background matches the connection sidebar
/// pixel-for-pixel instead of approximating it with a flat color.
struct SidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // The real sidebar dims to a duller gray whenever the window isn't
        // key (standard macOS behavior for every sidebar/toolbar) — forcing
        // `.active` here kept this panel permanently vibrant instead, so it
        // visibly diverged from the sidebar's own look the moment the window
        // lost focus. `.followsWindowActiveState` is the default; matching it
        // explicitly keeps both panels dimming together, never independently.
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
