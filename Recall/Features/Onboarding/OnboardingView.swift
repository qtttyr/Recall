import AppKit
import Combine
import SwiftUI

struct OnboardingView: View {
    let appState: AppState
    @Bindable var settings: AppSettings
    let models: ModelManager
    let assistantModels: AssistantModelManager
    let onClose: () -> Void

    @State private var step: Int
    @State private var permission: PasteboardAccess = .unknown
    @State private var ringRotation = 0.0

    init(appState: AppState, initialStep: Int = 0, onClose: @escaping () -> Void) {
        self.appState = appState
        self.settings = appState.settings
        self.models = appState.models
        self.assistantModels = appState.assistantModels
        self.onClose = onClose
        self._step = State(initialValue: min(max(initialStep, 0), 3))
        self._permission = State(initialValue: Permissions.pasteboardState())
    }

    var body: some View {
        ZStack {
            background
            ambientGlow

            VStack(alignment: .leading, spacing: 0) {
                brand

                VStack(alignment: .leading, spacing: 0) {
                    stepHeader
                    stepBody
                        .padding(.top, 20)
                }
                .id(step)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 10)),
                        removal: .opacity.combined(with: .offset(x: -10))
                    )
                )
                .padding(.top, 28)

                Spacer(minLength: 12)

                actions
                footer
                    .padding(.top, 14)
            }
            .padding(.horizontal, 38)
            .padding(.top, 34)
            .padding(.bottom, 20)
        }
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
        .onAppear { startAtmosphere() }
        .onChange(of: permission) { _, _ in
            appState.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = Permissions.pasteboardState()
        }
        .task(id: step) {
            if step == 2, models.phase == .unknown {
                await models.checkAtLaunch()
            } else if step == 3, assistantModels.phase == .unknown {
                await assistantModels.checkAtLaunch()
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            VisualEffectView(material: .hudWindow)
            LinearGradient(
                colors: [.white.opacity(0.05), .black.opacity(0.19)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var ambientGlow: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.15), Theme.accent.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 160
                        )
                    )
                    .frame(width: 320, height: 320)
                    .position(x: proxy.size.width * 0.82, y: proxy.size.height * 0.12)
                    .blur(radius: 26)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.accent.opacity(0.055), Theme.accent.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)
                    .position(x: proxy.size.width * 0.08, y: proxy.size.height * 0.9)
                    .blur(radius: 24)
            }
            .allowsHitTesting(false)
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .trim(from: 0.09, to: 0.91)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.2), Theme.accent.opacity(0.9)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
                    )
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(ringRotation))

                Circle()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 3, height: 3)
            }

            Text("RECALL")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "lock")
                    .font(.system(size: 7.5, weight: .medium))
                Text("ON-DEVICE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.15)
            }
            .foregroundStyle(.tertiary)
        }
        .frame(height: 22)
    }

    // MARK: - Header

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Theme.accent.opacity(0.82))
                .frame(height: 10, alignment: .bottomLeading)

            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.96))
                .lineSpacing(-1.5)
                .frame(height: 76, alignment: .topLeading)
                .padding(.top, 8)

            Text(subtitle)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(height: 34, alignment: .topLeading)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0:
            welcomeCard
        case 1:
            permissionCard
        case 2:
            modelCard
        default:
            assistantCard
        }
    }

    // MARK: - Welcome

    private var welcomeCard: some View {
        VStack(spacing: 0) {
            FeatureRow(
                symbol: "command",
                title: "One shortcut",
                detail: "Every copy, one keystroke away."
            ) {
                KeyCap(text: "⌥ Space")
            }

            DividerLine()

            FeatureRow(
                symbol: "sparkles",
                title: "Meaning",
                detail: "Find it without the exact words."
            )

            DividerLine()

            FeatureRow(
                symbol: "lock",
                title: "On-device",
                detail: "No account, cloud, or telemetry."
            )
        }
        .frame(height: 156)
        .background(cardBackground)
    }

    // MARK: - Permission

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CardIcon(symbol: "lock.shield")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard access")
                        .font(.system(size: 12, weight: .medium))
                    Text("Only after something changes.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)
                PermissionPill(permission: permission)
            }

            DividerLine()
                .padding(.horizontal, -16)
                .padding(.vertical, 12)

            Text(permissionExplanation)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                Text("Nothing is read until macOS allows it.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(height: 156, alignment: .topLeading)
        .background(cardBackground)
    }

    private var permissionExplanation: String {
        switch permission {
        case .allowed:
            "Recall can read the clipboard. It only looks after the clipboard changes, and never in the background."
        case .denied:
            "Access is off. Open System Settings and choose Allow for Recall, or continue with a limited experience."
        case .unavailable:
            "This Mac does not require an extra clipboard permission. Capture works as soon as you copy."
        default:
            "macOS will show one system prompt. Choose Allow, not Allow Once, so Recall keeps working after a restart."
        }
    }

    // MARK: - Model

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CardIcon(symbol: models.isReady ? "checkmark" : "sparkles", highlighted: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("EmbeddingGemma 2")
                        .font(.system(size: 12, weight: .medium))
                    Text("Multilingual · 768 dimensions")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)
                ModelStatusPill(phase: models.phase)
            }

            ModelProgressBar(phase: models.phase, progress: models.progress)
                .padding(.top, 14)

            Text(models.statusDetail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Text(models.totalSizeLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Apache 2.0")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if models.isReady {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                        Text("Verified")
                            .font(.system(size: 8.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent.opacity(0.8))
                } else {
                    Text(modelFooter)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(height: 156, alignment: .topLeading)
        .background(cardBackground)
    }

    private var modelFooter: String {
        switch models.phase {
        case .loading, .compiling, .verifying, .checking: "Preparing"
        default: "One-time download"
        }
    }

    // MARK: - Assistant

    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CardIcon(symbol: assistantModels.isReady ? "checkmark" : "cpu", highlighted: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Qwen 2.5 (0.5B Core ML)")
                        .font(.system(size: 12, weight: .medium))
                    Text("Semantic query assistant · On-demand")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)
                AssistantStatusPill(phase: assistantModels.phase)
            }

            ModelProgressBar(phase: assistantProgressPhase, progress: assistantModels.progress)
                .padding(.top, 14)

            Text(assistantModels.statusDetail)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Text(assistantModels.totalSizeLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Apple Neural Engine")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if assistantModels.isReady {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                        Text("Active")
                            .font(.system(size: 8.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent.opacity(0.8))
                } else {
                    Text("Optional")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(height: 156, alignment: .topLeading)
        .background(cardBackground)
    }

    private var assistantProgressPhase: ModelManager.Phase {
        switch assistantModels.phase {
        case .downloading(let p, let d): .downloading(progress: p, detail: d)
        case .compiling: .compiling
        case .ready: .ready
        case .failed(let m): .failed(m)
        default: .absent
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 16) {
            OnboardingPrimaryButton(
                title: primaryTitle,
                isLoading: primaryLoading,
                isDisabled: primaryDisabled
            ) {
                primaryAction()
            }

            if let secondaryTitle {
                Button(secondaryTitle) {
                    secondaryAction()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
        .frame(height: 38)
        .animation(.easeOut(duration: 0.18), value: primaryTitle)
    }

    private var primaryTitle: String {
        switch step {
        case 0:
            return "Continue"
        case 1:
            return permissionPrimaryTitle
        case 2:
            if models.isReady { return "Continue" }
            if models.isWorking { return "Preparing…" }
            if case .failed = models.phase { return "Try again" }
            if case .partial = models.phase { return "Resume download" }
            return "Download model"
        default:
            if assistantModels.isReady { return "Start using Recall" }
            if assistantModels.isWorking { return "Preparing…" }
            if case .failed = assistantModels.phase { return "Try again" }
            return "Download assistant (390 MB)"
        }
    }

    private var primaryLoading: Bool {
        (step == 2 && models.isWorking) || (step == 3 && assistantModels.isWorking)
    }

    private var primaryDisabled: Bool {
        (step == 2 && models.isWorking) || (step == 3 && assistantModels.isWorking)
    }

    private var secondaryTitle: String? {
        switch step {
        case 1:
            "Later"
        case 2:
            models.isReady ? nil : "Use basic search"
        case 3:
            assistantModels.isReady ? nil : "Keep it lightweight"
        default:
            nil
        }
    }

    private func primaryAction() {
        switch step {
        case 0:
            advance()
        case 1:
            switch permission {
            case .allowed, .unavailable:
                advance()
            case .denied:
                Permissions.openPasteboardSettings()
            default:
                permission = Permissions.requestPasteboardAccess()
                appState.refreshPermissions()
                if permission == .allowed {
                    advance(after: 0.25)
                }
            }
        case 2:
            switch models.phase {
            case .ready:
                advance()
            case .absent, .partial, .failed:
                models.download()
            case .unknown:
                Task { await models.checkAtLaunch() }
            default:
                break
            }
        default:
            switch assistantModels.phase {
            case .ready:
                finish()
            case .absent, .failed:
                assistantModels.download()
            case .unknown:
                Task { await assistantModels.checkAtLaunch() }
            default:
                break
            }
        }
    }

    private func secondaryAction() {
        if step == 1 || step == 2 {
            advance()
        } else if step == 3 {
            finish()
        }
    }

    private var permissionPrimaryTitle: String {
        switch permission {
        case .allowed, .unavailable: "Continue"
        case .denied: "Open Settings"
        default: "Allow access"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Button("Back") {
                back()
            }
            .buttonStyle(.plain)
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
            .opacity(step > 0 ? 1 : 0)
            .disabled(step == 0)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Theme.accent : Color.primary.opacity(0.16))
                        .frame(
                            width: index == step ? 12 : 3.5,
                            height: 3.5
                        )
                }
            }
            .animation(.easeOut(duration: 0.22), value: step)

            Spacer()

            Button((step == 2 && models.isWorking) || (step == 3 && assistantModels.isWorking) ? "Skip for now" : "Skip") {
                finish()
            }
            .buttonStyle(.plain)
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
        .frame(height: 20)
    }

    // MARK: - Copy

    private var eyebrow: String {
        switch step {
        case 0: "01 — WELCOME"
        case 1: "02 — PERMISSION"
        case 2: "03 — MEMORY"
        default: "04 — ASSISTANT"
        }
    }

    private var title: String {
        switch step {
        case 0: "Your clipboard,\nremembered."
        case 1: "One permission.\nThen silence."
        case 2: "Teach it to\nremember meaning."
        default: "Guide search\nwith an assistant."
        }
    }

    private var subtitle: String {
        switch step {
        case 0:
            "Every copy, one shortcut away. Search by meaning, in English or Russian."
        case 1:
            "Recall reads the clipboard only after it changes. macOS asks once. Choose Allow, not Allow Once."
        case 2:
            "EmbeddingGemma 2 runs entirely on this Mac. Download it once and search across 100+ languages, offline."
        default:
            "Optional 0.5B Core ML model. Translates natural language questions into code and keywords. Fits 8 GB Macs."
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.032))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
    }

    // MARK: - Flow

    private func advance(after delay: TimeInterval = 0) {
        guard step < 3 else { return }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(Motion.onboarding) {
                    step += 1
                }
            }
        } else {
            withAnimation(Motion.onboarding) {
                step += 1
            }
        }
    }

    private func back() {
        guard step > 0 else { return }
        withAnimation(Motion.onboarding) {
            step -= 1
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            appState.openPanel()
        }
    }

    private func startAtmosphere() {
        withAnimation(.linear(duration: 16).repeatForever(autoreverses: false)) {
            ringRotation = 360
        }
    }
}

