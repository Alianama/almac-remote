// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import SwiftTerm
import AppKit

/// Cursor blink speed for the embedded terminal. `off` = steady block, no blink.
enum CursorBlinkSpeed: String, CaseIterable, Identifiable {
    case off, slow, medium, fast
    var id: String { rawValue }
    /// Localized label used in Settings.
    var label: String {
        switch self {
        case .off:    return t("Blink.Off")
        case .slow:   return t("Blink.Slow")
        case .medium: return t("Blink.Medium")
        case .fast:   return t("Blink.Fast")
        }
    }
    /// Opacity-animation duration (auto-reverses). Only meaningful when != off.
    var duration: CFTimeInterval {
        switch self {
        case .off: return 0
        case .slow: return 1.2
        case .medium: return 0.7
        case .fast: return 0.3
        }
    }
}

/// Terminal with PuTTY-style behavior: copy-on-select + right-click paste.
///
/// In addition:
///   * **Auto-scroll while drag-selecting** when the cursor leaves the view
///     vertically. SwiftTerm sets `autoScrollDelta` in `mouseDragged` but does
///     not schedule the consuming timer (upstream bug). We schedule it here
///     and re-post a synthetic drag at each tick so the selection extends
///     over the newly-revealed lines.
///   * **Configurable cursor blink speed**. SwiftTerm hardcodes the animation
///     duration to 0.7s in `MacCaretView.updateAnimation` and `caretView` is
///     `internal`, so we reach it via `Mirror` and override the layer
///     animation directly. DECSCUSR is used for steady vs blink toggle.
///   * **Dynamic tab title** via OSC 0/1/2 — delegated to a `TerminalCoordinator`
///     stored on the SwiftUI Coordinator so that `setTerminalTitle` can flow
///     into the model and re-render the SessionTabBar.
final class MRNGTerminalView: LocalProcessTerminalView {
    /// Set once `startProcess` has actually been called — lets `TerminalContainer`
    /// defer the spawn while a proxy tunnel is still connecting.
    var started = false
    /// Notifies `TerminalContainer` when this specific pane gains keyboard focus —
    /// used to track which pane is focused when a tab is split into two.
    var onFocus: (() -> Void)?
    private var mouseUpMonitor: Any?
    private var autoScrollTimer: Timer?
    private var lastDragWindowLocation: NSPoint?
    /// > 0 = scroll DOWN (cursor below view, want newer content),
    /// < 0 = scroll UP (cursor above view, want older content).
    private var autoScrollLinesPerTick: Int = 0
    /// Re-applies blink animation after focus changes (SwiftTerm resets it in
    /// `becomeFirstResponder`).
    private var focusObserver: Any?
    private var currentBlinkSpeed: CursorBlinkSpeed = .medium

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPuttyMouse()
        installFocusObserver()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPuttyMouse()
        installFocusObserver()
    }

    private func setupPuttyMouse() {
        let rightClick = NSClickGestureRecognizer(target: self, action: #selector(rightClickPaste))
        rightClick.buttonMask = 0x2 // right button only (left stays for selection)
        addGestureRecognizer(rightClick)

        // Observe left mouse down/drag/up: down reports which pane got clicked (for
        // split-tab focus tracking, since we can't override becomeFirstResponder —
        // it's not `open` in SwiftTerm), drag drives auto-scroll, up triggers
        // copy-on-select. SwiftTerm processes them too — we don't consume the event.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .leftMouseDown:
                let pt = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(pt) { self.onFocus?() }
            case .leftMouseUp:
                self.stopAutoScroll()
                if self.selectionActive {
                    let pt = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(pt),
                       let text = self.getSelection(), !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            case .leftMouseDragged:
                self.handleDragForAutoScroll(event: event)
            default:
                break
            }
            return event
        }
    }

    @objc private func rightClickPaste() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            send(txt: text)
        }
    }

    // MARK: - Auto-scroll during drag selection

    private func handleDragForAutoScroll(event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        lastDragWindowLocation = event.locationInWindow
        // NSView is non-flipped: y=0 is bottom. Below view → pt.y < 0.
        // Above view → pt.y > bounds.height.
        let edgeMargin: CGFloat = 6
        if pt.y < edgeMargin {
            let dist = max(0, edgeMargin - pt.y)
            autoScrollLinesPerTick = max(1, Int(dist / 10) + 1)
            startAutoScrollIfNeeded()
        } else if pt.y > bounds.height - edgeMargin {
            let dist = max(0, pt.y - (bounds.height - edgeMargin))
            autoScrollLinesPerTick = -max(1, Int(dist / 10) + 1)
            startAutoScrollIfNeeded()
        } else {
            stopAutoScroll()
        }
    }

    private func startAutoScrollIfNeeded() {
        if autoScrollTimer != nil { return }
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickAutoScroll()
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollLinesPerTick = 0
    }

    private func tickAutoScroll() {
        let n = autoScrollLinesPerTick
        if n == 0 { return }
        if n > 0 { scrollDown(lines: n) } else { scrollUp(lines: -n) }
        // Post a synthetic drag at the same window location. After the scroll the
        // row-buffer under the cursor has changed, so SwiftTerm.dragExtend will
        // extend the selection by N rows. We can't call super.mouseDragged because
        // it's `public` (not `open`).
        guard let win = window, let loc = lastDragWindowLocation else { return }
        if let synth = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: loc,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) {
            NSApp.postEvent(synth, atStart: false)
        }
    }

    // MARK: - Cursor blink speed

    /// Applies the blink speed. Off → DECSCUSR steady block. Slow/Medium/Fast →
    /// DECSCUSR blink block + custom CABasicAnimation on the (internal) caretView
    /// reached via reflection.
    func applyCursorBlinkSpeed(_ speed: CursorBlinkSpeed) {
        currentBlinkSpeed = speed
        // DECSCUSR: 2 = steady block, 1 = blink block.
        let code: String = (speed == .off) ? "\u{1B}[2 q" : "\u{1B}[1 q"
        terminal.feed(text: code)
        DispatchQueue.main.async { [weak self] in self?.reapplyCursorAnimation() }
    }

    private func reapplyCursorAnimation() {
        let mirror = Mirror(reflecting: self)
        guard let cv = mirror.children.first(where: { $0.label == "caretView" })?.value as? NSView,
              let layer = cv.layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        guard currentBlinkSpeed != .off else { return }
        let anim = CABasicAnimation(keyPath: #keyPath(CALayer.opacity))
        anim.duration = currentBlinkSpeed.duration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(anim, forKey: #keyPath(CALayer.opacity))
    }

    /// SwiftTerm calls `caretView.updateCursorStyle()` in `becomeFirstResponder`
    /// (line 723 in MacTerminalView.swift), which resets the animation to its
    /// default 0.7s. Re-apply on any key-window change.
    private func installFocusObserver() {
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.reapplyCursorAnimation() }
        }
    }

    deinit {
        autoScrollTimer?.invalidate()
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        if let o = focusObserver { NotificationCenter.default.removeObserver(o) }
    }
}

