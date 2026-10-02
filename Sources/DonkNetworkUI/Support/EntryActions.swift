import DonkCore
import DonkUI
import Foundation
import SwiftUI

@MainActor
enum EntryActions {
    private static let repeatSession = URLSession(configuration: .default)

    // MARK: - Commands

    static func commandLabel(_ entry: NetworkEntry) -> String {
        entry.kind == .grpc ? "grpcurl" : "cURL"
    }

    static func command(for entry: NetworkEntry) -> String {
        let redaction = exportRedaction
        return entry.kind == .grpc
            ? GRPCurlExporter.command(for: entry, redaction: redaction)
            : CurlExporter.command(for: entry.request, redaction: redaction)
    }

    static var exportRedaction: RedactionPolicy? {
        NetworkSettingsStore.shared.settings.exportRedaction
    }

    // MARK: - Copy

    static func copyURL(_ entry: NetworkEntry) {
        DonkPasteboard.copy(entry.request.url, label: "URL")
    }

    static func copyCommand(_ entry: NetworkEntry) {
        DonkPasteboard.copy(command(for: entry), label: commandLabel(entry))
    }

    static func copyText(_ entry: NetworkEntry) {
        DonkPasteboard.copy(EntryTextExporter.text(for: entry, redaction: exportRedaction), label: "Text")
    }

    static func copyBody(_ body: BodyData?, label: String) {
        guard let body, !body.data.isEmpty else {
            DonkToast.show("No body to copy", tone: .neutral)
            return
        }
        if let pretty = body.prettyJSON {
            DonkPasteboard.copy(pretty, label: label)
        } else if let text = body.text {
            DonkPasteboard.copy(text, label: label)
        } else {
            DonkPasteboard.copy(body.data.base64EncodedString(), label: "\(label) (base64)")
        }
    }

    // MARK: - Share

    static func shareCommand(_ entry: NetworkEntry) {
        DonkShare.share(text: command(for: entry))
    }

    static func shareText(_ entry: NetworkEntry) {
        DonkShare.share(fileNamed: "\(baseName(for: entry)).txt", data: Data(EntryTextExporter.text(for: entry, redaction: exportRedaction).utf8))
    }

    static func shareHAR(_ entry: NetworkEntry) {
        shareHAR([entry], fileName: "\(baseName(for: entry)).har")
    }

