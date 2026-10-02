import DonkCore
import DonkUI
import ImageIO
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Image

struct ImageMetadata: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let typeName: String?
    let frameCount: Int
    let hasAlpha: Bool
    let colorModel: String?

    static func read(_ url: URL) -> ImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }
        let typeName = (CGImageSourceGetType(source) as String?).flatMap { identifier in
            UTType(identifier)?.preferredFilenameExtension?.uppercased() ?? identifier
        }
        return ImageMetadata(
            pixelWidth: width,
            pixelHeight: height,
            typeName: typeName,
            frameCount: CGImageSourceGetCount(source),
            hasAlpha: (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false,
            colorModel: properties[kCGImagePropertyColorModel] as? String
        )
    }
}

struct ImageFilePreview: View {
    let url: URL
    let fileSize: Int64
    var onUnreadable: (() -> Void)?

    @State private var image: UIImage?
    @State private var metadata: ImageMetadata?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                VStack(spacing: 0) {
                    ZoomableImageView(image: image)
                        .background(DonkColor.codeBackground)
                    infoBar
                }
            } else if didFail {
                StorageErrorView(title: "Can't decode image", message: "The file looks like an image but couldn't be decoded.", retry: onUnreadable)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .donkScreenBackground()
        .task { await load() }
    }

    private var infoBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DonkSpacing.s) {
                if let metadata {
                    TonePill(text: "\(metadata.pixelWidth) × \(metadata.pixelHeight) px", tone: .success, icon: "ruler")
                }
                TonePill(text: DonkFormat.bytes(fileSize), tone: .neutral)
                if let type = metadata?.typeName {
                    TonePill(text: type, tone: .neutral)
                }
                if let metadata, metadata.frameCount > 1 {
                    TonePill(text: "\(metadata.frameCount) frames", tone: .info)
                }
                if metadata?.hasAlpha == true {
                    TonePill(text: "Alpha", tone: .neutral)
                }
                if let image, image.scale > 1 {
                    TonePill(text: "@\(Int(image.scale))x", tone: .neutral)
                }
            }
            .padding(.horizontal, DonkSpacing.l)
            .padding(.vertical, DonkSpacing.m)
        }
        .background(DonkColor.card.ignoresSafeArea(edges: .bottom))
    }

    private func load() async {
        guard image == nil else { return }
        let url = self.url
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, ImageMetadata?) in
            let image = UIImage(contentsOfFile: url.path)
            return (image?.preparingForDisplay() ?? image, ImageMetadata.read(url))
        }.value
        metadata = loaded.1
        if let decoded = loaded.0 {
            image = decoded
        } else {
            didFail = true
        }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        ZoomingImageScrollView(image: image)
    }

    func updateUIView(_ view: ZoomingImageScrollView, context: Context) {
        view.setImage(image)
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Image preview"
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        setImage(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBoundsSize, bounds.width > 0, bounds.height > 0 else {
            centerContent()
            return
        }
        lastBoundsSize = bounds.size
        configureZoomScales()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        imageView.layer.magnificationFilter = zoomScale > 3 ? .nearest : .linear
        centerContent()
    }

    private func configureZoomScales() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let minimum = min(fit, 1)
        minimumZoomScale = minimum
        maximumZoomScale = max(minimum * 10, 8)
        zoomScale = minimum
        centerContent()
    }

    private func centerContent() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let target = min(max(minimumZoomScale * 3, 1), maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let width = bounds.width / target
        let height = bounds.height / target
        zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
    }
}

// MARK: - Quick Look

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QuickLookContainerController {
        QuickLookContainerController(url: url)
    }

    func updateUIViewController(_ controller: QuickLookContainerController, context: Context) {}
}

final class QuickLookContainerController: UIViewController, QLPreviewControllerDataSource {
    private let url: URL
    private let preview = QLPreviewController()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preview.dataSource = self
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: view.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preview.didMove(toParent: self)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }
}

// MARK: - Hex

struct HexFilePreview: View {
    let url: URL
    let fileSize: Int64
    let kind: FileKind

    @State private var dump: String?
    @State private var loadError: String?
    @StateObject private var search = CodeSearchState()
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if let loadError {
                StorageErrorView(title: "Can't read file", message: loadError)
            } else if let dump {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: DonkSpacing.s) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DonkSpacing.s) {
                                TonePill(text: kind.title, tone: kind.tone, icon: kind.icon)
                                TonePill(text: DonkFormat.bytes(fileSize), tone: .neutral)
                                if fileSize > Int64(HexDump.defaultLimit) {
                                    TonePill(text: "First 64 KB", tone: .warning)
                                }
                                NavigationLink {
                                    QuickLookPreview(url: url)
                                        .ignoresSafeArea(edges: .bottom)
                                        .donkNavigationTitle(url.lastPathComponent)
                                } label: {
                                    Label("Quick Look", systemImage: "eye")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }
                        CodeSearchBar(state: search, prompt: "Find bytes or text")
                    }
                    .padding(.horizontal, DonkSpacing.l)
                    .padding(.top, DonkSpacing.s)
                    if dump.isEmpty {
                        EmptyStateView(icon: "doc", title: "Empty file", tone: .neutral)
                    } else {
                        CodeView(text: dump, language: .plain, search: search, layout: .scrolling)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .donkScreenBackground()
        .task { await load() }
    }

    private func load() async {
        guard dump == nil else { return }
        let url = self.url
        let size = Int(fileSize)
        let bytesPerLine = sizeClass == .regular ? 16 : 8
        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            Result {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: HexDump.defaultLimit) ?? Data()
                return HexDump.dump(data, totalSize: max(size, data.count), bytesPerLine: bytesPerLine)
            }
        }.value
        switch result {
        case let .success(text): dump = text
        case let .failure(error): loadError = error.localizedDescription
        }
    }
}