/// Separate delegate so that PuttyTerminalView isn't its own processDelegate —
/// avoids infinite recursion in MacLocalTerminalView, which forwards
/// `hostCurrentDirectoryUpdate` / `processTerminated` to `processDelegate`.
final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    var onTitleChange: (String) -> Void = { _ in }
    var onProcessExit: (Int32?) -> Void = { _ in }
    var onFocus: () -> Void = {}
    /// The actual terminal view, since `TerminalContainer` now hands SwiftUI a
    /// plain wrapper (for the top/side inset) instead of the terminal itself.
    weak var terminal: MRNGTerminalView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [self] in onProcessExit(exitCode) }
    }
    /// SwiftTerm receives OSC 0/1/2 (set window title) and forwards here.
    /// On SSH remote, the remote shell's precmd writes "user@host:cwd" →
    /// arrives here and the tab title updates live.
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange(title)
    }
}

/// Keeps each session's live terminal NSView (and its running ssh/shell process)
/// around by session id, independent of where SwiftUI currently mounts it.
/// Splitting a tab moves its `TerminalContainer` into a new HSplitView/VSplitView
/// parent, which SwiftUI treats as a different view tree and would otherwise
/// call `makeNSView` again — restarting the process and forcing a fresh login.
/// `AppModel.closeSession`/`reconnect` call `remove(_:)` when a session should
/// actually go away.
@MainActor
final class TerminalViewRegistry {
    static let shared = TerminalViewRegistry()
    private var entries: [UUID: (container: NSView, term: MRNGTerminalView)] = [:]

    func existing(for id: UUID) -> (container: NSView, term: MRNGTerminalView)? { entries[id] }
    func store(_ id: UUID, container: NSView, term: MRNGTerminalView) { entries[id] = (container, term) }
    func remove(_ id: UUID) { entries[id] = nil }
}

/// SwiftUI wrapper over SwiftTerm's LocalProcessTerminalView. Spawns the system
/// ssh/telnet/sftp in a PTY embedded in the tab.
struct TerminalContainer: NSViewRepresentable {
    let session: Session
    let isActive: Bool
    let fontSize: Double
    var theme: String = "Implicit"
    var cursorBlinkSpeed: CursorBlinkSpeed = .medium
    /// Called when the underlying terminal reports a new title via OSC 0/1/2.
    /// AppModel uses it to rename the SwiftUI tab live (e.g. `user@host:cwd`).
    var onTitleChange: (String) -> Void = { _ in }
    /// Called when this pane becomes first responder — lets a split tab track
    /// which of its two panes currently has keyboard focus.
    var onFocus: () -> Void = {}

