import DonkCore
import DonkUI
import SwiftUI
import UIKit

struct HomeHeaderCard: View {
    let info: AppInfo

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            HStack(spacing: DonkSpacing.m + 2) {
                AppIconView(name: info.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name)
                        .font(DonkFont.title)
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(versionText)
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                infoLine(icon: "shippingbox", text: info.bundleID.isEmpty ? "Unknown bundle" : info.bundleID, monospaced: true)
                HStack(spacing: DonkSpacing.s) {
                    infoLine(icon: "iphone", text: "\(info.deviceModel) · iOS \(info.osVersion)", monospaced: false)
                    if Self.isSimulator {
                        TonePill(text: "Simulator", tone: .info)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(DonkSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                    .fill(DonkColor.card)
                RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DonkColor.accent.opacity(0.14), DonkColor.accent.opacity(0)],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
            }
        )
        .contextMenu {
            Button {
                DonkPasteboard.copy(info.bundleID, label: "Bundle ID")
            } label: {
                Label("Copy Bundle ID", systemImage: "doc.on.doc")
            }
            Button {
                DonkPasteboard.copy(summary, label: "App info")
            } label: {
                Label("Copy App Info", systemImage: "doc.on.clipboard")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var versionText: String {
        switch (info.version.isEmpty, info.build.isEmpty) {
        case (false, false): return "Version \(info.version) (\(info.build))"
        case (false, true): return "Version \(info.version)"
        case (true, false): return "Build \(info.build)"
        case (true, true): return "Unknown version"
        }
    }

    private var summary: String {
        DonkKeyValue.text(for: [
            DonkKeyValue("App", info.name),
            DonkKeyValue("Version", versionText),
            DonkKeyValue("Bundle ID", info.bundleID),
            DonkKeyValue("Device", info.deviceModel),
            DonkKeyValue("iOS", info.osVersion),
        ])
    }

    private func infoLine(icon: String, text: String, monospaced: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(DonkColor.textTertiary)
                .frame(width: 16)
            Text(DonkTextBreaking.breakable(text))
                .font(monospaced ? DonkFont.codeCaption : .caption)
                .foregroundColor(DonkColor.textSecondary)
                .lineLimit(2)
        }
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - App icon

struct AppIconView: View {
    let name: String
    private let size: CGFloat = 58

    var body: some View {
        Group {
            if let image = AppIconLoader.icon {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [DonkColor.accent, DonkColor.grpc],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(initial)
                        .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

enum AppIconLoader {
    @MainActor static let icon: UIImage? = load()

    static func iconNames(from info: [String: Any]?) -> [String] {
        guard let icons = info?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { return [] }
        var names: [String] = []
        if let files = primary["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files.reversed())
        }
        if let name = primary["CFBundleIconName"] as? String {
            names.append(name)
        }
        return names
    }

    @MainActor private static func load() -> UIImage? {
        for name in iconNames(from: Bundle.main.infoDictionary) {
            if let image = UIImage(named: name) {
                return image
            }
        }
        return nil
    }
}
