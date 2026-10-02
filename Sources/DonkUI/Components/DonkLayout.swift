import SwiftUI

// MARK: - Layout mode

public enum DonkLayoutMode: Hashable, Sendable {
    case scrolling
    case embedded
}

// MARK: - Navigation

public struct DonkNavigationContainer<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 16, *) {
            NavigationStack {
                content
            }
        } else {
            NavigationView {
                content
            }
            .navigationViewStyle(.stack)
        }
    }
}

public extension View {
    func donkNavigationTitle(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    func donkTheme() -> some View {
        tint(DonkColor.accent)
    }

    func donkScreenBackground() -> some View {
        background(DonkColor.background.ignoresSafeArea())
    }

    @ViewBuilder
    func donkListStyle() -> some View {
        if #available(iOS 16, *) {
            listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(DonkColor.background.ignoresSafeArea())
        } else {
            listStyle(.insetGrouped)
        }
    }

    func donkCardBackground(radius: CGFloat = DonkRadius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(DonkColor.card)
        )
    }
}

// MARK: - Scroll container

public struct DonkScrollContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = DonkSpacing.l, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(DonkSpacing.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .donkScreenBackground()
    }
}

// MARK: - Button style

public struct DonkPressableStyle: ButtonStyle {
    private let scale: CGFloat

    public init(scale: CGFloat = 0.97) {
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == DonkPressableStyle {
    static var donkPressable: DonkPressableStyle { DonkPressableStyle() }
}
