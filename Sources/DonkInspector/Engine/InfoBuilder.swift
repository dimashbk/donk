import DonkUI
import UIKit

@MainActor
enum InfoBuilder {
    struct Context {
        var formatter: UnitFormatter
        var includesModule: Bool
        weak var overlay: UIWindow?
        var stackPosition: Int
        var stackCount: Int
    }

    static let childLimit = 60

    static func build(for node: InspectorNode, context: Context) -> InspectorInfo? {
        switch node.kind {
        case .view:
            guard let view = node.view else { return nil }
            return viewInfo(view, node: node, context: context)
        case .element:
            guard let host = node.host else { return nil }
            return elementInfo(node, host: host, context: context)
        }
    }

    static func shortName(of object: AnyObject, includesModule: Bool = false) -> String {
        let name = TypeNaming.displayName(of: object, includesModule: includesModule)
        guard let bracket = name.firstIndex(of: "<"), name.count > 42 else { return name }
        return String(name[..<bracket]) + "<…>"
    }

    // MARK: - Views

    private static func viewInfo(_ view: UIView, node: InspectorNode, context: Context) -> InspectorInfo {
        let format = context.formatter
        let qualified = TypeNaming.qualifiedName(of: view)
        let title = context.includesModule ? qualified : TypeNaming.stripModules(qualified)
        let category = TypeNaming.category(of: view)
        var subtitle = [TypeNaming.moduleName(of: view)]
        if let owner = view.next as? UIViewController {
            subtitle.append("root of " + shortName(of: owner))
        }
        if context.stackCount > 1 {
            subtitle.append("\(context.stackPosition + 1) of \(context.stackCount) here")
        }

        var sections = [layoutSection(view, format), appearanceSection(view, format)]
        sections.append(contentsOf: textSections(view, format))
        if let section = imageSection(view, format) { sections.append(section) }
        if let section = stackSection(view, format) { sections.append(section) }
        if let section = scrollSection(view, format) { sections.append(section) }
        if let section = controlSection(view) { sections.append(section) }
        sections.append(accessibilitySection(view))
        if TypeNaming.isHostingView(view) {
            sections.append(InfoSection(
                title: "SwiftUI",
                icon: "swift",
                rows: [InfoRow("Hosting", "SwiftUI content")],
                note: "SwiftUI views aren't UIViews. Tap inside this view to pick SwiftUI elements from the accessibility tree (partial)."
            ))
        }

        let parents = ViewHierarchy.ancestors(of: view).map { link(for: $0, format: format) }
        let subviews = view.subviews
        let children = subviews.prefix(childLimit).map { link(for: $0, format: format) }
        let insets = insetTexts(for: node, context: context)
        let sizeText = format.size(view.bounds.size)
        let info = InspectorInfo(
            nodeID: node.id,
            title: title,
            qualifiedName: qualified,
            subtitle: subtitle.joined(separator: " · "),
            icon: category.icon,
            tone: category.tone,
            badge: view.isHidden ? "Hidden" : nil,
            sizeText: sizeText,
            unitSuffix: format.suffix,
            insets: insets,
            sections: sections,
            parents: parents,
            children: children,
            hiddenChildren: max(0, subviews.count - childLimit),
            copyText: ""
        )
        return withCopyText(info)
    }

