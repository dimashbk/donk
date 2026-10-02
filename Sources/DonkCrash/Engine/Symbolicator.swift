import DonkCrashC
import Foundation

struct LoadedImage: Equatable, Sendable {
    var loadAddress: UInt64
    var textSize: UInt64
    var uuid: String?
    var path: String
    var fileType: UInt32
}

struct ResolvedSymbol: Equatable, Sendable {
    var name: String
    var start: UInt64
}

struct ImageIndex: Sendable {
    let images: [RawImage]
    let appDirectory: String?
    private let sorted: [RawImage]

    init(images: [RawImage], currentBundlePath: String? = nil) {
        self.images = images
        sorted = images.sorted { $0.loadAddress < $1.loadAddress }
        if let main = images.first(where: { $0.isMainExecutable }), !main.path.isEmpty {
            appDirectory = (main.path as NSString).deletingLastPathComponent
        } else {
            appDirectory = currentBundlePath
        }
    }

    func image(containing address: UInt64) -> RawImage? {
        var low = 0
        var high = sorted.count - 1
        var candidate: RawImage?
        while low <= high {
            let middle = (low + high) / 2
            if sorted[middle].loadAddress <= address {
                candidate = sorted[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let candidate else { return nil }
        if candidate.textSize > 0 {
            return address < candidate.loadAddress &+ candidate.textSize ? candidate : nil
        }
        return address - candidate.loadAddress < 0x1000_0000 ? candidate : nil
    }

    func isApp(_ image: RawImage) -> Bool {
        if image.isMainExecutable { return true }
        guard let appDirectory, !appDirectory.isEmpty else { return false }
        return image.path.hasPrefix(appDirectory + "/")
    }
}

final class Symbolicator: @unchecked Sendable {
    typealias Resolver = @Sendable (UInt64) -> ResolvedSymbol?

    private let byUUID: [String: LoadedImage]
    private let byPath: [String: LoadedImage]
    private let resolver: Resolver
    let currentBundlePath: String

    init(loaded: [LoadedImage] = Symbolicator.currentImages(), currentBundlePath: String = Bundle.main.bundlePath, resolver: @escaping Resolver = Symbolicator.dladdrResolver) {
        var byUUID: [String: LoadedImage] = [:]
        var byPath: [String: LoadedImage] = [:]
        for image in loaded {
            if let uuid = image.uuid {
                byUUID[uuid] = image
            }
            if !image.path.isEmpty {
                byPath[image.path] = image
            }
        }
        self.byUUID = byUUID
        self.byPath = byPath
        self.currentBundlePath = currentBundlePath
        self.resolver = resolver
    }

    static func currentImages() -> [LoadedImage] {
        donk_crash_register_images()
        let count = donk_crash_image_count()
        var result: [LoadedImage] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            var info = donk_crash_image_t()
            guard donk_crash_image_at(index, &info) == 1 else { continue }
            result.append(LoadedImage(rawInfo: info))
        }
        return result
    }

    static func currentRawImages() -> [RawImage] {
        donk_crash_register_images()
        let count = donk_crash_image_count()
        var result: [RawImage] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            var info = donk_crash_image_t()
            guard donk_crash_image_at(index, &info) == 1 else { continue }
            result.append(RawImage(index: index, info: info))
        }
        return result
    }

    static let dladdrResolver: Resolver = { address in
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let namePointer = info.dli_sname else { return nil }
        let name = String(cString: namePointer)
        guard !name.isEmpty, name != "<redacted>" else { return nil }
        let start = info.dli_saddr.map { UInt64(UInt(bitPattern: $0)) } ?? address
        return ResolvedSymbol(name: name, start: start)
    }

    func currentImage(for image: RawImage) -> LoadedImage? {
        if let uuid = image.uuid {
            if let match = byUUID[uuid] {
                return match
            }
            if let match = byPath[image.path], match.uuid == nil {
                return match
            }
            return nil
        }
        return image.path.isEmpty ? nil : byPath[image.path]
    }

    func currentAddress(for address: UInt64, in image: RawImage) -> UInt64? {
        guard address >= image.loadAddress, let current = currentImage(for: image) else { return nil }
        return current.loadAddress &+ (address - image.loadAddress)
    }

    static let plausibleSymbolSpan: UInt64 = 64 * 1024

    static let imageHeaderSymbols: Set<String> = [
        "_mh_execute_header", "__mh_execute_header",
        "_mh_dylib_header", "__mh_dylib_header",
        "_mh_bundle_header", "__mh_bundle_header",
        "__dso_handle", "___dso_handle",
    ]

    static func isPlausible(_ symbol: ResolvedSymbol, address: UInt64) -> Bool {
        guard symbol.start <= address, !imageHeaderSymbols.contains(symbol.name) else { return false }
        return address - symbol.start <= plausibleSymbolSpan
    }

    func resolve(_ address: UInt64, in image: RawImage, isReturnAddress: Bool) -> (symbol: String, offset: UInt64, start: UInt64)? {
        guard address >= image.loadAddress, let loaded = currentImage(for: image) else { return nil }
        let current = loaded.loadAddress &+ (address - image.loadAddress)
        let lookup = isReturnAddress && current > 0 ? current - 1 : current
        guard let symbol = resolver(lookup), Self.isPlausible(symbol, address: current) else { return nil }
        return (CrashDemangler.demangle(symbol.name), current - symbol.start, symbol.start)
    }

    func frame(index: Int, address: UInt64, isReturnAddress: Bool, images: ImageIndex, fallbackSymbol: String? = nil) -> CrashFrame {
        var frame = CrashFrame(index: index, address: address)
        guard let image = images.image(containing: address) else {
            frame.symbol = fallbackSymbol
            return frame
        }
        frame.imageName = image.name
        frame.imageLoadAddress = image.loadAddress
        frame.imageOffset = address - image.loadAddress
        frame.isAppFrame = images.isApp(image)
        if let resolved = resolve(address, in: image, isReturnAddress: isReturnAddress) {
            frame.symbol = resolved.symbol
            frame.symbolOffset = resolved.offset
        } else if let fallbackSymbol {
            frame.symbol = fallbackSymbol
        }
        return frame
    }

    func symbolStart(for address: UInt64, images: ImageIndex, isReturnAddress: Bool) -> UInt64? {
        guard let image = images.image(containing: address) else { return nil }
        return resolve(address, in: image, isReturnAddress: isReturnAddress)?.start
    }
}

extension LoadedImage {
    init(rawInfo info: donk_crash_image_t) {
        let uuidBytes = withUnsafeBytes(of: info.uuid) { Array($0) }
        self.init(
            loadAddress: info.load_address,
            textSize: info.text_size,
            uuid: CrashUUID.format(bytes: uuidBytes),
            path: info.path.map { String(cString: $0) } ?? "",
            fileType: info.file_type
        )
    }
}

extension RawImage {
    init(index: Int, info: donk_crash_image_t) {
        let uuidBytes = withUnsafeBytes(of: info.uuid) { Array($0) }
        self.init(
            index: index,
            loadAddress: info.load_address,
            slide: info.slide,
            textSize: info.text_size,
            uuid: CrashUUID.format(bytes: uuidBytes),
            cpuType: info.cpu_type,
            cpuSubtype: info.cpu_subtype,
            fileType: info.file_type,
            path: info.path.map { String(cString: $0) } ?? ""
        )
    }
}

// MARK: - Demangling

enum CrashDemangler {
    private typealias SwiftDemangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private typealias CxxDemangle = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?
    ) -> UnsafeMutablePointer<CChar>?

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    private static let swiftDemangle: SwiftDemangle? = {
        guard let symbol = dlsym(defaultHandle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: SwiftDemangle.self)
    }()

