// SPDX-License-Identifier: GPL-2.0-or-later
// Almac Remote — based on mRemoteNXT, Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI

/// Sheet for the two master-password flows: unlocking a document protected
/// with a non-default password (`AppModel.tryMasterPassword`), and setting or
/// changing it (`AppModel.changeMasterPassword`) — see `Security.Menu`. Either
/// flow can optionally save the password to the Keychain (`MasterPasswordKeychain`,
/// Touch ID / account password gated) so it doesn't need retyping next time.
struct MasterPasswordSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var saveToKeychain = false
    @State private var keychainBusy = false
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

            if !isChange && model.masterPasswordKeychainSaved {
                Button {
                    unlockWithTouchID()
                } label: {
                    Label(t("Security.UnlockWithTouchID"), systemImage: "touchid")
                }
                .disabled(keychainBusy)
                Text(t("Security.OrEnterManually")).font(.caption).foregroundStyle(.secondary)
            }

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

            Toggle(isOn: $saveToKeychain) {
                Label(t("Security.SaveInKeychain"), systemImage: "touchid")
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
        .onAppear {
            focused = true
            saveToKeychain = model.masterPasswordKeychainSaved
        }
    }

    private func submit() {
        if isChange {
            guard password == confirmPassword else {
                model.masterPasswordError = t("Security.MasterPasswordMismatch")
                return
            }
            model.changeMasterPassword(to: password)
            model.syncMasterPasswordKeychain(enabled: saveToKeychain, password: password)
        } else if model.tryMasterPassword(password) {
            model.syncMasterPasswordKeychain(enabled: saveToKeychain, password: password)
        }
    }

    private func unlockWithTouchID() {
        keychainBusy = true
        Task {
            if let saved = await MasterPasswordKeychain.load(reason: t("Security.UnlockReason")) {
                _ = model.tryMasterPassword(saved)
            } else {
                model.masterPasswordError = t("Security.KeychainUnlockFailed")
            }
            keychainBusy = false
        }
    }
}