// MARK: - Components

private struct FeatureRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let trailing: Trailing

    init(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            CardIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 51)
    }
}

private extension FeatureRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

private struct CardIcon: View {
    let symbol: String
    var highlighted: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? Theme.accent.opacity(0.11) : Color.primary.opacity(0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            highlighted ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.055),
                            lineWidth: 0.5
                        )
                }
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(highlighted ? Theme.accent.opacity(0.85) : Color.secondary.opacity(0.72))
        }
        .frame(width: 26, height: 26)
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(height: 0.5)
            .padding(.leading, 50)
    }
}

private struct PermissionPill: View {
    let permission: PasteboardAccess

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(permission == .allowed ? Color.primary.opacity(0.82) : Color.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5)
                }
        }
    }

    private var color: Color {
        switch permission {
        case .allowed: Theme.accent
        case .denied: Color.red.opacity(0.7)
        default: Color.primary.opacity(0.22)
        }
    }

    private var label: String {
        switch permission {
        case .allowed: "On"
        case .denied: "Off"
        case .unavailable: "Not needed"
        default: "Waiting"
        }
    }
}

private struct ModelStatusPill: View {
    let phase: ModelManager.Phase

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(phase == .ready ? Color.primary.opacity(0.82) : Color.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5)
                }
        }
    }

    private var label: String {
        switch phase {
        case .ready: "Ready"
        case .absent: "Not installed"
        case .partial: "Incomplete"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .compiling: "Preparing"
        case .loading: "Loading"
        case .failed: "Failed"
        case .unknown, .checking: "Checking"
        }
    }

    private var color: Color {
        switch phase {
        case .ready: Theme.accent
        case .failed: Color.red.opacity(0.7)
        case .downloading, .verifying, .compiling, .loading, .checking: Theme.accent.opacity(0.75)
        default: Color.primary.opacity(0.22)
        }
    }
}

