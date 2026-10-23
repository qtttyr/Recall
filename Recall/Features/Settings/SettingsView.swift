import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let appState: AppState
    @Bindable var settings: AppSettings

    @State private var stats: StoreStats?
    @State private var isExporting = false
    @State private var isDeleting = false
    @State private var isRemovingModel = false
    @State private var isResetting = false

    init(appState: AppState) {
        self.appState = appState
        self.settings = appState.settings
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground)
            LinearGradient(
                colors: [Color.primary.opacity(0.025), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    general
                    history
                    search
                    privacy
                    footer
                }
                .padding(.horizontal, 30)
                .padding(.top, 44)
                .padding(.bottom, 30)
            }
        }
        .ignoresSafeArea()
        .tint(Theme.accent)
        .task { await refreshLoop() }
        .onChange(of: settings.retentionDays) { _, _ in
            Task { try? await appState.store.prune(retentionDays: settings.retentionDays, maxItems: settings.maxItems) }
        }
        .onChange(of: settings.maxItems) { _, _ in
            Task { try? await appState.store.prune(retentionDays: settings.retentionDays, maxItems: settings.maxItems) }
        }
        .alert("Delete all history?", isPresented: $isDeleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await appState.store.deleteAll()
                    await refreshStats()
                }
            }
        } message: {
            Text("This removes every item and image from this Mac. It cannot be undone.")
        }
        .alert("Remove the embedding model?", isPresented: $isRemovingModel) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await appState.models.remove() }
            }
        } message: {
            Text("Semantic search falls back to the smaller macOS model. You can download EmbeddingGemma 2 again at any time.")
        }
        .alert("Reset and replay onboarding?", isPresented: $isResetting) {
            Button("Cancel", role: .cancel) {}
            Button("Reset and start", role: .destructive) {
                Task {
                    await appState.resetToOnboarding()
                }
            }
        } message: {
            Text("This clears your clipboard history and launches the welcome flow again. Downloaded models remain installed on this Mac.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recall")
                    .font(.system(size: 19, weight: .semibold))
                Text("Your clipboard, remembered.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("0.1.0")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var general: some View {
        SettingsSection(title: "General") {
            SettingsRow {
                rowLabel("Launch at login", detail: "Start quietly in the menu bar.")
                Spacer()
                Toggle("", isOn: $settings.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow {
                rowLabel("Global shortcut", detail: "Works from any app.")
                Spacer()
                HStack(spacing: 4) {
                    if appState.hotKeyLabel.isEmpty {
                        KeyCap(text: "—")
                    } else if appState.hotKeyLabel == "⌥Space" {
                        KeyCap(text: "⌥")
                        KeyCap(text: "Space")
                    } else {
                        KeyCap(text: "⌃⌥")
                        KeyCap(text: "Space")
                    }
                }
            }
        }
    }

    private var history: some View {
        SettingsSection(title: "History") {
            SettingsRow {
                rowLabel("Keep items", detail: "Pinned items are never removed.")
                Spacer()
                Picker("", selection: $settings.retentionDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
            }
            SettingsDivider()
            SettingsRow {
                rowLabel("Maximum items", detail: "A hard ceiling for the local store.")
                Spacer()
                Picker("", selection: $settings.maxItems) {
                    Text("5,000").tag(5_000)
                    Text("20,000").tag(20_000)
                    Text("50,000").tag(50_000)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
            }
            SettingsDivider()
            SettingsRow {
                rowLabel("Pause capture", detail: "Useful for private sessions.")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.settings.isCapturePaused },
                    set: { _ in appState.togglePause() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            SettingsDivider()
            excludedApps
        }
    }

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                rowLabel("Excluded apps", detail: "Copies from these apps are never read.")
                Spacer()
                Button("Add app…") { addExcludedApp() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            if settings.excludedBundleIDs.isEmpty {
                Text("None yet.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 5) {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            Text(appName(for: bundleID))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(bundleID)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                settings.include(bundleID: bundleID)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var search: some View {
        SettingsSection(title: "Search") {
            SettingsRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search by meaning")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("Local semantic search. No cloud, no account.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: $settings.semanticEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            modelBlock
            SettingsDivider()
            assistantBlock
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(indexSummary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rebuild index") {
                        appState.indexNow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
                if let stats, stats.itemCount > 0 {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(Theme.accent.opacity(0.7))
                                .frame(width: proxy.size.width * progress(for: stats))
                        }
                    }
                    .frame(height: 2)
                }
                Text("Embeddings are stored beside your history. Rebuilding only touches this Mac.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var modelBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.14), lineWidth: 0.5)
                        }
                    Image(systemName: appState.models.isReady ? "checkmark" : "sparkles")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("EmbeddingGemma 2")
                            .font(.system(size: 11.5, weight: .medium))
                        modelStatusPill
                    }
                    Text("Multilingual · 768 dimensions · on-device")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if appState.models.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(appState.models.actionTitle) {
                        appState.models.retryOrVerify()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
            }

            if let progress = appState.models.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Theme.accent.opacity(0.55), Theme.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)
                .animation(.easeOut(duration: 0.25), value: progress)
            }

            Text(appState.models.statusDetail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineSpacing(2)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(appState.models.totalSizeLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Apache 2.0")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if appState.models.isReady {
                    Text("Verified on disk")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Button("Remove") { isRemovingModel = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Downloads once from Hugging Face")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var modelStatusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(appState.models.isReady ? Theme.accent : Color.primary.opacity(0.22))
                .frame(width: 4, height: 4)
            Text(appState.models.statusTitle)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(appState.models.isReady ? Color.primary.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.035))
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent.opacity(0.1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.14), lineWidth: 0.5)
                        }
                    Image(systemName: appState.assistantModels.isReady ? "checkmark" : "cpu")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("Qwen 2.5 Query Assistant")
                            .font(.system(size: 11.5, weight: .medium))
                        assistantStatusPill
                    }
                    Text("0.5B Core ML · Neural Engine · 8 GB+ Mac")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if appState.assistantModels.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if appState.assistantModels.isReady {
                    Toggle("", isOn: $settings.assistantEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                } else {
                    Button("Download") {
                        appState.assistantModels.download()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
            }

            if let progress = appState.assistantModels.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Theme.accent.opacity(0.55), Theme.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 3)
                .animation(.easeOut(duration: 0.25), value: progress)
            }

            Text(appState.assistantModels.statusDetail)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineSpacing(2)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(appState.assistantModels.totalSizeLabel)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Optional")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if appState.assistantModels.isReady {
                    Button("Remove") {
                        appState.assistantModels.remove()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                } else {
                    Text("Zero memory when idle")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var assistantStatusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(appState.assistantModels.isReady ? Theme.accent : Color.primary.opacity(0.22))
                .frame(width: 4, height: 4)
            Text(appState.assistantModels.statusTitle)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(appState.assistantModels.isReady ? Color.primary.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.035))
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
    }

    private var privacy: some View {
        SettingsSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 7) {
                Text("No accounts. No telemetry. One optional model download.")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Everything lives in ~/Library/Application Support/Recall. The model comes from Hugging Face once; everything else stays offline.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            SettingsDivider()

            SettingsRow {
                Button("Show database in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([appState.store.databaseURL])
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                Text(stats.map { ByteCountFormatter.string(fromByteCount: $0.databaseBytes, countStyle: .file) } ?? "—")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            SettingsDivider()
            SettingsRow {
                Button("Export history…") { exportHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            SettingsDivider()
            SettingsRow {
                Button("Delete all history…") { isDeleting = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.8))
                Spacer()
            }
            SettingsDivider()
            SettingsRow {
                Button("Reset and replay onboarding…") { isResetting = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Open source · MIT")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("Made for macOS")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    private var indexSummary: String {
        guard let stats else { return "Reading local index…" }
        let items = NumberFormatter.localizedString(from: NSNumber(value: stats.itemCount), number: .decimal)
        let indexed = NumberFormatter.localizedString(from: NSNumber(value: stats.indexedCount), number: .decimal)
        if stats.itemCount == 0 { return "No items yet" }
        return "\(items) items · \(indexed) indexed"
    }

    private func progress(for stats: StoreStats) -> CGFloat {
        guard stats.itemCount > 0 else { return 0 }
        return min(1, CGFloat(stats.indexedCount) / CGFloat(stats.itemCount))
    }

    private func rowLabel(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.title = "Exclude an app"
        panel.message = "Copies made in this app will never be remembered."
        panel.prompt = "Exclude"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                settings.exclude(bundleID: bundleID)
            }
        }
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.title = "Export Recall History"
        panel.nameFieldStringValue = "Recall History.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let data = try? await appState.store.exportJSON() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func refreshStats() async {
        let provider = await appState.semantic.currentProvider()
        stats = try? await appState.store.stats(provider: provider.id)
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshStats()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                content
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.032))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
        }
    }
}

private struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 42)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}
