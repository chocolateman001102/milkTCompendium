import Foundation

struct CompendiumComparison {
    let localOwnerName: String
    let peerOwnerID: String
    let peerOwnerName: String
    let localNodes: [ComparisonDrinkNode]
    let peerNodes: [ComparisonDrinkNode]
    let pairs: [ComparisonDrinkPair]
    let localOnlyCount: Int
    let peerOnlyCount: Int
    let matchedCount: Int

    var isEmpty: Bool {
        localNodes.isEmpty && peerNodes.isEmpty
    }
}

enum ComparisonSide: String {
    case local
    case peer
}

struct ComparisonDrinkNode: Identifiable {
    let id: String
    let side: ComparisonSide
    let productKey: String
    let representative: LadderDrinkDisplayItem
    let items: [LadderDrinkDisplayItem]
    let aggregateRating: Double
    let totalCupCount: Int
    let consumedCount: Int
    let matchedPairID: String?

    var displayBrand: String {
        let cleaned = representative.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未知品牌" : cleaned
    }

    var displayName: String {
        let cleaned = representative.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }
}

struct ComparisonDrinkPair: Identifiable {
    let id: String
    let productKey: String
    let local: ComparisonDrinkNode
    let peer: ComparisonDrinkNode
    let ratingDelta: Double
    let colorIndex: Int
}

enum ComparisonDisplayMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case matched = "共同"
    case different = "差异"

    var id: String { rawValue }
}

enum CompendiumComparisonBuilder {
    static func build(
        localDrinks: [Drink],
        sharedCompendium: SharedCompendium,
        localOwnerName: String = "我的"
    ) -> CompendiumComparison {
        let localItems = localDrinks.map(LadderDrinkDisplayItem.init(drink:))
        let peerItems = sharedCompendium.drinks.map {
            LadderDrinkDisplayItem(sharedDrink: $0, ownerID: sharedCompendium.ownerID)
        }

        let localGroups = Dictionary(grouping: localItems, by: DrinkProductMatcher.productKey(for:))
            .filter { !$0.key.isEmpty }
        let peerGroups = Dictionary(grouping: peerItems, by: DrinkProductMatcher.productKey(for:))
            .filter { !$0.key.isEmpty }

        let matchedKeys = Set(localGroups.keys).intersection(peerGroups.keys)
        var localOnlyKeys = Set(localGroups.keys).subtracting(matchedKeys)
        var peerOnlyKeys = Set(peerGroups.keys).subtracting(matchedKeys)
        var fallbackMatches: [(localKey: String, peerKey: String)] = []

        for localKey in localOnlyKeys.sorted() {
            guard let localRepresentative = localGroups[localKey]?.first else { continue }
            if let peerKey = peerOnlyKeys.sorted().first(where: { peerKey in
                guard let peerRepresentative = peerGroups[peerKey]?.first else { return false }
                return DrinkProductMatcher.isConservativeFallbackMatch(localRepresentative, peerRepresentative)
            }) {
                fallbackMatches.append((localKey, peerKey))
                localOnlyKeys.remove(localKey)
                peerOnlyKeys.remove(peerKey)
            }
        }

        var localNodesByKey: [String: ComparisonDrinkNode] = [:]
        var peerNodesByKey: [String: ComparisonDrinkNode] = [:]
        var pairs: [ComparisonDrinkPair] = []

        for key in matchedKeys.sorted() {
            guard let localItems = localGroups[key], let peerItems = peerGroups[key] else { continue }
            let pairID = "pair-\(key)"
            let localNode = makeNode(side: .local, key: key, items: localItems, pairID: pairID)
            let peerNode = makeNode(side: .peer, key: key, items: peerItems, pairID: pairID)
            localNodesByKey[key] = localNode
            peerNodesByKey[key] = peerNode
            pairs.append(makePair(id: pairID, key: key, local: localNode, peer: peerNode))
        }

        for match in fallbackMatches {
            guard let localItems = localGroups[match.localKey], let peerItems = peerGroups[match.peerKey] else { continue }
            let pairKey = match.localKey
            let pairID = "pair-\(pairKey)"
            let localNode = makeNode(side: .local, key: pairKey, items: localItems, pairID: pairID)
            let peerNode = makeNode(side: .peer, key: pairKey, items: peerItems, pairID: pairID)
            localNodesByKey[pairKey] = localNode
            peerNodesByKey[pairKey] = peerNode
            pairs.append(makePair(id: pairID, key: pairKey, local: localNode, peer: peerNode))
        }

        for key in localOnlyKeys.sorted() {
            guard let items = localGroups[key] else { continue }
            localNodesByKey[key] = makeNode(side: .local, key: key, items: items, pairID: nil)
        }

        for key in peerOnlyKeys.sorted() {
            guard let items = peerGroups[key] else { continue }
            peerNodesByKey[key] = makeNode(side: .peer, key: key, items: items, pairID: nil)
        }

        let localNodes = localNodesByKey.values.sorted(by: nodeSort)
        let peerNodes = peerNodesByKey.values.sorted(by: nodeSort)
        pairs.sort { first, second in
            if first.local.aggregateRating == second.local.aggregateRating {
                return first.local.displayName.localizedStandardCompare(second.local.displayName) == .orderedAscending
            }
            return first.local.aggregateRating > second.local.aggregateRating
        }

        return CompendiumComparison(
            localOwnerName: localOwnerName,
            peerOwnerID: sharedCompendium.ownerID,
            peerOwnerName: sharedCompendium.ownerName,
            localNodes: localNodes,
            peerNodes: peerNodes,
            pairs: pairs,
            localOnlyCount: localOnlyKeys.count,
            peerOnlyCount: peerOnlyKeys.count,
            matchedCount: pairs.count
        )
    }

