import Foundation
import Observation

// Drives the Sources tab: which external provider is selected, its online state, and a
// paginated, keyword-filterable page of asset cards. UI-only; imports go through ToolExecutor.
@MainActor
@Observable
final class SourceBrowserModel {
    struct ProviderState: Identifiable {
        let id: String
        let label: String
        let capabilities: [AssetType]
        var online: Bool?          // nil = not yet probed
    }

    private(set) var providers: [ProviderState] = AssetProviderRegistry.providers.map {
        ProviderState(id: $0.id, label: $0.label,
                      capabilities: $0.capabilities.sorted { $0.rawValue < $1.rawValue }, online: nil)
    }
    var selectedId: String? = AssetProviderRegistry.providers.first?.id
    private(set) var activeType: AssetType? = AssetProviderRegistry.providers.first?
        .capabilities.sorted { $0.rawValue < $1.rawValue }.first

    var searchText: String = ""
    private(set) var items: [AssetCard] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private var page = 1

    var selected: ProviderState? { providers.first { $0.id == selectedId } }

    // Types the selected provider offers, in a stable order for the picker.
    var availableTypes: [AssetType] {
        let order: [AssetType] = [.video, .image, .music, .sfx]
        let caps = selected?.capabilities ?? []
        return order.filter(caps.contains)
    }

    func refreshHealth() async {
        await withTaskGroup(of: (String, Bool).self) { group in
            for p in AssetProviderRegistry.providers {
                group.addTask { (p.id, await p.health()) }
            }
            for await (id, ok) in group {
                if let idx = providers.firstIndex(where: { $0.id == id }) { providers[idx].online = ok }
            }
        }
    }

    func select(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        activeType = availableTypes.first
        Task { await reload() }
    }

    func selectType(_ type: AssetType) {
        guard type != activeType else { return }
        activeType = type
        Task { await reload() }
    }

    func reload() async {
        page = 1
        hasLoaded = false
        await load(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        page += 1
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard let provider = selectedId.flatMap(AssetProviderRegistry.provider),
              let type = activeType else {
            items = []; hasMore = false; hasLoaded = true; return
        }
        isLoading = true
        loadError = nil
        let keys = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        do {
            let result = try await provider.list(type, query: ListQuery(keys: keys, page: page, limit: 30))
            if reset { items = result.items } else { items.append(contentsOf: result.items) }
            hasMore = result.hasMore
            if let idx = providers.firstIndex(where: { $0.id == provider.id }) { providers[idx].online = true }
        } catch {
            if reset { items = [] }
            hasMore = false
            loadError = error.localizedDescription
            if let idx = providers.firstIndex(where: { $0.id == provider.id }) { providers[idx].online = false }
        }
        isLoading = false
        hasLoaded = true
    }
}
