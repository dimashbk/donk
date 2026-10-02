import SwiftUI

// MARK: - Floating surfaces

public extension View {
    @ViewBuilder
    func donkGlassBackground<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.donkMaterialBackground(shape, tint: tint)
        }
        #else
        self.donkMaterialBackground(shape, tint: tint)
        #endif
    }

    func donkFloatingShadow(isVisible: Bool = true) -> some View {
        shadow(color: Color.black.opacity(isVisible ? 0.14 : 0), radius: 14, x: 0, y: 6)
    }

    private func donkMaterialBackground<S: Shape>(_ shape: S, tint: Color?) -> some View {
        background(
            ZStack {
                shape.fill(.ultraThinMaterial)
                if let tint {
                    shape.fill(tint.opacity(0.12))
                }
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        )
    }
}
