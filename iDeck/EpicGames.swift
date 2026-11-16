// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Epic Games sign-in, adapted from Madeira's EpicGames.swift
// (Madeira Converter Exception: see LICENSES/Madeira-LICENSE-EXCEPTION.md).

import SwiftUI

struct EpicSignInView: View {
    @ObservedObject private var epic = EpicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var opened = false

    var body: some View {
        NavigationStack {
            Group {
                if epic.signedIn {
                    Form {
                        LabeledContent(tr("Signed in as"), value: epic.accountName ?? "Epic Games account")
                        Button(tr("Sign out"), role: .destructive) { epic.signOut() }
                    }
                } else {
                    SafariPasteSignIn(store: "Epic Games", openURL: EpicAPI.loginURL,
                                      steps: ["Sign in on Epic's page in Safari.",
                                              "Epic then shows a short text with \"authorizationCode\": copy all of it.",
                                              "Come back to iDeck and paste it here."],
                                      placeholder: "authorizationCode", busy: busy) { submit($0) }
                        .onAppear { if !opened { opened = true; UIApplication.shared.open(EpicAPI.loginURL) } }
                }
            }
            .navigationTitle(tr("Epic Games")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Done")) { dismiss() } }
                if !epic.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(tr("Paste a sign-in code"), systemImage: "doc.on.clipboard") { pasted = ""; pasting = true }
                            Link(destination: EpicAPI.loginURL) { Label(tr("Open the login page in Safari"), systemImage: "safari") }
                        } label: { Label(tr("More"), systemImage: "ellipsis.circle") }
                    }
                }
            }
            .alert(tr("Sign in with a code"), isPresented: $pasting) {
                TextField("authorizationCode", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button(tr("Sign in")) { submit(pasted) }
                Button(tr("Cancel"), role: .cancel) {}
            } message: {
                Text(tr("Open the login page in Safari and sign in. Epic then shows a short text with \"authorizationCode\". Copy the whole text, or only the code, and paste it here."))
            }
            .alert(tr("Epic Games"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(tr("OK"), role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = EpicAPI.authorizationCode(in: text) else {
            failure = EpicAPI.correctiveAction(in: text).map(EpicAPI.correctiveMessage)
                ?? tr("This is not an Epic sign-in code. Copy the text Epic shows after you sign in.")
            return
        }
        busy = true
        Task {
            do {
                try await epic.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

