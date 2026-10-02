import Darwin
import Foundation
import os

struct MemoryReading: Sendable, Equatable {
    var footprint: UInt64
    var available: UInt64
    var limit: UInt64?
}

enum MemorySampler {
    private static let vmInfoCount = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = vmInfoCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func availableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    static func sample() -> MemoryReading {
        let footprint = footprint()
        let available = availableMemory()
        let limit: UInt64? = available > 0 ? footprint + available : nil
        return MemoryReading(footprint: footprint, available: available, limit: limit)
    }

    static var physicalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }
}

final class GPUSampler {
    enum Availability: Equatable {
        case unknown
        case available
        case unavailable
    }

    private static let powerInfoCount = mach_msg_type_number_t(
        MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size
    )

    private var previous: (time: TimeInterval, nanoseconds: UInt64)?
    private var zeroReadings = 0
    private(set) var availability: Availability = .unknown
    let zeroReadingsBeforeUnavailable = 5

    static func cumulativeNanoseconds() -> UInt64? {
        var info = task_power_info_v2()
        var count = powerInfoCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.gpu_energy.task_gpu_utilisation
    }

    func reset() {
        previous = nil
        zeroReadings = 0
        availability = .unknown
    }

    func sample(now: TimeInterval) -> Double? {
        guard let total = Self.cumulativeNanoseconds() else {
            availability = .unavailable
            return nil
        }
        defer { previous = (now, total) }
        if total == 0 {
            zeroReadings += 1
            if availability != .available, zeroReadings >= zeroReadingsBeforeUnavailable {
                availability = .unavailable
            }
        } else {
            availability = .available
        }
        guard availability == .available, let previous, now > previous.time else { return nil }
        let delta = total >= previous.nanoseconds ? total - previous.nanoseconds : 0
        return Double(delta) / 1_000_000 / (now - previous.time)
    }
}
