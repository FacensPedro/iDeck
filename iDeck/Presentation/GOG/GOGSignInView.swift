// GOGSignInView.swift
// Split from GOGLibrary.swift (iDeck 3.0 architecture).

import Foundation
import SwiftUI

/// GOG's own login page; closes itself once GOG redirects with the code.
struct GOGSignInView: View {
    @ObservedObject var library = GOGLibraryModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isFinishing = false
    @State private var errorMessage: String?
    @State private var opened = false

    private func finish(_ code: String) {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            do {
                try await library.completeSignIn(code: code)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isFinishing = false
            }
        }
    }

    /// The code in a pasted address of GOG's success page (or the bare code).
    private func submitPasted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let code = GOGAPI.loginCode(from: url) {
            finish(code)
        } else if !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" ") {
            finish(trimmed)
        } else {
            errorMessage = tr("This is not GOG's sign-in address. Copy the address of the page GOG opens after you sign in.")
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                SafariPasteSignIn(store: "GOG", openURL: GOGAPI.loginURL,
                                      steps: ["Sign in on GOG's page in Safari.",
                                              "GOG then opens a page whose address contains \"on_login_success\" and \"code=\": copy that address.",
                                              "Come back to iDeck and paste it here."],
                                      placeholder: "https://embed.gog.com/on_login_success?…code=…",
                                      busy: isFinishing) { submitPasted($0) }
                    .onAppear { if !opened { opened = true; UIApplication.shared.open(GOGAPI.loginURL) } }
                if isFinishing {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    ProgressView(tr("Signing in to GOG...")).tint(.white).foregroundColor(.white)
                }
            }
            .navigationTitle(tr("GOG sign-in"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel")) { dismiss() }
                }
            }
            .alert(tr("GOG sign-in"), isPresented: Binding(get: { errorMessage != nil },
                                                           set: { if !$0 { errorMessage = nil } })) {
                Button(tr("OK"), role: .cancel) {}
            } message: {
                Text(tr(errorMessage ?? ""))
            }
        }
        .navigationViewStyle(.stack)
    }
}
