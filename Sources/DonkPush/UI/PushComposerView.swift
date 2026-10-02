import DonkCore
import DonkUI
import SwiftUI
import UserNotifications

struct PushComposerView: View {
    @ObservedObject var model: PushComposerModel
    @ObservedObject var device: PushDeviceModel
    @ObservedObject var templates: PushTemplatesModel
    @State private var isSavingTemplate = false
    @State private var isConfirmingPermission = false

    var body: some View {
        DonkScrollContainer {
            previewCard
            payloadCard
            deliveryCard
            PushDeviceCard(device: device) { isConfirmingPermission = true }
        }
        .confirmationDialog("Show the system permission prompt?", isPresented: $isConfirmingPermission, titleVisibility: .visible) {
            Button("Show System Prompt") {
                Task { await device.requestAuthorization() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iOS shows this prompt only once per install. If you answer it here, your app's own onboarding won't be able to ask until the app is deleted and reinstalled.")
        }
        .sheet(isPresented: $isSavingTemplate) {
            PushNameSheet(title: "Save Template", initialName: model.templateName.map { "\($0) copy" } ?? "") { name in
                templates.save(name: name, payload: model.text)
                DonkToast.show("Template saved", tone: .success)
            }
        }
        .task {
            await device.refresh()
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        DonkCard(title: "Preview", icon: "rectangle.and.text.magnifyingglass") {
            PushBannerPreview(
                mapped: model.mapped,
                imageURL: model.imageURL,
                showsAttachment: model.showsAttachmentPreview,
                isValid: model.payload != nil
            )
            PushContentChips(mapped: model.mapped)
        } accessory: {
            if let name = model.templateName {
                Text(name)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Payload

    private var payloadCard: some View {
        DonkCard(title: "Payload", icon: "curlybraces") {
            CodeEditor(text: $model.text, language: .json, layout: .embedded, placeholder: "APNs payload JSON")
            if let error = model.parseError {
                PushStepRow(step: PushStep(.failure, error))
            }
            ForEach(model.warnings(categories: device.categories, categoriesLoaded: device.isLoaded)) { step in
                PushStepRow(step: step)
            }
            if let payload = model.payload {
                HStack(spacing: DonkSpacing.s) {
                    TonePill(
                        text: DonkFormat.bytes(payload.byteCount),
                        tone: payload.byteCount > PushPayload.apnsSizeLimit ? .error : .neutral,
                        icon: "scalemass"
                    )
                    TonePill(text: "\(payload.dictionary.count) top-level keys", tone: .neutral)
                    Spacer(minLength: 0)
                }
            }
        } accessory: {
            Menu {
                templateMenu
                Divider()
                Button {
                    isSavingTemplate = true
                } label: {
                    Label("Save as Template", systemImage: "square.and.arrow.down")
                }
                .disabled(model.payload == nil)
                Button {
                    DonkPasteboard.copy(model.text, label: "Payload")
                } label: {
                    Label("Copy Payload", systemImage: "doc.on.doc")
                }
                Button {
                    model.prettify()
                } label: {
                    Label("Format", systemImage: "text.alignleft")
                }
                .disabled(model.payload == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .accessibilityLabel("Payload actions")
            }
        }
    }

    @ViewBuilder
    private var templateMenu: some View {
        Menu {
            ForEach(templates.builtIn) { item in
                Button(item.template.name) { model.load(text: item.template.payload, name: item.template.name) }
            }
        } label: {
            Label("Built-in Templates", systemImage: "square.grid.2x2")
        }
        if !templates.host.isEmpty {
            Menu {
                ForEach(templates.host) { item in
                    Button(item.template.name) { model.load(text: item.template.payload, name: item.template.name) }
                }
            } label: {
                Label("App Templates", systemImage: "app")
            }
        }
        if !templates.saved.isEmpty {
            Menu {
                ForEach(templates.saved) { item in
                    Button(item.template.name) { model.load(text: item.template.payload, name: item.template.name) }
                }
            } label: {
                Label("Saved Templates", systemImage: "bookmark")
            }
        }
    }

    // MARK: - Delivery

    private var deliveryCard: some View {
        DonkCard(title: "Deliver", icon: "paperplane.fill") {
            SegmentedTabs(
                selection: $model.mode,
                tabs: PushDeliveryMode.allCases,
                title: { $0.rawValue }
            )
            VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                Text(model.mode.headline)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                Text(DonkTextBreaking.breakable(model.mode.explanation))
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.mode {
            case .banner:
                bannerOptions
            case .inject:
                injectOptions
            case .silent:
                silentOptions
            case .export:
                exportOptions
            }
            if model.isBusy {
                HStack(spacing: DonkSpacing.s) {
                    ProgressView()
                    Text(busyMessage)
                        .font(DonkFont.footnote)
                        .foregroundColor(DonkColor.textSecondary)
                }
            }
            if let outcome = model.outcome {
                PushOutcomeView(outcome: outcome)
            }
        }
    }

    private var bannerOptions: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            HStack(spacing: DonkSpacing.s) {
                Text("Permission")
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                StatusPill(device.statusTitle, tone: device.statusTone)
                Spacer(minLength: 0)
            }
            permissionNotice
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                Text("Delay")
                    .font(DonkFont.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                HStack(spacing: DonkSpacing.s) {
                    ForEach(PushDelayOption.allCases, id: \.self) { option in
                        FilterChip(title: option.rawValue, isSelected: model.delay == option) {
                            model.delay = option
                        }
                    }
                }
                if model.delay == .custom {
                    Stepper(value: $model.customDelay, in: 1...600, step: 5) {
                        Text("\(Int(model.customDelay)) seconds")
                            .font(DonkFont.callout)
                            .monospacedDigit()
                    }
                }
                Text(model.delaySeconds >= 5
                     ? "Background (⇧⌘H) or kill the app before it fires to see the system banner or test a cold start."
                     : "Fires almost immediately; in the foreground your delegate decides how it is presented.")
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            primaryButton(title: "Schedule Banner", icon: "bell.badge.fill", isBlocked: device.isLoaded && !device.canDeliver) {
                model.send()
            }
        }
    }

    @ViewBuilder
    private var permissionNotice: some View {
        if device.isLoaded && device.status == .notDetermined {
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                PushStepRow(step: PushStep(
                    .warning,
                    "Banners need notification permission, and donk never asks on its own. Requesting it uses the app's one-time system prompt, so your onboarding won't get to show it."
                ))
                secondaryButton(title: "Request Permission…", icon: "hand.raised.fill", isAlwaysEnabled: true) {
                    isConfirmingPermission = true
                }
            }
        } else if device.isLoaded && device.status == .denied {
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                PushStepRow(step: PushStep(.failure, "Notifications are denied for this app. Allow them in Settings to schedule banners."))
                secondaryButton(title: "Open Settings", icon: "gearshape.fill", isAlwaysEnabled: true) {
                    device.openSettings()
                }
            }
        }
    }

    private var keepOpenToggle: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.xs) {
            Toggle(isOn: $model.keepsDebuggerOpen) {
                Text("Keep donk open")
                    .font(DonkFont.callout)
            }
            Text(model.keepsDebuggerOpen
                 ? "donk stays on top, so screens your app presents from the key window open behind it."
                 : "donk closes before calling your app, so screens it presents from the key window appear on top. The result shows as a toast.")
                .font(DonkFont.caption)
                .foregroundColor(DonkColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var injectOptions: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            keepOpenToggle
            primaryButton(title: "Call willPresent", icon: "arrow.down.right.circle.fill") { model.send() }
            Divider()
            VStack(alignment: .leading, spacing: DonkSpacing.s) {
                Text("Simulate tap")
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                Picker("Response", selection: $model.tapKind) {
                    ForEach(PushTapKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                if model.tapKind != .open {
                    TextField(model.tapKind == .reply ? "Action identifier (REPLY)" : "Action identifier", text: $model.actionIdentifier)
                        .textFieldStyle(.roundedBorder)
                        .font(DonkFont.code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !registeredActions.isEmpty {
                        ChipRow(horizontalPadding: 0) {
                            ForEach(registeredActions, id: \.identifier) { action in
                                FilterChip(
                                    title: action.title.isEmpty ? action.identifier : action.title,
                                    icon: action is UNTextInputNotificationAction ? "text.bubble" : "hand.tap",
                                    isSelected: model.actionIdentifier == action.identifier
                                ) {
                                    model.actionIdentifier = action.identifier
                                    model.tapKind = action is UNTextInputNotificationAction ? .reply : .action
                                }
                            }
                        }
                    }
                }
                if model.tapKind == .reply {
                    TextField("Reply text", text: $model.replyText)
                        .textFieldStyle(.roundedBorder)
                }
                Text(tapDescription)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                secondaryButton(title: "Simulate Tap", icon: "hand.tap.fill") { model.simulateTap() }
            }
        }
    }

    private var busyMessage: String {
        if model.mapped.isMutableContent && model.mode != .silent {
            return "Running mutable-content processing…"
        }
        return model.mode == .banner ? "Scheduling…" : "Waiting for the app…"
    }

    private var registeredActions: [UNNotificationAction] {
        device.categories[model.mapped.categoryIdentifier] ?? []
    }

    private var tapDescription: String {
        switch model.tapKind {
        case .open:
            return "didReceive with UNNotificationDefaultActionIdentifier, as when the user taps the banner."
        case .action:
            return "didReceive with a custom action identifier from the notification's category."
        case .reply:
            return "didReceive with a UNTextInputNotificationResponse carrying the reply text."
        }
    }

    private var silentOptions: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            if !PushEnvironment.hasRemoteNotificationBackgroundMode {
                PushStepRow(step: PushStep(.warning, "Info.plist has no UIBackgroundModes → remote-notification. Real silent pushes will not wake the app."))
            }
            keepOpenToggle
            primaryButton(title: "Call didReceiveRemoteNotification", icon: "moon.zzz.fill") { model.send() }
        }
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.m) {
            VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                Toggle(isOn: $model.includesTargetBundle) {
                    Text("Include \"\(PushAPNsExport.targetBundleKey)\"")
                        .font(DonkFont.callout)
                }
                Text(model.includesTargetBundle
                     ? "Needed for drag-and-drop onto the Simulator. simctl keeps this key in userInfo, so the app sees one extra key."
                     : "The file is exactly the payload. The command below names the bundle, so userInfo matches a backend push.")
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                Text(PushAPNsExport.fileName)
                    .font(DonkFont.label)
                    .foregroundColor(DonkColor.textSecondary)
                CodeView(text: model.apnsFileContents, language: .json)
                    .padding(DonkSpacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkColor.codeBackground))
            }
            VStack(alignment: .leading, spacing: DonkSpacing.xs) {
                Text("Run on your Mac")
                    .font(DonkFont.label)
                    .foregroundColor(DonkColor.textSecondary)
                CodeView(text: model.simctlCommand)
                    .padding(DonkSpacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkColor.codeBackground))
            }
            HStack(spacing: DonkSpacing.s) {
                primaryButton(title: "Share .apns", icon: "square.and.arrow.up") { model.shareAPNsFile() }
                secondaryButton(title: "Copy Command", icon: "terminal") {
                    DonkPasteboard.copy(model.simctlCommand, label: "Command")
                }
            }
        }
    }