    private static func makeNode(
        side: ComparisonSide,
        key: String,
        items: [LadderDrinkDisplayItem],
        pairID: String?
    ) -> ComparisonDrinkNode {
        let sortedItems = items.sorted { first, second in
            if first.consumedAt == second.consumedAt {
                return first.createdAt > second.createdAt
            }
            return first.consumedAt > second.consumedAt
        }
        let totalCupCount = sortedItems.reduce(0) { $0 + max(1, $1.cupCount) }
        let weightedScore = sortedItems.reduce(0) { partial, item in
            partial + item.rating * Double(max(1, item.cupCount))
        }
        let aggregateRating = totalCupCount > 0 ? weightedScore / Double(totalCupCount) : (sortedItems.first?.rating ?? 0)
        let representative = sortedItems.first ?? items[0]
        return ComparisonDrinkNode(
            id: "\(side.rawValue)-\(key)",
            side: side,
            productKey: key,
            representative: representative,
            items: sortedItems,
            aggregateRating: min(5, max(0, aggregateRating)),
            totalCupCount: max(1, totalCupCount),
            consumedCount: sortedItems.count,
            matchedPairID: pairID
        )
    }

    private static func makePair(
        id: String,
        key: String,
        local: ComparisonDrinkNode,
        peer: ComparisonDrinkNode
    ) -> ComparisonDrinkPair {
        ComparisonDrinkPair(
            id: id,
            productKey: key,
            local: local,
            peer: peer,
            ratingDelta: abs(local.aggregateRating - peer.aggregateRating),
            colorIndex: stableColorIndex(for: key)
        )
    }

    private static func stableColorIndex(for key: String) -> Int {
        key.unicodeScalars.reduce(0) { partial, scalar in
            ((partial &* 31) &+ Int(scalar.value)) & 0x7fffffff
        }
    }

    private static func nodeSort(_ first: ComparisonDrinkNode, _ second: ComparisonDrinkNode) -> Bool {
        if first.aggregateRating == second.aggregateRating {
            return first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
        }
        return first.aggregateRating > second.aggregateRating
    }
}

enum DrinkProductMatcher {
    static func productKey(for item: LadderDrinkDisplayItem) -> String {
        let brand = normalizedToken(item.brand)
        let name = normalizedToken(item.name)
        if brand.isEmpty && name.isEmpty { return "" }
        return "\(brand)#\(name)"
    }

    static func isConservativeFallbackMatch(_ first: LadderDrinkDisplayItem, _ second: LadderDrinkDisplayItem) -> Bool {
        let firstName = normalizedToken(first.name)
        let secondName = normalizedToken(second.name)
        guard !firstName.isEmpty, firstName == secondName else { return false }

        let firstBrand = normalizedToken(first.brand)
        let secondBrand = normalizedToken(second.brand)
        guard !firstBrand.isEmpty, !secondBrand.isEmpty else { return true }
        return firstBrand == secondBrand || firstBrand.contains(secondBrand) || secondBrand.contains(firstBrand)
    }

    private static func normalizedToken(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isNewline && !$0.isPunctuation && !$0.isSymbol }
    }
}
