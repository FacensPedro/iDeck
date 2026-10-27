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
