import DonkCore
import DonkUI
import SwiftUI
import UIKit

// MARK: - Kind

enum BodyKind: Equatable, Sendable {
    case image, form, json, text, binary

    var title: String {
        switch self {
        case .image: return "Image"
        case .form: return "Form"
        case .json: return "JSON"
        case .text: return "Text"
        case .binary: return "Binary"
        }
    }

    static func startsLikeJSON(_ data: Data) -> Bool {
        for byte in data.prefix(64) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue
            case UInt8(ascii: "{"), UInt8(ascii: "["): return true
            default: return false
            }
        }
        return false
    }
}

// MARK: - Analysis

struct BodyAnalysis: Sendable {
    static let synchronousLimit = 128 * 1024

    let kind: BodyKind
    let text: String?
    let hexDump: String?
    let language: CodeLanguage

    static func analyze(_ body: BodyData) -> BodyAnalysis {
        let language = CodeLanguage.detect(contentType: body.contentType, text: nil)
        if body.isImage {
            return BodyAnalysis(kind: .image, text: nil, hexDump: nil, language: language)
        }
        if body.isFormURLEncoded {
            return BodyAnalysis(kind: .form, text: body.text ?? "", hexDump: nil, language: language)
        }
        let mime = body.mimeType ?? ""
        if mime.contains("json") || BodyKind.startsLikeJSON(body.data) {
            return BodyAnalysis(kind: .json, text: nil, hexDump: nil, language: .json)
        }
        let binaryMime = mime.contains("protobuf") || mime.contains("octet-stream") || mime.hasPrefix("application/grpc")
        if !binaryMime, let text = body.text {
            return BodyAnalysis(kind: .text, text: text, hexDump: nil, language: language)
        }
        return BodyAnalysis(kind: .binary, text: nil, hexDump: EntryFormat.hexDump(body.data), language: .plain)
    }
}

struct BodyFingerprint: Hashable, Sendable {
    let count: Int
    let originalSize: Int
    let isTruncated: Bool
    let contentType: String?
    let head: Int
    let tail: Int

    init(_ body: BodyData) {
        count = body.data.count
        originalSize = body.originalSize
        isTruncated = body.isTruncated
        contentType = body.contentType
        head = Self.hash(body.data.prefix(256))
        tail = Self.hash(body.data.suffix(256))
    }

    private static func hash(_ bytes: Data) -> Int {
        var hasher = Hasher()
        bytes.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}

final class BodyAnalysisCache: @unchecked Sendable {
    static let shared = BodyAnalysisCache()

    private final class Box {
        let analysis: BodyAnalysis

        init(_ analysis: BodyAnalysis) {
            self.analysis = analysis
        }
    }

    private let cache: NSCache<NSNumber, Box> = {
        let cache = NSCache<NSNumber, Box>()
        cache.countLimit = 48
        return cache
    }()
    private let lock = NSLock()
    private var keys: [BodyFingerprint: Int] = [:]
    private var nextKey = 0

    func analysis(for fingerprint: BodyFingerprint) -> BodyAnalysis? {
        guard let key = key(for: fingerprint, creating: false) else { return nil }
        return cache.object(forKey: NSNumber(value: key))?.analysis
    }

    func store(_ analysis: BodyAnalysis, for fingerprint: BodyFingerprint) {
        guard let key = key(for: fingerprint, creating: true) else { return }
        cache.setObject(Box(analysis), forKey: NSNumber(value: key))
    }

    func resolve(_ body: BodyData, fingerprint: BodyFingerprint) -> BodyAnalysis? {
        if let cached = analysis(for: fingerprint) { return cached }
        guard body.data.count <= BodyAnalysis.synchronousLimit else { return nil }
        let analysis = BodyAnalysis.analyze(body)
        store(analysis, for: fingerprint)
        return analysis
    }

    func load(_ body: BodyData, fingerprint: BodyFingerprint) async -> BodyAnalysis {
        if let cached = analysis(for: fingerprint) { return cached }
        let analysis = await Task.detached(priority: .userInitiated) { BodyAnalysis.analyze(body) }.value
        store(analysis, for: fingerprint)
        return analysis
    }

    private func key(for fingerprint: BodyFingerprint, creating: Bool) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let key = keys[fingerprint] { return key }
        guard creating else { return nil }
        if keys.count > 256 {
            keys.removeAll(keepingCapacity: true)
        }
        nextKey &+= 1
        keys[fingerprint] = nextKey
        return nextKey
    }
}

struct BodyAnalysisReader<Content: View, Placeholder: View>: View {
    let bodyData: BodyData
    let content: (BodyAnalysis) -> Content
    let placeholder: () -> Placeholder

    @State private var loaded: Loaded?

    private struct Loaded {
        let fingerprint: BodyFingerprint
        let analysis: BodyAnalysis
    }

