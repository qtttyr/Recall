import AppKit
import SwiftUI

/// The hosting view is larger than the visible surface so the soft shadow has
/// room to breathe. The surface itself fills the window, which lets AppKit
/// animate the window height while SwiftUI keeps the search line pinned top.
struct PanelSurface: View {
    @Bindable var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(Theme.windowInset)
            .opacity(model.isVisible ? 1 : 0)
            .scaleEffect(model.isVisible ? 1 : 0.985, anchor: .top)
            .offset(y: model.isVisible ? 0 : -4)
            .animation(reduceMotion ? .easeOut(duration: 0.1) : Motion.panel, value: model.isVisible)
    }
}

struct PanelView: View {
    @Bindable var model: PanelModel
    @FocusState private var isFocused: Bool
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { focusField() }
            .onChange(of: model.focusToken) { _, _ in focusField() }
            .onChange(of: model.panelHeight, initial: true) { _, height in
                model.onHeightChange?(height)
            }
            .onExitCommand { model.close() }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2), value: model.isExpanded)
    }

    @ViewBuilder
    private var mainContent: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                glassChildren
            }
        } else {
            glassChildren
        }
    }

    private var glassChildren: some View {
        VStack(spacing: 0) {
            searchHeader
                .transition(.opacity)

            if model.isExpanded {
                Spacer(minLength: 0)
                    .frame(height: Theme.resultGap)

                resultPanel
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : Motion.panel, value: model.isExpanded)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : Motion.panel, value: model.layout)
    }

    // MARK: - Search line

    private var searchHeader: some View {
        HStack(spacing: 12) {
            searchPill
            FilterButton(filter: model.filter) {
                model.cycleFilter()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.searchHeight)
    }

    private var searchPill: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(isFocused ? 0.95 : 0.68))
                .frame(width: 19, height: 19)
                .contentTransition(.opacity)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(model.searchPlaceholder)
                        .font(.system(size: 17.5, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                TextField("", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17.5, weight: .regular))
                    .focused($isFocused)
                    .onSubmit { model.copySelected() }
                    .accessibilityLabel(model.searchPlaceholder)
            }

            Spacer(minLength: 2)

            HStack(spacing: 9) {
                if model.isSearching || model.isSemanticSearching {
                    TinySpinner()
                        .transition(.opacity)
                } else if model.semanticUsed && !model.query.isEmpty {
                    MeaningPulse()
                        .transition(.opacity)
                }

                if !model.query.isEmpty {
                    Button {
                        model.clearQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.searchPillHeight)
        .modifier(GlassSearchField())
    }

    // MARK: - Content

    private var resultPanel: some View {
        VStack(spacing: 0) {
            switch model.layout {
            case .permission:
                PermissionBanner(model: model)
            case .noResults:
                NoResultsRow(isSearching: model.isSearching || model.isSemanticSearching) {
                    model.clearQuery()
                }
            case .results:
                sectionHeader
                ResultsList(model: model, namespace: selectionNamespace)
                footer
            case .compact:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .modifier(GlassPanelSurface())
    }

    private var sectionHeader: some View {
        let semantic = model.semanticUsed

        return HStack(spacing: 6) {
            Text(semantic ? "BY MEANING" : "RESULTS")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Color.secondary.opacity(semantic ? 0.92 : 0.55))
                .contentTransition(.opacity)

            Spacer(minLength: 8)

            Text("\(model.results.count)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.sectionHeaderHeight)
        .animation(.easeOut(duration: 0.18), value: semantic)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if model.semanticUsed && model.results.count < 4 {
                Text("Only the closest matches")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(model.filter == .favorite ? "⌘D  unpin" : "⌘D  pin")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text(hints)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.footerHeight)
        .animation(.easeOut(duration: 0.18), value: model.notice)
        .animation(.easeOut(duration: 0.18), value: model.semanticUsed)
    }

    private var hints: String {
        if model.filter == .favorite {
            return "↑↓  select     ↵  copy     ⌘D  unpin"
        }
        return "↑↓  select     ↵  copy     ⌘↵  paste"
    }

    private func focusField() {
        DispatchQueue.main.async {
            isFocused = true
        }
    }
}

// MARK: - Results

private struct ResultsList: View {
    @Bindable var model: PanelModel
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.rowSpacing) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { _, item in
                ResultRow(
                    item: item,
                    isSelected: item.id == model.selectedID,
                    isCopied: item.id == model.copiedID,
                    namespace: namespace
                )
                .id(item.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedID = item.id
                    model.copySelected()
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.listVerticalPadding)
        .animation(reduceMotion ? .easeOut(duration: 0.08) : Motion.selection, value: model.selectedID)
        .animation(reduceMotion ? .easeOut(duration: 0.08) : Motion.selection, value: model.results.map(\.id))
    }
}

private struct ResultRow: View {
    let item: ClipItem
    let isSelected: Bool
    let isCopied: Bool
    let namespace: Namespace.ID
    @State private var isHovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            leading
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.10) : Color.primary.opacity(0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.055),
                            lineWidth: 0.5
                        )
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayText)
                    .font(titleFont)
                    .foregroundStyle(.primary.opacity(isSelected ? 0.98 : 0.92))
                    .lineLimit(1)
                    .truncationMode(item.kind == .link ? .middle : .tail)

                Text(item.subtitle)
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundStyle(isSelected ? Color.secondary.opacity(0.82) : Color.secondary.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if item.isFavorite {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }

            if isCopied {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.primary)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if isSelected {
                Text("↵")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(width: 19, height: 17)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                            }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .help("Copy")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.rowSelection)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.5)
                    }
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.rowHover)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2.5, height: 17)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Motion.quick) { isHovering = hovering }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 3)
        .onAppear {
            guard !appeared else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.08) : Motion.selection) {
                appeared = true
            }
        }
        .animation(.easeOut(duration: 0.16), value: isCopied)
        .animation(.easeOut(duration: 0.16), value: item.isFavorite)
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }

    private var titleFont: Font {
        if item.kind == .code {
            return .system(size: 12, weight: .regular, design: .monospaced)
        }
        return .system(size: 13.5, weight: .regular)
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .image, let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(isSelected ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.7))
        }
    }
}

