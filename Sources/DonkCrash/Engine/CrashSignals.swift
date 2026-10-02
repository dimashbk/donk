import Foundation

enum CrashSignals {
    static func name(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: return "SIGHUP"
        case SIGINT: return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGEMT: return "SIGEMT"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGBUS: return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGSYS: return "SIGSYS"
        case SIGPIPE: return "SIGPIPE"
        case SIGALRM: return "SIGALRM"
        case SIGTERM: return "SIGTERM"
        default: return "SIG\(signal)"
        }
    }

    static func machException(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV, SIGBUS: return "EXC_BAD_ACCESS"
        case SIGILL: return "EXC_BAD_INSTRUCTION"
        case SIGFPE: return "EXC_ARITHMETIC"
        case SIGTRAP: return "EXC_BREAKPOINT"
        default: return "EXC_CRASH"
        }
    }

    static func terminationDescription(_ signal: Int32) -> String {
        switch signal {
        case SIGSEGV: return "Segmentation fault: 11"
        case SIGBUS: return "Bus error: 10"
        case SIGILL: return "Illegal instruction: 4"
        case SIGTRAP: return "Trace/BPT trap: 5"
        case SIGABRT: return "Abort trap: 6"
        case SIGFPE: return "Floating point exception: 8"
        case SIGSYS: return "Bad system call: 12"
        default: return "\(name(signal)): \(signal)"
        }
    }

    static func codeName(signal: Int32, code: Int32) -> String? {
        if code == 0x10001 { return "SI_USER" }
        if code == 0x10002 { return "SI_QUEUE" }
        switch signal {
        case SIGSEGV:
            switch code {
            case 1: return "SEGV_MAPERR"
            case 2: return "SEGV_ACCERR"
            default: return nil
            }
        case SIGBUS:
            switch code {
            case 1: return "BUS_ADRALN"
            case 2: return "BUS_ADRERR"
            case 3: return "BUS_OBJERR"
            default: return nil
            }
        case SIGILL:
            let names = ["ILL_ILLOPC", "ILL_ILLTRP", "ILL_PRVOPC", "ILL_ILLOPN", "ILL_ILLADR", "ILL_PRVREG", "ILL_COPROC", "ILL_BADSTK"]
            return (1...names.count).contains(Int(code)) ? names[Int(code) - 1] : nil
        case SIGFPE:
            let names = ["FPE_FLTDIV", "FPE_FLTOVF", "FPE_FLTUND", "FPE_FLTRES", "FPE_FLTINV", "FPE_FLTSUB", "FPE_INTDIV", "FPE_INTOVF"]
            return (1...names.count).contains(Int(code)) ? names[Int(code) - 1] : nil
        case SIGTRAP:
            switch code {
            case 1: return "TRAP_BRKPT"
            case 2: return "TRAP_TRACE"
            default: return nil
            }
        default:
            return nil
        }
    }

    static func exceptionSubtype(signal: Int32, code: Int32, faultAddress: UInt64? = nil) -> String? {
        switch (signal, code) {
        case (SIGSEGV, 1): return "KERN_INVALID_ADDRESS"
        case (SIGSEGV, 2): return (faultAddress ?? .max) < 0x1_0000_0000 ? "KERN_INVALID_ADDRESS" : "KERN_PROTECTION_FAILURE"
        case (SIGBUS, 1): return "EXC_ARM_DA_ALIGN"
        case (SIGBUS, _): return "KERN_MEMORY_ERROR"
        default: return nil
        }
    }

    static func hasFaultAddress(_ signal: Int32) -> Bool {
        signal == SIGSEGV || signal == SIGBUS
    }
}