    // Small top/side margin so the terminal content doesn't sit flush against the
    // tab bar above it or the window edges — matches Terminal.app's own inset.
    // Bottom stays flush (no visual boundary to separate from there).
    private let topInset: CGFloat = 6
    private let sideInset: CGFloat = 8

    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator() }

    func makeNSView(context: Context) -> NSView {
        if let existing = TerminalViewRegistry.shared.existing(for: session.id) {
            context.coordinator.onTitleChange = onTitleChange
            context.coordinator.onFocus = onFocus
            context.coordinator.terminal = existing.term
            existing.term.processDelegate = context.coordinator
            existing.term.onFocus = { [coordinator = context.coordinator] in coordinator.onFocus() }
            return existing.container
        }
        let term = MRNGTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        term.font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        TerminalThemes.apply(theme, to: term)
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.terminal = term
        term.processDelegate = context.coordinator
        term.onFocus = { [coordinator = context.coordinator] in coordinator.onFocus() }
        startIfReady(term)
        // Apply blink after the child has had a moment to render the prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            term.applyCursorBlinkSpeed(cursorBlinkSpeed)
        }

        // Wrap in a plain container so the terminal can be inset from it —
        // background matches the terminal's own so the inset margin isn't a
        // visible mismatched-color gutter.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = term.nativeBackgroundColor.cgColor
        container.addSubview(term)
        term.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: sideInset),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -sideInset),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        TerminalViewRegistry.shared.store(session.id, container: container, term: term)
        return container
    }

    /// Spawns the real ssh/telnet/sftp process, unless we're still waiting on
    /// a proxy tunnel (`.connecting`) — `updateNSView` retries once that resolves.
    private func startIfReady(_ term: MRNGTerminalView) {
        guard !term.started, session.proxyState != .connecting else { return }
        term.started = true
        let (exe, args) = Self.command(for: session)
        term.startProcess(executable: exe, args: args, environment: nil, execName: nil)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let term = context.coordinator.terminal else { return }
        let desired = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if term.font.pointSize != desired.pointSize {
            term.font = desired
        }
        TerminalThemes.apply(theme, to: term)
        nsView.layer?.backgroundColor = term.nativeBackgroundColor.cgColor
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.onFocus = onFocus
        term.applyCursorBlinkSpeed(cursorBlinkSpeed)
        startIfReady(term)
        // Give the terminal first responder status when its tab becomes active.
        guard isActive else { return }
        DispatchQueue.main.async {
            guard let window = term.window else { return }
            if window.firstResponder is NSText { return } // user is typing in search etc.
            if window.firstResponder !== term { window.makeFirstResponder(term) }
        }
    }

    static func command(for session: Session) -> (String, [String]) {
        if case .failed(let message) = session.proxyState {
            // Print the proxy error, then drop into a plain shell rather than
            // leaving the tab blank — same "surface it in the terminal" approach
            // used for real ssh/sftp failures.
            return ("/bin/sh", ["-c", "echo \"$1\"; exec /bin/sh", "--", message])
        }
        let node = session.node
        var host = node.hostname
        var port = node.port
        if case .ready(let localPort) = session.proxyState {
            host = "127.0.0.1"
            port = localPort
        }
        let user = node.username
        let target = user.isEmpty ? host : "\(user)@\(host)"

        switch session.kind {
        case .ssh:
            // -L localPort:remoteHost:remotePort, one flag per configured forward
            // (jump-host tunneling — e.g. RDP or another SSH hop through this host).
            let forwardArgs = node.sshLocalForwards.flatMap { ["-L", $0] }
            let sshArgs = forwardArgs + [
                "-p", "\(port)",
                "-o", "UserKnownHostsFile=\(appKnownHostsPath())",
                "-o", "StrictHostKeyChecking=accept-new",
                target,
            ]
            // If we have a password AND sshpass is installed -> inject it.
            // Otherwise plain ssh (uses agent key or prompts interactively).
            if !session.password.isEmpty, let sshpass = sshpassPath() {
                return (sshpass, ["-p", session.password, "/usr/bin/ssh"] + sshArgs)
            }
            return ("/usr/bin/ssh", sshArgs)
        case .telnet:
            return ("/usr/bin/telnet", [host, "\(port)"])
        case .sftp:
            return ("/usr/bin/sftp", [
                "-P", "\(port)", // SFTP uses uppercase -P for the port
                "-o", "UserKnownHostsFile=\(appKnownHostsPath())",
                "-o", "StrictHostKeyChecking=accept-new",
                target,
            ])
        case .externalTool:
            return ("/bin/sh", ["-lc", session.command ?? "echo 'no command'"])
        case .localShell:
            // -l: login shell, so .zprofile/.profile etc. run same as Terminal.app.
            return (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", ["-l"])
        default:
            return ("/bin/echo", ["Protocol not implemented in the terminal."])
        }
    }

    /// Look for an installed sshpass (brew). Returns the path, or nil.
    static func sshpassPath() -> String? {
        let candidates = ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// App-specific known_hosts (separate from ~/.ssh/known_hosts), so we don't
    /// collide with old system entries and we can auto-accept on first connect.
    static func appKnownHostsPath() -> String {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("AlmacRemote", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("known_hosts").path
    }
}
