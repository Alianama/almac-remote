// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import Vision
import UniformTypeIdentifiers
import MRNGCore

/// Decodes a QR code from a still image (native Vision, no extra dependency)
/// and parses a `otpauth://totp/...` payload into a label + Base32 secret.
enum OTPAuthQRCode {
    static func decode(image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results as? [VNBarcodeObservation])?.compactMap(\.payloadStringValue).first
    }

    /// `otpauth://totp/Issuer:account?secret=BASE32&issuer=Issuer&...` — only
    /// `secret` is required; algorithm/digits/period aren't parsed (TOTP.code
    /// only implements the near-universal SHA1/6-digit/30s default).
    static func parse(_ raw: String) -> (label: String, secret: String)? {
        guard let comps = URLComponents(string: raw), comps.scheme == "otpauth", comps.host == "totp",
              let secret = comps.queryItems?.first(where: { $0.name == "secret" })?.value, !secret.isEmpty
        else { return nil }
        let issuer = comps.queryItems?.first(where: { $0.name == "issuer" })?.value
        let path = (comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path)
            .removingPercentEncoding ?? comps.path
        // The label path is often already "Issuer:account" (Google Authenticator
        // includes both the path prefix AND a redundant `issuer` query param) —
        // only prepend issuer when the path doesn't already carry it, so entries
        // don't show up as "GitHub (GitHub:alice@example.com)".
        let label: String
        if path.contains(":") || issuer == nil || issuer!.isEmpty {
            label = path
        } else {
            label = path.isEmpty ? issuer! : "\(issuer!): \(path)"
        }
        return (label, secret)
    }
}

/// Standalone TOTP vault window (like Google Authenticator) — independent of any
/// RDP/SSH connection. Gates on `model.isLocked` itself since sheets/extra windows
/// aren't covered by ContentView's lock overlay.
struct AuthenticatorWindowView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false

    var body: some View {
        Group {
            if model.isLocked {
                LockScreenView()
            } else {
                content
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 300, idealHeight: 480)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if model.authenticatorEntries.isEmpty {
                Spacer()
                Text(t("Authenticator.Empty"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                Spacer()
            } else {
                List {
                    ForEach($model.authenticatorEntries) { $entry in
                        AuthenticatorRow(entry: $entry)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button { showAdd = true } label: { Label(t("Authenticator.Add"), systemImage: "plus") }
                    .padding(8)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddAuthenticatorEntrySheet().environmentObject(model)
        }
    }
}

private struct AuthenticatorRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var entry: AuthenticatorEntry
    @State private var copied = false

    var body: some View {
        let secret = model.decryptedAuthenticatorSecret(entry)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField(t("Authenticator.LabelPlaceholder"), text: $entry.label)
                    .textFieldStyle(.plain)
                    .font(.body)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let code = TOTP.code(secretBase32: secret, date: context.date) {
                        HStack(spacing: 6) {
                            Text(code).font(.system(.title3, design: .monospaced)).bold()
                            Text("\(TOTP.secondsRemaining(date: context.date))s")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(t("Authenticator.InvalidSecret")).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            Button {
                if let code = TOTP.code(secretBase32: secret) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(t("Authenticator.CopyCode"))
            Button(role: .destructive) { model.deleteAuthenticatorEntry(entry) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

private struct AddAuthenticatorEntrySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case qr, manual
        var id: String { rawValue }
    }
    @State private var mode: Mode = .qr
    @State private var label = ""
    @State private var secret = ""
    @State private var errorMessage: String?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Authenticator.AddTitle")).font(.title3).bold()

            Picker("", selection: $mode) {
                Text(t("Authenticator.Mode.QR")).tag(Mode.qr)
                Text(t("Authenticator.Mode.Manual")).tag(Mode.manual)
            }
            .pickerStyle(.segmented)

            if mode == .qr {
                qrDropZone
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(t("Authenticator.Label")).font(.caption).foregroundStyle(.secondary)
                TextField(t("Authenticator.LabelPlaceholder"), text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Authenticator.Secret")).font(.caption).foregroundStyle(.secondary)
                TextField(t("Authenticator.SecretPlaceholder"), text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(t("Authenticator.Cancel")) { dismiss() }
                Button(t("Authenticator.Save")) {
                    model.addAuthenticatorEntry(label: label, secret: secret)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TOTP.code(secretBase32: secret) == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var qrDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(t("Authenticator.DropHint")).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(t("Authenticator.ChooseImage")) { chooseImageFile() }
                Button(t("Authenticator.PasteImage")) { pasteImageFromClipboard() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(isTargeted ? 0.6 : 0.3)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4])))
        // A background/overlay alone isn't hit-testable across the whole zone (only the
        // Image/Text/Button children were) — without this, onDrop only fired if you
        // dropped exactly on a child glyph, which looked like "drag and drop does nothing".
        .contentShape(Rectangle())
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            // Prefer a file URL (Finder drags); fall back to raw image data for sources
            // with no file backing (e.g. a browser or Preview selection).
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let image = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async { handleQRImage(image) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async { handleQRImage(image) }
                }
                return true
            }
            return false
        }
    }

    private func chooseImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        handleQRImage(image)
    }

    private func pasteImageFromClipboard() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else {
            errorMessage = t("Authenticator.NoClipboardImage")
            return
        }
        handleQRImage(image)
    }

    private func handleQRImage(_ image: NSImage) {
        errorMessage = nil
        guard let payload = OTPAuthQRCode.decode(image: image) else {
            errorMessage = t("Authenticator.QRDecodeFailed")
            return
        }
        guard let parsed = OTPAuthQRCode.parse(payload) else {
            errorMessage = t("Authenticator.QROtpauthInvalid")
            return
        }
        if label.isEmpty { label = parsed.label }
        secret = parsed.secret
    }
}
