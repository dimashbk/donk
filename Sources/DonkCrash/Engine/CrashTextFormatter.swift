import Foundation

public enum CrashTextFormatter {
    public static func text(for report: CrashReport) -> String {
        var lines: [String] = []
        lines.append(contentsOf: header(for: report))
        lines.append("")
        lines.append(contentsOf: exceptionSection(for: report))

        if let message = applicationSpecificInformation(for: report) {
            lines.append("")
            lines.append("Application Specific Information:")
            lines.append(message)
        }

        if !report.details.isEmpty {
            lines.append("")
            lines.append(report.kind == .metricKit ? "MetricKit Diagnostic:" : "Details:")
            let width = (report.details.map(\.key.count).max() ?? 0) + 2
            for detail in report.details {
                lines.append(pad(detail.key + ":", width) + detail.value)
            }
        }

        if report.kind == .exception, !report.frames.isEmpty {
            lines.append("")
            lines.append("Last Exception Backtrace:")
            lines.append(contentsOf: report.frames.map(frameLine))
        }

        let threadFrames = report.kind == .exception ? report.signalFrames : report.frames
        if !threadFrames.isEmpty {
            lines.append("")
            lines.append("Thread 0 name:  \(threadName(for: report))")
            lines.append("Thread 0 Crashed:")
            lines.append(contentsOf: threadFrames.map(frameLine))
        }

        if !report.registers.isEmpty {
            lines.append("")
            let state = report.architecture?.hasPrefix("x86") == true ? "X86 Thread State (64-bit)" : "ARM Thread State (64-bit)"
            lines.append("Thread 0 crashed with \(state):")
            let pairs = report.registers.map { "\(pad($0.key, 4, leading: true)): \($0.value)" }
            stride(from: 0, to: pairs.count, by: 3).forEach { start in
                lines.append("    " + pairs[start..<min(start + 3, pairs.count)].joined(separator: "   "))
            }
        }

        if !report.binaryImages.isEmpty {
            lines.append("")
            lines.append("Binary Images:")
            lines.append(contentsOf: report.binaryImages.map(imageLine))
            if let total = report.loadedImageCount, total > report.binaryImages.count {
                lines.append("    (\(total - report.binaryImages.count) more loaded images omitted; only images referenced by the backtrace and app images are listed)")
            }
        }

        if let command = atosCommand(for: report) {
            lines.append("")
            if let top = report.topAppFrame, top.symbol == nil, top.imageLoadAddress != nil {
                lines.append("App frames are unsymbolicated (image + offset; stripped build). Symbolicate with the app's dSYM:")
            } else {
                lines.append("Symbolicate the top app frame with the app's dSYM:")
            }
            lines.append(command)
        }

        lines.append("")
        lines.append("EOF")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func atosCommand(for report: CrashReport, frame: CrashFrame? = nil) -> String? {
        guard let target = frame ?? report.topAppFrame ?? report.frames.first,
              let load = target.imageLoadAddress,
              let imageName = target.imageName else {
            return nil
        }
        let image = report.binaryImages.first { $0.loadAddress == load }
        let architecture = image?.architecture ?? report.architecture ?? "arm64"
        let dsym: String
        if image?.isMainExecutable == true || imageName == report.mainExecutable?.name {
            dsym = "\(imageName).app.dSYM/Contents/Resources/DWARF/\(imageName)"
        } else {
            let bundle = imageName.hasSuffix(".dylib") ? imageName : "\(imageName).framework"
            dsym = "\(bundle).dSYM/Contents/Resources/DWARF/\(imageName)"
        }
        return "atos -o \(dsym) -arch \(architecture) -l \(CrashHex.short(load)) \(CrashHex.short(target.address))"
    }

    public static func frameLine(_ frame: CrashFrame) -> String {
        let image = frame.imageName ?? "???"
        var line = pad(String(frame.index), 4) + pad(image, 32) + "\t" + CrashHex.padded(frame.address) + " "
        if let symbol = frame.symbol {
            line += symbol
            if let offset = frame.symbolOffset {
                line += " + \(offset)"
            }
        } else if let load = frame.imageLoadAddress, let offset = frame.imageOffset {
            line += "\(CrashHex.short(load)) + \(offset)"
        } else {
            line += "???"
        }
        return line
    }

    public static func imageLine(_ image: CrashBinaryImage) -> String {
        let end = image.size > 0 ? image.loadAddress &+ image.size &- 1 : image.loadAddress
        let uuid = image.uuid.map(CrashUUID.compact) ?? "00000000000000000000000000000000"
        return pad(CrashHex.short(image.loadAddress), 18, leading: true) + " - "
            + pad(CrashHex.short(end), 18, leading: true) + " "
            + "\(image.name) \(image.architecture)  <\(uuid)> \(image.path)"
    }

    // MARK: - Sections

    private static func header(for report: CrashReport) -> [String] {
        let process = report.processID.map { "\(report.appName) [\($0)]" } ?? report.appName
        var lines = [
            "Incident Identifier: \(report.id.uuidString)",
            "Hardware Model:      \(report.deviceModel)",
            "Process:             \(process)",
        ]
        if let path = report.mainExecutable?.path, !path.isEmpty {
            lines.append("Path:                \(path)")
        }
        lines.append(contentsOf: [
            "Identifier:          \(report.bundleID)",
            "Version:             \(report.appVersion) (\(report.appBuild))",
            "Code Type:           \(CrashArchitecture.codeType(report.architecture))",
            "",
            "Date/Time:           \(dateFormatter.string(from: report.date))",
        ])
        if let launch = report.launchDate {
            lines.append("Launch Time:         \(dateFormatter.string(from: launch))")
        }
        lines.append(contentsOf: [
            "OS Version:          iOS \(report.osVersion)",
            "Report Version:      104",
            "Reporter:            donk (\(reporterName(report.kind)))",
        ])
        return lines
    }

    private static func exceptionSection(for report: CrashReport) -> [String] {
        switch report.kind {
        case .signal, .exception:
            guard let signal = report.signal else {
                return [
                    "Exception Type:  EXC_CRASH (SIGABRT)",
                    "Termination Reason: Uncaught Objective-C exception",
                    "Triggered by Thread:  0",
                ]
            }
            var lines = ["Exception Type:  \(signal.machException) (\(signal.name))"]
            if let address = signal.faultAddress, let subtype = CrashSignals.exceptionSubtype(signal: signal.number, code: signal.code, faultAddress: address) {
                lines.append("Exception Subtype: \(subtype) at \(CrashHex.padded(address))")
            }
            var codes = "si_code \(signal.code)"
            if let name = signal.codeName {
                codes += " (\(name))"
            }
            if let address = signal.faultAddress {
                codes += ", fault address \(CrashHex.padded(address))"
            }
            lines.append("Exception Codes: \(codes)")
            lines.append("Termination Reason: SIGNAL \(signal.number) \(CrashSignals.terminationDescription(signal.number))")
            lines.append("Triggered by Thread:  0")
            return lines
        case .metricKit:
            return ["Exception Type:  \(report.title)"]
        case .uncleanExit:
            return [
                "Exception Type:  Unclean exit (no crash was recorded)",
                "Termination Reason: \(CrashReport.uncleanExitExplanation)",
            ]
        }
    }

    private static func applicationSpecificInformation(for report: CrashReport) -> String? {
        var lines: [String] = []
        if let exception = report.exception {
            lines.append("*** Terminating app due to uncaught exception '\(exception.name)', reason: '\(exception.reason ?? "")'")
            for item in exception.userInfo {
                lines.append("userInfo[\(item.key)]: \(item.value)")
            }
        }
        for entry in report.crashInfo where entry.field != "backtrace" {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let line = entry.imageName.map { "\($0): \(text)" } ?? text
            if !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func threadName(for report: CrashReport) -> String {
        var parts: [String] = []
        if report.isMainThread == true {
            parts.append("Dispatch queue: com.apple.main-thread")
        } else if let queue = report.details.first(where: { $0.key == "Queue" })?.value {
            parts.append("Dispatch queue: \(queue)")
        }
        if let name = report.threadName, !name.isEmpty {
            parts.insert(name, at: 0)
        }
        return parts.isEmpty ? "(unnamed)" : parts.joined(separator: "  ")
    }

    private static func reporterName(_ kind: CrashReport.Kind) -> String {
        switch kind {
        case .signal: return "signal handler"
        case .exception: return "NSException handler + signal handler"
        case .metricKit: return "MetricKit"
        case .uncleanExit: return "session tracking"
        }
    }

    private static func pad(_ text: String, _ width: Int, leading: Bool = false) -> String {
        guard text.count < width else { return leading ? text : text + " " }
        let padding = String(repeating: " ", count: width - text.count)
        return leading ? padding + text : text + padding
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return formatter
    }()
}
