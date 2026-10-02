import Foundation

struct RawImage: Codable, Equatable, Sendable {
    var index: Int
    var loadAddress: UInt64
    var slide: Int64
    var textSize: UInt64
    var uuid: String?
    var cpuType: Int32
    var cpuSubtype: Int32
    var fileType: UInt32
    var path: String

    var name: String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? String(format: "0x%llx", loadAddress) : component
    }

    var isMainExecutable: Bool { fileType == 2 }

    var architecture: String {
        CrashArchitecture.name(cpuType: cpuType, cpuSubtype: cpuSubtype)
    }
}

struct RawCrashInfo: Equatable, Sendable {
    var imageIndex: Int
    var field: String
    var text: String
}

struct RawCrash: Equatable, Sendable {
    var version: Int = 0
    var architecture: String?
    var signal: Int32 = 0
    var code: Int32 = 0
    var faultAddress: UInt64 = 0
    var time: Date?
    var processID: Int32?
    var isMainThread: Bool?
    var thread: UInt64?
    var pc: UInt64?
    var lr: UInt64?
    var fp: UInt64?
    var sp: UInt64?
    var esr: UInt64?
    var far: UInt64?
    var frames: [UInt64] = []
    var crashInfo: [RawCrashInfo] = []
    var images: [RawImage] = []
    var threadName: String?
    var queue: String?
    var isComplete = false
}

enum CrashArchitecture {
    static func name(cpuType: Int32, cpuSubtype: Int32) -> String {
        let subtype = cpuSubtype & 0x00FF_FFFF
        switch cpuType {
        case 0x0100_000C:
            return subtype == 2 ? "arm64e" : "arm64"
        case 0x0200_000C:
            return "arm64_32"
        case 0x0100_0007:
            return subtype == 8 ? "x86_64h" : "x86_64"
        case 12:
            return "arm"
        case 7:
            return "i386"
        default:
            return "unknown"
        }
    }

    static func codeType(_ architecture: String?) -> String {
        switch architecture {
        case "arm64", "arm64e": return "ARM-64 (Native)"
        case "x86_64", "x86_64h": return "X86-64 (Native)"
        default: return architecture ?? "Unknown"
        }
    }

    static var current: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

enum CrashUUID {
    static func format(hex: String) -> String? {
        let cleaned = hex.lowercased().filter { $0.isHexDigit }
        guard cleaned.count == 32, cleaned.contains(where: { $0 != "0" }) else { return nil }
        let characters = Array(cleaned.uppercased())
        let groups = [8, 4, 4, 4, 12]
        var parts: [String] = []
        var offset = 0
        for length in groups {
            parts.append(String(characters[offset..<(offset + length)]))
            offset += length
        }
        return parts.joined(separator: "-")
    }

    static func format(bytes: [UInt8]) -> String? {
        guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else { return nil }
        let digits = Array("0123456789ABCDEF".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(36)
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 {
                output.append(UInt8(ascii: "-"))
            }
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func compact(_ uuid: String) -> String {
        uuid.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
