import Combine
import DonkCore
import Foundation

public struct RemoteConfiguration: Sendable {
    public var isEnabled = false
    public var hubURL = URL(string: "ws://127.0.0.1:7337/app")!
    public var redacts = true
    public var redaction: RedactionPolicy?

    public init() {}
}

public enum RemoteStatus: Equatable, Sendable {
    case stopped
    case connecting
    case connected
    case rejected(String)
}

public enum DonkRemote {
    public static func start(_ configuration: RemoteConfiguration) {
        RemoteRuntime.shared.start(configuration)
    }

    public static func stop() {
        RemoteRuntime.shared.stop()
    }

    public static var status: RemoteStatus {
        RemoteRuntime.shared.status
    }

    public static var statusChanges: AnyPublisher<RemoteStatus, Never> {
        RemoteRuntime.shared.statusChanges
    }
}
