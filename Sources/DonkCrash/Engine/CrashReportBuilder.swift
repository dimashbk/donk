import Foundation

struct CrashReportBuilder {
    let symbolicator: Symbolicator
    let fallbackLaunch: LaunchInfo

    func build(raw: RawCrash?, exception: ExceptionRecord?, launch: LaunchInfo?, id: UUID = UUID()) -> CrashReport? {
        guard raw != nil || exception != nil else { return nil }
        let info = launch ?? fallbackLaunch
        let images = raw?.images.isEmpty == false ? raw?.images ?? [] : exception?.images ?? []
        let index = ImageIndex(images: images, currentBundlePath: symbolicator.currentBundlePath)

        var report = CrashReport(
            id: id,
            date: raw?.time ?? exception?.time ?? info.launchDate,
            kind: exception != nil ? .exception : .signal,
            appName: info.appName,
            bundleID: info.bundleID,
            appVersion: info.version,
            appBuild: info.build,
            osVersion: info.osVersion,
            deviceModel: info.deviceModel,
            architecture: raw?.architecture ?? CrashArchitecture.current,
            processID: raw?.processID ?? (launch != nil ? info.processID : nil),
            launchDate: launch?.launchDate
        )

        if let raw {
            report.signal = signalInfo(raw)
            report.crashInfo = raw.crashInfo.map { entry in
                let imageName = images.first { $0.index == entry.imageIndex }?.name
                return CrashInfoMessage(imageName: imageName, field: entry.field, text: entry.text)
            }
            report.registers = registers(raw)
            report.threadName = raw.threadName
            report.isMainThread = raw.isMainThread
            if let queue = raw.queue, !queue.isEmpty {
                report.details.append(CrashDetail("Queue", queue))
            }
            if !raw.isComplete {
                report.details.append(CrashDetail("Note", "The crash record was cut short; some sections may be missing."))
            }
        }

        if let exception {
            report.exception = CrashReport.ExceptionInfo(
                name: exception.name,
                reason: exception.reason,
                userInfo: exception.userInfo,
                symbols: exception.symbols
            )
            report.frames = exception.addresses.enumerated().map { offset, address in
                let fallback = offset < exception.symbols.count ? CrashDemangler.symbol(fromCallStackSymbol: exception.symbols[offset]) : nil
                return symbolicator.frame(index: offset, address: address, isReturnAddress: offset > 0, images: index, fallbackSymbol: fallback)
            }
            if report.threadName == nil {
                report.threadName = exception.threadName
            }
            if report.isMainThread == nil {
                report.isMainThread = exception.isMainThread
            }
            if let raw {
                report.signalFrames = threadFrames(raw, images: index)
            }
        } else if let raw {
            report.frames = threadFrames(raw, images: index)
        }

        report.binaryImages = binaryImages(for: report, images: images, index: index)
        report.loadedImageCount = images.isEmpty ? nil : images.count
        return report
    }

    func threadFrames(_ raw: RawCrash, images: ImageIndex) -> [CrashFrame] {
        var addresses = raw.frames
        if let lr = raw.lr, lr != 0, let pc = raw.pc, !addresses.isEmpty, shouldInsertLinkRegister(lr: lr, pc: pc, frames: addresses, images: images) {
            addresses.insert(lr, at: 1)
        }
        return addresses.enumerated().map { offset, address in
            symbolicator.frame(index: offset, address: address, isReturnAddress: offset > 0, images: images)
        }
    }

    func shouldInsertLinkRegister(lr: UInt64, pc: UInt64, frames: [UInt64], images: ImageIndex) -> Bool {
        if lr == pc { return false }
        if frames.count > 1, frames[1] == lr { return false }
        guard images.image(containing: lr) != nil,
              let pcStart = symbolicator.symbolStart(for: pc, images: images, isReturnAddress: false),
              let lrStart = symbolicator.symbolStart(for: lr, images: images, isReturnAddress: true) else {
            return false
        }
        return pcStart != lrStart
    }

    func signalInfo(_ raw: RawCrash) -> CrashReport.SignalInfo {
        CrashReport.SignalInfo(
            number: raw.signal,
            name: CrashSignals.name(raw.signal),
            code: raw.code,
            codeName: CrashSignals.codeName(signal: raw.signal, code: raw.code),
            faultAddress: CrashSignals.hasFaultAddress(raw.signal) ? raw.faultAddress : nil,
            machException: CrashSignals.machException(raw.signal)
        )
    }

    func registers(_ raw: RawCrash) -> [CrashDetail] {
        let values: [(String, UInt64?)] = [
            ("pc", raw.pc), ("lr", raw.lr), ("fp", raw.fp), ("sp", raw.sp), ("far", raw.far), ("esr", raw.esr),
        ]
        return values.compactMap { name, value in
            guard let value else { return nil }
            return CrashDetail(name, CrashHex.padded(value))
        }
    }

    func binaryImages(for report: CrashReport, images: [RawImage], index: ImageIndex) -> [CrashBinaryImage] {
        let referenced = Set((report.frames + report.signalFrames).compactMap(\.imageLoadAddress))
        return images
            .filter { referenced.contains($0.loadAddress) || index.isApp($0) }
            .sorted { $0.loadAddress < $1.loadAddress }
            .map { image in
                CrashBinaryImage(
                    name: image.name,
                    path: image.path,
                    loadAddress: image.loadAddress,
                    size: image.textSize,
                    uuid: image.uuid,
                    architecture: image.architecture,
                    isApp: index.isApp(image),
                    isMainExecutable: image.isMainExecutable
                )
            }
    }
}

enum CrashHex {
    static func padded(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    static func short(_ value: UInt64) -> String {
        String(format: "0x%llx", value)
    }
}
