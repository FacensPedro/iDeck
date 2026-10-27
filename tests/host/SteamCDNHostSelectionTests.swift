import Foundation

@main
struct SteamCDNHostSelectionTests {
    static func main() {
        let hosts = ["https://cdn-a.example.com",
                     "https://cdn-b.example.com",
                     "https://cdn-c.example.com"]
        let health = ContentHostHealth()

        assert(health.order([], seed: 0).isEmpty)
        assert(health.order(hosts, seed: 0) == hosts)
        assert(health.order(hosts, seed: 1).first == hosts[1])
        assert(health.order(hosts, seed: 2).first == hosts[2])

        health.recordSuccess(hosts[0], bytes: 1_000_000, seconds: 0.5,
                             responseLatency: 0.30)
        health.recordSuccess(hosts[1], bytes: 1_000_000, seconds: 0.1,
                             responseLatency: 0.05)
        health.recordSuccess(hosts[2], bytes: 1_000_000, seconds: 0.2,
                             responseLatency: 0.10)
        assert(health.order(hosts, seed: 1).first == hosts[1])

        let responseTime = ContentHostHealth()
        responseTime.recordSuccess(hosts[0], bytes: 1_000_000, seconds: 0.2,
                                   responseLatency: 0.01)
        responseTime.recordSuccess(hosts[1], bytes: 1_000_000, seconds: 0.2,
                                   responseLatency: 0.80)
        assert(responseTime.order([hosts[0], hosts[1]], seed: 1).first == hosts[0])

        for _ in 0..<5 {
            health.recordSuccess(hosts[1], bytes: 1_000_000, seconds: 0.1,
                                 responseLatency: 0.05)
        }
        assert(health.order(hosts, seed: 12).first == hosts[2])

        assert(!health.recordFailure(hosts[1]))
        assert(!health.recordFailure(hosts[1]))
        assert(health.recordFailure(hosts[1]))
        assert(!health.recordFailure(hosts[1]))
        assert(health.order(hosts, seed: 1).last == hosts[1])

        for _ in 0..<4 {
            health.recordSuccess(hosts[1], bytes: 1_000_000, seconds: 0.1,
                                 responseLatency: 0.05)
        }
        assert(health.order(hosts, seed: 1).first == hosts[1])

        let invalid = ContentHostHealth()
        invalid.recordSuccess(hosts[0], bytes: 0, seconds: 0, responseLatency: nil)
        invalid.recordSuccess(hosts[1], bytes: 1_000_000, seconds: .nan,
                              responseLatency: .infinity)
        assert(invalid.order(hosts, seed: 1).first == hosts[1])

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            health.recordSuccess(hosts[index % hosts.count], bytes: 1024,
                                 seconds: 0.01, responseLatency: 0.002)
            _ = health.order(hosts, seed: index)
        }

        print("PASS: Steam CDN throughput, response latency, exploration, failover, and concurrent ranking")
    }
}