    private static func layoutSection(_ view: UIView, _ format: UnitFormatter) -> InfoSection {
        var rows: [InfoRow] = []
        rows.append(InfoRow("Frame", format.rect(view.frame), monospaced: true))
        if let window = view.window {
            let rect = view.convert(view.bounds, to: window)
            rows.append(InfoRow("In window", format.point(rect.origin), monospaced: true))
        }
        rows.append(InfoRow("Bounds", format.rect(view.bounds), monospaced: true))
        let intrinsic = view.intrinsicContentSize
        rows.append(InfoRow("Intrinsic size", intrinsicText(intrinsic, format), monospaced: true))
        rows.append(InfoRow("Layout", view.translatesAutoresizingMaskIntoConstraints ? "Frames · autoresizing mask" : "Auto Layout"))
        let horizontal = view.constraintsAffectingLayout(for: .horizontal).count
        let vertical = view.constraintsAffectingLayout(for: .vertical).count
        rows.append(InfoRow("Constraints", "H \(horizontal) · V \(vertical) affecting", monospaced: true))
        if view.hasAmbiguousLayout {
            rows.append(InfoRow("Ambiguous", "Yes", tone: .warning))
        }
        rows.append(InfoRow(
            "Hugging",
            "H \(priority(view.contentHuggingPriority(for: .horizontal))) · V \(priority(view.contentHuggingPriority(for: .vertical)))",
            monospaced: true
        ))
        rows.append(InfoRow(
            "Compression",
            "H \(priority(view.contentCompressionResistancePriority(for: .horizontal))) · V \(priority(view.contentCompressionResistancePriority(for: .vertical)))",
            monospaced: true
        ))
        rows.append(InfoRow("Layout margins", format.insets(view.layoutMargins), monospaced: true))
        if view.safeAreaInsets != .zero {
            rows.append(InfoRow("Safe area", format.insets(view.safeAreaInsets), monospaced: true))
        }
        if !view.transform.isIdentity {
            rows.append(InfoRow("Transform", transformText(view.transform), monospaced: true))
        }
        if !CATransform3DIsIdentity(view.layer.transform), view.transform.isIdentity {
            rows.append(InfoRow("Layer transform", "3D", monospaced: true))
        }
        return InfoSection(title: "Layout", icon: "ruler", rows: rows)
    }

    private static func appearanceSection(_ view: UIView, _ format: UnitFormatter) -> InfoSection {
        let traits = view.traitCollection
        let layer = view.layer
        var rows: [InfoRow] = []
        rows.append(InfoRow("Background", color: RGBAColor(view.backgroundColor, traits: traits)))
        rows.append(InfoRow("Tint", color: RGBAColor(view.tintColor, traits: traits)))
        rows.append(InfoRow("Alpha", UnitFormatter.decimal(Double(view.alpha)), monospaced: true))
        rows.append(InfoRow("Hidden", yesNo(view.isHidden)))
        var radius = format.length(layer.cornerRadius)
        if layer.cornerRadius > 0 {
            if layer.cornerCurve == .continuous { radius += " · continuous" }
            let corners = cornerCount(layer.maskedCorners)
            if corners < 4 { radius += " · \(corners) corners" }
        }
        rows.append(InfoRow("Corner radius", radius, monospaced: true))
        if layer.borderWidth > 0 {
            var border = InfoRow("Border", color: RGBAColor(cgColor: layer.borderColor))
            border.value = "\(format.length(layer.borderWidth)) · \(border.value)"
            rows.append(border)
        } else {
            rows.append(InfoRow("Border", "None"))
        }
        rows.append(InfoRow("Clips to bounds", yesNo(view.clipsToBounds)))
        rows.append(InfoRow("Content mode", contentModeName(view.contentMode)))
        if layer.shadowOpacity > 0 {
            let color = RGBAColor(cgColor: layer.shadowColor)?.hex ?? "—"
            let offset = "\(format.value(layer.shadowOffset.width)), \(format.value(layer.shadowOffset.height))"
            rows.append(InfoRow(
                "Shadow",
                "\(color) · \(Int((layer.shadowOpacity * 100).rounded()))% · radius \(format.value(layer.shadowRadius)) · offset \(offset)",
                monospaced: true
            ))
        }
        if layer.mask != nil {
            rows.append(InfoRow("Layer mask", "Yes"))
        }
        if let effect = view as? UIVisualEffectView {
            rows.append(InfoRow("Effect", effect.effect.map { String(describing: type(of: $0)) } ?? "None"))
        }
        return InfoSection(title: "Appearance", icon: "paintbrush", rows: rows)
    }