    init(
        bodyData: BodyData,
        @ViewBuilder content: @escaping (BodyAnalysis) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.bodyData = bodyData
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        let fingerprint = BodyFingerprint(bodyData)
        let exact = loaded?.fingerprint == fingerprint ? loaded?.analysis : nil
        let analysis = exact ?? BodyAnalysisCache.shared.resolve(bodyData, fingerprint: fingerprint) ?? loaded?.analysis
        Group {
            if let analysis {
                content(analysis)
            } else {
                placeholder()
            }
        }
        .task(id: fingerprint) {
            guard bodyData.data.count > BodyAnalysis.synchronousLimit, loaded?.fingerprint != fingerprint else { return }
            let body = bodyData
            let result = await BodyAnalysisCache.shared.load(body, fingerprint: fingerprint)
            guard !Task.isCancelled else { return }
            loaded = Loaded(fingerprint: fingerprint, analysis: result)
        }
    }
}

extension BodyAnalysisReader where Placeholder == BodyLoadingView {
    init(bodyData: BodyData, @ViewBuilder content: @escaping (BodyAnalysis) -> Content) {
        self.init(bodyData: bodyData, content: content) { BodyLoadingView() }
    }
}

struct BodyLoadingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

// MARK: - Card

struct BodyCard: View {
    static let embedLimit = 200 * 1024

    let bodyData: BodyData?
    let title: String
    let note: String?
    let fileName: String

