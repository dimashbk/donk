import Combine
import DonkCore
import Foundation
import SwiftUI

// MARK: - Enums

enum FramesPalette: String, Codable, CaseIterable, Sendable {
    case depth, category

    var title: String {
        switch self {
        case .depth: return "Depth"
        case .category: return "Category"
        }
    }
}

enum MeasureUnit: String, Codable, CaseIterable, Sendable {
    case points, pixels

    var suffix: String {
        switch self {
        case .points: return "pt"
        case .pixels: return "px"
        }
    }
}

enum ToolbarEdge: String, Codable, Sendable {
    case top, bottom
}

// MARK: - Grid

struct GridColumns: Codable, Equatable, Sendable {
    var isEnabled = false
    var count = 4
    var margin: Double = 16
    var gutter: Double = 16
    var isFilled = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GridColumns()
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? fallback.isEnabled
        count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? fallback.count
        margin = (try? container.decodeIfPresent(Double.self, forKey: .margin)) ?? fallback.margin
        gutter = (try? container.decodeIfPresent(Double.self, forKey: .gutter)) ?? fallback.gutter
        isFilled = (try? container.decodeIfPresent(Bool.self, forKey: .isFilled)) ?? fallback.isFilled
    }
}

struct GridSettings: Codable, Equatable, Sendable {
    static let cellRange: ClosedRange<Double> = 1...200
    static let offsetRange: ClosedRange<Double> = -200...200
    static let palette = ["#F43F5E", "#6D5DFC", "#0EA5E9", "#22C55E", "#F59E0B", "#EC4899", "#14B8A6", "#64748B"]

    var cellWidth: Double = 8
    var cellHeight: Double = 8
    var isLinked = true
    var colorHex = "#F43F5E"
    var opacity: Double = 0.35
    var lineWidth: Double = 0.5
    var offsetX: Double = 0
    var offsetY: Double = 0
    var showsVerticalLines = true
    var showsHorizontalLines = true
    var columns = GridColumns()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GridSettings()
        cellWidth = (try? container.decodeIfPresent(Double.self, forKey: .cellWidth)) ?? fallback.cellWidth
        cellHeight = (try? container.decodeIfPresent(Double.self, forKey: .cellHeight)) ?? fallback.cellHeight
        isLinked = (try? container.decodeIfPresent(Bool.self, forKey: .isLinked)) ?? fallback.isLinked
        colorHex = (try? container.decodeIfPresent(String.self, forKey: .colorHex)) ?? fallback.colorHex
        opacity = (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? fallback.opacity
        lineWidth = (try? container.decodeIfPresent(Double.self, forKey: .lineWidth)) ?? fallback.lineWidth
        offsetX = (try? container.decodeIfPresent(Double.self, forKey: .offsetX)) ?? fallback.offsetX
        offsetY = (try? container.decodeIfPresent(Double.self, forKey: .offsetY)) ?? fallback.offsetY
        showsVerticalLines = (try? container.decodeIfPresent(Bool.self, forKey: .showsVerticalLines)) ?? fallback.showsVerticalLines
        showsHorizontalLines = (try? container.decodeIfPresent(Bool.self, forKey: .showsHorizontalLines)) ?? fallback.showsHorizontalLines
        columns = (try? container.decodeIfPresent(GridColumns.self, forKey: .columns)) ?? fallback.columns
        sanitize()
    }

    var color: RGBAColor {
        RGBAColor(hex: colorHex) ?? RGBAColor(red: 0.96, green: 0.25, blue: 0.37)
    }

    var showsLines: Bool {
        showsVerticalLines || showsHorizontalLines
    }

