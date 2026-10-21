import Foundation

class JITEnabler {
    private let debugServerPort: UInt16 = 54321
    
    func activate(for pid: Int32, useVPN: Bool = false, completion: @escaping (Bool) -> Void) {
        let endpoint = useVPN ? "enable_jit_vpn" : "enable_jit"
        let urlString = "http://localhost:\(debugServerPort)/\(endpoint)?pid=\(pid)"
        
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }
    
    func mountDeveloperDiskImage(urls: [URL], completion: @escaping (Bool) -> Void) {
        guard urls.count >= 2 else {
            completion(false)
            return
        }
        
        let urlString = "http://localhost:\(debugServerPort)/mount_ddi"
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                completion(true)
            } else {
                completion(false)
            }
        }
        task.resume()
    }
}