    var body: some View {
        if let bodyData, !bodyData.data.isEmpty {
            BodyAnalysisReader(bodyData: bodyData) { analysis in
                card(bodyData: bodyData, analysis: analysis)
            } placeholder: {
                DonkCard(title: title, icon: "doc.text", tone: .info) {
                    noteText
                    BodyLoadingView()
                }
            }
        } else {
            DonkCard(title: title, icon: "doc.text", tone: .info) {
                noteText
                HStack(spacing: DonkSpacing.s) {
                    Image(systemName: "doc")
                        .foregroundColor(DonkColor.textTertiary)
                    Text("No body")
                        .font(.footnote)
                        .foregroundColor(DonkColor.textTertiary)
                }
                .padding(.vertical, DonkSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var noteText: some View {
        if let note {
            Text(note)
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(bodyData: BodyData, analysis: BodyAnalysis) -> some View {
        DonkCard(title: title, icon: "doc.text", tone: .info) {
            noteText
            if bodyData.data.count > Self.embedLimit {
                LargeBodySummary(bodyData: bodyData, kind: analysis.kind, title: title, fileName: fileName)
            } else {
                BodyViewer(bodyData: bodyData, analysis: analysis, layout: .embedded, fileName: fileName)
            }
        } accessory: {
            HStack(spacing: DonkSpacing.s) {
                Text("\(analysis.kind.title) · \(DonkFormat.bytes(bodyData.originalSize))")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundColor(DonkColor.textTertiary)
                NavigationLink {
                    BodyScreen(title: title, bodyData: bodyData, fileName: fileName)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 28, minHeight: 28)
                }
                .accessibilityLabel("Open full screen")
            }
        }
    }
}

private struct LargeBodySummary: View {
    let bodyData: BodyData
    let kind: BodyKind
    let title: String
    let fileName: String

    var body: some View {
        HStack(spacing: DonkSpacing.m) {
            DonkIconBadge("doc.text.magnifyingglass", tone: .info, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(DonkFormat.bytes(bodyData.originalSize)) \(kind.title)")
                    .font(.subheadline.weight(.semibold))
                Text("Large bodies open in a dedicated viewer with search and a JSON tree.")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if bodyData.isTruncated {
            TruncatedNotice(bodyData: bodyData)
        }
        NavigationLink {
            BodyScreen(title: title, bodyData: bodyData, fileName: fileName)
        } label: {
            Label("Open Viewer", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }
}

struct TruncatedNotice: View {
    let bodyData: BodyData

    var body: some View {
        NoticeBanner(
            icon: "scissors",
            text: "Truncated — showing the first \(DonkFormat.bytes(bodyData.data.count)) of \(DonkFormat.bytes(bodyData.originalSize)).",
            tone: .warning
        )
    }
}

// MARK: - Viewer

struct BodyViewer: View {
    let bodyData: BodyData
    let analysis: BodyAnalysis
    let layout: DonkLayoutMode
    let fileName: String
    @StateObject private var search = CodeSearchState()

    private var inset: CGFloat { layout == .scrolling ? DonkSpacing.l : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if bodyData.isTruncated && layout == .embedded {
                TruncatedNotice(bodyData: bodyData)
            }
            switch analysis.kind {
            case .image:
                ImageBodyView(bodyData: bodyData, layout: layout)
                    .padding(.horizontal, inset)
            case .form:
                FormBodyView(text: analysis.text ?? "", layout: layout)
                    .padding(.horizontal, inset)
            case .json:
                CodeSearchBar(state: search)
                    .padding(.horizontal, inset)
                JSONBodyView(data: bodyData.data, search: search, layout: layout, fileName: fileName)
            case .text:
                CodeSearchBar(state: search)
                    .padding(.horizontal, inset)
                CodeView(
                    text: analysis.text ?? "",
                    language: analysis.language,
                    search: search,
                    layout: layout
                )
            case .binary:
                HStack(spacing: DonkSpacing.s) {
                    TonePill(text: "Binary · \(DonkFormat.bytes(bodyData.originalSize))", tone: .neutral, icon: "cube.box")
                    if bodyData.data.count > 4096 {
                        Text("First 4 KB")
                            .font(.caption)
                            .foregroundColor(DonkColor.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, inset)
                CodeView(text: analysis.hexDump ?? "", language: .plain, layout: layout)
            }
        }
        .padding(.top, layout == .scrolling ? DonkSpacing.m : 0)
        .frame(maxWidth: .infinity, maxHeight: layout == .scrolling ? .infinity : nil, alignment: .topLeading)
    }
}

// MARK: - Full screen

struct BodyScreen: View {
    let title: String
    let bodyData: BodyData
    let fileName: String

    var body: some View {
        VStack(spacing: 0) {
            if bodyData.isTruncated {
                TruncatedNotice(bodyData: bodyData)
                    .padding(.horizontal, DonkSpacing.l)
                    .padding(.top, DonkSpacing.s)
            }
            BodyAnalysisReader(bodyData: bodyData) { analysis in
                BodyViewer(bodyData: bodyData, analysis: analysis, layout: .scrolling, fileName: fileName)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(DonkColor.card.ignoresSafeArea())
        .donkNavigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    DonkShare.share(fileNamed: fileName, data: bodyData.data)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share body")
            }
        }
    }
}

// MARK: - Form

private struct FormBodyView: View {
    enum Mode: String, CaseIterable { case table = "Table", raw = "Raw" }

    let text: String
    let layout: DonkLayoutMode
    @State private var mode: Mode = .table

    var body: some View {
        let fields = EntryFormat.formFields(text)
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            HStack {
                SegmentedTabs(selection: $mode, tabs: Mode.allCases, title: \.rawValue)
                    .frame(maxWidth: 180)
                Spacer(minLength: DonkSpacing.s)
                CopyButton(text: text, label: "Body")
            }
            switch mode {
            case .table:
                if fields.isEmpty {
                    Text("No fields")
                        .font(.footnote)
                        .foregroundColor(DonkColor.textTertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                            KeyValueRow(key: field.key, value: field.value, monospacedValue: true)
                            if index < fields.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            case .raw:
                CodeView(text: text, language: .plain, layout: .embedded)
            }
        }
    }
}

// MARK: - Image

private struct ImageBodyView: View {
    let bodyData: BodyData
    let layout: DonkLayoutMode
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    NavigationLink {
                        ZoomableImageScreen(image: image)
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: layout == .embedded ? 260 : 420)
                            .padding(DonkSpacing.s)
                            .background(
                                CheckerboardView()
                                    .clipShape(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous))
                            )
                    }
                    .buttonStyle(.donkPressable)
                    .accessibilityLabel("Image, tap to zoom")
                    HStack(spacing: 6) {
                        TonePill(text: dimensions(image), tone: .info, icon: "aspectratio")
                        TonePill(text: format, tone: .neutral)
                        Spacer(minLength: 0)
                        Text("Tap to zoom")
                            .font(.caption)
                            .foregroundColor(DonkColor.textTertiary)
                    }
                }
            } else if failed {
                VStack(alignment: .leading, spacing: DonkSpacing.s) {
                    NoticeBanner(icon: "photo", text: "The image could not be decoded. Showing the first bytes instead.", tone: .warning)
                    CodeView(text: EntryFormat.hexDump(bodyData.data, limit: 512), language: .plain)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: bodyData.data) {
            let data = bodyData.data
            let decoded = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
            image = decoded
            failed = decoded == nil
        }
    }

    private var format: String {
        if let mime = bodyData.mimeType, mime.hasPrefix("image/") {
            return String(mime.dropFirst(6)).uppercased()
        }
        return EntryFormat.fileExtension(for: bodyData).uppercased()
    }

    private func dimensions(_ image: UIImage) -> String {
        let width = image.cgImage.map { $0.width } ?? Int(image.size.width * image.scale)
        let height = image.cgImage.map { $0.height } ?? Int(image.size.height * image.scale)
        return "\(width) × \(height) px"
    }
}

private struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            let columns = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(DonkColor.fill))
                }
            }
        }
        .background(DonkColor.elevated)
    }
}

struct ZoomableImageScreen: View {
    let image: UIImage

    var body: some View {
        ZoomableImageView(image: image)
            .background(Color.black.ignoresSafeArea())
            .ignoresSafeArea(edges: .bottom)
            .donkNavigationTitle("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        DonkShare.share(items: [image])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share image")
                }
            }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        uiView.setImage(image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerContent()
        }
    }
}

private final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var lastBounds: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        minimumZoomScale = 1
        maximumZoomScale = 8
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        lastBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBounds, let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        lastBounds = bounds.size
        setZoomScale(1, animated: false)
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        centerContent()
    }

    func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 3
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
