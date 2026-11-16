// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// The EA sign-in sheet from Madeira's EAGames.swift (8b52c18), unchanged.

import SwiftUI

// MARK: - Sign-in

/// EA's own login page in a web view. When the login finishes, EA sends the page
/// to the EA app's private address (qrc:///html/login_successful.html) with a
/// one-use code; Madeira stops that navigation, reads the code and signs in. That
/// address can also be pasted, for logins the web view cannot complete.
struct EASignInView: View {
    @ObservedObject private var ea = EALibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var opened = false

    /// EA's login page in Safari (outside iDeck). EA ends on qrc:///…?code=, an address
    /// iDeck is registered for, so Safari hands it back to iDeck (iDeckApp.onOpenURL).
    private func openSafari() { UIApplication.shared.open(EALibrary.shared.loginURL()) }

    var body: some View {
        NavigationStack {
            Group {
                if ea.signedIn {
                    Form {
                        LabeledContent("Signed in as", value: ea.accountName ?? "EA account")
                        Button("Sign out", role: .destructive) { ea.signOut() }
                    }
                } else {
                    Form {
                        Section {
                            Button { openSafari() } label: { Label(tr("Sign in with Safari"), systemImage: "safari") }
                                .disabled(busy)
                        } footer: {
                            Text(tr("EA's login page opens in Safari and returns to iDeck by itself when you finish."))
                        }
                        if busy { Section { HStack(spacing: 12) { ProgressView(); Text("Signing in…") } } }
                    }
                    .onAppear { if !opened { opened = true; openSafari() } }
                }
            }
            .navigationTitle("EA app").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !ea.signedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Paste the sign-in address", systemImage: "doc.on.clipboard") { pasted = ""; pasting = true }
                        } label: { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .alert("Sign in with an address", isPresented: $pasting) {
                TextField("qrc:///html/login_successful.html?code=…", text: $pasted).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Sign in") { submit(pasted) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the page shows an address that ends in login_successful.html with a code, copy that whole address and paste it here.")
            }
            .alert("EA app", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: EALibrary.redirectSignInFailed)) { note in
                failure = note.object as? String
            }
        }
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        guard let code = EAAPI.authorizationCode(in: text) else {
            failure = "This is not an EA sign-in address. Copy the address of the page EA opens after you sign in."
            return
        }
        busy = true
        Task {
            do {
                try await ea.signIn(code: code)
                busy = false
                dismiss()
            } catch {
                busy = false
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Safari sign-in

extension EALibrary {
    /// Posted with the error text when Safari's hand-back address could not sign in.
    static let redirectSignInFailed = Notification.Name("iDeck.EASignInRedirectFailed")

    /// EA's end-of-login address (qrc:///html/login_successful.html?code=…) that
    /// Safari opens in iDeck once the user signs in on EA's page.
    static func handleSignInRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "qrc" else { return false }
        guard let code = EAAPI.authorizationCode(in: url.absoluteString) else {
            NotificationCenter.default.post(name: redirectSignInFailed,
                                            object: "This is not an EA sign-in address. Copy the address of the page EA opens after you sign in.")
            return true
        }
        Task { @MainActor in
            do { try await EALibrary.shared.signIn(code: code) }
            catch { NotificationCenter.default.post(name: redirectSignInFailed, object: error.localizedDescription) }
        }
        return true
    }
}


/// Sign-in that opens the store's page in Safari. Stores whose login ends on their
/// own https address (GOG, Epic) cannot hand the code back to an app, so the page
/// address (GOG) or the code text (Epic) is copied in Safari and pasted here.
struct SafariPasteSignIn: View {
    let store: String
    let openURL: URL
    let steps: [String]
    let placeholder: String
    let busy: Bool
    let submit: (String) -> Void
    @State private var pasted = ""

    var body: some View {
        Form {
            Section {
                Button {
                    UIApplication.shared.open(openURL)
                } label: {
                    Label(String(format: tr("Open %@ in Safari"), store), systemImage: "safari")
                }
            }
            Section(tr("After signing in")) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). " + tr(step)).font(.callout)
                }
                TextField(placeholder, text: $pasted, axis: .vertical)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .lineLimit(1...4)
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first {
                        pasted = text
                        submit(text)
                    }
                }
                Button(tr("Sign in")) { submit(pasted) }
                    .disabled(busy || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if busy {
                Section { HStack(spacing: 12) { ProgressView(); Text(tr("Signing in…")) } }
            }
        }
    }
}
