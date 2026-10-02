import Darwin
import Foundation

struct CPUSnapshot: Sendable, Equatable {
    var total: Double
    var mainThread: Double
    var threadCount: Int
    var threads: [PerformanceThread]

    static let empty = CPUSnapshot(total: 0, mainThread: 0, threadCount: 0, threads: [])
}

enum CPUSampler {
    static let mainThreadPort: thread_t = {
        if Thread.isMainThread {
            return pthread_mach_thread_np(pthread_self())
        }
        return firstThreadPort() ?? 0
    }()

    private static func firstThreadPort() -> thread_t? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        let first: thread_t? = count > 0 ? list[0] : nil
        for index in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, list[index])
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return first
    }

    private static let basicInfoCount = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )

    static func sample(includeThreadDetails: Bool = true) -> CPUSnapshot {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return .empty
        }
        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, list[index])
            }
            let size = vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), size)
        }
        let main = mainThreadPort
        var total: Double = 0
        var mainUsage: Double = 0
        var threads: [PerformanceThread] = []
        if includeThreadDetails {
            threads.reserveCapacity(Int(count))
        }
        for index in 0..<Int(count) {
            let port = list[index]
            guard let info = basicInfo(port) else { continue }
            let isMain = port == main
            guard info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let usage = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            total += usage
            if isMain {
                mainUsage = usage
            }
            if includeThreadDetails {
                threads.append(
                    PerformanceThread(
                        id: port,
                        name: isMain ? "Main Thread" : threadName(port),
                        isMain: isMain,
                        cpu: usage,
                        runState: info.run_state
                    )
                )
            }
        }
        threads.sort { lhs, rhs in
            if lhs.cpu == rhs.cpu { return lhs.isMain && !rhs.isMain }
            return lhs.cpu > rhs.cpu
        }
        return CPUSnapshot(total: total, mainThread: mainUsage, threadCount: Int(count), threads: threads)
    }

    static func basicInfo(_ port: thread_t) -> thread_basic_info_data_t? {
        var info = thread_basic_info_data_t()
        var infoCount = basicInfoCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    static func threadName(_ port: thread_t) -> String {
        guard let thread = pthread_from_mach_thread_np(port) else { return "" }
        var buffer = [CChar](repeating: 0, count: 128)
        guard pthread_getname_np(thread, &buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }

    static var processorCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }
}
