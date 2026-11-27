// WebSignIn.swift
// iDeck 3.0.1: store sign-ins in Safari's sign-in sheet (AuthenticationServices).

import AuthenticationServices
import UIKit

/// A store's login page in the system's Safari sign-in sheet
/// (ASWebAuthenticationSession), over iDeck instead of switching to the Safari app.
/// It shares Safari's cookies, so an account already signed in on the web needs no
/// password. The sheet closes by itself:
/// - when the page goes to the store's end-of-login address on a custom scheme (the
///   EA app's qrc:///html/login_successful.html?code=…): `start` returns that address;
/// - when iDeck learns by other means that the login is done (Epic's device sign-in,
///   whose approval iDeck polls): `finish()` closes it.
/// GOG ends on an https page of its own site, which an app can only receive with that
/// site's associated domain, so GOG keeps Safari and the pasted address.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebSignIn()

    private var session: ASWebAuthenticationSession?
    private var finishedByIDeck = false
    /// Which sheet is current: the completion of one replaced by a newer sheet must
    /// not clear the newer one.
    private var generation = 0

    enum Failure: LocalizedError {
        case cancelled, couldNotStart
        var errorDescription: String? {
            switch self {
            case .cancelled: return tr("Sign-in was cancelled.")
            case .couldNotStart: return tr("The sign-in page could not be opened.")
            }
        }
    }

    /// Opens `url` and returns the address on `scheme` the page ended on. For a page
    /// that never goes there (Epic), it returns nil once `finish()` closed the sheet.
    func start(url: URL, scheme: String) async throws -> URL? {
        session?.cancel()
        finishedByIDeck = false
        generation += 1
        let mine = generation
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { [weak self] callback, error in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    let current = self?.generation == mine
                    let finished = current && (self?.finishedByIDeck ?? false)
                    if current { self?.session = nil }
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if finished {
                        continuation.resume(returning: nil)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: Failure.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? Failure.cancelled)
                    }
                } }
            }
            session.presentationContextProvider = self
            // Safari's own cookies: an account already signed in on the web goes straight through.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: Failure.couldNotStart)
            } else {
                AppLog.record("[sign-in] \(url.host ?? "store") opened in Safari's sign-in sheet")
            }
        }
    }

    /// Closes the sheet because the sign-in finished another way.
    func finish() {
        guard let session else { return }
        finishedByIDeck = true
        session.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}
