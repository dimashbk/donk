import Combine
import DonkCore
import Foundation
import UserNotifications

final class PushState: @unchecked Sendable {
    static let shared = PushState()

    private let lock = DonkLock()
    private var storedConfiguration = PushConfiguration()
    private var storedDeviceToken: Data?
    private var storedFCMToken: String?
    private var storedProcessor: (@Sendable (UNMutableNotificationContent) async -> UNNotificationContent)?
    private let subject = PassthroughSubject<Void, Never>()

    var configuration: PushConfiguration {
        get { lock.withLock { storedConfiguration } }
        set {
            lock.withLock { storedConfiguration = newValue }
            subject.send(())
        }
    }

    var deviceToken: Data? {
        get { lock.withLock { storedDeviceToken } }
        set {
            lock.withLock { storedDeviceToken = newValue }
            subject.send(())
        }
    }

    var fcmToken: String? {
        get { lock.withLock { storedFCMToken } }
        set {
            lock.withLock { storedFCMToken = newValue }
            subject.send(())
        }
    }

    var contentProcessor: (@Sendable (UNMutableNotificationContent) async -> UNNotificationContent)? {
        get { lock.withLock { storedProcessor } }
        set { lock.withLock { storedProcessor = newValue } }
    }

    var changes: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
