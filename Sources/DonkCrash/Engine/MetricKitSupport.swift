import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

struct MetricKitFrame: Equatable, Sendable {
    var address: UInt64
    var binaryName: String?
    var binaryUUID: String?
    var offset: UInt64?
    var sampleCount: Int
}

struct MetricKitDiagnostic: Sendable {
    enum Category: String, Sendable {
        case crash
        case hang
        case cpuException
    }

    var category: Category
    var title: String
    var date: Date
    var version: String?
    var build: String?
    var osVersion: String?
    var deviceType: String?
    var architecture: String?
    var processID: Int32?
    var details: [CrashDetail]
    var callStackJSON: Data?
    var signature: String
}

enum MetricKitCallStack {
    static func attributedFrames(from data: Data) -> [MetricKitFrame] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = object["callStacks"] as? [[String: Any]], !stacks.isEmpty else {
            return []
        }
        let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks[0]
        guard let roots = attributed["callStackRootFrames"] as? [[String: Any]] else { return [] }
        var frames: [MetricKitFrame] = []
        var level = heaviest(roots)
        while let node = level, frames.count < 512 {
            if let frame = frame(from: node) {
                frames.append(frame)
            }
            level = heaviest(node["subFrames"] as? [[String: Any]] ?? [])
        }
        return frames
    }

    private static func heaviest(_ nodes: [[String: Any]]) -> [String: Any]? {
        nodes.max { sampleCount($0) < sampleCount($1) }
    }

    private static func sampleCount(_ node: [String: Any]) -> Int {
        (node["sampleCount"] as? NSNumber)?.intValue ?? 0
    }

    private static func frame(from node: [String: Any]) -> MetricKitFrame? {
        guard let address = (node["address"] as? NSNumber)?.uint64Value else { return nil }
        return MetricKitFrame(
            address: address,
            binaryName: node["binaryName"] as? String,
            binaryUUID: (node["binaryUUID"] as? String)?.uppercased(),
            offset: (node["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value,
            sampleCount: sampleCount(node)
        )
    }
}

enum MetricKitConverter {
    static func report(from diagnostic: MetricKitDiagnostic, symbolicator: Symbolicator, current: LaunchInfo) -> CrashReport {
        let frames = diagnostic.callStackJSON.map(MetricKitCallStack.attributedFrames(from:)) ?? []
        let mainName = (current.bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let crashFrames = frames.enumerated().map { offset, frame in
            symbolicator.metricKitFrame(index: offset, frame: frame, isReturnAddress: offset > 0, mainExecutableName: mainName)
        }
        var images: [String: CrashBinaryImage] = [:]
        for (frame, crashFrame) in zip(frames, crashFrames) {
            guard let load = crashFrame.imageLoadAddress, let name = frame.binaryName else { continue }
            let key = frame.binaryUUID ?? name
            guard images[key] == nil else { continue }
            images[key] = CrashBinaryImage(
                name: name,
                path: name,
                loadAddress: load,
                size: 0,
                uuid: frame.binaryUUID,
                architecture: diagnostic.architecture ?? CrashArchitecture.current,
                isApp: crashFrame.isAppFrame,
                isMainExecutable: name == mainName
            )
        }
        return CrashReport(
            date: diagnostic.date,
            kind: .metricKit,
            appName: current.appName,
            bundleID: current.bundleID,
            appVersion: diagnostic.version ?? current.version,
            appBuild: diagnostic.build ?? current.build,
            osVersion: diagnostic.osVersion ?? current.osVersion,
            deviceModel: diagnostic.deviceType ?? current.deviceModel,
            architecture: diagnostic.architecture ?? CrashArchitecture.current,
            processID: diagnostic.processID,
            frames: crashFrames,
            binaryImages: images.values.sorted { $0.loadAddress < $1.loadAddress },
            details: diagnostic.details,
            metricKitTitle: diagnostic.title
        )
    }

    static func signature(category: MetricKitDiagnostic.Category, date: Date, payload: Data) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in payload {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "\(category.rawValue)-\(Int(date.timeIntervalSince1970))-\(String(hash, radix: 16))"
    }

    static func machExceptionName(_ type: Int) -> String {
        let names = [
            1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
            5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
            9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
        ]
        return names[type] ?? "EXC_\(type)"
    }
}

extension Symbolicator {
    func metricKitFrame(index: Int, frame: MetricKitFrame, isReturnAddress: Bool, mainExecutableName: String) -> CrashFrame {
        var result = CrashFrame(index: index, address: frame.address, imageName: frame.binaryName)
        guard let offset = frame.offset, frame.address >= offset else {
            return result
        }
        let load = frame.address - offset
        result.imageLoadAddress = load
        result.imageOffset = offset
        let image = RawImage(index: index, loadAddress: load, slide: 0, textSize: 0, uuid: frame.binaryUUID, cpuType: 0, cpuSubtype: 0, fileType: 0, path: "")
        if let current = currentImage(for: image) {
            result.isAppFrame = current.fileType == 2 || current.path.hasPrefix(currentBundlePath + "/")
            if let resolved = resolve(frame.address, in: image, isReturnAddress: isReturnAddress) {
                result.symbol = resolved.symbol
                result.symbolOffset = resolved.offset
            }
        } else {
            result.isAppFrame = frame.binaryName == mainExecutableName
        }
        return result
    }
}

#if canImport(MetricKit)
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber {
    private let handler: @Sendable ([MetricKitDiagnostic]) -> Void

    init(handler: @escaping @Sendable ([MetricKitDiagnostic]) -> Void) {
        self.handler = handler
        super.init()
    }

    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        consume(manager.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        consume(payloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}

    private func consume(_ payloads: [MXDiagnosticPayload]) {
        let diagnostics = payloads.flatMap(MetricKitCollector.diagnostics(from:))
        if !diagnostics.isEmpty {
            handler(diagnostics)
        }
    }

    static func diagnostics(from payload: MXDiagnosticPayload) -> [MetricKitDiagnostic] {
        var result: [MetricKitDiagnostic] = []
        for crash in payload.crashDiagnostics ?? [] {
            var details: [CrashDetail] = []
            var title = "Crash"
            if let type = crash.exceptionType?.intValue {
                let name = MetricKitConverter.machExceptionName(type)
                title = name
                details.append(CrashDetail("Exception type", "\(name) (\(type))"))
            }
            if let signal = crash.signal?.int32Value {
                title += " / \(CrashSignals.name(signal))"
                details.append(CrashDetail("Signal", "\(CrashSignals.name(signal)) (\(signal))"))
            }
            if let code = crash.exceptionCode {
                details.append(CrashDetail("Exception code", code.stringValue))
            }
            if let reason = crash.terminationReason, !reason.isEmpty {
                details.append(CrashDetail("Termination reason", reason))
            }
            if let region = crash.virtualMemoryRegionInfo, !region.isEmpty {
                details.append(CrashDetail("VM region", region))
            }
            if #available(iOS 17.0, *), let reason = crash.exceptionReason {
                details.append(CrashDetail("Exception", "\(reason.exceptionName): \(reason.composedMessage)"))
            }
            result.append(make(.crash, title: title, diagnostic: crash, payload: payload, details: details, callStack: crash.callStackTree.jsonRepresentation()))
        }
        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            let duration = String(format: "%.2f s", seconds)
            result.append(make(.hang, title: "Hang · \(duration)", diagnostic: hang, payload: payload, details: [CrashDetail("Hang duration", duration)], callStack: hang.callStackTree.jsonRepresentation()))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            let total = String(format: "%.1f s", cpu.totalCPUTime.converted(to: .seconds).value)
            let sampled = String(format: "%.1f s", cpu.totalSampledTime.converted(to: .seconds).value)
            let details = [CrashDetail("Total CPU time", total), CrashDetail("Sampled time", sampled)]
            result.append(make(.cpuException, title: "CPU exception · \(total)", diagnostic: cpu, payload: payload, details: details, callStack: cpu.callStackTree.jsonRepresentation()))
        }
        return result
    }

    private static func make(_ category: MetricKitDiagnostic.Category, title: String, diagnostic: MXDiagnostic, payload: MXDiagnosticPayload, details: [CrashDetail], callStack: Data) -> MetricKitDiagnostic {
        let metaData = diagnostic.metaData
        var processID: Int32?
        if #available(iOS 17.0, *) {
            processID = metaData.pid
        }
        var allDetails = details
        allDetails.append(CrashDetail("Window", "\(DonkDateText.full(payload.timeStampBegin)) – \(DonkDateText.full(payload.timeStampEnd))"))
        return MetricKitDiagnostic(
            category: category,
            title: title,
            date: payload.timeStampEnd,
            version: diagnostic.applicationVersion,
            build: metaData.applicationBuildVersion,
            osVersion: metaData.osVersion,
            deviceType: metaData.deviceType,
            architecture: metaData.platformArchitecture,
            processID: processID,
            details: allDetails,
            callStackJSON: callStack,
            signature: MetricKitConverter.signature(category: category, date: payload.timeStampEnd, payload: diagnostic.jsonRepresentation())
        )
    }
}
#endif
