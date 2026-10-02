import Donk
import SwiftUI

enum InspectorPlaygroundTab: String, CaseIterable {
    case uikit = "UIKit"
    case swiftUI = "SwiftUI"
}

struct InspectorPlaygroundScreen: View {
    @State private var tab: InspectorPlaygroundTab

    init(initialTab: InspectorPlaygroundTab = .uikit) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    modeButton("Select", icon: "cursorarrow.rays", mode: .select)
                    modeButton("Frames", icon: "square.dashed", mode: .frames)
                    modeButton("Grid", icon: "squareshape.split.3x3", mode: .grid)
                    modeButton("Eyedropper", icon: "eyedropper.halffull", mode: .colorPicker)
                    Button {
                        InspectorDemoSupport.showDebugger()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        DonkInspector.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Picker("Playground", selection: $tab) {
                ForEach(InspectorPlaygroundTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            switch tab {
            case .uikit:
                InspectorUIKitPlayground()
                    .ignoresSafeArea(edges: .bottom)
            case .swiftUI:
                InspectorSwiftUIPlayground()
            }
        }
        .navigationTitle("Inspector")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeButton(_ title: String, icon: String, mode: InspectorMode) -> some View {
        Button {
            DonkInspector.start(mode)
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("demo.start.\(mode.rawValue)")
    }
}

struct InspectorSwiftUIPlayground: View {
    @State private var isOn = true
    @State private var amount = 0.4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("SwiftUI section")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("swiftui.title")
                Text("SwiftUI views aren't UIViews, so the inspector offers their accessibility elements instead. Tap the text, the button or a tile.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    tile("#6D5DFC", label: "Purple tile", red: 0x6D, green: 0x5D, blue: 0xFC)
                    tile("#22C55E", label: "Green tile", red: 0x22, green: 0xC5, blue: 0x5E)
                    tile("#F59E0B", label: "Amber tile", red: 0xF5, green: 0x9E, blue: 0x0B)
                }
                Button {
                    isOn.toggle()
                } label: {
                    Label("SwiftUI button", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("swiftui.button")
                Toggle("Notifications", isOn: $isOn)
                    .accessibilityIdentifier("swiftui.toggle")
                Slider(value: $amount)
                    .accessibilityLabel("Amount")
                HStack(spacing: 16) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.orange)
                        .accessibilityLabel("Palette icon")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Card title")
                            .font(.headline)
                        Text("Secondary caption")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            }
            .padding(16)
        }
    }

    private func tile(_ hex: String, label: String, red: Double, green: Double, blue: Double) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: 1))
            .frame(height: 64)
            .overlay(Text(hex).font(.caption.monospaced().weight(.semibold)).foregroundColor(.white))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("swiftui.tile.\(hex)")
    }
}
