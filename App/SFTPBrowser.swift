// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// FileZilla-style two-pane SFTP browser (local | remote + transfer queue).
///
/// No SFTP library: one `ssh -M` ControlMaster authenticates once (stored
/// password via SSH_ASKPASS, 2FA/host-key prompts via its osascript fallback),
/// then every listing/transfer is a short `sftp -b -` multiplexed over it.
final class SFTPConnection: @unchecked Sendable {
    let target: String
    let port: Int
    let password: String
    // Short path: unix socket paths are capped at 104 bytes on macOS.
    private let socketPath = "/tmp/almac-sftp-\(UUID().uuidString.prefix(8))"

    private let masterLock = NSLock()
    private lazy var browseLane = Lane(conn: self)
    private lazy var transferLane = Lane(conn: self)

    init(target: String, port: Int, password: String) {
        self.target = target
        self.port = port
        self.password = password
        // A lane's sftp can die between our isRunning check and the write;
        // make that an EPIPE error instead of a process-killing SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    fileprivate var commonOpts: [String] {
        ["-o", "ControlPath=\(socketPath)",
         "-o", "UserKnownHostsFile=\(TerminalContainer.appKnownHostsPath())",
         "-o", "StrictHostKeyChecking=accept-new"]
    }

    /// Brings the master connection up if it isn't (first use, or after the
    /// ControlPersist idle timeout reaped it). `-f` makes ssh exit only once
    /// auth has succeeded, so the exit status is the readiness signal.
    func ensureMaster() throws {
        masterLock.lock()
        defer { masterLock.unlock() }
        if (try? Self.run("/usr/bin/ssh", commonOpts + ["-O", "check", target])) != nil { return }
        var env = ProcessInfo.processInfo.environment
        let script = SSHAskpass.writeScript()
        defer { script.map { try? FileManager.default.removeItem(atPath: $0) } }
        if let script {
            env["SSH_ASKPASS"] = script
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["MRNG_SSH_ASKPASS_SECRET"] = password
        }
        _ = try Self.run("/usr/bin/ssh", commonOpts + [
            "-M", "-f", "-N",
            "-o", "ControlPersist=10m",
            "-o", "ServerAliveInterval=30",
            "-p", "\(port)", target,
        ], env: env, captureOutput: false)
    }

    /// Runs sftp batch commands on a long-lived sftp process (browse or
    /// transfer lane, so a big upload doesn't freeze folder browsing).
    func sftp(_ batch: String, transfer: Bool = false) throws -> String {
        try (transfer ? transferLane : browseLane).run(batch)
    }

    func shell(_ command: String) throws {
        try ensureMaster()
        _ = try Self.run("/usr/bin/ssh", commonOpts + ["-p", "\(port)", target, command])
    }

    func close() {
        browseLane.stop()
        transferLane.stop()
        _ = try? Self.run("/usr/bin/ssh", commonOpts + ["-O", "exit", target])
    }

