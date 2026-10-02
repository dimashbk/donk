import Foundation

enum HexDump {
    static let defaultLimit = 64 * 1024

    private static let digits = Array("0123456789abcdef".utf8)

    static func dump(_ data: Data, limit: Int = defaultLimit, totalSize: Int? = nil, bytesPerLine: Int = 16) -> String {
        let width = max(4, bytesPerLine)
        let bytes = [UInt8](data.prefix(limit))
        let offsetDigits = bytes.count <= 0x10000 ? 4 : 8
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count / width * (width * 4 + 14) + 64)
        var offset = 0
        while offset < bytes.count {
            appendHex(UInt32(offset), width: offsetDigits, to: &output)
            output.append(0x20)
            output.append(0x20)
            let end = min(offset + width, bytes.count)
            for index in offset..<(offset + width) {
                if index < end {
                    let byte = bytes[index]
                    output.append(digits[Int(byte >> 4)])
                    output.append(digits[Int(byte & 0x0F)])
                } else {
                    output.append(0x20)
                    output.append(0x20)
                }
                output.append(0x20)
                if width >= 16, index - offset == width / 2 - 1 {
                    output.append(0x20)
                }
            }
            output.append(0x20)
            output.append(0x7C)
            for index in offset..<end {
                let byte = bytes[index]
                output.append((0x20...0x7E).contains(byte) ? byte : 0x2E)
            }
            output.append(0x7C)
            output.append(0x0A)
            offset += width
        }
        if !output.isEmpty {
            output.removeLast()
        }
        var text = String(decoding: output, as: UTF8.self)
        let total = totalSize ?? data.count
        if total > bytes.count {
            text += "\n… \(total - bytes.count) more bytes not shown"
        }
        return text
    }

    static func hex(_ data: Data, limit: Int? = nil, grouped: Bool = true) -> String {
        let slice = limit.map { data.prefix($0) } ?? data[...]
        var output: [UInt8] = []
        output.reserveCapacity(slice.count * 3)
        for (index, byte) in slice.enumerated() {
            if grouped, index > 0, index % 4 == 0 {
                output.append(index % 16 == 0 ? 0x0A : 0x20)
            }
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        var text = String(decoding: output, as: UTF8.self)
        if let limit, data.count > limit {
            text += "…"
        }
        return text
    }

    private static func appendHex(_ value: UInt32, width: Int, to output: inout [UInt8]) {
        for shift in stride(from: (width - 1) * 4, through: 0, by: -4) {
            output.append(digits[Int((value >> UInt32(shift)) & 0x0F)])
        }
    }
}