    private static let cxxDemangle: CxxDemangle? = {
        guard let symbol = dlsym(defaultHandle, "__cxa_demangle") else { return nil }
        return unsafeBitCast(symbol, to: CxxDemangle.self)
    }()

    static var isSwiftDemanglerAvailable: Bool { swiftDemangle != nil }

    static func isSwiftMangled(_ name: String) -> Bool {
        let prefixes = ["$s", "_$s", "$S", "_$S", "$e", "_$e", "_T0", "@__swiftmacro_"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    static func demangle(_ name: String) -> String {
        if isSwiftMangled(name), let swiftDemangle {
            return name.withCString { pointer -> String in
                guard let result = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
                defer { free(result) }
                let text = String(cString: result)
                return text.isEmpty ? name : text
            }
        }
        if name.hasPrefix("_Z") || name.hasPrefix("__Z"), let cxxDemangle {
            let mangled = name.hasPrefix("__Z") ? String(name.dropFirst()) : name
            return mangled.withCString { pointer -> String in
                var status: Int32 = 0
                guard let result = cxxDemangle(pointer, nil, nil, &status), status == 0 else { return name }
                defer { free(result) }
                return String(cString: result)
            }
        }
        return name
    }

    static func symbol(fromCallStackSymbol line: String) -> String? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let addressIndex = tokens.firstIndex(where: { $0.hasPrefix("0x") }), addressIndex + 1 < tokens.count else {
            return nil
        }
        var symbolTokens = Array(tokens[(addressIndex + 1)...])
        if symbolTokens.count >= 2, symbolTokens[symbolTokens.count - 2] == "+" {
            symbolTokens.removeLast(2)
        }
        let symbol = symbolTokens.joined(separator: " ")
        guard !symbol.isEmpty, symbol != "<redacted>", !symbol.hasPrefix("0x") else { return nil }
        return demangle(symbol)
    }
}
