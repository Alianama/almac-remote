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
        .background(SidebarMaterialView())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("AskAI.Title")).font(.headline)
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
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(t("AskAI.Placeholder")).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)
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
            HStack {
                Spacer(minLength: 30)
                MarkdownMessageView(text: msg.text)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    // Guaranteed to work even where drag-select-then-⌘C doesn't
                    // (that path fights the composer's own text view for first
                    // responder) — right-click always copies the full message.
                    .contextMenu {
                        Button(t("AskAI.CopyResponse")) { copyToClipboard(msg.text) }
                    }
            }
        case .assistant:
            VStack(alignment: .trailing, spacing: 3) {
                HStack {
                    MarkdownMessageView(text: msg.text)
                        .padding(8)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                        .contextMenu {
                            Button(t("AskAI.CopyResponse")) { copyToClipboard(msg.text) }
                        }
                    Spacer(minLength: 30)
                }
                HStack(spacing: 6) {
                    if let usage = msg.usage, usage.usedTokens != nil || usage.costUSD != nil {
                        usageCaption(usage)
                    }
                    Button { copyToClipboard(msg.text) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(t("AskAI.CopyResponse"))
                }
                .padding(.trailing, 4)
            }
        case .error:
            HStack {
                Text(msg.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .contextMenu {
                        Button(t("AskAI.CopyResponse")) { copyToClipboard(msg.text) }
                    }
                Spacer(minLength: 30)
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
        let displayText = file.map { "\(q)\n\n📎 \($0.name)" } ?? q
        model.appendAIChatMessage(AIChatMessage(role: .user, text: displayText, provider: provider), toSession: sessionID)
        // The file's content only goes to the CLI, not the chat bubble — keeps
        // the visible transcript readable while still giving the model the text.
        let sendPrompt: String
        if let file {
            sendPrompt = "<file path=\"\(file.path)\">\n\(file.content)\n</file>\n\n\(q)"
        } else {
            sendPrompt = q
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

/// Renders chat text as light markdown (bold/italic/links/inline code) with
/// fenced ``` code blocks ``` broken out into their own monospaced,
/// horizontally-scrollable boxes — native `AttributedString(markdown:)`,
/// no external Markdown package needed.
struct MarkdownMessageView: View {
    let text: String

    private enum Segment { case text(String), code(String?, String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let s):
                    if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(Self.renderInline(s)).textSelection(.enabled)
                    }
                case .code(let lang, let code):
                    codeBlock(lang: lang, code: code)
                }
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var remaining = ArraySlice(text.components(separatedBy: "\n"))
        var textLines: [String] = []
        while let line = remaining.first {
            remaining = remaining.dropFirst()
            if line.hasPrefix("```") {
                if !textLines.isEmpty {
                    result.append(.text(textLines.joined(separator: "\n")))
                    textLines = []
                }
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                while let codeLine = remaining.first, !codeLine.hasPrefix("```") {
                    codeLines.append(codeLine)
                    remaining = remaining.dropFirst()
                }
                if remaining.first?.hasPrefix("```") == true { remaining = remaining.dropFirst() }
                result.append(.code(lang.isEmpty ? nil : lang, codeLines.joined(separator: "\n")))
            } else {
                textLines.append(line)
            }
        }
        if !textLines.isEmpty { result.append(.text(textLines.joined(separator: "\n"))) }
        return result
    }

    private static func renderInline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    @ViewBuilder private func codeBlock(lang: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let lang {
                    Text(lang).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                // A dedicated copy button per code block — a horizontal-drag
                // selection here fights the block's own horizontal scrolling
                // (same class of bug the outer chat history's LazyVStack had),
                // so this is the one guaranteed-reliable way to grab the code.
                Button { copyStringToPasteboard(code) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(t("AskAI.CopyResponse"))
            }
            // Wrap instead of horizontal-scroll: removes the competing
            // horizontal-drag gesture entirely, which was also intermittently
            // hiding the text mid-selection, not just blocking the copy.
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
