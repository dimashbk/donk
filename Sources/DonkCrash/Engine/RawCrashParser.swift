import Foundation

enum RawCrashParser {
    static let magic = "donk-crash"

    static func parse(_ data: Data) -> RawCrash? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true).makeIterator()
        guard let header = lines.next(), let headerText = String(bytes: header, encoding: .utf8),
              headerText.hasPrefix(magic + " ") else {
            return nil
        }
        var raw = RawCrash()
        raw.version = Int(headerText.dropFirst(magic.count + 1)) ?? 0
        while let line = lines.next() {
            apply(Array(line), to: &raw)
        }
        guard raw.signal != 0 || !raw.frames.isEmpty else { return nil }
        return raw
    }

    private static func apply(_ line: [UInt8], to raw: inout RawCrash) {
        guard let space = line.firstIndex(of: 0x20) else {
            if line == Array("end".utf8) {
                raw.isComplete = true
            }
            return
        }
        let key = String(decoding: line[..<space], as: UTF8.self)
        let valueBytes = Array(line[(space + 1)...])
        let value = String(decoding: valueBytes, as: UTF8.self)
        switch key {
        case "arch": raw.architecture = value
        case "signal": raw.signal = Int32(value) ?? 0
        case "code": raw.code = Int32(value) ?? 0
        case "addr": raw.faultAddress = hex(value) ?? 0
        case "time": raw.time = Double(value).map { Date(timeIntervalSince1970: $0) }
        case "pid": raw.processID = Int32(value)
        case "main": raw.isMainThread = value == "1"
        case "thread": raw.thread = hex(value)
        case "pc": raw.pc = hex(value)
        case "lr": raw.lr = hex(value)
        case "fp": raw.fp = hex(value)
        case "sp": raw.sp = hex(value)
        case "esr": raw.esr = hex(value)
        case "far": raw.far = hex(value)
        case "frame":
            if let address = hex(value) {
                raw.frames.append(address)
            }
        case "crashinfo":
            if let info = parseCrashInfo(valueBytes) {
                raw.crashInfo.append(info)
            }
        case "image":
            if let image = parseImage(valueBytes) {
                raw.images.append(image)
            }
        case "threadname": raw.threadName = unescape(valueBytes)
        case "queue": raw.queue = unescape(valueBytes)
        default: break
        }
    }

    private static func parseCrashInfo(_ bytes: [UInt8]) -> RawCrashInfo? {
        let parts = bytes.split(separator: 0x20, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let index = Int(String(decoding: parts[0], as: UTF8.self)) else { return nil }
        let field = String(decoding: parts[1], as: UTF8.self)
        let text = parts.count > 2 ? unescape(Array(parts[2])) : ""
        guard !text.isEmpty else { return nil }
        return RawCrashInfo(imageIndex: index, field: field, text: text)
    }

    private static func parseImage(_ bytes: [UInt8]) -> RawImage? {
        let parts = bytes.split(separator: 0x20, maxSplits: 8, omittingEmptySubsequences: false)
        guard parts.count >= 8 else { return nil }
        let fields = parts.map { String(decoding: $0, as: UTF8.self) }
        guard let index = Int(fields[0]), let load = hex(fields[1]) else { return nil }
        let slide = hex(fields[2]).map { Int64(bitPattern: $0) } ?? 0
        let path = parts.count > 8 ? unescape(Array(parts[8])) : ""
        return RawImage(
            index: index,
            loadAddress: load,
            slide: slide,
            textSize: hex(fields[3]) ?? 0,
            uuid: CrashUUID.format(hex: fields[4]),
            cpuType: Int32(fields[5]) ?? 0,
            cpuSubtype: Int32(fields[6]) ?? 0,
            fileType: UInt32(fields[7]) ?? 0,
            path: path
        )
    }

    static func hex(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed, radix: 16)
    }

    static func unescape(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x5C, index + 1 < bytes.count else {
                output.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            switch next {
            case 0x5C: output.append(0x5C); index += 2
            case 0x6E: output.append(0x0A); index += 2
            case 0x72: output.append(0x0D); index += 2
            case 0x74: output.append(0x09); index += 2
            case 0x78 where index + 3 < bytes.count:
                let hexText = String(decoding: bytes[(index + 2)...(index + 3)], as: UTF8.self)
                if let value = UInt8(hexText, radix: 16) {
                    output.append(value)
                    index += 4
                } else {
                    output.append(byte)
                    index += 1
                }
            default:
                output.append(byte)
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
