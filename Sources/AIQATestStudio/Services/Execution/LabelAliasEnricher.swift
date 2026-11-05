import Foundation

/// Adds the other-language texts of every label locator as fallbacks, so a case written with Japanese design text
/// ("現在の注文") also matches what the Simulator really shows ("Current Orders"). The first locator stays the author's own text.
enum LabelAliasEnricher {
    static func enrich(_ cases: [PlannedCase], index: LocalizationIndex) -> [PlannedCase] {
        cases.map { planned in
            var copy = planned
            copy.actions = planned.actions.map { action in
                guard let target = action.target, target.strategy == .label || target.strategy == .name else { return action }
                var enriched = action
                var known = Set(action.allLocators)
                for alias in index.aliases(for: target.value) {
                    let locator = Locator(strategy: .label, value: alias)
                    if known.insert(locator).inserted { enriched.fallbackTargets.append(locator) }
                }
                return enriched
            }
            return copy
        }
    }
}
