import Combine
import DonkCore
import Foundation

final class RemoteRuntime: @unchecked Sendable {
    static let shared = RemoteRuntime()

    private let lock = DonkLock()
    private var client: RemoteClient?
    private var storedStatus: RemoteStatus = .stopped
    private let subject = CurrentValueSubject<RemoteStatus, Never>(.stopped)
    private let publication: PublicationQueue<RemoteStatus>

    init() {
        let subject = self.subject
        publication = PublicationQueue(latestOnly: true) { subject.send($0) }
    }

    var status: RemoteStatus {
        lock.withLock { storedStatus }
    }

    var statusChanges: AnyPublisher<RemoteStatus, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    func start(_ configuration: RemoteConfiguration) {
        guard configuration.isEnabled else { return }
        let identity = RemoteIdentity.current()
        let crashes = LiveCrashProvider()
        let ui = LiveUIProvider()
        let context = RemoteContext(
            identity: identity,
            store: .shared,
            settings: .shared,
            rules: .shared,
            crashes: crashes,
            ui: ui,
            redacts: configuration.redacts,
            redaction: configuration.redaction
        )
        let client = RemoteClient(
            url: configuration.hubURL,
            handler: RemoteRequestHandler(context: context),
            hello: {
                let hasScene = await ui.hasForegroundScene()
                return identity.hello(hasCrashes: crashes.isInstalled, hasForegroundScene: hasScene)
            },
            onStatus: { [weak self] client, status in
                self?.update(status, from: client)
            }
        )
        let previous: RemoteClient? = lock.withLock {
            let previous = self.client
            self.client = client
            setLocked(.connecting)
            return previous
        }
        publication.flush()
        previous?.stop()
        client.start()
    }

    func stop() {
        let previous: RemoteClient? = lock.withLock {
            let previous = client
            client = nil
            setLocked(.stopped)
            return previous
        }
        publication.flush()
        previous?.stop()
    }

    private func update(_ status: RemoteStatus, from client: RemoteClient) {
        lock.withLock {
            guard self.client === client else { return }
            setLocked(status)
        }
        publication.flush()
    }

    private func setLocked(_ status: RemoteStatus) {
        guard storedStatus != status else { return }
        storedStatus = status
        publication.enqueue(status)
    }
}
