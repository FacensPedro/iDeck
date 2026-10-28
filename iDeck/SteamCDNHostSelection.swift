import Foundation

final class ContentHostHealth: @unchecked Sendable {
    private struct State {
        var throughput: Double = 0
        var responseLatency: Double = 0
        var samples = 0
        var failures = 0

        var score: Double {
            throughput / (1 + min(responseLatency, 2) * 0.5)
        }
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]
    private var reportedFailures = 0

    func order(_ hosts: [String], seed: Int) -> [String] {
        guard hosts.count > 1 else { return hosts }
        let start = (seed % hosts.count + hosts.count) % hosts.count
        let rotated = (0..<hosts.count).map { hosts[($0 + start) % hosts.count] }

        lock.lock()
        let snapshot = states
        lock.unlock()

        let explore = seed % 12 == 0
        return rotated.enumerated().sorted { a, b in
            let left = snapshot[a.element] ?? State()
            let right = snapshot[b.element] ?? State()

            if left.failures != right.failures {
                return left.failures < right.failures
            }
            if explore && left.samples != right.samples {
                return left.samples < right.samples
            }
            if (left.samples > 0) != (right.samples > 0) {
                return left.samples > 0
            }
            if left.samples > 0 && right.samples > 0 && left.score != right.score {
                return left.score > right.score
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    func recordSuccess(_ host: String, bytes: Int,
                       seconds: Double, responseLatency: Double?) {
        guard bytes > 0, seconds.isFinite, seconds > 0 else { return }
        let throughput = Double(bytes) / max(0.001, seconds)
        guard throughput.isFinite else { return }

        lock.lock()
        var state = states[host] ?? State()
        state.throughput = state.samples == 0
            ? throughput : state.throughput * 0.75 + throughput * 0.25
        if let latency = responseLatency, latency.isFinite, latency >= 0 {
            let bounded = min(latency, 2)
            state.responseLatency = state.samples == 0
                ? bounded : state.responseLatency * 0.75 + bounded * 0.25
        }
        state.samples = min(1024, state.samples + 1)
        state.failures = max(0, state.failures - 1)
        states[host] = state
        lock.unlock()
    }

    @discardableResult
    func recordFailure(_ host: String) -> Bool {
        lock.lock()
        var state = states[host] ?? State()
        state.failures = min(20, state.failures + 1)
        states[host] = state
        let shouldReport = state.failures == 3 && reportedFailures < 8
        if shouldReport { reportedFailures += 1 }
        lock.unlock()
        return shouldReport
    }
}


/// Bounded, round-robin scheduling across Steam depots. Only the next work
/// index for each depot is retained, even for very large games.
struct SteamChunkScheduler {
    private let counts: [Int]
    private var offsets: [Int]
    private var nextDepot = 0
    private(set) var remaining: Int

    init(counts: [Int]) {
        self.counts = counts.map { max(0, $0) }
        offsets = [Int](repeating: 0, count: counts.count)
        remaining = self.counts.reduce(0, +)
    }

    mutating func next() -> (depot: Int, item: Int)? {
        guard remaining > 0, !counts.isEmpty else { return nil }
        for _ in counts.indices {
            let depot = nextDepot
            nextDepot = (nextDepot + 1) % counts.count
            guard offsets[depot] < counts[depot] else { continue }
            let item = offsets[depot]
            offsets[depot] += 1
            remaining -= 1
            return (depot, item)
        }
        return nil
    }

    /// Ordered waves of depots that can write concurrently without touching
    /// the same file. Depots whose manifests include the same output file
    /// stay sequential (the later depot retains the final contents), while
    /// independent depots can transfer together. An empty string is a
    /// skipped/directory manifest entry, not a file.
    static func batches(paths: [[String]]) -> [[Int]] {
        var lastBatchForFile: [String: Int] = [:]
        var batches: [[Int]] = []
        for (depot, files) in paths.enumerated() {
            let uniqueFiles = Set(files.filter { !$0.isEmpty }.map { $0.lowercased() })
            var batch = 0
            for file in uniqueFiles {
                if let previous = lastBatchForFile[file] {
                    batch = max(batch, previous + 1)
                }
            }
            while batches.count <= batch { batches.append([]) }
            batches[batch].append(depot)
            for file in uniqueFiles { lastBatchForFile[file] = batch }
        }
        return batches
    }
}
