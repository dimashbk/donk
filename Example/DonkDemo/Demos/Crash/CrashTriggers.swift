import Foundation

enum DemoCrashKind: String, CaseIterable, Identifiable {
    case fatalError
    case forceUnwrap
    case outOfBounds
    case nsException
    case segfault
    case abort
    case stackOverflow
    case divideByZero

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fatalError: return "fatalError()"
        case .forceUnwrap: return "Force-unwrap nil"
        case .outOfBounds: return "Array index out of range"
        case .nsException: return "NSException (NSArray objectAtIndex:)"
        case .segfault: return "Segfault (write to bad pointer)"
        case .abort: return "abort()"
        case .stackOverflow: return "Stack overflow (unbounded recursion)"
        case .divideByZero: return "Integer divide by zero"
        }
    }

    var expectation: String {
        switch self {
        case .fatalError, .forceUnwrap, .outOfBounds: return "EXC_BREAKPOINT / SIGTRAP + Swift message"
        case .nsException: return "NSRangeException + SIGABRT"
        case .segfault: return "EXC_BAD_ACCESS / SIGSEGV at 0x10"
        case .abort: return "EXC_CRASH / SIGABRT"
        case .stackOverflow: return "EXC_BAD_ACCESS on the guard page"
        case .divideByZero: return "Swift trap on arm64, SIGFPE on x86_64"
        }
    }

    var icon: String {
        switch self {
        case .fatalError: return "exclamationmark.octagon"
        case .forceUnwrap: return "exclamationmark.circle"
        case .outOfBounds: return "square.stack.3d.up.slash"
        case .nsException: return "exclamationmark.triangle"
        case .segfault: return "memorychip"
        case .abort: return "stop.circle"
        case .stackOverflow: return "arrow.triangle.2.circlepath"
        case .divideByZero: return "divide.circle"
        }
    }

    func trigger() -> Never {
        switch self {
        case .fatalError:
            DemoCrashes.callFatalError()
        case .forceUnwrap:
            DemoCrashes.forceUnwrapNil()
        case .outOfBounds:
            DemoCrashes.indexOutOfRange()
        case .nsException:
            DemoCrashes.raiseRangeException()
        case .segfault:
            DemoCrashes.writeToBadPointer()
        case .abort:
            DemoCrashes.callAbort()
        case .stackOverflow:
            DemoCrashes.overflowStack()
        case .divideByZero:
            DemoCrashes.divideByZero()
        }
    }
}

enum DemoCrashes {
    @inline(never)
    static func opaque<T>(_ value: T) -> T {
        value
    }

    @inline(never)
    static func callFatalError() -> Never {
        fatalError("Donk demo: fatalError() was called on purpose")
    }

    @inline(never)
    static func forceUnwrapNil() -> Never {
        let value: String? = opaque(nil)
        print(value!)
        Darwin.abort()
    }

    @inline(never)
    static func indexOutOfRange() -> Never {
        let numbers = opaque([1, 2, 3])
        print(numbers[opaque(5)])
        Darwin.abort()
    }

    @inline(never)
    static func raiseRangeException() -> Never {
        let array = opaque(NSArray(array: [1, 2, 3]))
        print(array.object(at: opaque(5)))
        Darwin.abort()
    }

    @inline(never)
    static func writeToBadPointer() -> Never {
        let pointer = UnsafeMutablePointer<Int>(bitPattern: opaque(0x10))
        pointer?.pointee = 42
        Darwin.abort()
    }

    @inline(never)
    static func callAbort() -> Never {
        Darwin.abort()
    }

    @inline(never)
    static func overflowStack() -> Never {
        print(recurse(opaque(1)))
        Darwin.abort()
    }

    @inline(never)
    static func recurse(_ depth: Int) -> Int {
        var padding = (depth, depth, depth, depth, depth, depth, depth, depth)
        if opaque(depth > 0) {
            padding.0 = recurse(opaque(depth + 1))
        }
        return padding.0 &+ padding.7
    }

    @inline(never)
    static func divideByZero() -> Never {
        let zero = opaque(0)
        print(42 / zero)
        Darwin.abort()
    }
}