    static func shareHAR(_ entries: [NetworkEntry], fileName: String) {
        guard !entries.isEmpty else {
            DonkToast.show("Nothing to export", tone: .neutral)
            return
        }
        let redaction = exportRedaction
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                try? HARExporter.data(for: entries, redaction: redaction)
            }.value
            guard let data else {
                DonkHaptics.error()
                DonkToast.show("HAR export failed", tone: .error)
                return
            }
            DonkShare.share(fileNamed: fileName, data: data)
        }
    }

    static func shareAllText(_ entries: [NetworkEntry], fileName: String) {
        guard !entries.isEmpty else {
            DonkToast.show("Nothing to export", tone: .neutral)
            return
        }
        let redaction = exportRedaction
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data in
                let separator = "\n" + String(repeating: "─", count: 60) + "\n\n"
                return Data(entries.map { EntryTextExporter.text(for: $0, redaction: redaction) }.joined(separator: separator).utf8)
            }.value
            DonkShare.share(fileNamed: fileName, data: data)
        }
    }

    static func shareBody(_ entry: NetworkEntry, response: Bool) {
        let body = response ? entry.response?.body : entry.request.body
        guard let body, !body.data.isEmpty else {
            DonkToast.show("No body to share", tone: .neutral)
            return
        }
        let name = EntryFormat.fileName(for: entry, part: response ? "response" : "request", body: body)
        DonkShare.share(fileNamed: name, data: body.data)
    }

    static func exportFileName(_ ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "donk-network-\(formatter.string(from: Date())).\(ext)"
    }

    private static func baseName(for entry: NetworkEntry) -> String {
        let last = entry.title.split(separator: "/").last.map(String.init) ?? "request"
        let trimmed = last.split(separator: "?").first.map(String.init) ?? last
        return "\(entry.methodLabel.lowercased().replacingOccurrences(of: " ", with: "-"))-\(trimmed.isEmpty ? "request" : trimmed)"
    }

    // MARK: - Mutations

    static func togglePin(_ id: UUID) {
        var pinned = false
        NetworkStore.shared.update(id) { entry in
            entry.isPinned.toggle()
            pinned = entry.isPinned
        }
        DonkHaptics.light()
        DonkToast.show(pinned ? "Pinned" : "Unpinned", icon: pinned ? "pin.fill" : "pin.slash", tone: .neutral, duration: 1.2)
    }

    static func delete(_ ids: Set<UUID>) {
        NetworkStore.shared.remove(ids)
        DonkHaptics.light()
    }

    static func hideHost(_ host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        var settings = NetworkSettingsStore.shared.settings
        guard !settings.hiddenHosts.contains(where: { $0.lowercased() == host }) else { return }
        settings.hiddenHosts.append(host)
        NetworkSettingsStore.shared.settings = settings
        DonkHaptics.light()
        DonkToast.show("Hidden \(host)", icon: "eye.slash", tone: .neutral)
    }

    static func unhideHost(_ pattern: String) {
        var settings = NetworkSettingsStore.shared.settings
        settings.hiddenHosts.removeAll { $0.caseInsensitiveCompare(pattern) == .orderedSame }
        NetworkSettingsStore.shared.settings = settings
    }

    // MARK: - Repeat

    static let safeRepeatMethods: Set<String> = ["GET", "HEAD", "OPTIONS"]

    static func repeatPlan(for entry: NetworkEntry) -> RepeatPlan {
        guard EntryStyle.canRepeat(entry), let url = URL(string: entry.request.url) else {
            return .blocked(message: "Only HTTP and HTTPS requests can be repeated.")
        }
        if let body = entry.request.body, body.isTruncated {
            return .blocked(
                message: "The request body was truncated when it was captured (\(DonkFormat.bytes(body.data.count)) of \(DonkFormat.bytes(body.originalSize))), so donk can't send the original request again. Raise Max body size in donk Settings and capture the request again."
            )
        }
        let method = entry.request.method.uppercased()
        guard !safeRepeatMethods.contains(method) else { return .send }
        let host = url.host ?? entry.host ?? entry.request.url
        let auth = authHeaderNames(in: entry.request.headers)
        let authLine = auth.isEmpty
            ? "Any auth headers and cookies captured with it are sent too."
            : "Auth headers will be sent: \(auth.joined(separator: ", "))."
        return .confirm(
            method: method,
            message: "This sends \(method) to \(host) again with the captured headers and body. \(authLine) The server may apply the change a second time."
        )
    }

    static func authHeaderNames(in headers: [HTTPHeader]) -> [String] {
        let policy = NetworkSettingsStore.shared.settings.redaction
        let keywords = ["auth", "token", "cookie", "session", "api-key", "apikey", "secret"]
        var seen = Set<String>()
        return headers.compactMap { header in
            let name = header.name.lowercased()
            guard !name.hasPrefix(":"), policy.redactsHeader(name) || keywords.contains(where: name.contains) else { return nil }
            return seen.insert(name).inserted ? header.name : nil
        }
    }

    static func beginRepeat(_ entry: NetworkEntry) -> RepeatPrompt? {
        let plan = repeatPlan(for: entry)
        if case .send = plan {
            repeatRequest(entry)
            return nil
        }
        DonkHaptics.warning()
        return RepeatPrompt(entry: entry, plan: plan)
    }

    static func repeatRequest(_ entry: NetworkEntry) {
        guard EntryStyle.canRepeat(entry), let url = URL(string: entry.request.url) else {
            DonkToast.show("Only HTTP requests can be repeated", tone: .warning)
            return
        }
        guard entry.request.body?.isTruncated != true else {
            DonkToast.show("Truncated bodies can't be repeated", tone: .warning)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = entry.request.method
        for header in entry.request.headers where !header.name.hasPrefix(":") && header.name.lowercased() != "content-length" {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if let body = entry.request.body, !body.data.isEmpty {
            request.httpBody = body.data
        }
        DonkHaptics.light()
        DonkToast.show("Request sent", icon: "arrow.clockwise", tone: .accent, duration: 1.5)
        repeatSession.dataTask(with: request) { _, response, error in
            if let error {
                DonkToast.show("Repeat failed: \(error.localizedDescription)", tone: .error)
            } else if let http = response as? HTTPURLResponse {
                DonkToast.show("Repeat finished · \(http.statusCode)", tone: DonkTone.httpStatus(http.statusCode), duration: 1.5)
            }
        }.resume()
    }
}

// MARK: - Repeat prompt

enum RepeatPlan: Equatable {
    case send
    case confirm(method: String, message: String)
    case blocked(message: String)
}

struct RepeatPrompt: Identifiable {
    let id = UUID()
    let entry: NetworkEntry
    let plan: RepeatPlan
}

private struct RepeatPromptModifier: ViewModifier {
    @Binding var prompt: RepeatPrompt?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                confirmTitle,
                isPresented: binding(isBlocked: false),
                titleVisibility: .visible,
                presenting: prompt
            ) { prompt in
                if case let .confirm(method, _) = prompt.plan {
                    Button("Send \(method) Again", role: .destructive) {
                        EntryActions.repeatRequest(prompt.entry)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                if case let .confirm(_, message) = prompt.plan {
                    Text(message)
                }
            }
            .alert(
                "Can't repeat this request",
                isPresented: binding(isBlocked: true),
                presenting: prompt
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { prompt in
                if case let .blocked(message) = prompt.plan {
                    Text(message)
                }
            }
    }

    private var confirmTitle: String {
        if case let .confirm(method, _)? = prompt?.plan {
            return "Repeat \(method) request?"
        }
        return "Repeat request?"
    }

    private func binding(isBlocked: Bool) -> Binding<Bool> {
        Binding(
            get: {
                switch prompt?.plan {
                case .blocked?: return isBlocked
                case .confirm?: return !isBlocked
                case .send?, nil: return false
                }
            },
            set: { isPresented in
                if !isPresented {
                    prompt = nil
                }
            }
        )
    }
}

extension View {
    func repeatRequestPrompt(_ prompt: Binding<RepeatPrompt?>) -> some View {
        modifier(RepeatPromptModifier(prompt: prompt))
    }
}
