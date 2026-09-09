import Foundation

@MainActor
final class ProviderVisibilityStore: ObservableObject {
    static let shared = ProviderVisibilityStore()
    static let selectionKey = "MacIsland.selectedProviders"
    static let singleSlotKey = "MacIsland.singleProviderSlot"

    @Published private(set) var selected: [IslandProvider]
    @Published private(set) var singleProviderSlot: Int
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        singleProviderSlot = defaults.object(forKey: Self.singleSlotKey) == nil
            ? 0 : min(1, max(0, defaults.integer(forKey: Self.singleSlotKey)))
        if let saved = defaults.stringArray(forKey: Self.selectionKey) {
            self.selected = Self.normalized(saved.compactMap(IslandProvider.init(rawValue:)))
        } else {
            let legacy: [IslandProvider] = [.claude, .codex].filter {
                defaults.object(forKey: "MacIsland.\($0.rawValue)Visible") as? Bool ?? true
            }
            self.selected = Self.normalized(legacy)
        }
        persist()
    }

    var left: IslandProvider { selected.first ?? .claude }
    var right: IslandProvider? { selected.count == 2 ? selected[1] : nil }
    var leftSlot: IslandProvider? { provider(at: 0) }
    var rightSlot: IslandProvider? { provider(at: 1) }
    var claudeVisible: Bool { selected.contains(.claude) }
    var codexVisible: Bool { selected.contains(.codex) }

    static func normalized(_ providers: [IslandProvider]) -> [IslandProvider] {
        var result: [IslandProvider] = []
        for provider in providers where !result.contains(provider) {
            result.append(provider)
            if result.count == 2 { break }
        }
        return result.isEmpty ? [.claude] : result
    }

    func set(_ provider: IslandProvider?, at slot: Int) {
        guard (0...1).contains(slot) else { return }
        guard let provider else {
            guard selected.count == 2 else { return }
            selected.remove(at: slot)
            singleProviderSlot = 1 - slot
            persist()
            return
        }
        if selected.count == 1 {
            if selected[0] == provider {
                singleProviderSlot = slot
            } else if singleProviderSlot == slot {
                selected = [provider]
            } else {
                selected = slot == 0 ? [provider, selected[0]] : [selected[0], provider]
            }
            persist()
            return
        }
        if let current = selected.firstIndex(of: provider) {
            if current != slot, selected.count == 2 { swap() }
            return
        }
        var next = selected
        if slot < next.count { next[slot] = provider } else { next.append(provider) }
        selected = Self.normalized(next)
        persist()
    }

    func swap() {
        guard selected.count == 2 else { return }
        selected.swapAt(0, 1)
        persist()
    }

    private func persist() {
        defaults.set(selected.map(\.rawValue), forKey: Self.selectionKey)
        defaults.set(singleProviderSlot, forKey: Self.singleSlotKey)
    }

    private func provider(at slot: Int) -> IslandProvider? {
        if selected.count == 2 { return selected[slot] }
        return singleProviderSlot == slot ? selected.first : nil
    }
}