    private static func textSections(_ view: UIView, _ format: UnitFormatter) -> [InfoSection] {
        let traits = view.traitCollection
        if let label = view as? UILabel {
            return [textSection(
                title: "Text",
                text: label.attributedText?.string ?? label.text,
                font: label.font,
                color: label.textColor,
                attributed: label.attributedText,
                alignment: label.textAlignment,
                lines: label.numberOfLines,
                dynamicType: label.adjustsFontForContentSizeCategory,
                traits: traits,
                format: format,
                extra: label.adjustsFontSizeToFitWidth ? [InfoRow("Shrinks to fit", "min scale \(UnitFormatter.decimal(Double(label.minimumScaleFactor)))")] : []
            )]
        }
        if let field = view as? UITextField {
            var extra: [InfoRow] = []
            if let placeholder = field.placeholder, !placeholder.isEmpty {
                extra.append(InfoRow("Placeholder", placeholder))
            }
            extra.append(InfoRow("Secure", yesNo(field.isSecureTextEntry)))
            return [textSection(
                title: "Text",
                text: field.isSecureTextEntry ? (field.text?.isEmpty == false ? "••••" : "") : field.text,
                font: field.font,
                color: field.textColor,
                attributed: nil,
                alignment: field.textAlignment,
                lines: 1,
                dynamicType: field.adjustsFontForContentSizeCategory,
                traits: traits,
                format: format,
                extra: extra
            )]
        }
        if let textView = view as? UITextView {
            return [textSection(
                title: "Text",
                text: textView.text,
                font: textView.font,
                color: textView.textColor,
                attributed: textView.attributedText,
                alignment: textView.textAlignment,
                lines: textView.textContainer.maximumNumberOfLines,
                dynamicType: textView.adjustsFontForContentSizeCategory,
                traits: traits,
                format: format,
                extra: [
                    InfoRow("Container inset", format.insets(textView.textContainerInset), monospaced: true),
                    InfoRow("Editable", yesNo(textView.isEditable)),
                ]
            )]
        }
        if let button = view as? UIButton, let label = button.titleLabel, label.text?.isEmpty == false {
            return [textSection(
                title: "Title label",
                text: button.currentTitle ?? label.text,
                font: label.font,
                color: label.textColor,
                attributed: label.attributedText,
                alignment: label.textAlignment,
                lines: label.numberOfLines,
                dynamicType: label.adjustsFontForContentSizeCategory,
                traits: traits,
                format: format,
                extra: []
            )]
        }
        return []
    }

    // swiftlint:disable:next function_parameter_count
    private static func textSection(
        title: String,
        text: String?,
        font: UIFont?,
        color: UIColor?,
        attributed: NSAttributedString?,
        alignment: NSTextAlignment,
        lines: Int,
        dynamicType: Bool,
        traits: UITraitCollection,
        format: UnitFormatter,
        extra: [InfoRow]
    ) -> InfoSection {
        var rows: [InfoRow] = []
        let content = text ?? ""
        rows.append(InfoRow("Text", content.count > 400 ? String(content.prefix(400)) + "…" : content))
        let attributes = attributed.flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
        let resolvedFont = (attributes[.font] as? UIFont) ?? font
        if let resolvedFont {
            rows.append(InfoRow("Font", resolvedFont.fontName, monospaced: true))
            rows.append(InfoRow("Family", familyName(resolvedFont)))
            rows.append(InfoRow("Point size", format.length(resolvedFont.pointSize), monospaced: true))
            rows.append(InfoRow("Weight", weightName(resolvedFont)))
            rows.append(InfoRow("Line height", lineHeightText(resolvedFont, attributes: attributes, format: format), monospaced: true))
            if let style = resolvedFont.fontDescriptor.object(forKey: .textStyle) as? String {
                rows.append(InfoRow("Text style", textStyleName(style)))
            }
        }
        rows.append(InfoRow("Lines", lines == 0 ? "Unlimited" : "\(lines)"))
        let textColor = (attributes[.foregroundColor] as? UIColor) ?? color
        rows.append(InfoRow("Text color", color: RGBAColor(textColor, traits: traits)))
        rows.append(InfoRow("Alignment", alignmentName(alignment)))
        if let kern = attributes[.kern] as? NSNumber, kern.doubleValue != 0 {
            rows.append(InfoRow("Letter spacing", format.length(CGFloat(kern.doubleValue)), monospaced: true))
        }
        rows.append(InfoRow("Dynamic Type", dynamicType ? "Adjusts" : "Fixed"))
        rows.append(contentsOf: extra)
        return InfoSection(title: title, icon: "textformat.size", rows: rows)
    }

