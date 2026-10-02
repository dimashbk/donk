import SwiftUI
import UIKit

struct InspectorUIKitPlayground: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InspectorPlaygroundViewController {
        InspectorPlaygroundViewController()
    }

    func updateUIViewController(_ controller: InspectorPlaygroundViewController, context: Context) {}
}

final class InspectorPlaygroundViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let content = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "demo.root"
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "demo.scroll"
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.accessibilityIdentifier = "demo.content"
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        buildContent()
    }

    private func buildContent() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.accessibilityIdentifier = "demo.column"
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32),
        ])

        let title = UILabel()
        title.text = "Inspector playground"
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .label
        title.accessibilityIdentifier = "demo.title"

        let subtitle = UILabel()
        subtitle.text = "Labels, buttons, fields, images and nested containers"
        subtitle.font = .systemFont(ofSize: 15, weight: .regular)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 1
        subtitle.adjustsFontSizeToFitWidth = true
        subtitle.minimumScaleFactor = 0.8
        subtitle.accessibilityIdentifier = "demo.subtitle"

        let multiline = UILabel()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        multiline.attributedText = NSAttributedString(
            string: "A multi-line label that wraps across several lines. It uses a 14 pt medium font with a 1.2 line height multiple so you can check the line height in the info panel.",
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
            ]
        )
        multiline.numberOfLines = 0
        multiline.accessibilityIdentifier = "demo.multiline"

        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(multiline)
        stack.addArrangedSubview(makeButtonsRow())
        stack.addArrangedSubview(makeTextField())
        stack.addArrangedSubview(makeBlocksRow())
        stack.addArrangedSubview(makeSecureRow())
        stack.addArrangedSubview(makeNestedContainers())
        stack.addArrangedSubview(makeControlsRow())
    }

    private func makeButtonsRow() -> UIView {
        var primaryConfig = UIButton.Configuration.filled()
        primaryConfig.title = "Primary"
        primaryConfig.cornerStyle = .large
        primaryConfig.baseBackgroundColor = Self.color(0x6D5DFC)
        let primary = UIButton(configuration: primaryConfig)
        primary.accessibilityIdentifier = "demo.button.primary"

        let secondary = UIButton(type: .system)
        secondary.setTitle("Secondary", for: .normal)
        secondary.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        secondary.layer.cornerRadius = 12
        secondary.layer.borderWidth = 1
        secondary.layer.borderColor = Self.color(0x6D5DFC).cgColor
        secondary.accessibilityIdentifier = "demo.button.secondary"

        let row = UIStackView(arrangedSubviews: [primary, secondary])
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        row.accessibilityIdentifier = "demo.buttons"
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return row
    }

    private func makeTextField() -> UIView {
        let field = UITextField()
        field.placeholder = "Email address"
        field.font = .systemFont(ofSize: 16)
        field.borderStyle = .roundedRect
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "demo.textField"
        field.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return field
    }

    private func makeBlocksRow() -> UIView {
        let image = UIImageView(image: Self.gradientImage(size: CGSize(width: 56, height: 56)))
        image.contentMode = .scaleAspectFill
        image.layer.cornerRadius = 12
        image.layer.cornerCurve = .continuous
        image.clipsToBounds = true
        image.accessibilityIdentifier = "demo.image"

        let blocks = UIStackView(arrangedSubviews: [
            block(0x6D5DFC, radius: 8, id: "demo.block.purple"),
            block(0x22C55E, radius: 12, id: "demo.block.green"),
            block(0xF59E0B, radius: 16, id: "demo.block.amber"),
        ])
        blocks.axis = .horizontal
        blocks.spacing = 12
        blocks.accessibilityIdentifier = "demo.stack"

        let row = UIStackView(arrangedSubviews: [image, blocks, UIView()])
        row.axis = .horizontal
        row.spacing = 16
        row.alignment = .center
        row.accessibilityIdentifier = "demo.blocksRow"
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 56),
            image.heightAnchor.constraint(equalToConstant: 56),
        ])
        return row
    }

    private func block(_ hex: UInt32, radius: CGFloat, id: String) -> UIView {
        let view = UIView()
        view.backgroundColor = Self.color(hex)
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.accessibilityIdentifier = id
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 56),
            view.heightAnchor.constraint(equalToConstant: 56),
        ])
        return view
    }

    private func makeSecureRow() -> UIView {
        let container = SecureLayerContainerView(color: Self.color(0xF97316))
        let caption = UILabel()
        caption.text = "Secure-layer container, like ScreenProtectorKit. drawHierarchy leaves it out; the eyedropper falls back to layer rendering."
        caption.font = .systemFont(ofSize: 12, weight: .regular)
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        caption.accessibilityIdentifier = "demo.secureCaption"
        let row = UIStackView(arrangedSubviews: [container, caption])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.accessibilityIdentifier = "demo.secureRow"
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 120),
            container.heightAnchor.constraint(equalToConstant: 56),
        ])
        return row
    }

    private func makeNestedContainers() -> UIView {
        let outer = UIView()
        outer.backgroundColor = Self.color(0xE2E8F0)
        outer.layer.cornerRadius = 20
        outer.layer.cornerCurve = .continuous
        outer.accessibilityIdentifier = "demo.nested.outer"

        let middle = UIView()
        middle.backgroundColor = Self.color(0xCBD5E1)
        middle.layer.cornerRadius = 14
        middle.layer.cornerCurve = .continuous
        middle.translatesAutoresizingMaskIntoConstraints = false
        middle.accessibilityIdentifier = "demo.nested.middle"

        let inner = UIView()
        inner.backgroundColor = Self.color(0x6D5DFC)
        inner.layer.cornerRadius = 10
        inner.layer.cornerCurve = .continuous
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.accessibilityIdentifier = "demo.nested.inner"

        let label = UILabel()
        label.text = "padding 16 · 24"
        label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "demo.nested.label"

        outer.addSubview(middle)
        middle.addSubview(inner)
        inner.addSubview(label)
        NSLayoutConstraint.activate([
            middle.topAnchor.constraint(equalTo: outer.topAnchor, constant: 16),
            middle.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: 16),
            middle.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -16),
            middle.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: middle.topAnchor, constant: 24),
            inner.leadingAnchor.constraint(equalTo: middle.leadingAnchor, constant: 24),
            inner.trailingAnchor.constraint(equalTo: middle.trailingAnchor, constant: -24),
            inner.bottomAnchor.constraint(equalTo: middle.bottomAnchor, constant: -24),
            inner.heightAnchor.constraint(equalToConstant: 40),
            label.centerXAnchor.constraint(equalTo: inner.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
        ])
        return outer
    }

    private func makeControlsRow() -> UIView {
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.onTintColor = Self.color(0x22C55E)
        toggle.accessibilityIdentifier = "demo.switch"

        let slider = UISlider()
        slider.value = 0.35
        slider.accessibilityIdentifier = "demo.slider"

        let segmented = UISegmentedControl(items: ["pt", "px"])
        segmented.selectedSegmentIndex = 0
        segmented.accessibilityIdentifier = "demo.segmented"

        let row = UIStackView(arrangedSubviews: [toggle, slider, segmented])
        row.axis = .horizontal
        row.spacing = 16
        row.alignment = .center
        row.accessibilityIdentifier = "demo.controls"
        return row
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func gradientImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [color(0xF43F5E).cgColor, color(0xF59E0B).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
}

final class SecureLayerContainerView: UIView {
    private let field = UITextField()
    private let swatch = UIView()

    init(color: UIColor) {
        super.init(frame: .zero)
        accessibilityIdentifier = "demo.secureContainer"
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        swatch.backgroundColor = color
        swatch.layer.cornerRadius = 12
        swatch.layer.cornerCurve = .continuous
        swatch.accessibilityIdentifier = "demo.secureSwatch"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.layoutIfNeeded()
        guard let canvas = secureCanvas else { return }
        if swatch.layer.superlayer !== canvas {
            canvas.addSublayer(swatch.layer)
        }
        swatch.frame = canvas.convert(bounds, from: layer)
    }

    private var secureCanvas: CALayer? {
        if #available(iOS 17.0, *) {
            return field.layer.sublayers?.last
        }
        return field.layer.sublayers?.first
    }
}

enum SecureWindowDemo {
    private static var field: UITextField?

    @MainActor
    static func protect(_ window: UIWindow) {
        guard field == nil, let superlayer = window.layer.superlayer else { return }
        let secure = UITextField()
        secure.isSecureTextEntry = true
        secure.isUserInteractionEnabled = false
        window.addSubview(secure)
        superlayer.addSublayer(secure.layer)
        let canvas: CALayer?
        if #available(iOS 17.0, *) {
            canvas = secure.layer.sublayers?.last
        } else {
            canvas = secure.layer.sublayers?.first
        }
        canvas?.addSublayer(window.layer)
        field = secure
    }
}
