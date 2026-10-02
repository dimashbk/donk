import DonkUI
import SwiftUI

// MARK: - CPU

struct CPUCard: View {
    @ObservedObject var model: DashboardModel
    @State private var showsInfo = false

    var body: some View {
        let sample = model.latest
        let cpu = sample?.cpu ?? 0
        let rule = model.preferences.alerts.cpu
        let tone = sample == nil ? DonkTone.neutral : FrameHealth.cpuTone(cpu, threshold: rule.threshold)
        let cores = CPUSampler.processorCount
        DonkCard(title: "CPU", icon: "cpu", tone: .success) {
            HStack(alignment: .top) {
                MetricHeadline(
                    value: sample.map { "\(Int($0.cpu.rounded()))" } ?? "–",
                    unit: "%",
                    tone: tone,
                    caption: "% of one core · \(cores) cores = \(cores * 100)% max"
                )
                Spacer(minLength: DonkSpacing.s)
                VStack(alignment: .trailing, spacing: DonkSpacing.s) {
                    SecondaryMetric(title: "main thread", value: sample.map { PerformanceText.percent($0.mainThreadCPU) } ?? "–", tone: .accent)
                    SecondaryMetric(title: "threads", value: sample.map { "\($0.threadCount)" } ?? "–", tone: .neutral)
                }
            }
            InfoDisclosure(
                text: "Total CPU is the sum of all non-idle threads, measured with task_threads + thread_info. 100% means one fully busy core, so the value can exceed 100% on a multicore device (Xcode's CPU gauge uses the same convention).",
                isExpanded: $showsInfo
            )
            LazyChart(isReady: model.chartsReady, height: 190) {
                LineChartView(
                    series: [
                        DonkChartSeries("Total", values: model.cpuValues, tone: .success),
                        DonkChartSeries("Main", values: model.mainThreadValues, tone: .accent),
                    ],
                    range: model.cpuRange,
                    threshold: rule.isEnabled ? rule.threshold : nil,
                    unit: "%",
                    window: model.chartWindow.duration,
                    capacity: model.capacity,
                    valueFormatter: { "\(Int($0.rounded()))" }
                )
            }
        } accessory: {
            InfoButton(isExpanded: $showsInfo, label: "About CPU usage")
        }
    }
}

// MARK: - Memory

struct MemoryCard: View {
    @ObservedObject var model: DashboardModel
    @State private var showsLimit = true
    @State private var showsInfo = false

    var body: some View {
        let sample = model.latest
        let limit = sample?.memoryLimit
        let fraction = sample?.memoryUsageFraction
        let tone = memoryTone(fraction)
        DonkCard(title: "Memory", icon: "memorychip", tone: .info) {
            MetricHeadline(
                value: sample.map { value(for: $0.footprint) } ?? "–",
                unit: sample.map { unit(for: $0.footprint) } ?? "MB",
                tone: sample == nil ? .neutral : tone,
                caption: caption(sample)
            )
            if let fraction {
                UsageBar(fraction: fraction, tone: tone)
                    .accessibilityLabel("Memory used \(PerformanceText.percent(fraction * 100)) of limit")
            }
            InfoDisclosure(
                text: "Footprint is task_vm_info.phys_footprint, the number Xcode and Jetsam use. The limit is estimated as footprint + os_proc_available_memory(). The Simulator has no Jetsam limit, so the limit is unavailable there.",
                isExpanded: $showsInfo
            )
            LazyChart(isReady: model.chartsReady, height: 190) {
                LineChartView(
                    values: model.memoryValues,
                    tone: .info,
                    name: "Footprint",
                    threshold: showsLimit ? limit.map { Double($0) / 1_048_576 } : nil,
                    unit: "MB",
                    window: model.chartWindow.duration,
                    capacity: model.capacity,
                    valueFormatter: { megabytesLabel($0) }
                )
            }
        } accessory: {
            HStack(spacing: DonkSpacing.m) {
                if limit != nil {
                    Button(showsLimit ? "Zoom" : "Limit") {
                        withAnimation(.easeInOut(duration: 0.2)) { showsLimit.toggle() }
                        DonkHaptics.selection()
                    }
                    .accessibilityLabel(showsLimit ? "Hide limit line" : "Show limit line")
                }
                InfoButton(isExpanded: $showsInfo, label: "About memory")
            }
        }
    }

    private func memoryTone(_ fraction: Double?) -> DonkTone {
        guard let fraction else { return .info }
        if fraction >= 0.8 { return .error }
        if fraction >= 0.6 { return .warning }
        return .info
    }

    private func value(for bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1024 { return String(format: "%.2f", megabytes / 1024) }
        return String(format: megabytes >= 100 ? "%.0f" : "%.1f", megabytes)
    }

    private func unit(for bytes: UInt64) -> String {
        Double(bytes) / 1_048_576 >= 1024 ? "GB" : "MB"
    }

    private func caption(_ sample: PerformanceSample?) -> String {
        guard let sample else { return "Physical footprint" }
        guard let limit = sample.memoryLimit, let fraction = sample.memoryUsageFraction else {
            return "Physical footprint · limit unavailable (device RAM \(PerformanceText.megabytes(MemorySampler.physicalMemory)))"
        }
        return "Footprint · \(PerformanceText.percent(fraction * 100)) of ~\(PerformanceText.megabytes(limit)) estimated limit"
    }
}