    private static func imageSection(_ view: UIView, _ format: UnitFormatter) -> InfoSection? {
        guard let imageView = view as? UIImageView else { return nil }
        guard let image = imageView.image else {
            return InfoSection(title: "Image", icon: "photo", rows: [InfoRow("Image", "None")])
        }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        var rows = [
            InfoRow("Image size", "\(UnitFormatter.number(image.size.width)) × \(UnitFormatter.number(image.size.height)) pt", monospaced: true),
            InfoRow("Scale", "@\(UnitFormatter.number(image.scale))x", monospaced: true),
            InfoRow("Pixels", "\(Int(pixels.width.rounded())) × \(Int(pixels.height.rounded())) px", monospaced: true),
            InfoRow("Rendering", renderingName(image.renderingMode)),
            InfoRow("Symbol", yesNo(image.isSymbolImage)),
        ]
        if image.images?.isEmpty == false {
            rows.append(InfoRow("Frames", "\(image.images?.count ?? 0) · \(UnitFormatter.decimal(image.duration)) s"))
        }
        if !image.capInsets.isZero {
            rows.append(InfoRow("Cap insets", format.insets(image.capInsets), monospaced: true))
        }
        return InfoSection(title: "Image", icon: "photo", rows: rows)
    }

    private static func stackSection(_ view: UIView, _ format: UnitFormatter) -> InfoSection? {
        guard let stack = view as? UIStackView else { return nil }
        return InfoSection(title: "Stack", icon: "rectangle.split.3x1", rows: [
            InfoRow("Axis", stack.axis == .horizontal ? "Horizontal" : "Vertical"),
            InfoRow("Spacing", format.length(stack.spacing), monospaced: true),
            InfoRow("Alignment", stackAlignmentName(stack.alignment)),
            InfoRow("Distribution", distributionName(stack.distribution)),
            InfoRow("Arranged", "\(stack.arrangedSubviews.count) views"),
            InfoRow("Margins relative", yesNo(stack.isLayoutMarginsRelativeArrangement)),
        ])
    }

    private static func scrollSection(_ view: UIView, _ format: UnitFormatter) -> InfoSection? {
        guard let scroll = view as? UIScrollView else { return nil }
        var rows = [
            InfoRow("Content size", format.size(scroll.contentSize), monospaced: true),
            InfoRow("Content offset", format.point(scroll.contentOffset), monospaced: true),
            InfoRow("Content inset", format.insets(scroll.contentInset), monospaced: true),
            InfoRow("Adjusted inset", format.insets(scroll.adjustedContentInset), monospaced: true),
            InfoRow("Scroll enabled", yesNo(scroll.isScrollEnabled)),
            InfoRow("Paging", yesNo(scroll.isPagingEnabled)),
        ]
        if scroll.minimumZoomScale != scroll.maximumZoomScale || scroll.zoomScale != 1 {
            rows.append(InfoRow("Zoom", "\(UnitFormatter.decimal(Double(scroll.zoomScale))) (\(UnitFormatter.decimal(Double(scroll.minimumZoomScale)))…\(UnitFormatter.decimal(Double(scroll.maximumZoomScale))))", monospaced: true))
        }
        return InfoSection(title: "Scroll", icon: "scroll", rows: rows)
    }

    private static func controlSection(_ view: UIView) -> InfoSection? {
        guard let control = view as? UIControl else { return nil }
        var rows = [
            InfoRow("Enabled", yesNo(control.isEnabled), tone: control.isEnabled ? nil : .warning),
            InfoRow("Selected", yesNo(control.isSelected)),
            InfoRow("Highlighted", yesNo(control.isHighlighted)),
        ]
        switch control {
        case let toggle as UISwitch:
            rows.append(InfoRow("On", yesNo(toggle.isOn)))
        case let slider as UISlider:
            rows.append(InfoRow("Value", "\(UnitFormatter.decimal(Double(slider.value))) (\(UnitFormatter.decimal(Double(slider.minimumValue)))…\(UnitFormatter.decimal(Double(slider.maximumValue))))", monospaced: true))
        case let segmented as UISegmentedControl:
            let index = segmented.selectedSegmentIndex
            let title = index >= 0 ? (segmented.titleForSegment(at: index) ?? "#\(index)") : "None"
            rows.append(InfoRow("Selected segment", "\(title) · \(segmented.numberOfSegments) segments"))
        case let stepper as UIStepper:
            rows.append(InfoRow("Value", UnitFormatter.decimal(stepper.value), monospaced: true))
        default:
            break
        }
        let targets = control.allTargets.count
        rows.append(InfoRow("Targets", "\(targets)"))
        return InfoSection(title: "Control", icon: "hand.tap", rows: rows)
    }

