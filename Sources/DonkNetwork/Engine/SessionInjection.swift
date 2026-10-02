import DonkCore
import Foundation
import ObjectiveC.runtime

// MARK: - Swizzle

package final class SessionSwizzler: @unchecked Sendable {
    private static let state = SessionSwizzler()

    private let lock = DonkLock()
    private var installed = false

    package static var isInstalled: Bool { state.lock.withLock { state.installed } }

    package static func install() {
        let shouldInstall: Bool = state.lock.withLock {
            guard !state.installed else { return false }
            state.installed = true
            return true
        }
        guard shouldInstall else { return }
        let didSwizzle = DonkSwizzle.classMethod(
            URLSession.self,
            NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:"),
            #selector(URLSession.donk_session(configuration:delegate:delegateQueue:))
        )
        if !didSwizzle {
            state.lock.withLock { state.installed = false }
        }
    }
}

extension URLSession {
    @objc(donk_sessionWithConfiguration:delegate:delegateQueue:)
    dynamic class func donk_session(
        configuration: URLSessionConfiguration?,
        delegate: URLSessionDelegate?,
        delegateQueue queue: OperationQueue?
    ) -> URLSession? {
        let prepared = SessionInjector.prepare(configuration)
        let session = donk_session(configuration: prepared.configuration, delegate: delegate, delegateQueue: queue)
        if let session, let context = prepared.context {
            SessionInjector.attach(context, to: session)
        }
        return session
    }
}

// MARK: - Injection