    // MARK: - Buttons

    private func primaryButton(title: String, icon: String, isBlocked: Bool = false, action: @escaping () -> Void) -> some View {
        let enabled = isEnabled && !isBlocked
        return Button(action: action) {
            Label(title, systemImage: icon)
                .font(DonkFont.rounded(.subheadline, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                        .fill(enabled ? DonkColor.accent : DonkColor.accent.opacity(0.4))
                )
        }
        .buttonStyle(.donkPressable)
        .disabled(!enabled)
    }

    private func secondaryButton(
        title: String,
        icon: String,
        isAlwaysEnabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let enabled = isAlwaysEnabled || isEnabled
        return Button(action: action) {
            Label(title, systemImage: icon)
                .font(DonkFont.rounded(.subheadline, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(enabled ? DonkColor.accent : DonkColor.textTertiary)
                .background(
                    RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                        .fill(DonkTone.accent.softBackground)
                )
        }
        .buttonStyle(.donkPressable)
        .disabled(!enabled)
    }

    private var isEnabled: Bool {
        model.payload != nil && !model.isBusy
    }
}

// MARK: - Outcome

struct PushOutcomeView: View {
    let outcome: PushDeliveryOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            HStack(spacing: DonkSpacing.s) {
                Image(systemName: tone.defaultIcon)
                    .foregroundColor(tone.color)
                Text(outcome.title)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(DonkFormat.time(outcome.date))
                    .font(DonkFont.codeCaption2)
                    .foregroundColor(DonkColor.textTertiary)
            }
            if !outcome.lines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(outcome.lines.enumerated()), id: \.offset) { index, line in
                        if index > 0 {
                            Divider()
                        }
                        KeyValueRow(key: line.key, value: line.value, monospacedValue: true, keyWidth: 96)
                    }
                }
            }
            ForEach(outcome.steps) { step in
                PushStepRow(step: step)
            }
        }
        .padding(DonkSpacing.m)
        .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(tone.softBackground))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var tone: DonkTone {
        switch outcome.status {
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        }
    }
}

