import Combine
import Donk
import DonkGRPC
import DonkUI
import Foundation
import GRPC
import NIOCore
import SwiftUI

@MainActor
final class GRPCDemoModel: ObservableObject {
    enum ServerState: Equatable {
        case starting
        case running(port: Int)
        case failed(String)
    }

    enum Outcome {
        case success, failure, info
    }

    struct Activity: Identifiable {
        let id = UUID()
        let date = Date()
        let title: String
        let detail: String
        let outcome: Outcome
    }

    struct ChatLine: Identifiable {
        let id = UUID()
        let isMine: Bool
        let text: String
    }

    static let sampleMockRuleID = UUID(uuidString: "6D5DFC00-0000-4000-8000-00000000E001")!
    static let sampleBreakpointRuleID = UUID(uuidString: "6D5DFC00-0000-4000-8000-00000000E002")!

    @Published private(set) var serverState = ServerState.starting
    @Published private(set) var activity: [Activity] = []
    @Published private(set) var entries: [NetworkEntry] = []
    @Published private(set) var pending: [PausedExchange] = []
    @Published private(set) var hasSampleRules = false
    @Published private(set) var rulesEnabled = true
    @Published private(set) var streamProgress: Int?
    @Published private(set) var isCollecting = false
    @Published private(set) var isFlooding = false
    @Published private(set) var isChatOpen = false
    @Published private(set) var chat: [ChatLine] = []
    @Published var chatDraft = ""
    @Published var usesPublicServer = false

