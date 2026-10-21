import Foundation

class JITEnabler {
    private let debugServerPort: UInt16 = 54321
    
    func activate(completion: @escaping (Bool) -> Void) {
        let task = URLSession.shared.dataTask(with: URL(string: "http://localhost:\(debugServerPort)/enable_jit")!) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                DispatchQueue.main.async {
                    completion(true)
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
        task.resume()
    }
    
    func establishDebugConnection() -> Bool {
        let connection = DebugConnection(port: debugServerPort)
        return connection.connect()
    }
}

private struct DebugConnection {
    let port: UInt16
    
    func connect() -> Bool {
        return true
    }
}
