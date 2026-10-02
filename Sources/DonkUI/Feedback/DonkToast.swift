import SwiftUI
import UIKit

// MARK: - Public API

public enum DonkToast {
    public static func show(_ message: String, icon: String? = nil, tone: DonkTone = .neutral, duration: TimeInterval = 2) {
        DonkMain.run {
            DonkToastCenter.shared.show(message, icon: icon, tone: tone, duration: duration)
        }
    }

    public static func dismissAll() {
        DonkMain.run {
            DonkToastCenter.shared.dismissAll()
        }
    }
}

// MARK: - Model

struct DonkToastItem: Identifiable, Equatable {
    let id: UUID
    var message: String
    var icon: String?
    var tone: DonkTone
    var pulse: Int
}

@MainActor
final class DonkToastCenter: ObservableObject {
    static let shared = DonkToastCenter()

    @Published private(set) var items: [DonkToastItem] = []

    private var window: DonkHostingPassthroughWindow<DonkToastStack>?
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var hideTask: Task<Void, Never>?
    private let maxVisible = 3
    private let animation = Animation.spring(response: 0.42, dampingFraction: 0.82)

    func show(_ message: String, icon: String?, tone: DonkTone, duration: TimeInterval) {
        guard let scene = DonkWindowManager.activeWindowScene else { return }
        attachWindow(to: scene)
        let resolvedIcon = icon ?? (tone == .neutral ? nil : tone.defaultIcon)
        withAnimation(animation) {
            if let index = items.firstIndex(where: { $0.message == message && $0.tone == tone }) {
                items[index].pulse += 1
                items[index].icon = resolvedIcon
                schedule(items[index].id, after: duration)
            } else {
                let item = DonkToastItem(id: UUID(), message: message, icon: resolvedIcon, tone: tone, pulse: 0)
                items.insert(item, at: 0)
                while items.count > maxVisible {
                    let removed = items.removeLast()
                    timers.removeValue(forKey: removed.id)?.cancel()
                }
                schedule(item.id, after: duration)
            }
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func dismiss(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        withAnimation(animation) {
            items.removeAll { $0.id == id }
        }
        scheduleHideIfIdle()
    }

    func dismissAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        withAnimation(animation) {
            items.removeAll()
        }
        scheduleHideIfIdle()
    }

    private func schedule(_ id: UUID, after duration: TimeInterval) {
        timers[id]?.cancel()
        let nanoseconds = UInt64(max(0.5, duration) * 1_000_000_000)
        timers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    private func attachWindow(to scene: UIWindowScene) {
        hideTask?.cancel()
        hideTask = nil
        if let window {
            if window.windowScene !== scene {
                window.windowScene = scene
            }
            window.isHidden = false
            return
        }
        let window = DonkHostingPassthroughWindow(
            windowScene: scene,
            level: DonkWindowLevel.toast,
            rootView: DonkToastStack(center: self)
        )
        window.isHidden = false
        self.window = window
    }

    private func scheduleHideIfIdle() {
        guard items.isEmpty else { return }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.items.isEmpty else { return }
            self.window?.isHidden = true
        }
    }
}

// MARK: - Views

struct DonkToastStack: View {
    @ObservedObject var center: DonkToastCenter

    var body: some View {
        VStack(spacing: DonkSpacing.s) {
            ForEach(center.items) { item in
                DonkToastCapsule(item: item) {
                    center.dismiss(item.id)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    )
                )
            }
        }
        .padding(.top, DonkSpacing.xs)
        .padding(.horizontal, DonkSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard)
    }
}

struct DonkToastCapsule: View {
    let item: DonkToastItem
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var bounce = false

    var body: some View {
        HStack(spacing: DonkSpacing.s) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(item.tone.color)
            }
            Text(item.message)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DonkColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DonkSpacing.l)
        .padding(.vertical, 11)
        .donkGlassBackground(Capsule())
        .donkFloatingShadow()
        .scaleEffect(bounce ? 1.06 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.55), value: bounce)
        .offset(y: min(0, dragOffset))
        .contentShape(Capsule())
        .onTapGesture(perform: onDismiss)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { dragOffset = $0.translation.height }
                .onEnded { value in
                    if value.translation.height < -16 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { dragOffset = 0 }
                    }
                }
        )
        .donkInteractive()
        .task(id: item.pulse) {
            guard item.pulse > 0 else { return }
            bounce = true
            try? await Task.sleep(nanoseconds: 140_000_000)
            bounce = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to dismiss")
    }
}
