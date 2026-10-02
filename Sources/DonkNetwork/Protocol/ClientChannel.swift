import Foundation

package final class ClientChannel: @unchecked Sendable {
    package let thread: Thread
    package let modes: [String]

    package init(thread: Thread = .current, currentMode: RunLoop.Mode? = RunLoop.current.currentMode) {
        self.thread = thread
        var modes = [RunLoop.Mode.default.rawValue]
        if let currentMode, currentMode != .default {
            modes.append(currentMode.rawValue)
        }
        self.modes = modes
    }

    package func perform(_ block: @escaping () -> Void) {
        let invocation = ClientInvocation(block)
        invocation.perform(#selector(ClientInvocation.invoke), on: thread, with: nil, waitUntilDone: false, modes: modes)
    }
}

private final class ClientInvocation: NSObject {
    private let block: () -> Void

    init(_ block: @escaping () -> Void) {
        self.block = block
    }

    @objc func invoke() {
        block()
    }
}
