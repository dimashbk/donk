import DonkUI
import SwiftUI

struct PerformanceEventDetailView: View {
    let event: PerformanceEvent

    var body: some View {
        DonkScrollContainer {
            DonkCard(title: "Summary", icon: event.icon, tone: event.severity.tone) {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Event", value: event.title)
                    if case let .hang(duration) = event.kind {
                        Divider()
                        KeyValueRow(key: "Duration", value: PerformanceText.duration(duration), monospacedValue: true, valueTone: event.severity.tone)
                    }
                    Divider()
                    KeyValueRow(key: "Started", value: "\(DonkFormat.dateTime(event.date)) (\(DonkFormat.time(event.date)))", monospacedValue: true)
                    Divider()
                    KeyValueRow(key: "Severity", value: event.severity.title, valueTone: event.severity.tone)
                    if let backtrace = event.backtrace {
                        Divider()
                        KeyValueRow(key: "Captured", value: "\(PerformanceText.duration(backtrace.capturedAfter)) into the hang")
                        Divider()
                        KeyValueRow(key: "Frames", value: "\(backtrace.frames.count)", monospacedValue: true)
                        if let frame = Self.firstAppFrame(in: backtrace) {
                            Divider()
                            KeyValueRow(key: "First app frame", value: frame.symbol ?? frame.line, monospacedValue: true, layout: .vertical, valueTone: .accent)
                        }
                    }
                }
            } accessory: {
                CopyButton(text: event.copyText, label: "Event")
            }
            if let backtrace = event.backtrace {
                DonkCard(title: "Main thread stack", icon: "list.number", tone: .accent) {
                    CodeView(text: backtrace.compactText)
                        .padding(DonkSpacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                                .fill(DonkColor.codeBackground)
                        )
                } accessory: {
                    CopyButton(text: backtrace.text, label: "Stack")
                }
            } else if event.isHang {
                DonkCard(title: "No stack", icon: "list.number", tone: .neutral) {
                    Text("The main thread's stack is captured while it is still blocked, once a hang lasts at least 1 s. Shorter hangs are recorded with their duration only.")
                        .font(DonkFont.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .donkNavigationTitle(event.isHang ? "Hang" : "Event")
        .tracksDonkScreen()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    DonkShare.share(fileNamed: fileName, data: Data(event.copyText.utf8))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
            }
        }
    }

    private var fileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(event.isHang ? "hang" : "event")-\(formatter.string(from: event.date)).txt"
    }

    static func firstAppFrame(in backtrace: PerformanceBacktrace) -> PerformanceStackFrame? {
        guard let executable = Bundle.main.executableURL?.lastPathComponent else { return nil }
        return backtrace.frames.first { frame in
            guard let image = frame.image else { return false }
            return image == executable || image.hasPrefix(executable + ".")
        }
    }
}
