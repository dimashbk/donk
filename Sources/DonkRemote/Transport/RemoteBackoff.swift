import Foundation

struct RemoteBackoff: Equatable, Sendable {
    static let standard = RemoteBackoff(delays: [1, 2, 4, 8, 16, 30])

    var delays: [TimeInterval]
    var welcomeTimeout: TimeInterval = 10

    func delay(afterFailures failures: Int) -> TimeInterval {
        guard let last = delays.last else { return 0 }
        let index = max(0, failures - 1)
        return index < delays.count ? delays[index] : last
    }
}