    let streamLength = 20
    let floodLength = 5000
    private let backend = GRPCDemoBackend.shared
    private var chatCall: BidirectionalStreamingCall<EchoRequest, EchoResponse>?
    private var collectCall: ClientStreamingCall<EchoRequest, EchoResponse>?
    private var doomedCall: ServerStreamingCall<EchoRequest, EchoResponse>?
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NetworkStore.shared.events
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.reloadEntries() }
            .store(in: &cancellables)
        BreakpointCenter.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exchanges in self?.pending = exchanges.filter { $0.kind == .grpc } }
            .store(in: &cancellables)
        RuleStore.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rules in self?.reloadRules(rules) }
            .store(in: &cancellables)
        reloadEntries()
        reloadRules(RuleStore.shared.rules)
        backend.start().whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                switch result {
                case let .success(port):
                    self?.serverState = .running(port: port)
                case let .failure(error):
                    self?.serverState = .failed(String(describing: error))
                }
            }
        }
    }

    var recentEntries: [NetworkEntry] { entries }

    // MARK: - Unary

    func unary() {
        guard let client = echoClient() else { return }
        var request = EchoRequest()
        request.text = "Hello from donk"
        request.mood = .happy
        let call = client.get(request, callOptions: CallOptions(customMetadata: ["authorization": "Bearer demo-token", "x-request-id": UUID().uuidString]))
        report("Get", call.response.map(\.text), status: call.status)
    }

    func unaryError() {
        guard let client = echoClient() else { return }
        var request = EchoRequest()
        request.text = "status:5:Account 42 was not found"
        let call = client.get(request)
        report("Get (error)", call.response.map(\.text), status: call.status)
    }

    func deadlineExceeded() {
        guard let client = echoClient() else { return }
        var request = EchoRequest()
        request.text = "sleep:1500"
        let call = client.get(request, callOptions: CallOptions(timeLimit: .timeout(.milliseconds(500))))
        report("Get (500 ms deadline)", call.response.map(\.text), status: call.status)
    }

    // MARK: - Streaming

    func serverStream() {
        guard streamProgress == nil, let client = echoClient() else { return }
        var request = EchoRequest()
        request.text = "Tick"
        request.repeatCount = Int32(streamLength)
        request.intervalMs = 200
        streamProgress = 0
        let call = client.expand(request) { _ in
            DispatchQueue.main.async { [weak self] in
                self?.streamProgress = (self?.streamProgress ?? 0) + 1
            }
        }
        call.status.whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let count = streamProgress ?? 0
                streamProgress = nil
                record("Expand", result: result, success: "\(count) messages received")
            }
        }
    }

    func floodStream() {
        guard !isFlooding, let client = echoClient() else { return }
        isFlooding = true
        var request = EchoRequest()
        request.text = "Burst"
        request.repeatCount = Int32(floodLength)
        let started = Date()
        let call = client.expand(request) { _ in }
        call.status.whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isFlooding = false
                let elapsed = Date().timeIntervalSince(started)
                record("Expand (burst)", result: result, success: "\(floodLength) messages in \(String(format: "%.2f", elapsed)) s")
            }
        }
    }

    func clientStream() {
        guard collectCall == nil, let client = echoClient() else { return }
        isCollecting = true
        let call = client.collect()
        collectCall = call
        call.status.whenComplete { _ in
            DispatchQueue.main.async { [weak self] in
                self?.isCollecting = false
                self?.collectCall = nil
            }
        }
        report("Collect", call.response.map { "“\($0.text)” (\($0.index) messages)" }, status: call.status)
        Task { [weak self] in
            for word in ["donk", "records", "every", "streamed", "message"] {
                try? await Task.sleep(nanoseconds: 150_000_000)
                var request = EchoRequest()
                request.text = word
                self?.collectCall?.sendMessage(request, promise: nil)
            }
            self?.collectCall?.sendEnd(promise: nil)
        }
    }

    func cancelStream() {
        guard doomedCall == nil, let client = echoClient() else { return }
        var request = EchoRequest()
        request.text = "Long stream"
        request.repeatCount = 100
        request.intervalMs = 100
        let call = client.expand(request) { _ in }
        doomedCall = call
        call.status.whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                self?.doomedCall = nil
                self?.record("Expand (cancelled after 1.5 s)", result: result, success: "Completed")
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.doomedCall?.cancel(promise: nil)
        }
    }

    // MARK: - Chat

    func openChat() {
        guard chatCall == nil, let client = echoClient() else { return }
        chat = []
        isChatOpen = true
        let call = client.update(callOptions: CallOptions(timeLimit: .none)) { response in
            DispatchQueue.main.async { [weak self] in
                self?.chat.append(ChatLine(isMine: false, text: response.text))
            }
        }
        chatCall = call
        call.status.whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                chatCall = nil
                isChatOpen = false
                record("Update (chat)", result: result, success: "Chat closed")
            }
        }
        send("Hi there")
    }

    func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatDraft = ""
        send(text)
    }

    func closeChat() {
        chatCall?.sendEnd(promise: nil)
    }

    private func send(_ text: String) {
        guard let chatCall else { return }
        var request = EchoRequest()
        request.text = text
        chat.append(ChatLine(isMine: true, text: text))
        chatCall.sendMessage(request, promise: nil)
    }

    // MARK: - Public server

    func sayHello() {
        var request = Hello_HelloRequest()
        request.greeting = "donk"
        let call = backend.hello.sayHello(request)
        report("grpcb.in SayHello", call.response.map(\.reply), status: call.status)
    }

    func lotsOfReplies() {
        var request = Hello_HelloRequest()
        request.greeting = "donk"
        let call = backend.hello.lotsOfReplies(request) { _ in }
        call.status.whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                self?.record("grpcb.in LotsOfReplies", result: result, success: "Stream finished")
            }
        }
    }

    // MARK: - Rules & breakpoints

    func toggleSampleRules() {
        if hasSampleRules {
            RuleStore.shared.remove(Self.sampleMockRuleID)
            RuleStore.shared.remove(Self.sampleBreakpointRuleID)
            reloadRules(RuleStore.shared.rules)
            DonkToast.show("Sample rules removed", icon: "trash", tone: .neutral)
        } else {
            addSampleRules()
        }
    }

    func addSampleRules() {
        let mock = MockResponse(
            headers: [HTTPHeader(name: "x-donk-mock", value: "true")],
            delay: 0.4,
            grpcStatusCode: 0,
            grpcMessages: [#"{"text":"Hello from a donk mock","index":42,"mood":"MOOD_HAPPY"}"#]
        )
        RuleStore.shared.add(NetworkRule(
            id: Self.sampleMockRuleID,
            name: "Mock Echo.Get",
            match: RuleMatch(kinds: [.grpc], url: URLMatcher(pattern: "/donk.echo.v1.Echo/Get")),
            action: .mapLocal(mock)
        ))
        RuleStore.shared.add(NetworkRule(
            id: Self.sampleBreakpointRuleID,
            name: "Pause Echo.Expand responses",
            match: RuleMatch(kinds: [.grpc], url: URLMatcher(pattern: "/donk.echo.v1.Echo/Expand")),
            action: .breakpoint(request: false, response: true)
        ))
        RuleStore.shared.isEnabled = true
        reloadRules(RuleStore.shared.rules)
        DonkToast.show("Sample gRPC rules added", icon: "wand.and.stars", tone: .success)
    }

    func resume(_ exchange: PausedExchange) {
        BreakpointCenter.shared.resolve(exchange.id, with: .resume(exchange.payload))
    }

    func abort(_ exchange: PausedExchange) {
        BreakpointCenter.shared.resolve(exchange.id, with: .abort)
    }

    func resumeAll() {
        for exchange in pending {
            resume(exchange)
        }
    }

    func clearEntries() {
        let ids = Set(NetworkStore.shared.snapshot().filter { $0.kind == .grpc && !$0.isPinned }.map(\.id))
        NetworkStore.shared.remove(ids)
    }

    // MARK: - Private

    private func echoClient() -> Donk_Echo_V1_EchoNIOClient? {
        guard let client = backend.echo else {
            DonkToast.show("Echo server is not running yet", tone: .warning)
            return nil
        }
        return client
    }

    private func reloadEntries() {
        entries = Array(NetworkStore.shared.snapshot().lazy.filter { $0.kind == .grpc }.prefix(12))
    }

    private func reloadRules(_ rules: [NetworkRule]) {
        let ids = Set(rules.map(\.id))
        hasSampleRules = ids.contains(Self.sampleMockRuleID) || ids.contains(Self.sampleBreakpointRuleID)
        rulesEnabled = RuleStore.shared.isEnabled
    }

    private func report(_ title: String, _ response: EventLoopFuture<String>, status: EventLoopFuture<GRPCStatus>) {
        response.and(status).whenComplete { result in
            DispatchQueue.main.async { [weak self] in
                switch result {
                case let .success((text, _)):
                    self?.push(Activity(title: title, detail: text, outcome: .success))
                case .failure:
                    status.whenSuccess { status in
                        DispatchQueue.main.async { [weak self] in
                            self?.push(Activity(title: title, detail: Self.describe(status), outcome: .failure))
                        }
                    }
                }
            }
        }
    }

    private func record(_ title: String, result: Result<GRPCStatus, Error>, success: String) {
        switch result {
        case let .success(status) where status.isOk:
            push(Activity(title: title, detail: success, outcome: .success))
        case let .success(status):
            push(Activity(title: title, detail: Self.describe(status), outcome: status.code == .cancelled ? .info : .failure))
        case let .failure(error):
            push(Activity(title: title, detail: String(describing: error), outcome: .failure))
        }
    }

    private func push(_ item: Activity) {
        activity.insert(item, at: 0)
        if activity.count > 6 { activity.removeLast(activity.count - 6) }
        switch item.outcome {
        case .success: DonkHaptics.success()
        case .failure: DonkHaptics.error()
        case .info: DonkHaptics.light()
        }
    }

    private static func describe(_ status: GRPCStatus) -> String {
        let name = GRPCDetails.statusName(for: status.code.rawValue)
        guard let message = status.message, !message.isEmpty else { return name }
        return "\(name) · \(message)"
    }
}
