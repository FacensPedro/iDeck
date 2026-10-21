import Foundation

class JITEnabler {
    private let defaultServerURL = "http://127.0.0.1:54321"
    private let requestTimeout: TimeInterval = 120

    /// Base URL of the JIT server. Configurable via UserDefaults ("jitServerURL");
    /// from the device's point of view "localhost" is the device itself, so a
    /// server running on a computer must be addressed explicitly.
    private var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "jitServerURL") ?? ""
        return stored.isEmpty ? defaultServerURL : stored
    }

    private var serverToken: String? {
        let token = UserDefaults.standard.string(forKey: "jitServerToken") ?? ""
        return token.isEmpty ? nil : token
    }

    private func makeRequest(endpoint: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)/\(endpoint)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        if let token = serverToken {
            request.setValue(token, forHTTPHeaderField: "X-JIT-Token")
        }
        return request
    }

    private func send(_ request: URLRequest, completion: @escaping (Bool) -> Void) {
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }
        task.resume()
    }

    func activate(for pid: Int32, useVPN: Bool = false, pairingFileURL: URL?, completion: @escaping (Bool) -> Void) {
        let endpoint = useVPN ? "enable_jit_vpn" : "enable_jit"
        guard var request = makeRequest(endpoint: endpoint) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["pid": Int(pid)]
        if let pairingURL = pairingFileURL, let pairingData = try? Data(contentsOf: pairingURL) {
            body["pairing_data"] = pairingData.base64EncodedString()
        }

        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
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