private func megabytesLabel(_ value: Double) -> String {
    if value >= 1024 { return String(format: "%.1fG", value / 1024) }
    if value >= 100 { return "\(Int(value.rounded()))" }
    return String(format: "%.1f", value)
}

// MARK: - Frames

struct FramesCard: View {
    @ObservedObject var model: DashboardModel
    @State private var showsInfo = false

    var body: some View {
        let sample = model.latest
        let fps = sample?.fps
        let tone = FrameHealth.tone(fps: fps, target: sample?.targetFPS ?? 60)
        let hitch = sample?.hitchRatio
        let fpsRule = model.preferences.alerts.lowFPS
        DonkCard(title: "Frames", icon: "speedometer", tone: .accent) {
            HStack(alignment: .top) {
                MetricHeadline(
                    value: fps.map { "\(Int($0.rounded()))" } ?? "–",
                    unit: "FPS",
                    tone: tone,
                    caption: "Target \(sample?.targetFPS ?? 60) Hz · display max \(model.maximumFPS) Hz"
                )
                Spacer(minLength: DonkSpacing.s)
                VStack(alignment: .trailing, spacing: DonkSpacing.s) {
                    SecondaryMetric(
                        title: "hitch ms/s",
                        value: hitch.map { PerformanceText.number($0) } ?? "–",
                        tone: FrameHealth.hitchTone(hitch)
                    )
                    SecondaryMetric(title: "dropped (\(model.chartWindow.rawValue))", value: "\(model.droppedFramesInWindow)", tone: .neutral)
                }
            }
            InfoDisclosure(
                text: "Measured with a CADisplayLink on the main run loop. A frame is late when it arrives after the previous frame's targetTimestamp; the hitch time ratio is late time per second (Apple: under 5 ms/s good, 5–10 warning, 10+ critical). The 120 Hz toggle only changes this display link's preferredFrameRateRange.",
                isExpanded: $showsInfo
            )
            LazyChart(isReady: model.chartsReady, height: 180) {
                LineChartView(
                    series: [
                        DonkChartSeries("FPS", values: model.fpsValues, tone: .accent),
                        DonkChartSeries("Max", values: model.maximumFPSValues, tone: .neutral),
                    ],
                    range: model.fpsRange,
                    threshold: fpsRule.isEnabled ? fpsRule.threshold : nil,
                    unit: "fps",
                    window: model.chartWindow.duration,
                    capacity: model.capacity,
                    valueFormatter: { "\(Int($0.rounded()))" }
                )
            }
            HStack {
                Text("Hitch time ratio")
                    .font(DonkFont.label)
                    .foregroundColor(DonkColor.textSecondary)
                Spacer()
                HStack(spacing: DonkSpacing.xs) {
                    TonePill("<5", tone: .success)
                    TonePill("5–10", tone: .warning)
                    TonePill("10+", tone: .error)
                }
            }
            LazyChart(isReady: model.chartsReady, height: 150) {
                LineChartView(
                    values: model.hitchValues,
                    tone: .warning,
                    name: "Hitches",
                    range: model.hitchRange,
                    threshold: 10,
                    unit: "ms/s",
                    window: model.chartWindow.duration,
                    capacity: model.capacity,
                    valueFormatter: { PerformanceText.number($0, digits: $0 >= 100 ? 0 : 1) }
                )
            }
        } accessory: {
            InfoButton(isExpanded: $showsInfo, label: "About frame metrics")
        }
    }
}

// MARK: - GPU

struct GPUCard: View {
    @ObservedObject var model: DashboardModel
    @State private var showsInfo = false

    var body: some View {
        let values = model.gpuValues
        let available = model.snapshot.gpuAvailability == .available && !values.isEmpty
        DonkCard(title: "GPU", icon: "cube.transparent", tone: .grpc) {
            if available, let last = values.last {
                MetricHeadline(
                    value: PerformanceText.number(last),
                    unit: "ms/s",
                    tone: .grpc,
                    caption: "GPU time per second · ≈\(PerformanceText.number(last / 10))% of wall time"
                )
            } else {
                MetricHeadline(
                    value: "N/A",
                    unit: nil,
                    tone: .neutral,
                    caption: model.snapshot.gpuAvailability == .unknown ? "Waiting for GPU counters…" : "No GPU time reported for this process"
                )
            }
            InfoDisclosure(
                text: "iOS has no public GPU utilization API. This experimental metric reads the task's cumulative GPU time from task_info(TASK_POWER_INFO_V2) and shows milliseconds of GPU time per second. It is often zero or unavailable, and always on the Simulator.",
                isExpanded: $showsInfo
            )
            if available {
                LazyChart(isReady: model.chartsReady, height: 160) {
                    LineChartView(
                        values: values,
                        tone: .grpc,
                        name: "GPU",
                        unit: "ms/s",
                        window: model.chartWindow.duration,
                        capacity: model.capacity,
                        valueFormatter: { PerformanceText.number($0) }
                    )
                }
            }
        } accessory: {
            HStack(spacing: DonkSpacing.s) {
                TonePill("Experimental", tone: .grpc)
                InfoButton(isExpanded: $showsInfo, label: "About GPU time")
            }
        }
    }
}
