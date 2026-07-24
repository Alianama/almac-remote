// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

/// Full-window overlay shown while `AppModel.isLocked` is true. Blocks all
/// interaction with the tree/sessions underneath until Touch ID (or the Mac
/// account password, via the same system prompt) succeeds.
struct LockScreenView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(t("Security.Locked"))
                    .font(.title2).bold()
                if let error = model.lockAuthError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                Button(t("Security.Unlock")) { model.authenticateToUnlock() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .contentShape(Rectangle())
    }
}
