import Combine
import DonkUI
import SwiftUI

@MainActor
final class SparklineModel: ObservableObject {
    @Published private(set) var cpu: [Double] = []
    @Published private(set) var latest: PerformanceSample?
    @Published private(set) var isRunning = false

    let capacity = 60
    private var cancellable: AnyCancellable?

    init(monitor: PerformanceMonitor = .shared) {
        let snapshot = monitor.snapshot()
        cpu = snapshot.samples.suffix(capacity).map(\.cpu)
        latest = snapshot.samples.last
        isRunning = snapshot.isRunning
        cancellable = monitor.updates
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak monitor] update in
                guard let self else { return }
                switch update {
                case let .sample(sample):
                    self.latest = sample
                    self.cpu.append(sample.cpu)
                    if self.cpu.count > self.capacity {
                        self.cpu.removeFirst(self.cpu.count - self.capacity)
                    }
                case .reset:
                    self.cpu = []
                    self.latest = nil
                case .state:
                    self.isRunning = monitor?.isRunning ?? false
                case .events:
                    break
                }
            }
    }
}

struct PerformanceSparklineView: View {
    @StateObject private var model = SparklineModel()

    var body: some View {
        let sample = model.latest
        let fpsTone = FrameHealth.tone(fps: sample?.fps, target: sample?.targetFPS ?? 60)
        let cpuTone: DonkTone = sample.map { FrameHealth.cpuTone($0.cpu) } ?? .neutral
        HStack(spacing: 8) {
            SparklineView(
                values: model.cpu,
                range: 0...max(20, (model.cpu.max() ?? 0) * 1.25),
                tone: cpuTone == .neutral ? .success : cpuTone,
                capacity: model.capacity,
                lineWidth: 1.4
            )
            .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 0) {
                Text(sample.map { PerformanceText.percent($0.cpu) } ?? "–")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundColor(cpuTone == .neutral ? DonkColor.textSecondary : cpuTone.color)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(sample?.fps.map { "\(Int($0.rounded()))" } ?? "–")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundColor(fpsTone == .neutral ? DonkColor.textSecondary : fpsTone.color)
                    Text("fps")
                        .font(.caption2)
                        .foregroundColor(DonkColor.textSecondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .frame(minHeight: 14)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .opacity(model.isRunning || sample != nil ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Performance")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let sample = model.latest else { return "No data" }
        var parts = ["CPU \(PerformanceText.percent(sample.cpu))"]
        if let fps = sample.fps {
            parts.append("\(Int(fps.rounded())) frames per second")
        }
        return parts.joined(separator: ", ")
    }
}