    private static func accessibilitySection(_ view: UIView) -> InfoSection {
        var rows: [InfoRow] = []
        rows.append(InfoRow("Identifier", view.accessibilityIdentifier ?? "", monospaced: true))
        rows.append(InfoRow("Label", view.accessibilityLabel ?? ""))
        if let value = view.accessibilityValue, !value.isEmpty {
            rows.append(InfoRow("Value", value))
        }
        if let hint = view.accessibilityHint, !hint.isEmpty {
            rows.append(InfoRow("Hint", hint))
        }
        let traits = AccessibilityElements.traitNames(view.accessibilityTraits)
        rows.append(InfoRow("Traits", traits.isEmpty ? "None" : traits.joined(separator: ", ")))
        rows.append(InfoRow("Is element", yesNo(view.isAccessibilityElement)))
        rows.append(InfoRow("User interaction", view.isUserInteractionEnabled ? "Enabled" : "Disabled"))
        return InfoSection(title: "Accessibility", icon: "figure.wave", rows: rows)
    }

    // MARK: - SwiftUI elements

    private static func elementInfo(_ node: InspectorNode, host: UIView, context: Context) -> InspectorInfo {
        let format = context.formatter
        let summary = node.summary ?? ElementSummary(traits: [])
        let frame = node.currentScreenFrame
        let windowRect: CGRect? = host.window.map { $0.convert(frame, from: $0.screen.coordinateSpace) }
        let title = summary.label.map { "“\($0)”" } ?? "SwiftUI element"
        var subtitle = ["in " + shortName(of: host)]
        if context.stackCount > 1 {
            subtitle.append("\(context.stackPosition + 1) of \(context.stackCount) here")
        }

        var accessibilityRows = [
            InfoRow("Label", summary.label ?? ""),
            InfoRow("Identifier", summary.identifier ?? "", monospaced: true),
            InfoRow("Traits", summary.traits.isEmpty ? "None" : summary.traits.joined(separator: ", ")),
        ]
        if let value = summary.value { accessibilityRows.insert(InfoRow("Value", value), at: 1) }
        if let hint = summary.hint { accessibilityRows.append(InfoRow("Hint", hint)) }

        var layoutRows: [InfoRow] = []
        if let windowRect {
            layoutRows.append(InfoRow("In window", format.rect(windowRect), monospaced: true))
        }
        layoutRows.append(InfoRow("Size", format.sizeWithUnit(frame.size), monospaced: true))

        let sourceRows = [
            InfoRow("Element", node.elementClassName.map(TypeNaming.stripModules) ?? "—", monospaced: true),
            InfoRow("Host", shortName(of: host), monospaced: true),
        ]

        let sections = [
            InfoSection(title: "Accessibility", icon: "figure.wave", rows: accessibilityRows),
            InfoSection(title: "Layout", icon: "ruler", rows: layoutRows),
            InfoSection(
                title: "Source",
                icon: "swift",
                rows: sourceRows,
                note: "SwiftUI views aren't UIViews. These values come from the accessibility tree, so fonts, colors and padding aren't available."
            ),
        ]

        let parents = ([host] + ViewHierarchy.ancestors(of: host)).map { link(for: $0, format: format) }
        var children: [NodeLink] = []
        if let element = node.element {
            let nested = AccessibilityElements.children(of: element).filter { !($0 is UIView) }
            children = nested.prefix(childLimit).map { child in
                let childNode = InspectorNode(element: child, host: host, screenFrame: child.accessibilityFrame)
                let label = childNode.summary?.label.map { "“\($0)”" } ?? "SwiftUI element"
                return NodeLink(node: childNode, title: label, detail: format.size(child.accessibilityFrame.size), icon: "swift")
            }
        }

        let info = InspectorInfo(
            nodeID: node.id,
            title: title,
            qualifiedName: node.elementClassName ?? "SwiftUI element",
            subtitle: subtitle.joined(separator: " · "),
            icon: "swift",
            tone: .grpc,
            badge: "SwiftUI element (accessibility, partial)",
            sizeText: format.size(frame.size),
            unitSuffix: format.suffix,
            insets: insetTexts(for: node, context: context),
            sections: sections,
            parents: parents,
            children: children,
            hiddenChildren: 0,
            copyText: ""
        )
        return withCopyText(info)
    }

