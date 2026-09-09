// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

/// Sheet for the two master-password flows: unlocking a document protected
/// with a non-default password (`AppModel.tryMasterPassword`), and setting or
/// changing it (`AppModel.changeMasterPassword`) — see `Security.Menu`.
struct MasterPasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var focused: Bool

    private var isChange: Bool { model.masterPasswordSheetMode == .change }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isChange ? t("Security.ChangeTitle") : t("Security.UnlockTitle"))
                .font(.headline)
            Text(isChange ? t("Security.ChangeHint") : t("Security.UnlockHint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(isChange ? t("Security.NewMasterPasswordField") : t("Security.MasterPasswordField"),
                        text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !isChange { submit() } }
            if isChange {
                SecureField(t("Security.ConfirmMasterPasswordField"), text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }

            if let error = model.masterPasswordError {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(t("Security.Cancel")) { model.masterPasswordSheetVisible = false }
                    .keyboardShortcut(.cancelAction)
                Button(isChange ? t("Security.SetPassword") : t("Security.Unlock")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || (isChange && password != confirmPassword))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() {
        if isChange {
            guard password == confirmPassword else {
                model.masterPasswordError = t("Security.MasterPasswordMismatch")
                return
            }
            model.changeMasterPassword(to: password)
        } else {
            model.tryMasterPassword(password)
        }
    }
}
