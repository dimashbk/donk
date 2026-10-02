import Darwin
import Foundation

// MARK: - Capture

enum BacktraceCapture {
    static let defaultMaxFrames = 128

    #if arch(arm64)
    static let stateFlavor = thread_state_flavor_t(ARM_THREAD_STATE64)
    static let stateWords = 34
    static let pcWord = 32
    static let lrWord = 30
    static let fpWord = 29
    #elseif arch(x86_64)
    static let stateFlavor = thread_state_flavor_t(x86_THREAD_STATE64)
    static let stateWords = 21
    static let pcWord = 16
    static let lrWord = -1
    static let fpWord = 6
    #else
    static let stateFlavor = thread_state_flavor_t(0)
    static let stateWords = 0
    static let pcWord = -1
    static let lrWord = -1
    static let fpWord = -1
    #endif

    static var addressMask: UInt {
        #if arch(arm64) && !targetEnvironment(simulator)
        return 0x0000_000F_FFFF_FFFF
        #elseif arch(arm64)
        return 0x0000_7FFF_FFFF_FFFF
        #else
        return UInt.max
        #endif
    }

    final class Scratch {
        let capacity: Int
        let frames: UnsafeMutablePointer<UInt>
        let state: UnsafeMutablePointer<UInt>
        let stateBuffer: thread_state_t
        let record: UnsafeMutablePointer<UInt>
        let recordAddress: vm_address_t

        init(capacity: Int = BacktraceCapture.defaultMaxFrames) {
            self.capacity = max(capacity, 0)
            frames = .allocate(capacity: max(capacity, 1))
            frames.initialize(repeating: 0, count: max(capacity, 1))
            state = .allocate(capacity: BacktraceCapture.stateWords + 8)
            state.initialize(repeating: 0, count: BacktraceCapture.stateWords + 8)
            stateBuffer = thread_state_t(OpaquePointer(state))
            record = .allocate(capacity: 2)
            record.initialize(repeating: 0, count: 2)
            recordAddress = vm_address_t(UInt(bitPattern: record))
        }

        deinit {
            frames.deallocate()
            state.deallocate()
            record.deallocate()
        }
    }

    static func capture(thread: thread_t, maxFrames: Int = defaultMaxFrames) -> [UInt] {
        guard maxFrames > 2 else { return [] }
        return capture(thread: thread, scratch: Scratch(capacity: maxFrames))
    }

    static func capture(thread: thread_t, scratch: Scratch) -> [UInt] {
        guard scratch.capacity > 2, stateWords > 0 else { return [] }
        guard thread != pthread_mach_thread_np(pthread_self()) else { return [] }
        let count = suspendAndWalk(
            thread: thread,
            flavor: stateFlavor,
            state: scratch.state,
            stateBuffer: scratch.stateBuffer,
            stateCount: mach_msg_type_number_t(stateWords * 2),
            pcWord: pcWord,
            lrWord: lrWord,
            fpWord: fpWord,
            task: mach_task_self_,
            record: scratch.record,
            recordAddress: scratch.recordAddress,
            frames: scratch.frames,
            capacity: scratch.capacity,
            mask: addressMask
        )
        return Array(UnsafeBufferPointer(start: scratch.frames, count: count))
    }

    @inline(never)
    static func suspendAndWalk(
        thread: thread_t,
        flavor: thread_state_flavor_t,
        state: UnsafeMutablePointer<UInt>,
        stateBuffer: thread_state_t,
        stateCount: mach_msg_type_number_t,
        pcWord: Int,
        lrWord: Int,
        fpWord: Int,
        task: mach_port_t,
        record: UnsafeMutablePointer<UInt>,
        recordAddress: vm_address_t,
        frames: UnsafeMutablePointer<UInt>,
        capacity: Int,
        mask: UInt
    ) -> Int {
        if thread_suspend(thread) != KERN_SUCCESS {
            return 0
        }
        var count = stateCount
        var written = 0
        if thread_get_state(thread, flavor, stateBuffer, &count) == KERN_SUCCESS {
            let pc = state[pcWord] & mask
            let linkRegister = lrWord >= 0 ? state[lrWord] & mask : 0
            var frame = state[fpWord]
            frames[written] = pc
            written += 1
            if linkRegister != 0 {
                frames[written] = linkRegister
                written += 1
            }
            var isFirstRecord = true
            var outSize: vm_size_t = 0
            while written < capacity && frame != 0 && frame & 0x7 == 0 {
                outSize = 0
                if vm_read_overwrite(task, frame, 16, recordAddress, &outSize) != KERN_SUCCESS || outSize != 16 {
                    break
                }
                let next = record[0]
                let returnAddress = record[1] & mask
                if returnAddress == 0 {
                    break
                }
                if !(isFirstRecord && linkRegister != 0 && returnAddress == linkRegister) {
                    frames[written] = returnAddress
                    written += 1
                }
                isFirstRecord = false
                if next <= frame {
                    break
                }
                frame = next
            }
        }
        thread_resume(thread)
        return written
    }

    @inline(__always)
    static func strip(_ address: UInt) -> UInt {
        address & addressMask
    }
}

// MARK: - Symbolication

enum Symbolicator {
    static func symbolicate(_ addresses: [UInt]) -> [PerformanceStackFrame] {
        addresses.enumerated().map { index, address in
            frame(index: index, address: address)
        }
    }

    static func frame(index: Int, address: UInt) -> PerformanceStackFrame {
        let lookup = index == 0 || address == 0 ? address : address &- 1
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 else {
            return PerformanceStackFrame(index: index, address: address, image: nil, symbol: nil, offset: 0)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent }
        let symbol = info.dli_sname.map { demangle(String(cString: $0)) }
        let base: UInt
        if symbol != nil, let start = info.dli_saddr {
            base = UInt(bitPattern: start)
        } else if let imageBase = info.dli_fbase {
            base = UInt(bitPattern: imageBase)
        } else {
            base = address
        }
        return PerformanceStackFrame(
            index: index,
            address: address,
            image: image,
            symbol: symbol,
            offset: address >= base ? address - base : 0
        )
    }

    static func demangle(_ name: String) -> String {
        let prefixes = ["$s", "_$s", "$S", "_$S", "$e", "_$e", "_T0"]
        guard prefixes.contains(where: { name.hasPrefix($0) }), let function = swiftDemangle else { return name }
        let demangled: String = name.withCString { pointer in
            guard let output = function(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(output) }
            return String(cString: output)
        }
        return simplify(demangled)
    }

    private static let privateDiscriminator = try? NSRegularExpression(pattern: "\\(([^()]+) in _[0-9A-F]{32}\\)")

    static func simplify(_ symbol: String) -> String {
        guard let regex = privateDiscriminator, symbol.contains(" in _") else { return symbol }
        let range = NSRange(symbol.startIndex..., in: symbol)
        return regex.stringByReplacingMatches(in: symbol, options: [], range: range, withTemplate: "$1")
    }

    private typealias DemangleFunction = @convention(c) (
        UnsafePointer<CChar>?,
        Int,
        UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?,
        UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: DemangleFunction? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: DemangleFunction.self)
    }()
}