package enum SessionInjector {
    private static let contextKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    package static func prepare(_ configuration: URLSessionConfiguration?) -> (configuration: URLSessionConfiguration?, context: SessionContext?) {
        guard let configuration, isEligible(configuration),
              CaptureEngine.shared.isRunning || containsDonkClass(configuration.protocolClasses),
              let copy = configuration.copy() as? URLSessionConfiguration
        else { return (configuration, nil) }
        let foreign = foreignClasses(copy.protocolClasses)
        let context = SessionContextRegistry.shared.makeContext(template: copy, foreignClasses: foreign)
        copy.protocolClasses = [context?.protocolClass ?? DonkURLProtocol.self] + foreign
        return (copy, context)
    }

    package static func attach(_ context: SessionContext, to session: URLSession) {
        context.outerSession = session
        objc_setAssociatedObject(session, contextKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    package static func context(of session: URLSession) -> SessionContext? {
        objc_getAssociatedObject(session, contextKey) as? SessionContext
    }

    package static func inject(into configuration: URLSessionConfiguration) {
        guard isEligible(configuration) else { return }
        SessionSwizzler.install()
        let registry = SessionContextRegistry.shared
        let foreign = foreignClasses(configuration.protocolClasses)
        if let existing = configuration.protocolClasses?.first(where: { isDonkClass($0) && registry.isInjected($0) }) {
            configuration.protocolClasses = [existing] + foreign
            return
        }
        let context = registry.makeInjectedContext(template: configuration, foreignClasses: foreign)
        configuration.protocolClasses = [context?.protocolClass ?? DonkURLProtocol.self] + foreign
    }

    package static func containsDonkClass(_ classes: [AnyClass]?) -> Bool {
        (classes ?? []).contains { isDonkClass($0) }
    }

    package static func isEligible(_ configuration: URLSessionConfiguration) -> Bool {
        configuration.identifier == nil && !DonkEnvironment.isInternal(configuration)
    }

    package static func isDonkClass(_ cls: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let candidate = current {
            if candidate === DonkURLProtocol.self { return true }
            current = class_getSuperclass(candidate)
        }
        return false
    }

    package static func foreignClasses(_ classes: [AnyClass]?) -> [AnyClass] {
        (classes ?? []).filter { !isDonkClass($0) }
    }
}

// MARK: - Context

package final class SessionContext: @unchecked Sendable {
    package let protocolClass: AnyClass
    package let additionalHeaders: [HTTPHeader]
    package let foreignClasses: [AnyClass]

    private let template: URLSessionConfiguration
    private let recyclable: Bool
    private let lock = DonkLock()
    private var session: URLSession?
    private weak var outer: URLSession?
    private let delegateQueue: OperationQueue

    init(protocolClass: AnyClass, template: URLSessionConfiguration, foreignClasses: [AnyClass], recyclable: Bool) {
        self.protocolClass = protocolClass
        self.template = (template.copy() as? URLSessionConfiguration) ?? template
        self.foreignClasses = foreignClasses
        self.recyclable = recyclable
        additionalHeaders = HTTPHeader.list(from: template.httpAdditionalHeaders)
        let queue = OperationQueue()
        queue.name = "dev.donk.network.inner"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        delegateQueue = queue
    }

    deinit {
        session?.finishTasksAndInvalidate()
        if recyclable {
            SessionContextRegistry.shared.recycle(protocolClass)
        }
    }

    package var innerSession: URLSession {
        let testClasses = CaptureEngine.shared.innerProtocolClasses
        return lock.withLock {
            if let session { return session }
            let configuration = (template.copy() as? URLSessionConfiguration) ?? .default
            configuration.protocolClasses = testClasses + foreignClasses
            DonkEnvironment.markInternal(configuration)
            let created = URLSession(configuration: configuration, delegate: InnerSessionDelegate.shared, delegateQueue: delegateQueue)
            session = created
            return created
        }
    }

    package var innerConfiguration: URLSessionConfiguration { innerSession.configuration }

    package var outerSession: URLSession? {
        get { lock.withLock { outer } }
        set { lock.withLock { outer = newValue } }
    }

    func resetSession() {
        let previous: URLSession? = lock.withLock {
            defer { session = nil }
            return session
        }
        previous?.finishTasksAndInvalidate()
    }
}

// MARK: - Registry

package final class SessionContextRegistry: @unchecked Sendable {
    package static let shared = SessionContextRegistry()

    private final class WeakContext {
        weak var value: SessionContext?
        init(_ value: SessionContext) { self.value = value }
    }

    private let lock = DonkLock()
    private var live: [ObjectIdentifier: WeakContext] = [:]
    private var injected: [ObjectIdentifier: SessionContext] = [:]
    private var freeClasses: [AnyClass] = []
    private var classCount = 0
    private var nameIndex = 0
    private var fallback: SessionContext?

    package var defaultContext: SessionContext {
        lock.withLock {
            if let fallback { return fallback }
            let template = URLSessionConfiguration.default
            let context = SessionContext(
                protocolClass: DonkURLProtocol.self,
                template: template,
                foreignClasses: SessionInjector.foreignClasses(template.protocolClasses),
                recyclable: false
            )
            fallback = context
            return context
        }
    }

    package func makeContext(template: URLSessionConfiguration, foreignClasses: [AnyClass]) -> SessionContext? {
        lock.withLock {
            guard let protocolClass = dequeueClassLocked() else { return nil }
            let context = SessionContext(protocolClass: protocolClass, template: template, foreignClasses: foreignClasses, recyclable: true)
            live[ObjectIdentifier(protocolClass)] = WeakContext(context)
            return context
        }
    }

    package func makeInjectedContext(template: URLSessionConfiguration, foreignClasses: [AnyClass]) -> SessionContext? {
        lock.withLock {
            guard let protocolClass = dequeueClassLocked() else { return nil }
            let context = SessionContext(protocolClass: protocolClass, template: template, foreignClasses: foreignClasses, recyclable: false)
            let key = ObjectIdentifier(protocolClass)
            live[key] = WeakContext(context)
            injected[key] = context
            return context
        }
    }

    package func isInjected(_ protocolClass: AnyClass) -> Bool {
        lock.withLock { injected[ObjectIdentifier(protocolClass)] != nil }
    }

    package func context(for protocolClass: AnyClass) -> SessionContext {
        if protocolClass !== DonkURLProtocol.self,
           let context = lock.withLock({ live[ObjectIdentifier(protocolClass)]?.value }) {
            return context
        }
        return defaultContext
    }

    package var liveContextCount: Int {
        let contexts: [SessionContext] = lock.withLock { live.values.compactMap(\.value) }
        return contexts.count
    }

    package var allocatedClassCount: Int {
        lock.withLock { classCount }
    }

    package func isRecycled(_ protocolClass: AnyClass) -> Bool {
        lock.withLock { freeClasses.contains { $0 === protocolClass } }
    }

    func recycle(_ protocolClass: AnyClass) {
        lock.withLock {
            let key = ObjectIdentifier(protocolClass)
            if let entry = live[key], entry.value == nil {
                live[key] = nil
            }
            freeClasses.append(protocolClass)
        }
    }

    func resetInnerSessions() {
        let contexts: [SessionContext] = lock.withLock {
            live.values.compactMap(\.value) + (fallback.map { [$0] } ?? [])
        }
        contexts.forEach { $0.resetSession() }
    }

    private func dequeueClassLocked() -> AnyClass? {
        if let reused = freeClasses.popLast() { return reused }
        for _ in 0..<32 {
            nameIndex += 1
            let name = "DonkURLProtocolSession\(nameIndex)"
            guard let allocated = objc_allocateClassPair(DonkURLProtocol.self, name, 0) else { continue }
            objc_registerClassPair(allocated)
            classCount += 1
            return allocated
        }
        return nil
    }
}