private struct ModelProgressBar: View {
    let phase: ModelManager.Phase
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let progress {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.075))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Theme.accent.opacity(0.55), Theme.accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(0, proxy.size.width * progress))
                }
            }
            .frame(height: 3)
            .animation(.easeOut(duration: 0.28), value: progress)
        } else if isWorking {
            IndeterminateBar(active: !reduceMotion)
                .frame(height: 3)
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 3)
        }
    }

    private var isWorking: Bool {
        switch phase {
        case .compiling, .loading, .checking: true
        default: false
        }
    }
}

private struct IndeterminateBar: View {
    let active: Bool
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.075))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.accent.opacity(0.05), Theme.accent, Theme.accent.opacity(0.05)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: proxy.size.width * 0.32)
                    .offset(x: proxy.size.width * phase)
                    .onAppear {
                        guard active else { return }
                        withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                            phase = 1.05
                        }
                    }
            }
            .clipShape(Capsule())
        }
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.66)
                        .tint(Color(nsColor: .windowBackgroundColor))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 22)
            .frame(minWidth: 190, minHeight: 38)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(isHovering && !isDisabled ? 0.98 : 0.92))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(isHovering && !isDisabled ? 0.12 : 0.04), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .scaleEffect(isHovering && !isDisabled ? 1.008 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.7 : 1)
        .onHover { hovering in
            withAnimation(Motion.quick) { isHovering = hovering }
        }
    }
}

private struct AssistantStatusPill: View {
    let phase: AssistantModelManager.Phase

    var body: some View {
        Text(title)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(background)
            }
    }

    private var title: String {
        switch phase {
        case .ready: "Ready"
        case .downloading: "Downloading"
        case .compiling: "Optimizing"
        case .failed: "Failed"
        default: "Optional"
        }
    }

    private var foreground: Color {
        switch phase {
        case .ready: Theme.accent
        case .failed: .secondary
        default: .secondary
        }
    }

    private var background: Color {
        switch phase {
        case .ready: Theme.accent.opacity(0.12)
        default: Color.primary.opacity(0.06)
        }
    }
}