    // MARK: - Helpers

    private static func link(for view: UIView, format: UnitFormatter) -> NodeLink {
        let category = TypeNaming.category(of: view)
        var detail = format.size(view.bounds.size)
        if view.isHidden { detail += " · hidden" }
        return NodeLink(node: InspectorNode(view: view), title: shortName(of: view), detail: detail, icon: category.icon)
    }

    private static func insetTexts(for node: InspectorNode, context: Context) -> (top: String, left: String, bottom: String, right: String)? {
        guard let overlay = context.overlay,
              let rect = node.frame(in: overlay),
              let parent = node.parentFrame(in: overlay) else { return nil }
        let values = Measurement.insetValues(of: rect, in: parent)
        let format = context.formatter
        return (format.value(values.top), format.value(values.left), format.value(values.bottom), format.value(values.right))
    }

    private static func withCopyText(_ info: InspectorInfo) -> InspectorInfo {
        var lines = [info.qualifiedName]
        if let badge = info.badge { lines.append(badge) }
        lines.append("Size: \(info.sizeText) \(info.unitSuffix)")
        if let insets = info.insets {
            lines.append("Padding to parent: top \(insets.top), left \(insets.left), bottom \(insets.bottom), right \(insets.right) \(info.unitSuffix)")
        }
        for section in info.sections {
            lines.append("")
            lines.append("[\(section.title)]")
            for row in section.rows {
                lines.append("\(row.key): \(row.copyValue.isEmpty ? "—" : row.copyValue)")
            }
            if let note = section.note { lines.append(note) }
        }
        if !info.parents.isEmpty {
            lines.append("")
            lines.append("[Parents]")
            lines.append(info.parents.map(\.title).joined(separator: " › "))
        }
        if !info.children.isEmpty {
            lines.append("")
            lines.append("[Children]")
            lines.append(contentsOf: info.children.map { "\($0.title) (\($0.detail))" })
            if info.hiddenChildren > 0 { lines.append("+\(info.hiddenChildren) more") }
        }
        var result = info
        result.copyText = lines.joined(separator: "\n")
        return result
    }

    private static func intrinsicText(_ size: CGSize, _ format: UnitFormatter) -> String {
        let none = UIView.noIntrinsicMetric
        if size.width == none && size.height == none { return "None" }
        let width = size.width == none ? "–" : format.value(size.width)
        let height = size.height == none ? "–" : format.value(size.height)
        return "\(width) × \(height)"
    }

    private static func priority(_ value: UILayoutPriority) -> String {
        UnitFormatter.number(CGFloat(value.rawValue))
    }

    private static func transformText(_ transform: CGAffineTransform) -> String {
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        let scaleX = sqrt(transform.a * transform.a + transform.c * transform.c)
        let scaleY = sqrt(transform.b * transform.b + transform.d * transform.d)
        var parts: [String] = []
        if abs(angle) > 0.01 { parts.append("rotate \(UnitFormatter.number(angle))°") }
        if abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 {
            parts.append("scale \(UnitFormatter.number(scaleX)) × \(UnitFormatter.number(scaleY))")
        }
        if transform.tx != 0 || transform.ty != 0 {
            parts.append("translate \(UnitFormatter.number(transform.tx)), \(UnitFormatter.number(transform.ty))")
        }
        return parts.isEmpty ? "Custom" : parts.joined(separator: " · ")
    }