    /// stderr goes to a temp file, not a pipe: the backgrounded (`-f`) master
    /// could otherwise keep a pipe open and hang the read forever.
    private static func run(_ exe: String, _ args: [String], env: [String: String]? = nil, captureOutput: Bool = true) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("almac-sftp-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        p.standardError = try FileHandle(forWritingTo: errURL)
        let out = Pipe()
        p.standardOutput = captureOutput ? out : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = captureOutput ? out.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw SFTPError(message: err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "\(exe) exited with \(p.terminationStatus)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One persistent `sftp -b -` multiplexed over the master: no per-command
/// process spawn / channel setup / subsystem handshake. Each request ends with
/// a local `!echo <marker>` so we know where its output stops (sftp's stdout
/// is line-buffered). In batch mode any failing command makes sftp exit, so
/// EOF + stderr is the error; the next request respawns the lane.
private final class Lane {
    private unowned let conn: SFTPConnection
    private let lock = NSLock()
    private let marker = "__ALMAC_END_\(UUID().uuidString.prefix(8))__"
    private var proc: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errPipe: Pipe?
    private var buffer = Data()

    init(conn: SFTPConnection) { self.conn = conn }

    func run(_ batch: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if proc?.isRunning != true { try spawn() }
        do {
            try input?.write(contentsOf: Data((batch + "\n!echo \(marker)\n").utf8))
        } catch {
            try fail()
        }
        var out = ""
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == marker { return out }
                out += line + "\n"
                continue
            }
            guard let chunk = output?.availableData, !chunk.isEmpty else { try fail() }
            buffer.append(chunk)
        }
    }

    private func spawn() throws {
        try conn.ensureMaster()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        p.arguments = conn.commonOpts + ["-b", "-", "-P", "\(conn.port)", conn.target]
        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = e
        try p.run()
        proc = p
        input = i.fileHandleForWriting
        output = o.fileHandleForReading
        errPipe = e
        buffer = Data()
    }

    /// sftp exited (a command failed, or the connection dropped): surface its stderr.
    private func fail() throws -> Never {
        let p = proc
        p?.terminate()
        p?.waitUntilExit()
        let err = errPipe.map { String(decoding: $0.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) } ?? ""
        proc = nil; input = nil; output = nil; errPipe = nil
        let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
        throw SFTPError(message: msg.isEmpty ? "sftp exited (\(p?.terminationStatus ?? -1))" : msg)
    }

    /// No lock: must be able to kill a lane mid-transfer when the tab closes.
    func stop() { proc?.terminate() }
}

struct SFTPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteEntry: Identifiable, Hashable {
    let name: String
    let perms: String
    let size: Int64
    let date: String
    var id: String { name }
    var isDir: Bool { perms.hasPrefix("d") }
    var isLink: Bool { perms.hasPrefix("l") }

    // `sftp ls -la <dir>` line: perms nlink(or "?") user group size
    // "Mon dd HH:MM" | "Mon dd  YYYY" <dir>/name.
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^([-dlcbsp][-rwxsStT]{9}\S*)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\S+\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s(.+)$"#)

    static func parse(_ output: String) -> [RemoteEntry] {
        output.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            let ns = line as NSString
            guard let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            // sftp prefixes each name with the listed dir; "/" can't occur in a name.
            let name = ns.substring(with: m.range(at: 4)).components(separatedBy: "/").last ?? ""
            guard name != ".", name != ".." else { return nil }
            return RemoteEntry(name: name, perms: ns.substring(with: m.range(at: 1)),
                               size: Int64(ns.substring(with: m.range(at: 2))) ?? 0,
                               date: ns.substring(with: m.range(at: 3)))
        }
    }

    #if DEBUG
    static func selfCheck() {
        let sample = """
        sftp> ls -lan "/home/x"
        drwxr-xr-x    ? x        staff          96 Jan  3 12:00 /home/x/.
        drwxr-xr-x    3 root     root         4096 Jan  3  2024 /home/x/..
        -rw-r--r--    1 x        staff         220 Feb 25 09:05 /home/x/my file.txt
        lrwxrwxrwx    1 x        staff           7 Mar  1  2023 /home/x/link
        """
        let e = parse(sample)
        assert(e.map(\.name) == ["my file.txt", "link"], "\(e)")
        assert(e[0].size == 220 && !e[0].isDir && e[1].isLink)
    }
    #endif
}

