import Combine
import DonkCore
import DonkInspector
import DonkNetworkUI
import DonkUI
import SwiftUI
import UIKit

// MARK: - Queue logic

struct BreakpointQueue: Equatable {
    private(set) var pending: [PausedExchange.ID] = []
    private(set) var presented: PausedExchange.ID?
    private(set) var dismissedByUser: Set<PausedExchange.ID> = []

    struct Update: Equatable {
        var fresh: [PausedExchange.ID] = []
        var presentedResolved = false
    }

    mutating func sync(_ ids: [PausedExchange.ID]) -> Update {
        let known = Set(pending)
        let current = Set(ids)
        var update = Update()
        update.fresh = ids.filter { !known.contains($0) }
        if let presented, !current.contains(presented) {
            update.presentedResolved = true
        }
        pending = ids
        dismissedByUser.formIntersection(current)
        return update
    }

    var next: PausedExchange.ID? {
        pending.first { !dismissedByUser.contains($0) }
    }

    mutating func markPresented(_ id: PausedExchange.ID?) {
        presented = id
    }

    mutating func markDismissedByUser(_ id: PausedExchange.ID) {
        dismissedByUser.insert(id)
        if presented == id {
            presented = nil
        }
    }

    mutating func allowAgain(_ id: PausedExchange.ID) {
        dismissedByUser.remove(id)
    }

    mutating func reset() {
        self = BreakpointQueue()
    }
}

// MARK: - Coordinator

@MainActor
final class BreakpointCoordinator: NSObject, UIAdaptivePresentationControllerDelegate {
    private var queue = BreakpointQueue()
    private var exchanges: [UUID: PausedExchange] = [:]
    private var subscription: AnyCancellable?
    private weak var sheet: UIViewController?
    private var isTransitioning = false

    func start() {
        guard subscription == nil else { return }
        BreakpointCenter.shared.hasPresenter = true
        subscription = BreakpointCenter.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exchanges in
                MainActor.assumeIsolated { self?.update(exchanges) }
            }
    }

    func stop() {
        subscription = nil
        BreakpointCenter.shared.hasPresenter = false
        dismissSheet(animated: false, completion: nil)
        queue.reset()
        exchanges.removeAll()
    }

    func presentFirstPending() {
        guard let first = queue.pending.first else { return }
        queue.allowAgain(first)
        if let presented = queue.presented, presented == first, sheet != nil { return }
        present(first, openingDebugger: true)
    }

    // MARK: - Changes

    private func update(_ list: [PausedExchange]) {
        exchanges = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let update = queue.sync(list.map(\.id))
        if update.presentedResolved {
            queue.markPresented(nil)
            let opensDebugger = !update.fresh.isEmpty && DonkInspector.activeMode == nil
            dismissSheet(animated: true) { [weak self] in
                self?.presentNextIfNeeded(openingDebugger: opensDebugger)
            }
            return
        }
        guard !update.fresh.isEmpty else { return }
        if DonkInspector.activeMode != nil {
            let names = update.fresh.compactMap { exchanges[$0]?.ruleName }
            let title = names.first.map { "Breakpoint hit · \($0)" } ?? "Breakpoint hit"
            DonkToast.show(title, icon: "pause.circle.fill", tone: .warning, duration: 3)
            DonkHaptics.warning()
            return
        }
        presentNextIfNeeded(openingDebugger: true)
    }

    private func presentNextIfNeeded(openingDebugger: Bool) {
        guard queue.presented == nil, sheet == nil, !isTransitioning, let next = queue.next else { return }
        if !openingDebugger, !DonkRuntime.shared.debugger.isVisible { return }
        present(next, openingDebugger: openingDebugger)
    }

    private func present(_ id: UUID, openingDebugger: Bool) {
        guard let exchange = exchanges[id] else { return }
        isTransitioning = true
        DonkHaptics.warning()
        let presentSheet = { [weak self] in
            guard let self else { return }
            self.dismissSheet(animated: false, completion: nil)
            guard self.queue.pending.contains(id),
                  let presenter = DonkRuntime.shared.debugger.presentingController else {
                self.isTransitioning = false
                return
            }
            let controller = UIHostingController(rootView: BreakpointSheet(exchange: exchange))
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
            controller.presentationController?.delegate = self
            DonkWindowManager.markDonkPresentation(controller)
            self.sheet = controller
            self.queue.markPresented(id)
            presenter.present(controller, animated: true) { [weak self] in
                self?.isTransitioning = false
                guard let self, !self.queue.pending.contains(id) else { return }
                self.queue.markPresented(nil)
                self.dismissSheet(animated: true) { [weak self] in
                    self?.presentNextIfNeeded(openingDebugger: false)
                }
            }
        }
        if DonkRuntime.shared.debugger.isVisible {
            presentSheet()
        } else if openingDebugger {
            DonkRuntime.shared.show(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated { presentSheet() }
            }
        } else {
            isTransitioning = false
        }
    }

    private func dismissSheet(animated: Bool, completion: (() -> Void)?) {
        guard let sheet else {
            completion?()
            return
        }
        self.sheet = nil
        guard sheet.presentingViewController != nil else {
            completion?()
            return
        }
        sheet.dismiss(animated: animated && sheet.view.window != nil) {
            completion?()
        }
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let presented = queue.presented else { return }
        queue.markDismissedByUser(presented)
        sheet = nil
    }
}

// MARK: - Sheet

struct BreakpointSheet: View {
    let exchange: PausedExchange

    var body: some View {
        DonkNavigationContainer {
            DonkNetworkUI.makeBreakpointView(exchange)
        }
        .donkTheme()
    }
}