// MARK: - Chrome

private struct FilterButton: View {
    let filter: ItemFilter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: filter.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(filter == .all ? Color.primary.opacity(0.62) : Color.primary.opacity(0.95))
                .frame(width: 24, height: 24)
                .frame(width: Theme.filterButtonSize, height: Theme.filterButtonSize)
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.selection, value: filter)
        }
        .modifier(GlassCircleButton())
        .help("Filter · \(filter.label)")
        .accessibilityLabel("Filter, \(filter.label)")
        .accessibilityValue(filter.label)
    }
}

// MARK: - Glass surfaces

private struct GlassSearchField: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular.interactive(),
                    in: Capsule(style: .continuous)
                )
        } else {
            content
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    Color.primary.opacity(0.075),
                                    lineWidth: 0.5
                                )
                        }
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                }
                .contentShape(Capsule(style: .continuous))
        }
    }
}

private struct GlassCircleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .buttonStyle(.plain)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(0.055))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                }
                .contentShape(Circle())
        }
    }
}

private struct GlassPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(
                        cornerRadius: Theme.cornerRadius,
                        style: .continuous
                    )
                )
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }
}

// MARK: - States

private struct NoResultsRow: View {
    let isSearching: Bool
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.045))
                    .frame(width: 36, height: 36)
                Image(systemName: isSearching ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSearching ? AnyShapeStyle(Color.primary.opacity(0.9)) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeOut(duration: 0.16), value: isSearching)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isSearching ? "Searching memory" : "No close matches")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isSearching ? Color.primary.opacity(0.9) : Color.secondary)
                    .contentTransition(.opacity)
                Text(isSearching ? "Reading meaning from your history." : "Try fewer or different words.")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.16), value: isSearching)
            }

            Spacer(minLength: 8)

            if isSearching {
                TinySpinner()
                    .padding(.trailing, 22)
                    .transition(.opacity)
            } else {
                Button(action: clear) {
                    Text("Clear")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                }
                        }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: Theme.noResultsHeight)
        .animation(Motion.quick, value: isSearching)
    }
}

private struct PermissionBanner: View {
    @Bindable var model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.045))
                    .frame(width: 38, height: 38)
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Clipboard access is off")
                    .font(.system(size: 12.5, weight: .medium))
                Text("Allow Recall to remember what you copy.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Settings") { model.openPasteboardSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Button("Allow") { model.requestPasteboardAccess() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
        }
        .padding(.horizontal, 22)
        .frame(height: Theme.permissionHeight)
    }
}

// MARK: - Motion details

private struct TinySpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Circle()
                .trim(from: 0.02, to: 0.24)
                .stroke(
                    Color.primary.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(
                    reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 280
                ))
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

private struct MeaningPulse: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 2.5, height: 2.5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(time * 3.2 + Double(index) * 0.85)))
                }
            }
        }
        .frame(width: 16, height: 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
