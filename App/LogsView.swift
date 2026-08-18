// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

/// Live tail of `AppLog`'s event file — app/window activation, terminal focus
/// reclaim, and process-exit events — so a user can self-diagnose an
/// intermittent issue (e.g. reproduce it, then check what actually fired)
/// without needing a developer attached.
struct LogsWindowView: View {
    @State private var text = AppLog.tail()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? t("Logs.Empty") : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .onChange(of: text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack {
                Button(t("Logs.Reveal")) {
                    NSWorkspace.shared.selectFile(AppLog.fileURL.path, inFileViewerRootedAtPath: AppLog.logDirectory.path)
                }
                Button(t("Logs.Clear"), role: .destructive) {
                    AppLog.clear()
                    text = ""
                }
                Spacer()
                Button(t("Logs.Refresh")) { text = AppLog.tail() }
            }
            .padding(8)
        }
        .onReceive(timer) { _ in text = AppLog.tail() }
        .frame(minWidth: 520, minHeight: 360)
    }
}
