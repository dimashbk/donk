import DonkUI
import Foundation

struct InfoRow: Equatable, Identifiable {
    var key: String
    var value: String
    var color: RGBAColor?
    var isColor: Bool
    var isMonospaced: Bool
    var tone: DonkTone?

    var id: String { key }

    init(_ key: String, _ value: String, monospaced: Bool = false, tone: DonkTone? = nil) {
        self.key = key
        self.value = value
        self.isMonospaced = monospaced
        self.tone = tone
        color = nil
        isColor = false
    }

    init(_ key: String, color: RGBAColor?) {
        self.key = key
        self.color = color
        isColor = true
        value = color?.hex ?? "None"
        isMonospaced = true
        tone = nil
    }

    var copyValue: String {
        guard let color else { return value }
        return color.hex + (color.isOpaque ? "" : " (\(color.rgbDescription))")
    }
}

struct InfoSection: Equatable, Identifiable {
    var title: String
    var icon: String
    var rows: [InfoRow]
    var note: String?

    var id: String { title }
}

struct NodeLink: Equatable, Identifiable {
    let node: InspectorNode
    var title: String
    var detail: String
    var icon: String

    var id: ObjectIdentifier { node.id }

    static func == (lhs: NodeLink, rhs: NodeLink) -> Bool {
        lhs.node.id == rhs.node.id && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.icon == rhs.icon
    }
}

struct InspectorInfo: Equatable {
    var nodeID: ObjectIdentifier
    var title: String
    var qualifiedName: String
    var subtitle: String
    var icon: String
    var tone: DonkTone
    var badge: String?
    var sizeText: String
    var unitSuffix: String
    var insets: (top: String, left: String, bottom: String, right: String)?
    var sections: [InfoSection]
    var parents: [NodeLink]
    var children: [NodeLink]
    var hiddenChildren: Int
    var copyText: String

    static func == (lhs: InspectorInfo, rhs: InspectorInfo) -> Bool {
        lhs.nodeID == rhs.nodeID
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.icon == rhs.icon
            && lhs.tone == rhs.tone
            && lhs.badge == rhs.badge
            && lhs.sizeText == rhs.sizeText
            && lhs.unitSuffix == rhs.unitSuffix
            && lhs.insets?.top == rhs.insets?.top
            && lhs.insets?.left == rhs.insets?.left
            && lhs.insets?.bottom == rhs.insets?.bottom
            && lhs.insets?.right == rhs.insets?.right
            && lhs.sections == rhs.sections
            && lhs.parents == rhs.parents
            && lhs.children == rhs.children
            && lhs.hiddenChildren == rhs.hiddenChildren
    }
}

struct MeasureSummary: Equatable {
    var targetTitle: String
    var relation: MeasureRelation
    var rows: [InfoRow]
}
