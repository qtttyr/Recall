import AppKit
import Foundation

/// The panel has exactly two postures: a single-line search bar at rest, and
/// a compact result surface while the user is looking for something. Keeping
/// this as a small value makes the window resize deterministic.
enum PanelLayout: Equatable {
    case compact
    case permission
    case noResults
    case results(Int)
}

@MainActor
@Observable
final class PanelModel {
    let store: ClipStore
    let search: SearchEngine
    let settings: AppSettings

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            runSearch()
        }
    }

    var results: [ClipItem] = []
    var selectedID: Int64?
    var filter: ItemFilter = .all
    var isVisible = false
    var isSearching = false
    var isSemanticSearching = false
    var semanticUsed = false
    var permission: PasteboardAccess = .unknown
    var notice: String?
    var copiedID: Int64?
    var focusToken = 0
    var generation = 0

    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRequestPasteboard: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    private var searchTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var copiedTask: Task<Void, Never>?

    init(store: ClipStore, search: SearchEngine, settings: AppSettings) {
        self.store = store
        self.search = search
        self.settings = settings
        self.permission = Permissions.pasteboardState()
    }

    func prepareForPresentation() {
        query = ""
        filter = .all
        notice = nil
        copiedID = nil
        permission = Permissions.pasteboardState()
        focusToken += 1
        refresh()
    }

    func refresh() {
        if !hasQuery {
            cancelSearch()
            isSearching = false
            isSemanticSearching = false
            semanticUsed = false
            results = []
            selectedID = nil
            return
        }
        runSearch()
    }

    func runSearch() {
        cancelSearch()
        let currentGeneration = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            isSearching = false
            isSemanticSearching = false
            semanticUsed = false
            results = []
            selectedID = nil
            return
        }

        let parsed = SearchQueryParser.parse(query, filter: filter)
        isSearching = true
        isSemanticSearching = false

        // A filter token on its own (#fav, #code) is a valid query, but it has
        // no words to embed. Show the newest clips of that type instead.
        if parsed.isEmpty {
            searchTask = Task { [weak self, store] in
                let items = (try? await store.recent(limit: parsed.limit, filter: parsed.filter)) ?? []
                guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
                self.semanticUsed = false
                self.apply(items)
                self.isSearching = false
            }
            return
        }

        searchTask = Task { [weak self, search] in
            let keyword = await search.keyword(parsed)
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }

            guard self.settings.semanticEnabled else {
                self.semanticUsed = false
                self.apply(keyword)
                self.isSearching = false
                return
            }

            self.isSemanticSearching = true
            self.semanticTask = Task { [weak self, search] in
                // A tiny pause keeps a fast typist from launching an embedding
                // for every intermediate keystroke.
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                let fused = await search.semantic(parsed, keyword: keyword)
                guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
                self.semanticUsed = fused.semanticUsed
                self.apply(fused.items)
                self.isSearching = false
                self.isSemanticSearching = false
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        semanticTask?.cancel()
        searchTask = nil
        semanticTask = nil
        generation += 1
    }

    private func apply(_ items: [ClipItem]) {
        let previous = selectedID
        results = items
        if let previous, items.contains(where: { $0.id == previous }) {
            selectedID = previous
        } else {
            selectedID = items.first?.id
        }
    }

    var layout: PanelLayout {
        if permission == .denied || permission == .needsPermission {
            return .permission
        }
        guard hasQuery else { return .compact }
        // While the query is alive the surface stays open. Collapsing during a
        // in-flight search would strobe open/shut on every keystroke; a stable
        // card under the moving query reads as one continuous search.
        if !results.isEmpty {
            return .results(min(results.count, SearchQuery.resultLimit))
        }
        return .noResults
    }

    var isExpanded: Bool {
        layout != .compact
    }

    var panelHeight: CGFloat {
        switch layout {
        case .compact:
            return Theme.searchHeight
        case .permission:
            return Theme.searchHeight + Theme.resultGap + Theme.permissionHeight
        case .noResults:
            return Theme.searchHeight + Theme.resultGap + Theme.noResultsHeight
        case .results(let count):
            let rows = CGFloat(count)
            let listHeight = rows * Theme.rowHeight
                + max(0, rows - 1) * Theme.rowSpacing
                + Theme.listVerticalPadding * 2
            return Theme.searchHeight
                + Theme.resultGap
                + Theme.sectionHeaderHeight
                + listHeight
                + Theme.footerHeight
        }
    }

    var searchPlaceholder: String {
        switch filter {
        case .all: "Search your memory"
        case .text: "Search text"
        case .code: "Search code"
        case .link: "Search links"
        case .image: "Search images"
        case .favorite: "Search pinned"
        }
    }

    func cycleFilter() {
        applyFilter(filter.next)
    }

    func cycleFilterBackward() {
        applyFilter(filter.previous)
    }

    private func applyFilter(_ newFilter: ItemFilter) {
        guard filter != newFilter else { return }
        setFilter(newFilter)
    }

    func setFilter(_ newFilter: ItemFilter) {
        guard filter != newFilter else { return }
        filter = newFilter
        if hasQuery {
            runSearch()
        } else {
            // At rest the panel stays a single line. The selected circle is the
            // feedback; the placeholder tells the user what will be searched.
            refresh()
        }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    func selectFirst() {
        selectedID = results.first?.id
    }

    func clearQuery() {
        query = ""
        focusToken += 1
    }

    var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func copySelected(andPaste: Bool = false, keepOpen: Bool = false) {
        guard let item = results.first(where: { $0.id == selectedID }) ?? results.first else { return }
        guard PasteboardWriter.copy(item) else { return }

        haptic()
        copiedID = item.id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.copiedID = nil }
        }

        Task { [store] in
            try? await store.touch(id: item.id)
        }

        guard !keepOpen else { return }

        if andPaste {
            guard Permissions.isAccessibilityTrusted else {
                Permissions.requestAccessibility()
                showNotice("Copied. Allow Accessibility to paste automatically.", duration: .seconds(4))
                return
            }
            onClose?()
            Task {
                try? await Task.sleep(for: .milliseconds(90))
                Paster.paste()
            }
        } else {
            onClose?()
        }
    }

    func toggleFavorite() {
        guard let item = results.first(where: { $0.id == selectedID }) else { return }
        Task { [weak self, store] in
            try? await store.setFavorite(id: item.id, favorite: !item.isFavorite)
            guard let self else { return }
            self.refresh()
        }
    }

    func deleteSelected() {
        guard let item = results.first(where: { $0.id == selectedID }) else { return }
        Task { [weak self, store] in
            try? await store.delete(id: item.id)
            guard let self else { return }
            let index = self.results.firstIndex { $0.id == item.id } ?? 0
            self.results.removeAll { $0.id == item.id }
            if self.results.isEmpty {
                self.selectedID = nil
            } else {
                self.selectedID = self.results[min(index, self.results.count - 1)].id
            }
        }
    }

    func requestPasteboardAccess() {
        permission = Permissions.requestPasteboardAccess()
        if permission == .allowed {
            showNotice("Clipboard access is on.", duration: .seconds(1.4))
        }
    }

    func refreshPermission() {
        permission = Permissions.pasteboardState()
    }

    func openSettings() { onOpenSettings?() }
    func openPasteboardSettings() { Permissions.openPasteboardSettings() }
    func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }
    func close() { onClose?() }

    func showNotice(_ text: String, duration: Duration = .seconds(2)) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.notice = nil }
        }
    }

    private func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