    mutating func sanitize() {
        cellWidth = Self.clampCell(cellWidth)
        cellHeight = Self.clampCell(cellHeight)
        opacity = min(max(opacity, 0.05), 1)
        lineWidth = min(max(lineWidth, 0.25), 4)
        offsetX = min(max(offsetX, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        offsetY = min(max(offsetY, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
        columns.count = min(max(columns.count, 1), 24)
        columns.margin = min(max(columns.margin, 0), 200)
        columns.gutter = min(max(columns.gutter, 0), 200)
    }

    static func clampCell(_ value: Double) -> Double {
        guard value.isFinite else { return 8 }
        return min(max(value, cellRange.lowerBound), cellRange.upperBound)
    }
}

// MARK: - Presets

struct GridPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let apply: (inout GridSettings) -> Void

    static func == (lhs: GridPreset, rhs: GridPreset) -> Bool { lhs.id == rhs.id }

    static let all: [GridPreset] = [
        GridPreset(id: "4pt", title: "4 pt", icon: "squareshape.split.3x3") { grid in
            grid.cellWidth = 4
            grid.cellHeight = 4
            grid.isLinked = true
            grid.showsVerticalLines = true
            grid.showsHorizontalLines = true
            grid.columns.isEnabled = false
        },
        GridPreset(id: "8pt", title: "8 pt", icon: "squareshape.split.2x2") { grid in
            grid.cellWidth = 8
            grid.cellHeight = 8
            grid.isLinked = true
            grid.showsVerticalLines = true
            grid.showsHorizontalLines = true
            grid.columns.isEnabled = false
        },
        GridPreset(id: "baseline16", title: "16 pt baseline", icon: "text.alignleft") { grid in
            grid.cellWidth = 16
            grid.cellHeight = 16
            grid.isLinked = true
            grid.showsVerticalLines = false
            grid.showsHorizontalLines = true
            grid.columns.isEnabled = false
        },
        GridPreset(id: "columns4", title: "4 columns", icon: "rectangle.split.3x1") { grid in
            grid.showsVerticalLines = false
            grid.showsHorizontalLines = false
            grid.columns.isEnabled = true
            grid.columns.count = 4
            grid.columns.margin = 16
            grid.columns.gutter = 16
            grid.columns.isFilled = true
        },
        GridPreset(id: "columns12", title: "12 columns", icon: "rectangle.split.3x1") { grid in
            grid.showsVerticalLines = false
            grid.showsHorizontalLines = false
            grid.columns.isEnabled = true
            grid.columns.count = 12
            grid.columns.margin = 16
            grid.columns.gutter = 8
            grid.columns.isFilled = true
        },
    ]

    func matches(_ grid: GridSettings) -> Bool {
        var copy = grid
        apply(&copy)
        return copy == grid
    }
}

// MARK: - Settings

struct InspectorSettings: Codable, Equatable, Sendable {
    static let recentColorLimit = 12

    var grid = GridSettings()
    var framesPalette = FramesPalette.depth
    var showsFrameSizes = false
    var unit = MeasureUnit.points
    var showsModulePrefix = false
    var opensPanelExpanded = false
    var includesSwiftUIElements = false
    var outlinesWhileSelecting = false
    var toolbarEdge = ToolbarEdge.top
    var recentColors: [String] = []

    enum CodingKeys: String, CodingKey {
        case grid, framesPalette, showsFrameSizes, unit, showsModulePrefix, opensPanelExpanded
        case includesSwiftUIElements = "includesSwiftUIElementsOptIn"
        case outlinesWhileSelecting, toolbarEdge, recentColors
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = InspectorSettings()
        grid = (try? container.decodeIfPresent(GridSettings.self, forKey: .grid)) ?? fallback.grid
        framesPalette = (try? container.decodeIfPresent(FramesPalette.self, forKey: .framesPalette)) ?? fallback.framesPalette
        showsFrameSizes = (try? container.decodeIfPresent(Bool.self, forKey: .showsFrameSizes)) ?? fallback.showsFrameSizes
        unit = (try? container.decodeIfPresent(MeasureUnit.self, forKey: .unit)) ?? fallback.unit
        showsModulePrefix = (try? container.decodeIfPresent(Bool.self, forKey: .showsModulePrefix)) ?? fallback.showsModulePrefix
        opensPanelExpanded = (try? container.decodeIfPresent(Bool.self, forKey: .opensPanelExpanded)) ?? fallback.opensPanelExpanded
        includesSwiftUIElements = (try? container.decodeIfPresent(Bool.self, forKey: .includesSwiftUIElements))
            ?? fallback.includesSwiftUIElements
        outlinesWhileSelecting = (try? container.decodeIfPresent(Bool.self, forKey: .outlinesWhileSelecting))
            ?? fallback.outlinesWhileSelecting
        toolbarEdge = (try? container.decodeIfPresent(ToolbarEdge.self, forKey: .toolbarEdge)) ?? fallback.toolbarEdge
        let colors = (try? container.decodeIfPresent([String].self, forKey: .recentColors)) ?? []
        recentColors = Array(colors.filter { RGBAColor(hex: $0) != nil }.prefix(Self.recentColorLimit))
    }
}

// MARK: - Store

@MainActor
final class InspectorSettingsStore: ObservableObject {
    static let shared = InspectorSettingsStore()

    private static let fileName = "inspector-settings.json"
    private static let saveQueue = DispatchQueue(label: "donk.inspector.settings", qos: .utility)

    @Published var settings: InspectorSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
        }
    }

    private var pendingSave: DispatchWorkItem?

    init() {
        settings = DonkPersistence.load(InspectorSettings.self, from: Self.fileName) ?? InspectorSettings()
    }

    func binding<Value>(_ keyPath: WritableKeyPath<InspectorSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 }
        )
    }

    func updateGrid(_ transform: (inout GridSettings) -> Void) {
        var grid = settings.grid
        transform(&grid)
        grid.sanitize()
        settings.grid = grid
    }

    func setCellWidth(_ value: Double) {
        updateGrid { grid in
            grid.cellWidth = GridSettings.clampCell(value)
            if grid.isLinked { grid.cellHeight = grid.cellWidth }
        }
    }

    func setCellHeight(_ value: Double) {
        updateGrid { grid in
            grid.cellHeight = GridSettings.clampCell(value)
            if grid.isLinked { grid.cellWidth = grid.cellHeight }
        }
    }

    func apply(_ preset: GridPreset) {
        updateGrid(preset.apply)
    }

    func resetGrid() {
        settings.grid = GridSettings()
    }

    func addRecentColor(_ hex: String) {
        var colors = settings.recentColors.filter { $0.caseInsensitiveCompare(hex) != .orderedSame }
        colors.insert(hex, at: 0)
        settings.recentColors = Array(colors.prefix(InspectorSettings.recentColorLimit))
    }

    func removeRecentColor(_ hex: String) {
        settings.recentColors.removeAll { $0.caseInsensitiveCompare(hex) == .orderedSame }
    }

    func clearRecentColors() {
        settings.recentColors = []
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = settings
        let name = Self.fileName
        let queue = Self.saveQueue
        let work = DispatchWorkItem {
            queue.async {
                DonkPersistence.save(snapshot, to: name)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
