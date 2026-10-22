import Foundation

class JITEnabler {
    private let defaultServerURL = ""
    private let requestTimeout: TimeInterval = 120

    /// Base URL of the JIT server. Configurable via UserDefaults ("jitServerURL");
    /// from the device's point of view "localhost" is the device itself, so a
    /// server running on a computer must be addressed explicitly.
    private var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "jitServerURL") ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultServerURL : stored.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var serverToken: String? {
        let token = UserDefaults.standard.string(forKey: "jitServerToken") ?? ""
        return token.isEmpty ? nil : token
    }

    private func makeRequest(endpoint: String) -> URLRequest? {
        guard !baseURL.isEmpty else {
            lastError = "JIT server address is not configured. Enter the reachable computer/server address in Settings."
            return nil
        }
        guard let url = URL(string: "\(baseURL)/\(endpoint)"),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            lastError = "Invalid JIT server URL. Enter a valid http:// or https:// address."
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        if let token = serverToken {
            request.setValue(token, forHTTPHeaderField: "X-JIT-Token")
        }
        return request
    }

    /// Human-readable reason of the last failed request (nil after a success).
    private(set) var lastError: String?

    private func send(_ request: URLRequest, completion: @escaping (Bool) -> Void) {
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var failure: String?
            if let error = error {
                failure = "JIT server unreachable at \(request.url?.host ?? "?") (\(error.localizedDescription))"
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                failure = http.statusCode == 401 ? "JIT server rejected the token" : (body.isEmpty ? "HTTP \(http.statusCode)" : body)
            }
            DispatchQueue.main.async {
                self?.lastError = failure
                completion(failure == nil)
            }
        }
        task.resume()
    }

    func activate(for pid: Int32, useVPN: Bool = false, completion: @escaping (Bool) -> Void) {
        let endpoint = useVPN ? "enable_jit_vpn" : "enable_jit"
        guard var request = makeRequest(endpoint: endpoint) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // The pairing file (it contains a private key) is deliberately never sent over the network.
        guard let payload = try? JSONSerialization.data(withJSONObject: ["pid": Int(pid)]) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        request.httpBody = payload
        send(request, completion: completion)
    }

    /// The server mounts the Developer Disk Image itself (`pymobiledevice3 mounter auto-mount`),
    /// so no local files need to be sent.
    func mountDeveloperDiskImage(completion: @escaping (Bool) -> Void) {
        guard let request = makeRequest(endpoint: "mount_ddi") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        send(request, completion: completion)
    }
}
