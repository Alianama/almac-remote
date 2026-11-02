// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import CryptoKit

/// In-app updates without an Apple Developer ID (Sparkle/notarization need one),
/// same scheme as Almac Browser's updater.js: every GitHub release carries
/// almac-update.json + .sig, the manifest is signed with the owner's Ed25519 key
/// (~/.almac/update-key.pem, see scripts/release.sh), and the app only installs
/// a zip whose SHA-512 is in a validly signed manifest — a hijacked GitHub
/// account alone can't push a fake update.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable { case idle, checking, latest, available, downloading, ready, error }
    @Published private(set) var status: Status = .idle
    @Published private(set) var version = ""
    @Published private(set) var notes = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage = ""
    @Published var autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    static let repo = "Alianama/almac-remote"
    static let appID = "almac-remote"
    /// Raw Ed25519 public key (same key pair as Almac Browser).
    private static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "XxYynRD5E9YcHDGEK5YOBMwCt0UJPvmoLwSsIsMzsQg=")!)
    private static var latestURL: URL { URL(string: "https://github.com/\(repo)/releases/latest/download/")! }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    #if arch(arm64)
    static let fileKey = "arm64"
    #else
    static let fileKey = "x86_64"
    #endif

    struct Manifest: Decodable {
        struct File: Decodable { let name: String; let size: Int; let sha512: String }
        let app: String
        let version: String
        let files: [String: File]
    }

    private var manifest: Manifest?
    private var staged: (dir: URL, app: URL)?

    /// 1.10.0 > 1.9.2
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<3 where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    nonisolated static func verify(_ json: Data, signatureBase64: String) -> Bool {
        guard let sig = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return publicKey.isValidSignature(sig, for: json)
    }

    /// .../Almac Remote.app
    private var bundleURL: URL { Bundle.main.bundleURL }

    private func cannotUpdate() -> String? {
        let path = bundleURL.path
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return "Development build: rebuild from source to update." }
        if path.contains("AppTranslocation") || path.hasPrefix("/Volumes/") { return "Move Almac Remote to the Applications folder first, then reopen it." }
        let dir = bundleURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: dir) { return "No permission to replace the app in \(dir)." }
        return nil
    }

    func check(manual: Bool = false) async {
        guard ![.checking, .downloading, .ready].contains(status) else { return }
        if let blocked = cannotUpdate() {
            if manual { fail(blocked) }
            return
        }
        status = .checking
        errorMessage = ""
        do {
            async let json = fetch(Self.latestURL.appendingPathComponent("almac-update.json"))
            async let sig = fetch(Self.latestURL.appendingPathComponent("almac-update.json.sig"))
            let (j, s) = try await (json, sig)
            guard Self.verify(j, signatureBase64: String(decoding: s, as: UTF8.self)) else {
                throw UpdateError("Update signature is invalid. The update was refused.")
            }
            let m = try JSONDecoder().decode(Manifest.self, from: j)
            guard m.app == Self.appID else { throw UpdateError("Update manifest is for another app. The update was refused.") }
            guard Self.isNewer(m.version, than: Self.currentVersion) else {
                status = manual ? .latest : .idle
                return
            }
            guard m.files[Self.fileKey] != nil else { throw UpdateError("No \(Self.fileKey) build in this release.") }
            manifest = m
            version = m.version
            notes = await releaseNotes(m.version)
            status = .available
        } catch {
            if manual { fail(error.localizedDescription) } else { status = .idle }
        }
    }

    func download() async {
        guard status == .available, let m = manifest, let f = m.files[Self.fileKey] else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("almac-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            status = .downloading
            progress = 0
            let zip = dir.appendingPathComponent("update.zip")
            FileManager.default.createFile(atPath: zip.path, contents: nil)
            let out = try FileHandle(forWritingTo: zip)
            defer { try? out.close() }
            let url = URL(string: "https://github.com/\(Self.repo)/releases/download/v\(m.version)/")!.appendingPathComponent(f.name)
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            var hasher = SHA512()
            var buffer = [UInt8]()
            buffer.reserveCapacity(1 << 16)
            var got = 0, lastReport = Date.distantPast
            func flush() throws {
                hasher.update(data: buffer)
                try out.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            for try await byte in bytes {
                buffer.append(byte)
                got += 1
                if buffer.count == 1 << 16 {
                    if got > f.size { throw UpdateError("Download is larger than expected.") }
                    try flush()
                    if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress = Double(got) / Double(f.size) }
                }
            }
            try flush()
            guard got == f.size, Data(hasher.finalize()).base64EncodedString() == f.sha512 else {
                throw UpdateError("Downloaded file does not match the signed checksum. The update was refused.")
            }
            // ditto keeps the bundle as-is (symlinks, exec bits, code signature).
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            guard let appName = try FileManager.default.contentsOfDirectory(atPath: dir.path).first(where: { $0.hasSuffix(".app") }),
                  Bundle(url: dir.appendingPathComponent(appName))?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("Update archive has no Almac Remote app inside.")
            }
            staged = (dir, dir.appendingPathComponent(appName))
            progress = 1
            status = .ready
        } catch {
            try? FileManager.default.removeItem(at: dir)
            fail(error.localizedDescription)
        }
    }

    /// Swap the bundle after we quit: a tiny script waits for this PID, swaps
    /// old for new (rolling back if the move fails), then reopens the app.
    /// Paths go in as $1..$5, never interpolated into the script text.
    func installAndRelaunch() {
        guard status == .ready, let staged else { return }
        let target = bundleURL.path
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$4"
        if mv "$3" "$4" && mv "$2" "$3"; then rm -rf "$4"; else rm -rf "$3"; mv "$4" "$3"; fi
        rm -rf "$5"
        open "$3"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "almac-update", String(ProcessInfo.processInfo.processIdentifier),
                       staged.app.path, target, target + ".old", staged.dir.path]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        status = .error
    }

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("\(url.lastPathComponent): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private func releaseNotes(_ version: String) async -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/tags/v\(version)"),
              let data = try? await fetch(url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return String((obj["body"] as? String ?? "").prefix(4000))
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { proc in
                proc.terminationStatus == 0 ? cont.resume() : cont.resume(throwing: UpdateError("\(tool) failed (\(proc.terminationStatus))."))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Status + actions; used in Settings › Updates and the toolbar popover.
struct UpdatePanel: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch updater.status {
            case .idle, .checking, .latest, .error:
                HStack {
                    Button(t("Update.Check")) { Task { await updater.check(manual: true) } }
                        .disabled(updater.status == .checking)
                    if updater.status == .checking { ProgressView().controlSize(.small); Text(t("Update.Checking")).foregroundStyle(.secondary) }
                }
                if updater.status == .latest {
                    Text(String(format: t("Update.Latest"), Updater.currentVersion)).foregroundStyle(.secondary)
                }
                if updater.status == .error {
                    Text(updater.errorMessage).foregroundStyle(.red).textSelection(.enabled)
                }
            case .available:
                Text(String(format: t("Update.Available"), updater.version)).bold()
                if !updater.notes.isEmpty {
                    ScrollView { MarkdownNotes(text: updater.notes) }.frame(maxHeight: 180)
                }
                Button(t("Update.Download")) { Task { await updater.download() } }
                    .buttonStyle(.borderedProminent)
            case .downloading:
                ProgressView(value: updater.progress)
                Text(String(format: t("Update.Downloading"), Int(updater.progress * 100))).foregroundStyle(.secondary)
            case .ready:
                Text(t("Update.Ready"))
                Button(t("Update.Restart")) { updater.installAndRelaunch() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Release notes as inline markdown (links, bold, code); newlines kept.
private struct MarkdownNotes: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// Standalone "Check for Updates…" dialog: app icon + version + the same status/actions as Settings.
struct UpdateWindowView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                Text("Almac Remote \(Updater.currentVersion)").font(.headline)
                UpdatePanel()
            }
            .frame(width: 320, alignment: .leading)
        }
        .padding(20)
    }
}
