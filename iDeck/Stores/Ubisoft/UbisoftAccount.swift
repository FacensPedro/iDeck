// UbisoftAccount.swift
// Split from SettingsView.swift (iDeck 3.0 architecture).

import SwiftUI
import Security

/// The Ubisoft sign-in typed last, kept in this device's Keychain (never synced, only
/// after the first unlock) so the form is filled next time. iOS's password AutoFill
/// does not offer to save it: iDeck has no associated domain with Ubisoft.
/// Sign out removes it with the session.
enum UbisoftSavedLogin {
    private static let service = "ideck.ubisoft.login"

    private static func query(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func load() -> (email: String, password: String)? {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let fields = item as? [String: Any],
              let email = fields[kSecAttrAccount as String] as? String,
              let data = fields[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (email, password)
    }

    static func save(email: String, password: String) {
        remove()
        var q = query(email)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func remove() { SecItemDelete(query() as CFDictionary) }
}

struct UbisoftLoginView: View {
    @Binding var accountName: String
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var challenge: String?
    @State private var challengeAppID: String?
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""
    @State private var request: Task<Void, Never>?
    /// Saved once the sign-in succeeds (the password is cleared for a 2FA code).
    @State private var pendingLogin: (String, String)?

    var body: some View {
        NavigationStack {
            Form {
                if challenge == nil {
                    TextField(tr("Email"), text: $email)
                        .keyboardType(.emailAddress).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(tr("Password"), text: $password).textContentType(.password)
                } else {
                    TextField(tr("Verification code"), text: $code).textContentType(.oneTimeCode)
                }
                Button(tr("Sign in")) {
                    busy = true
                    request = Task { await authenticate() }
                }
                .disabled(busy || (challenge == nil ? email.isEmpty || password.isEmpty : code.isEmpty))
                if busy { ProgressView() }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Ubisoft Connect")
            .toolbar { Button(tr("Cancel")) { dismiss() } }
        }
        .onAppear {
            if email.isEmpty, let saved = UbisoftSavedLogin.load() {
                email = saved.email
                password = saved.password
            }
        }
        .onDisappear { request?.cancel() }
    }

    @MainActor private func authenticate() async {
        defer { busy = false }
        error = ""
        // A 2FA answer goes with the Ubi-AppId that asked for it.
        let candidates = challenge == nil ? UbisoftSavedSession.appIDs : [challengeAppID ?? UbisoftSavedSession.appIDs[0]]
        do {
            var data = Data()
            var response: URLResponse?
            var usedAppID = candidates[0]
            for appID in candidates {
                var login = UbisoftSavedSession.request(appID: appID)
                if let challenge {
                    login.setValue("ubi_2fa_v1 t=" + challenge, forHTTPHeaderField: "Authorization")
                    login.setValue(code, forHTTPHeaderField: "Ubi-2FACode")
                } else {
                    pendingLogin = (email.trimmingCharacters(in: .whitespacesAndNewlines), password)
                    let credentials = Data((email.trimmingCharacters(in: .whitespacesAndNewlines) + ":" + password).utf8)
                    login.setValue("Basic " + credentials.base64EncodedString(), forHTTPHeaderField: "Authorization")
                }
                (data, response) = try await URLSession.shared.data(for: login)
                try Task.checkCancellation()
                usedAppID = appID
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) || !UbisoftSavedSession.refusedAppID(data) { break }
            }
            let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let token = fields?["twoFactorAuthenticationTicket"] as? String, !token.isEmpty {
                challenge = token
                challengeAppID = usedAppID
                password = ""
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  fields?["ticket"] is String,
                  let name = fields?["nameOnPlatform"] as? String, !name.isEmpty else {
                error = (fields?["message"] as? String) ?? tr("Sign-in failed")
                return
            }
            try UbisoftSavedSession.decode(data, appID: usedAppID).save()
            if let pendingLogin { UbisoftSavedLogin.save(email: pendingLogin.0, password: pendingLogin.1) }
            accountName = name
            UbisoftLibrary.shared.refresh()   // the store page lists the account's games now
            dismiss()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct UbisoftSavedSession: Codable {
    /// The Ubi-AppId values tried, in order: Ubisoft Connect for PC first, then
    /// Ubisoft's web account pages. Ubisoft refused the old one
    /// ("The Ubi-AppId header is invalid"); the first one Ubisoft accepts is kept
    /// with the session and used for its renewal and the library.
    static let appIDs = ["f68a4bb5-608a-4ff2-8123-be8ef797e0a6",
                         "314d4fef-e568-454a-ae06-43e3bece12a6",
                         "82b650c0-6cb3-40c0-9f41-25a53b62b206"]
    static var appID: String { load()?.appIDUsed ?? appIDs[0] }

    let name: String
    let ticket: String
    let remember: String?
    let expiry: Date
    let sessionID: String?
    /// The Ubi-AppId Ubisoft accepted for this session (nil: saved before 2.12.0).
    var appIDUsed: String?
    var expired: Bool { expiry <= Date() }

    /// Whether Ubisoft refused the request's Ubi-AppId (try the next one).
    static func refusedAppID(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("ubi-appid") || text.contains("appid")
    }

    static func request(appID: String = appID) -> URLRequest {
        var login = URLRequest(url: URL(string: "https://public-ubiservices.ubi.com/v3/profiles/sessions")!)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue(appID, forHTTPHeaderField: "Ubi-AppId")
        login.setValue("uplay", forHTTPHeaderField: "Ubi-RequestedPlatformType")
        login.httpBody = Data(#"{"rememberMe":true}"#.utf8)
        return login
    }

    static func decode(_ data: Data, previous: Self? = nil, appID: String? = nil) throws -> Self {
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let name = fields?["nameOnPlatform"] as? String, !name.isEmpty,
              let ticket = fields?["ticket"] as? String, !ticket.isEmpty,
              let timestamp = fields?["expiration"] as? String else { throw URLError(.cannotParseResponse) }
        let format = ISO8601DateFormatter()
        let seconds = format.date(from: timestamp)
        format.formatOptions.insert(.withFractionalSeconds)
        guard let expiry = seconds ?? format.date(from: timestamp) else { throw URLError(.cannotParseResponse) }
        return Self(name: name, ticket: ticket, remember: fields?["rememberMeTicket"] as? String ?? previous?.remember,
                    expiry: expiry, sessionID: fields?["sessionId"] as? String,
                    appIDUsed: appID ?? previous?.appIDUsed)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "iDeck.Ubisoft", kSecAttrAccount as String: "session"]
    }

    static func load() -> Self? {
        var search = query
        search[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(self),
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(Self.query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func clear() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
