import DonkCore
import DonkUI
import SwiftUI
import UIKit

struct PushBannerPreview: View {
    let mapped: PushMappedContent
    let imageURL: URL?
    let showsAttachment: Bool
    let isValid: Bool

    var body: some View {
        ZStack {
            wallpaper
            content
                .padding(DonkSpacing.m)
                .opacity(isValid ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var wallpaper: some View {
        LinearGradient(
            colors: [DonkColor.accent.opacity(0.85), DonkColor.info.opacity(0.7), DonkColor.web.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(colors: [Color.white.opacity(0.35), .clear], center: .topTrailing, startRadius: 4, endRadius: 220)
        )
    }

    @ViewBuilder
    private var content: some View {
        if mapped.hasAlert {
            banner
        } else {
            noBanner
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 10) {
            PushAppIcon(size: 38, badge: mapped.badge)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.xs) {
                    Text(DonkEnvironment.appInfo.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let level = mapped.interruptionLevel, level == .timeSensitive || level == .critical {
                        Text(level.title.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundColor(level == .critical ? DonkColor.error : DonkColor.warning)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DonkSpacing.xs)
                    Text("now")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !mapped.title.isEmpty {
                    Text(DonkTextBreaking.breakable(mapped.title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                if !mapped.subtitle.isEmpty {
                    Text(DonkTextBreaking.breakable(mapped.subtitle))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                if !mapped.body.isEmpty {
                    Text(DonkTextBreaking.breakable(mapped.body))
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAttachment, let imageURL {
                PushRemoteThumbnail(url: imageURL)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DonkRadius.large, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private var noBanner: some View {
        HStack(spacing: DonkSpacing.m) {
            PushAppIcon(size: 44, badge: mapped.badge)
            VStack(alignment: .leading, spacing: 2) {
                Text(noBannerTitle)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                    .foregroundColor(.primary)
                Text(noBannerMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: mapped.isContentAvailable ? "moon.zzz.fill" : "bell.slash.fill")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DonkRadius.large, style: .continuous))
    }

    private var noBannerTitle: String {
        if !mapped.hasAPS { return "No aps dictionary" }
        if mapped.isContentAvailable { return "Silent push" }
        if mapped.badge != nil { return "Badge update" }
        if mapped.sound != nil { return "Sound only" }
        return "Nothing to show"
    }

    private var noBannerMessage: String {
        if !mapped.hasAPS { return "iOS shows nothing; the app sees it only through Silent or Inject." }
        if mapped.isContentAvailable { return "No banner. The app wakes in the background." }
        if let badge = mapped.badge { return "Sets the app icon badge to \(badge) without a banner." }
        if mapped.sound != nil { return "Plays a sound without a banner." }
        return "Add aps.alert to show a banner."
    }

    private var accessibilityText: String {
        if mapped.hasAlert {
            return ["Notification preview", mapped.title, mapped.subtitle, mapped.body].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return "Notification preview, \(noBannerTitle)"
    }
}

// MARK: - Content summary

struct PushContentChips: View {
    let mapped: PushMappedContent

    var body: some View {
        let chips = items
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DonkSpacing.xs) {
                    ForEach(chips, id: \.text) { chip in
                        TonePill(text: chip.text, tone: chip.tone, icon: chip.icon)
                    }
                }
            }
        }
    }

    private var items: [(text: String, tone: DonkTone, icon: String)] {
        var result: [(String, DonkTone, String)] = []
        if let sound = mapped.sound {
            result.append((sound.label, .info, "speaker.wave.2.fill"))
        }
        if let badge = mapped.badge {
            result.append(("badge \(badge)", .error, "app.badge"))
        }
        if !mapped.threadIdentifier.isEmpty {
            result.append(("thread \(mapped.threadIdentifier)", .neutral, "text.bubble"))
        }
        if !mapped.categoryIdentifier.isEmpty {
            result.append((mapped.categoryIdentifier, .success, "hand.tap"))
        }
        if let level = mapped.interruptionLevel {
            result.append((level.title, level == .critical ? .error : .warning, "exclamationmark.circle"))
        }
        if let score = mapped.relevanceScore {
            result.append(("relevance \(DonkFormat.number(score, fractionDigits: 2))", .neutral, "chart.bar"))
        }
        if let target = mapped.targetContentIdentifier {
            result.append(("target \(target)", .neutral, "scope"))
        }
        if mapped.isMutableContent {
            result.append(("mutable-content", .web, "wand.and.stars"))
        }
        if mapped.isContentAvailable {
            result.append(("content-available", .grpc, "moon.zzz"))
        }
        return result
    }
}

// MARK: - App icon

struct PushAppIcon: View {
    let size: CGFloat
    var badge: Int?

    var body: some View {
        icon
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: max(10, size * 0.28), weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: size * 0.42, minHeight: size * 0.42)
                        .background(Capsule().fill(Color.red))
                        .offset(x: size * 0.18, y: -size * 0.18)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = Self.appIcon {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [DonkColor.accent, DonkColor.info], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(Self.initial)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }

    private static let initial: String = {
        let name = DonkEnvironment.appInfo.name.trimmingCharacters(in: .whitespaces)
        return name.first.map { String($0).uppercased() } ?? "A"
    }()

    private static let appIcon: UIImage? = {
        let info = Bundle.main.infoDictionary ?? [:]
        let icons = info["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        var names = (primary?["CFBundleIconFiles"] as? [String] ?? []).reversed().map { $0 }
        if let name = primary?["CFBundleIconName"] as? String {
            names.append(name)
        }
        for name in names {
            if let image = UIImage(named: name) {
                return image
            }
        }
        return nil
    }()
}

// MARK: - Remote image

@MainActor
final class PushImageLoader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(UIImage)
        case failed
    }

    @Published private(set) var phase: Phase = .idle

    private static let cache = NSCache<NSURL, UIImage>()

    func load(_ url: URL) async {
        if let cached = Self.cache.object(forKey: url as NSURL) {
            phase = .loaded(cached)
            return
        }
        phase = .loading
        do {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
                data = try await DonkEnvironment.internalSession.data(for: request).0
            }
            try Task.checkCancellation()
            guard let image = UIImage(data: data) else {
                phase = .failed
                return
            }
            Self.cache.setObject(image, forKey: url as NSURL)
            phase = .loaded(image)
        } catch {
            if !Task.isCancelled {
                phase = .failed
            }
        }
    }
}

struct PushRemoteThumbnail: View {
    let url: URL
    @StateObject private var loader = PushImageLoader()

    var body: some View {
        ZStack {
            DonkColor.fill
            switch loader.phase {
            case let .loaded(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .failed:
                Image(systemName: "photo")
                    .foregroundColor(DonkColor.textTertiary)
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            await loader.load(url)
        }
    }
}