struct PushStepRow: View {
    let step: PushStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.s) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundColor(tone.color)
            Text(DonkTextBreaking.breakable(step.text))
                .font(DonkFont.footnote)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button {
                DonkPasteboard.copy(step.text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var tone: DonkTone {
        switch step.kind {
        case .info: return .info
        case .success: return .success
        case .warning: return .warning
        case .failure: return .error
        }
    }

    private var icon: String {
        switch step.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Device card

struct PushDeviceCard: View {
    @ObservedObject var device: PushDeviceModel
    let onRequestPermission: () -> Void

    var body: some View {
        DonkCard(title: "Device", icon: "iphone.radiowaves.left.and.right", tone: .info) {
            VStack(spacing: 0) {
                tokenRow(title: "APNs token", value: device.deviceToken, label: "APNs token")
                Divider()
                tokenRow(title: "FCM token", value: device.fcmToken, label: "FCM token")
                Divider()
                HStack(spacing: DonkSpacing.s) {
                    Text("Permission")
                        .font(DonkFont.subheadline)
                        .foregroundColor(DonkColor.textSecondary)
                    Spacer(minLength: DonkSpacing.s)
                    StatusPill(device.statusTitle, tone: device.statusTone)
                }
                .padding(.vertical, 10)
                if device.isLoaded && device.status == .authorized && !device.alertsEnabled {
                    Text("Alerts are turned off for this app in Settings.")
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, DonkSpacing.s)
                }
            }
            HStack(spacing: DonkSpacing.s) {
                if device.isLoaded && device.status == .notDetermined {
                    actionButton("Request Permission…", icon: "bell", action: onRequestPermission)
                } else {
                    actionButton("Notification Settings", icon: "gearshape") { device.openSettings() }
                }
                if device.deviceToken == nil {
                    actionButton("Register", icon: "antenna.radiowaves.left.and.right") { device.registerForRemoteNotifications() }
                }
            }
        }
    }

    private func tokenRow(title: String, value: String?, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DonkSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DonkFont.subheadline)
                    .foregroundColor(DonkColor.textSecondary)
                Text(value.map { DonkTextBreaking.breakable($0) } ?? "Not set")
                    .font(value == nil ? DonkFont.footnote : DonkFont.codeCaption)
                    .foregroundColor(value == nil ? DonkColor.textTertiary : DonkColor.textPrimary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: DonkSpacing.s)
            if let value {
                CopyButton(text: value, label: label)
            }
        }
        .padding(.vertical, 10)
        .contextMenu {
            if let value {
                Button {
                    DonkPasteboard.copy(value, label: label)
                } label: {
                    Label("Copy \(title)", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DonkFont.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundColor(DonkColor.accent)
                .background(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous).fill(DonkTone.accent.softBackground))
        }
        .buttonStyle(.donkPressable)
    }
}

// MARK: - Name sheet

struct PushNameSheet: View {
    let title: String
    let initialName: String
    let onSave: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DonkNavigationContainer {
            Form {
                Section {
                    TextField("Template name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .donkNavigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .donkTheme()
        .onAppear { name = initialName }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(name)
        dismiss()
    }
}