    private static func cornerCount(_ corners: CACornerMask) -> Int {
        [CACornerMask.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            .filter { corners.contains($0) }
            .count
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func familyName(_ font: UIFont) -> String {
        let family = font.familyName
        if family.hasPrefix(".") {
            return font.fontName.lowercased().contains("rounded") ? "System Rounded (SF)" : "System (SF)"
        }
        return family
    }

    static func weightName(_ font: UIFont) -> String {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        let number = traits?[.weight] as? NSNumber
        guard let raw = number.map({ CGFloat($0.doubleValue) }) else {
            return inferredWeight(from: font.fontName)
        }
        let table: [(CGFloat, String)] = [
            (-0.8, "Ultralight"), (-0.6, "Thin"), (-0.4, "Light"), (0, "Regular"), (0.23, "Medium"),
            (0.3, "Semibold"), (0.4, "Bold"), (0.56, "Heavy"), (0.62, "Black"),
        ]
        let nearest = table.min { abs($0.0 - raw) < abs($1.0 - raw) }?.1 ?? "Regular"
        return "\(nearest) (\(UnitFormatter.number(raw)))"
    }

    private static func inferredWeight(from name: String) -> String {
        let lower = name.lowercased()
        let table = ["ultralight", "thin", "light", "medium", "semibold", "bold", "heavy", "black"]
        if let match = table.last(where: { lower.contains($0) }) {
            return match.prefix(1).uppercased() + match.dropFirst()
        }
        return "Regular"
    }

    private static func lineHeightText(_ font: UIFont, attributes: [NSAttributedString.Key: Any], format: UnitFormatter) -> String {
        var text = format.length(font.lineHeight)
        guard let style = attributes[.paragraphStyle] as? NSParagraphStyle else { return text }
        if style.lineHeightMultiple > 0 { text += " · ×\(UnitFormatter.number(style.lineHeightMultiple))" }
        if style.minimumLineHeight > 0 { text += " · min \(format.value(style.minimumLineHeight))" }
        if style.maximumLineHeight > 0 { text += " · max \(format.value(style.maximumLineHeight))" }
        if style.lineSpacing > 0 { text += " · spacing \(format.value(style.lineSpacing))" }
        return text
    }

    private static func textStyleName(_ raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "UICTFontTextStyle", with: "")
        return trimmed.prefix(1).lowercased() + trimmed.dropFirst()
    }

    private static func alignmentName(_ alignment: NSTextAlignment) -> String {
        switch alignment {
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        case .justified: return "Justified"
        case .natural: return "Natural"
        @unknown default: return "Unknown"
        }
    }

    private static func contentModeName(_ mode: UIView.ContentMode) -> String {
        switch mode {
        case .scaleToFill: return "Scale to fill"
        case .scaleAspectFit: return "Aspect fit"
        case .scaleAspectFill: return "Aspect fill"
        case .redraw: return "Redraw"
        case .center: return "Center"
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        @unknown default: return "Unknown"
        }
    }

    private static func renderingName(_ mode: UIImage.RenderingMode) -> String {
        switch mode {
        case .automatic: return "Automatic"
        case .alwaysOriginal: return "Original"
        case .alwaysTemplate: return "Template"
        @unknown default: return "Unknown"
        }
    }

    private static func stackAlignmentName(_ alignment: UIStackView.Alignment) -> String {
        switch alignment {
        case .fill: return "Fill"
        case .leading: return "Leading / top"
        case .firstBaseline: return "First baseline"
        case .center: return "Center"
        case .trailing: return "Trailing / bottom"
        case .lastBaseline: return "Last baseline"
        @unknown default: return "Unknown"
        }
    }

    private static func distributionName(_ distribution: UIStackView.Distribution) -> String {
        switch distribution {
        case .fill: return "Fill"
        case .fillEqually: return "Fill equally"
        case .fillProportionally: return "Fill proportionally"
        case .equalSpacing: return "Equal spacing"
        case .equalCentering: return "Equal centering"
        @unknown default: return "Unknown"
        }
    }
}

private extension UIEdgeInsets {
    var isZero: Bool { self == .zero }
}
