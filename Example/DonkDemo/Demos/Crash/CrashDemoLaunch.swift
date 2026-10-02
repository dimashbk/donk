import Donk
import DonkUI
import SwiftUI
import UIKit

enum CrashDemoLaunch {
    private static var didHandle = false

    static func handleArguments() {
        guard !didHandle else { return }
        didHandle = true
        let arguments = ProcessInfo.processInfo.arguments
        if LaterCrashReporter.isRequested {
            LaterCrashReporter.install()
        }
        if let index = arguments.firstIndex(of: "-DonkCrashDemo"), index + 1 < arguments.count,
           let kind = DemoCrashKind(rawValue: arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                kind.trigger()
            }
            return
        }
        if arguments.contains("-DonkCrashShowLatest") {
            presentLatest(attempt: 0)
        } else if arguments.contains("-DonkCrashShowList") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                present(CrashReportsSheet())
            }
        }
    }

    private static func presentLatest(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let report = DonkCrash.reports().first {
                present(CrashReportDetailSheet(report: report))
            } else if attempt < 15 {
                presentLatest(attempt: attempt + 1)
            } else {
                present(CrashReportsSheet())
            }
        }
    }

    static func present<Content: View>(_ view: Content) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(UIHostingController(rootView: view), animated: true)
    }
}

struct CrashReportsSheet: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        DonkNavigationContainer {
            DonkCrash.makeRootView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
        }
        .donkTheme()
    }
}

struct CrashReportDetailSheet: View {
    let report: CrashReport
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        DonkNavigationContainer {
            DonkCrash.makeDetailView(for: report)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
        }
        .donkTheme()
    }
}