struct LocalEntry: Identifiable, Hashable {
    let url: URL
    let isDir: Bool
    let size: Int64
    let date: Date?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct SFTPTransfer: Identifiable {
    enum State { case queued, running, done, failed(String) }
    let id = UUID()
    let label: String
    var state: State = .queued
}

/// Quote a path for an sftp batch line. Inside double quotes sftp already
/// treats `* ? [` literally (verified against sftp-server), so only `\` and `"` need escaping.
private func sq(_ path: String) -> String {
    "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// POSIX single-quote for the remote shell.
private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private func remoteJoin(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    // Kept per session so switching tabs doesn't reconnect (same idea as TerminalViewRegistry).
    private static var registry: [UUID: SFTPBrowserModel] = [:]
    static func model(for session: Session) -> SFTPBrowserModel {
        if let m = registry[session.id] { return m }
        let m = SFTPBrowserModel(session: session)
        registry[session.id] = m
        return m
    }
    static func remove(_ id: UUID) {
        registry.removeValue(forKey: id)?.disconnect()
    }

    let conn: SFTPConnection
    @Published var remotePath = ""
    @Published var remoteEntries: [RemoteEntry] = []
    @Published var localPath = FileManager.default.homeDirectoryForCurrentUser
    @Published var localEntries: [LocalEntry] = []
    @Published var busy = false
    @Published var error: String?
    @Published var transfers: [SFTPTransfer] = []
    private var queueTail: Task<Void, Never>?
    /// Remote files opened in a local editor (FileZilla's View/Edit): remote
    /// path -> temp copy + the mtime we last synced.
    private var edits: [String: (local: URL, synced: Date)] = [:]
    private var editTimer: Timer?
    private let editRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("almac-sftp-edit-\(UUID().uuidString.prefix(8))", isDirectory: true)

    private init(session: Session) {
        let node = session.node
        var host = node.hostname, port = node.port
        if case .ready(let localPort) = session.proxyState { host = "127.0.0.1"; port = localPort }
        conn = SFTPConnection(target: node.username.isEmpty ? host : "\(node.username)@\(host)",
                              port: port, password: session.password)
        #if DEBUG
        RemoteEntry.selfCheck()
        #endif
        loadLocal(localPath)
        Task { await start() }
    }

    private func bg<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(with: Result { try work() }) }
        }
    }

    private func start() async {
        await loadRemote(nil)
    }

    func disconnect() {
        editTimer?.invalidate()
        try? FileManager.default.removeItem(at: editRoot)
        let conn = self.conn
        DispatchQueue.global().async { conn.close() }
    }

    // MARK: Remote

    /// Lists `path` (nil = login dir). The server resolves the path via `cd`
    /// and reports back the real absolute dir via `pwd`, so we never trust our
    /// own path joins (symlinks, chroots, `..`, relative input all just work).
    func loadRemote(_ path: String?) async {
        busy = true
        defer { busy = false }
        do {
            let conn = self.conn
            let cd = path.map { "cd \(sq($0))\n" } ?? ""
            let out = try await bg { try conn.sftp(cd + "pwd\nls -la") }
            let prefix = "Remote working directory: "
            guard let pwd = out.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
                .map({ String($0.dropFirst(prefix.count)) }) else {
                throw SFTPError(message: "Unexpected sftp output:\n\(out)")
            }
            remoteEntries = RemoteEntry.parse(out).sorted {
                ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased())
            }
            remotePath = pwd
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remoteUp() {
        Task { await loadRemote(remoteJoin(remotePath, "..")) }
    }

    func openRemote(_ e: RemoteEntry) {
        // Symlinks: just try to enter — if it points at a file, ls errors and we stay put.
        if e.isDir || e.isLink { Task { await loadRemote(remoteJoin(remotePath, e.name)) } }
        else { download([e]) }
    }

    func remoteOp(_ work: @escaping @Sendable (SFTPConnection) throws -> Void) {
        let conn = self.conn, path = remotePath
        Task {
            do { try await bg { try work(conn) } } catch { self.error = error.localizedDescription }
            await loadRemote(path)
        }
    }

    func remoteMkdir(_ name: String) {
        let p = remoteJoin(remotePath, name)
        remoteOp { _ = try $0.sftp("mkdir \(sq(p))") }
    }

    func remoteRename(_ e: RemoteEntry, to name: String) {
        let a = remoteJoin(remotePath, e.name), b = remoteJoin(remotePath, name)
        remoteOp { _ = try $0.sftp("rename \(sq(a)) \(sq(b))") }
    }

    func remoteDelete(_ entries: [RemoteEntry]) {
        let dir = remotePath
        remoteOp { conn in
            for e in entries {
                let p = remoteJoin(dir, e.name)
                // sftp has no recursive rm; directories go through the shell.
                if e.isDir { try conn.shell("rm -rf -- \(shq(p))") }
                else { _ = try conn.sftp("rm \(sq(p))") }
            }
        }
    }

    // MARK: Local

    func loadLocal(_ url: URL) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            localEntries = urls.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return LocalEntry(url: u, isDir: v?.isDirectory ?? false, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate)
            }.sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
            localPath = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openLocal(_ e: LocalEntry) {
        if e.isDir { loadLocal(e.url) } else { upload([e.url]) }
    }

    // MARK: Transfers (serial queue, like FileZilla's default)

    func upload(_ urls: [URL]) {
        let dir = remotePath
        for u in urls {
            let dest = remoteJoin(dir, u.lastPathComponent)
            enqueue("↑ \(u.lastPathComponent) → \(dir)") { conn in
                _ = try conn.sftp("put -r -p \(sq(u.path)) \(sq(dest))", transfer: true)
            } then: { [weak self] _ in
                guard let self, self.remotePath == dir else { return }
                await self.loadRemote(dir)
            }
        }
    }

    func download(_ entries: [RemoteEntry]) {
        let dir = remotePath, local = localPath
        for e in entries {
            let src = remoteJoin(dir, e.name)
            let dest = local.appendingPathComponent(e.name).path
            enqueue("↓ \(e.name) → \(local.path)") { conn in
                _ = try conn.sftp("get -r -p \(sq(src)) \(sq(dest))", transfer: true)
            } then: { [weak self] _ in
                guard let self, self.localPath == local else { return }
                self.loadLocal(local)
            }
        }
    }

    // MARK: Edit in local editor (upload on every save)

    func edit(_ e: RemoteEntry) {
        let remote = remoteJoin(remotePath, e.name)
        if let existing = edits[remote] { openInEditor(existing.local); return }
        let dir = editRoot.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(e.name)
        enqueue("↓ \(e.name) (edit)") { conn in
            _ = try conn.sftp("get \(sq(remote)) \(sq(local.path))", transfer: true)
        } then: { [weak self] ok in
            if ok { self?.startEditing(remote: remote, local: local) }
        }
    }

    /// FileZilla's "Create new file": upload an empty file, then open it for editing.
    func newRemoteFile(_ name: String) {
        let remote = remoteJoin(remotePath, name), dir = remotePath
        let tmp = editRoot.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let local = tmp.appendingPathComponent(name)
        FileManager.default.createFile(atPath: local.path, contents: Data())
        enqueue("↑ \(name) (new)") { conn in
            _ = try conn.sftp("put \(sq(local.path)) \(sq(remote))", transfer: true)
        } then: { [weak self] ok in
            guard let self, ok else { return }
            if self.remotePath == dir { await self.loadRemote(dir) }
            self.startEditing(remote: remote, local: local)
        }
    }

    private func startEditing(remote: String, local: URL) {
        guard let mtime = Self.mtime(local) else { return } // download failed; the queue shows why
        edits[remote] = (local, mtime)
        openInEditor(local)
        // ponytail: 1s mtime poll, not FSEvents/DispatchSource — editors save by
        // atomic rename, which breaks a vnode watch; polling a handful of files is free.
        if editTimer == nil {
            editTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.syncEdits() }
            }
        }
    }

    private func syncEdits() {
        for (remote, e) in edits {
            guard let m = Self.mtime(e.local), m > e.synced else { continue }
            edits[remote]?.synced = m
            let local = e.local, dir = (remote as NSString).deletingLastPathComponent
            enqueue("↑ \(local.lastPathComponent) (saved)") { conn in
                _ = try conn.sftp("put \(sq(local.path)) \(sq(remote))", transfer: true)
            } then: { [weak self] _ in
                guard let self, self.remotePath == dir else { return }
                await self.loadRemote(dir)
            }
        }
    }

    private func openInEditor(_ url: URL) {
        // Default plain-text editor (TextEdit, or whatever the user set, e.g. VS
        // Code) — extension-based lookup fails for .conf/.env/no-extension files.
        if let app = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func enqueue(_ label: String, _ work: @escaping @Sendable (SFTPConnection) throws -> Void,
                         then refresh: @escaping @MainActor (_ ok: Bool) async -> Void) {
        let t = SFTPTransfer(label: label)
        transfers.append(t)
        let prev = queueTail, conn = self.conn
        queueTail = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            self.setState(t.id, .running)
            var ok = true
            do {
                try await self.bg { try work(conn) }
                self.setState(t.id, .done)
            } catch {
                ok = false
                self.setState(t.id, .failed(error.localizedDescription))
            }
            await refresh(ok)
        }
    }

    private func setState(_ id: UUID, _ s: SFTPTransfer.State) {
        if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].state = s }
    }

    func clearFinished() {
        transfers.removeAll { if case .done = $0.state { return true }; return false }
    }
}

