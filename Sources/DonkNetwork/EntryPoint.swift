import DonkCore
import Foundation

public struct NetworkCaptureConfiguration: Sendable {
    public var isEnabled = true
    public var bypassHosts: [String] = []

    public init() {}
}

public enum DonkNetworkCapture {
    public static func start(_ configuration: NetworkCaptureConfiguration) {
        CaptureEngine.shared.start(configuration)
    }

    public static func stop() {
        CaptureEngine.shared.stop()
    }

    public static var isRunning: Bool { CaptureEngine.shared.isRunning }

    public static func inject(into configuration: URLSessionConfiguration) {
        SessionInjector.inject(into: configuration)
    }

    public static var configuration: NetworkCaptureConfiguration { CaptureEngine.shared.configuration }
}
