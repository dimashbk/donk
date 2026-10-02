import Darwin
import Foundation

enum LaterCrashReporter {
    static let previous: UnsafeMutablePointer<sigaction> = {
        let pointer = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
        pointer.initialize(repeating: sigaction(), count: Int(NSIG))
        return pointer
    }()

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let storage = previous
        for signal in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = laterCrashReporterHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, storage + Int(signal))
        }
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-DonkCrashLaterReporter")
    }
}

private func resetHandledSignals() {
    var reset = sigaction()
    sigemptyset(&reset.sa_mask)
    sigaction(SIGABRT, &reset, nil)
    sigaction(SIGBUS, &reset, nil)
    sigaction(SIGFPE, &reset, nil)
    sigaction(SIGILL, &reset, nil)
    sigaction(SIGSEGV, &reset, nil)
    sigaction(SIGSYS, &reset, nil)
    sigaction(SIGTRAP, &reset, nil)
}

private func reinstallPrevious(_ storage: UnsafeMutablePointer<sigaction>) {
    sigaction(SIGABRT, storage + Int(SIGABRT), nil)
    sigaction(SIGBUS, storage + Int(SIGBUS), nil)
    sigaction(SIGFPE, storage + Int(SIGFPE), nil)
    sigaction(SIGILL, storage + Int(SIGILL), nil)
    sigaction(SIGSEGV, storage + Int(SIGSEGV), nil)
    sigaction(SIGSYS, storage + Int(SIGSYS), nil)
    sigaction(SIGTRAP, storage + Int(SIGTRAP), nil)
}

private let laterCrashReporterHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
    let storage = LaterCrashReporter.previous
    resetHandledSignals()
    var everything = sigset_t()
    sigfillset(&everything)
    sigprocmask(SIG_UNBLOCK, &everything, nil)
    reinstallPrevious(storage)
    let saved = storage[Int(signal)]
    if saved.sa_flags & SA_SIGINFO != 0 {
        saved.__sigaction_u.__sa_sigaction?(signal, info, context)
    } else if let handler = saved.__sigaction_u.__sa_handler, unsafeBitCast(handler, to: Int.self) > 1 {
        handler(signal)
    }
}
