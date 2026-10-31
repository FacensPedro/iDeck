// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Akshay CM
// Epic Games sign-in, adapted from Madeira's EpicGames.swift
// (Madeira Converter Exception: see LICENSES/Madeira-LICENSE-EXCEPTION.md).

import SwiftUI
import WebKit

/// Game page for one Epic game: install, update, repair, cloud saves, remove.
struct EpicGameDetailView: View {
    let appName: String
    let launch: (EpicInstalledGame) -> Void
    @ObservedObject private var epic = EpicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false

    var body: some View {
        NavigationStack {
            Form {
                let installed = epic.installed[appName]
                Section {
                    if let installed {
                        Button {
                            dismiss()
                            launch(installed)
                        } label: { Label(tr("Launch"), systemImage: "play.fill") }
                        LabeledContent(tr("Size"), value: ByteCountFormatter.string(fromByteCount: installed.installBytes, countStyle: .file))
                        LabeledContent(tr("Version"), value: installed.buildVersion)
                        if epic.updateAvailable(appName) {
                            Button(tr("Update")) { epic.install(appName) }
                        }
                        Button(tr("Repair")) { epic.repair(appName) }
                    } else if epic.downloads[appName] == nil {
                        Button { epic.install(appName) } label: { Label(tr("Install"), systemImage: "arrow.down.circle") }
                    }
                    if let download = epic.downloads[appName] {
                        EpicDownloadRow(appName: appName, download: download)
                    }
                }
                EpicCloudSection(appName: appName)
                if installed != nil {
                    Section {
                        Button(tr("Uninstall"), role: .destructive) { confirmUninstall = true }
                            .disabled(epic.sessionRunning || EpicCloud.shared.isBusy)
                    }
                }
            }
            .navigationTitle(epic.game(appName)?.title ?? epic.installed[appName]?.title ?? "Epic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Done")) { dismiss() } }
            }
            .confirmationDialog(tr("Delete this game's files?"), isPresented: $confirmUninstall, titleVisibility: .visible) {
                Button(tr("Uninstall"), role: .destructive) { epic.uninstall(appName); dismiss() }
                Button(tr("Cancel"), role: .cancel) {}
            }
        }
    }
}

struct EpicDownloadRow: View {
    let appName: String
    let download: EpicLibrary.Download
    @ObservedObject private var epic = EpicLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch download.state {
            case .queued:
                Text(tr("Waiting to download")).foregroundStyle(.secondary)
            case .active:
                ProgressView(value: download.progress.fraction)
                Text(tr("Downloading %d%%", Int((download.progress.fraction * 100).rounded())))
                    .font(.caption).foregroundStyle(.secondary)
            case .paused:
                Text(tr("Paused")).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if download.state == .active || download.state == .queued {
                    Button(tr("Pause")) { epic.pause(appName) }
                } else {
                    Button(tr("Resume")) { epic.install(appName) }
                }
                Spacer()
                Button(tr("Cancel"), role: .destructive) { epic.cancel(appName) }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct EpicSignInView: View {
    @ObservedObject private var epic = EpicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var failure: String?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            Group {
                if epic.signedIn {
                    Form {
                        LabeledContent(tr("Signed in as"), value: epic.accountName ?? "Epic Games account")
                        Button(tr("Sign out"), role: .destructive) { epic.signOut() }
                    }
                } else {
                    EpicLoginWebView(reload: reload) { code in submit(code) }
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if busy {
                                ProgressView(tr("Signing in…")).padding(20)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
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
                            Button(tr("Reload"), systemImage: "arrow.clockwise") { reload += 1 }
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
                Button(tr("OK"), role: .cancel) { failure = nil; reload += 1 }
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

/// WKWebView with Epic's login page, in a private (non-persistent) data store.
struct EpicLoginWebView: UIViewRepresentable {
    var reload: Int
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: EpicAPI.loginURL))
        context.coordinator.loadedReload = reload
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.loadedReload != reload {
            context.coordinator.loadedReload = reload
            context.coordinator.delivered = false
            view.load(URLRequest(url: EpicAPI.loginURL))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onCode: (String) -> Void
        var loadedReload = 0
        var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, EpicAPI.isRedirectPage(webView.url) else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                // A code, or Epic's request for an action on the account (shown as a message).
                guard let self, !self.delivered, let text = result as? String,
                      EpicAPI.authorizationCode(in: text) != nil || EpicAPI.correctiveAction(in: text) != nil else { return }
                self.delivered = true
                self.onCode(text)
            }
        }

        /// Links that open a new window (some sign-in providers) load in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