// MARK: - Views

private func prompt(_ title: String, _ initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: t("Delete.Cancel"))
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    return name.isEmpty || name.contains("/") ? nil : name
}

private func confirm(_ title: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.alertStyle = .warning
    alert.addButton(withTitle: t("Context.Delete"))
    alert.addButton(withTitle: t("Delete.Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
}

private func sizeText(_ size: Int64, isDir: Bool) -> String {
    isDir ? "" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
}

private let remoteDragPrefix = "almac-sftp-remote:"

struct SFTPBrowserView: View {
    @ObservedObject var model: SFTPBrowserModel
    @State private var localSel = Set<URL>()
    @State private var remoteSel = Set<String>()
    @State private var localPathField = ""
    @State private var remotePathField = ""

    init(session: Session) {
        model = SFTPBrowserModel.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                localPane.frame(minWidth: 280)
                remotePane.frame(minWidth: 280)
            }
            Divider()
            queue.frame(height: 130)
            if let err = model.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .font(.callout).padding(6)
                .background(.orange.opacity(0.12))
            }
        }
        .onChange(of: model.localPath) { _, v in localPathField = v.path }
        .onChange(of: model.remotePath) { _, v in remotePathField = v }
        .onAppear { localPathField = model.localPath.path; remotePathField = model.remotePath }
    }

    private func header(_ title: String, path: Binding<String>, onSubmit: @escaping () -> Void,
                        up: @escaping () -> Void, refresh: @escaping () -> Void, mkdir: @escaping () -> Void,
                        newFile: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            TextField("", text: path).textFieldStyle(.roundedBorder).onSubmit(onSubmit)
            Button(action: up) { Image(systemName: "arrow.up") }.help("Parent folder")
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh")
            Button(action: mkdir) { Image(systemName: "folder.badge.plus") }.help("New folder")
            if let newFile { Button(action: newFile) { Image(systemName: "doc.badge.plus") }.help("New file") }
        }
        .buttonStyle(.borderless)
        .padding(6)
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            header("Local", path: $localPathField,
                   onSubmit: { model.loadLocal(URL(fileURLWithPath: (localPathField as NSString).expandingTildeInPath)) },
                   up: { model.loadLocal(model.localPath.deletingLastPathComponent()) },
                   refresh: { model.loadLocal(model.localPath) },
                   mkdir: {
                       guard let name = prompt("New folder") else { return }
                       do {
                           try FileManager.default.createDirectory(at: model.localPath.appendingPathComponent(name), withIntermediateDirectories: false)
                       } catch { model.error = error.localizedDescription }
                       model.loadLocal(model.localPath)
                   })
            Table(of: LocalEntry.self, selection: $localSel) {
                TableColumn("Name") { e in
                    Label(e.name, systemImage: e.isDir ? "folder.fill" : "doc")
                }
                TableColumn("Size") { e in Text(sizeText(e.size, isDir: e.isDir)).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
                TableColumn("Modified") { e in
                    Text(e.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 140)
            } rows: {
                ForEach(model.localEntries) { e in
                    TableRow(e).draggable(e.url)
                }
            }
            .contextMenu(forSelectionType: URL.self) { ids in
                let items = model.localEntries.filter { ids.contains($0.url) }
                if !items.isEmpty {
                    Button("Upload") { model.upload(items.map(\.url)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        for i in items { try? FileManager.default.trashItem(at: i.url, resultingItemURL: nil) }
                        model.loadLocal(model.localPath)
                    }
                }
            } primaryAction: { ids in
                if ids.count == 1, let e = model.localEntries.first(where: { ids.contains($0.url) }) { model.openLocal(e) }
                else { model.upload(Array(ids)) }
            }
            .dropDestination(for: String.self) { items, _ in
                let names = items.filter { $0.hasPrefix(remoteDragPrefix) }.map { String($0.dropFirst(remoteDragPrefix.count)) }
                let entries = model.remoteEntries.filter { names.contains($0.name) }
                model.download(entries)
                return !entries.isEmpty
            }
        }
    }

    private func newRemoteFolder() { if let name = prompt("New folder") { model.remoteMkdir(name) } }
    private func newRemoteFile() { if let name = prompt("New file") { model.newRemoteFile(name) } }

    private var remotePane: some View {
        VStack(spacing: 0) {
            header("Remote", path: $remotePathField,
                   onSubmit: { Task { await model.loadRemote(remotePathField) } },
                   up: { model.remoteUp() },
                   refresh: { Task { await model.loadRemote(model.remotePath) } },
                   mkdir: newRemoteFolder, newFile: newRemoteFile)
            ZStack {
                Table(of: RemoteEntry.self, selection: $remoteSel) {
                    TableColumn("Name") { e in
                        Label(e.name, systemImage: e.isDir ? "folder.fill" : e.isLink ? "arrow.up.right.square" : "doc")
                    }
                    TableColumn("Size") { e in Text(sizeText(e.size, isDir: e.isDir)).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 80)
                    TableColumn("Modified") { e in Text(e.date).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 110)
                    TableColumn("Permissions") { e in Text(e.perms).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 100)
                } rows: {
                    ForEach(model.remoteEntries) { e in
                        TableRow(e).draggable(remoteDragPrefix + e.name)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let items = model.remoteEntries.filter { ids.contains($0.name) }
                    if !items.isEmpty {
                        Button("Download") { model.download(items) }
                        if items.count == 1, !items[0].isDir {
                            Button("Edit") { model.edit(items[0]) }
                        }
                        if items.count == 1 {
                            Button("Rename…") {
                                if let name = prompt("Rename", items[0].name) { model.remoteRename(items[0], to: name) }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            if confirm("Delete \(items.count == 1 ? items[0].name : "\(items.count) items") on the server?") {
                                model.remoteDelete(items)
                            }
                        }
                    } else {
                        Button("New file…", action: newRemoteFile)
                        Button("New folder…", action: newRemoteFolder)
                    }
                } primaryAction: { ids in
                    let items = model.remoteEntries.filter { ids.contains($0.name) }
                    if items.count == 1 { model.openRemote(items[0]) } else { model.download(items) }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    model.upload(files)
                    return !files.isEmpty
                }
                if model.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear finished") { model.clearFinished() }.buttonStyle(.borderless)
            }
            .padding(6)
            List(model.transfers.reversed()) { tr in
                HStack {
                    switch tr.state {
                    case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Text(tr.label).lineLimit(1).truncationMode(.middle)
                    if case .failed(let msg) = tr.state {
                        Text(msg).foregroundStyle(.red).lineLimit(1).help(msg)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
