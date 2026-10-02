import UIKit

struct UnitFormatter: Equatable {
    var unit: MeasureUnit
    var scale: CGFloat

    var suffix: String { unit.suffix }

    func converted(_ value: CGFloat) -> CGFloat {
        unit == .pixels ? value * scale : value
    }

    func value(_ value: CGFloat) -> String {
        Self.number(converted(value))
    }

    func length(_ value: CGFloat) -> String {
        "\(self.value(value)) \(suffix)"
    }

    func size(_ size: CGSize) -> String {
        "\(value(size.width)) × \(value(size.height))"
    }

    func sizeWithUnit(_ size: CGSize) -> String {
        "\(self.size(size)) \(suffix)"
    }

    func point(_ point: CGPoint) -> String {
        "x \(value(point.x)), y \(value(point.y))"
    }

    func rect(_ rect: CGRect) -> String {
        "x \(value(rect.minX)), y \(value(rect.minY)), \(size(rect.size))"
    }

    func insets(_ insets: UIEdgeInsets) -> String {
        if insets == .zero { return "0" }
        return "T \(value(insets.top)) · L \(value(insets.left)) · B \(value(insets.bottom)) · R \(value(insets.right))"
    }

    func label(_ value: CGFloat) -> String {
        unit == .pixels ? "\(self.value(value))px" : self.value(value)
    }

    static func number(_ value: CGFloat) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (Double(value) * 100).rounded() / 100
        if rounded == 0 { return "0" }
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func decimal(_ value: Double, digits: Int = 2) -> String {
        number(CGFloat((value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))))
    }
}
