import QuartzCore
import SwiftUI

struct JankListView: View {
    @State private var workPerRow: Double = 2
    @State private var isAnimating = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Main-thread work per row")
                        Spacer()
                        Text(String(format: "%.1f ms", workPerRow))
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $workPerRow, in: 0...8, step: 0.5)
                    Toggle("Animate rows", isOn: $isAnimating)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Every visible row redraws each frame and burns this much main-thread time, so the frame rate drops and hitches appear in the HUD and the dashboard.")
            }
            Section("Rows") {
                ForEach(0..<400, id: \.self) { index in
                    JankRow(index: index, workPerRow: workPerRow, isAnimating: isAnimating)
                }
            }
        }
        .navigationTitle("Jank")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct JankRow: View {
    let index: Int
    let workPerRow: Double
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isAnimating)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let checksum = JankRow.burn(milliseconds: workPerRow, seed: index)
            HStack(spacing: 12) {
                ZStack {
                    ForEach(0..<6, id: \.self) { ring in
                        Circle()
                            .stroke(hue(ring).opacity(0.6), lineWidth: 2)
                            .frame(width: CGFloat(10 + ring * 5), height: CGFloat(10 + ring * 5))
                            .rotationEffect(.degrees(phase * Double(40 + ring * 25)))
                            .shadow(color: hue(ring).opacity(0.5), radius: CGFloat(ring + 2))
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Row \(index + 1)")
                        .font(.subheadline.weight(.semibold))
                    Text("checksum \(checksum % 10_000)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Capsule()
                    .fill(LinearGradient(colors: [hue(0), hue(3)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 40 + 30 * CGFloat(abs(sin(phase * 2 + Double(index)))), height: 8)
                    .blur(radius: 1.5)
            }
            .padding(.vertical, 4)
        }
    }

    private func hue(_ offset: Int) -> Color {
        Color(hue: Double((index * 7 + offset * 23) % 100) / 100, saturation: 0.7, brightness: 0.9)
    }

    @inline(never)
    static func burn(milliseconds: Double, seed: Int) -> Int {
        guard milliseconds > 0 else { return seed }
        let deadline = CACurrentMediaTime() + milliseconds / 1000
        var value = seed &+ 1
        while CACurrentMediaTime() < deadline {
            for step in 0..<200 {
                value = (value &* 31 &+ step) % 1_000_003
            }
        }
        return value
    }
}
