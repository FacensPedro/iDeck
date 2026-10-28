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
            health.recordSuccess(hosts[0], bytes: 1_000_000, seconds: 0.5,
                                 responseLatency: 0.30)
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

        // Chunk work is interleaved without ever pre-materializing a huge
        // per-game list, and empty depots never create phantom work.
        var schedule = SteamChunkScheduler(counts: [3, 1, 2])
        var order: [String] = []
        while let item = schedule.next() {
            order.append("\(item.depot):\(item.item)")
        }
        assert(order == ["0:0", "1:0", "2:0", "0:1", "2:1", "0:2"])
        assert(schedule.remaining == 0 && schedule.next() == nil)
        var emptySchedule = SteamChunkScheduler(counts: [0, 0])
        assert(emptySchedule.remaining == 0 && emptySchedule.next() == nil)
        var veryLargeSchedule = SteamChunkScheduler(counts: [250_000, 0])
        assert(veryLargeSchedule.next()?.item == 0)
        assert(veryLargeSchedule.remaining == 249_999)

        // Output files shared between depots cannot be written concurrently.
        // Last-writer order for Steam's overlay remains the same.
        let batches = SteamChunkScheduler.batches(paths: [
            ["/game/a", "/game/b", ""],
            ["/game/c"],
            ["/game/a", "/game/d"],
            ["/game/d"],
            ["/game/e"],
            ["/game/b", "/game/c"]
        ])
        assert(batches == [[0, 1, 4], [2, 5], [3]], "\(batches)")
        assert(SteamChunkScheduler.batches(paths: [
            ["/game/one"], ["/game/two"], ["/game/three"]
        ]) == [[0, 1, 2]])
        assert(SteamChunkScheduler.batches(paths: [
            ["/game/shared"], ["/game/shared"], ["/game/shared"]
        ]) == [[0], [1], [2]])
        assert(SteamChunkScheduler.batches(paths: [
            ["/Games/Foo/File.DLL"], ["/games/foo/file.dll"]
        ]) == [[0], [1]])
        assert(SteamChunkScheduler.batches(paths: []).isEmpty)

        print("PASS: Steam CDN throughput, response latency, exploration, failover, and concurrent ranking and fair depot pipelining")
    }
}
