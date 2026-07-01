import SwiftUI
import UIKit

struct CompendiumComparisonView: View {
    let localDrinks: [Drink]
    let sharedCompendiums: [SharedCompendium]
    let initialOwnerID: String
    let localOwnerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOwnerID: String
    @State private var orderedSharedOwnerIDs: [String]
    @State private var selectedEntry: ComparisonLadderNodeEntry?

    init(
        localDrinks: [Drink],
        sharedCompendiums: [SharedCompendium],
        initialOwnerID: String,
        localOwnerName: String
    ) {
        self.localDrinks = localDrinks
        self.sharedCompendiums = sharedCompendiums
        self.initialOwnerID = initialOwnerID
        self.localOwnerName = localOwnerName
        let shuffledOwnerIDs = Self.shuffledOwnerIDs(sharedCompendiums: sharedCompendiums, preferredFirstOwnerID: initialOwnerID)
        _selectedOwnerID = State(initialValue: initialOwnerID)
        _orderedSharedOwnerIDs = State(initialValue: shuffledOwnerIDs)
    }

    private var orderedSharedCompendiums: [SharedCompendium] {
        let byOwnerID = Dictionary(uniqueKeysWithValues: sharedCompendiums.map { ($0.ownerID, $0) })
        let ordered = orderedSharedOwnerIDs.compactMap { byOwnerID[$0] }
        let missing = sharedCompendiums.filter { compendium in
            !orderedSharedOwnerIDs.contains(compendium.ownerID)
        }
        return ordered + missing
    }

    private var comparisonOwners: [ComparisonOwnerColumn] {
        let owners: [ComparisonOwnerSource] = [.local(localOwnerName)] + orderedSharedCompendiums.map { .shared($0) }
        let groupsByOwner = matchedGroups(for: owners)
        let sharedKeys = groupsByOwner
            .flatMap { $0.1.keys }
            .reduce(into: [:]) { counts, key in counts[key, default: 0] += 1 }
            .filter { $0.value >= 2 }
            .map(\.key)
        let sharedKeySet = Set(sharedKeys)

        return groupsByOwner.map { owner, groups in
            let nodes = groups
                .filter { sharedKeySet.contains($0.key) }
                .map { key, items in
                    makeNode(
                        owner: owner,
                        key: key,
                        items: items
                    )
                }
                .sorted { first, second in
                    if first.aggregateRating == second.aggregateRating {
                        return first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
                    }
                    return first.aggregateRating > second.aggregateRating
                }
            return ComparisonOwnerColumn(id: owner.id, name: owner.name, nodes: nodes)
        }
        .filter { !$0.nodes.isEmpty }
        .map { $0 }
    }

    private var comparisonPartyMembers: [PixelPartyMember] {
        let localMember = PixelPartyMember(
            id: "local-\(SharedCompendiumStore.localOwnerID)",
            name: localOwnerName,
            pixelPerson: PixelPersonProfile.make(
                ownerID: SharedCompendiumStore.localOwnerID,
                ownerName: localOwnerName,
                profile: TasteScoreCalculator.profile(from: localDrinks)
            ),
            isFocused: false
        )
        let sharedMembers = orderedSharedCompendiums.map { compendium in
            PixelPartyMember(
                id: compendium.ownerID,
                name: compendium.ownerName,
                pixelPerson: compendium.pixelPerson ?? PixelPersonProfile.make(
                    ownerID: compendium.ownerID,
                    ownerName: compendium.ownerName,
                    profile: TasteScoreCalculator.profile(from: compendium)
                ),
                isFocused: compendium.ownerID == selectedOwnerID
            )
        }
        return [localMember] + sharedMembers
    }

    private static func shuffledOwnerIDs(
        sharedCompendiums: [SharedCompendium],
        preferredFirstOwnerID: String
    ) -> [String] {
        let ids = sharedCompendiums.map(\.ownerID)
        guard !ids.isEmpty else { return [] }
        var shuffled = ids.shuffled()
        if let preferredIndex = shuffled.firstIndex(of: preferredFirstOwnerID) {
            let preferred = shuffled.remove(at: preferredIndex)
            shuffled.insert(preferred, at: 0)
        }
        return shuffled
    }

    private func moveSharedOwnerToFront(_ ownerID: String) {
        guard let index = orderedSharedOwnerIDs.firstIndex(of: ownerID), index != 0 else { return }
        var ids = orderedSharedOwnerIDs
        let owner = ids.remove(at: index)
        ids.insert(owner, at: 0)
        applySharedOwnerOrder(ids)
    }

    private func moveSharedOwner(_ ownerID: String, by offset: Int) {
        guard let index = orderedSharedOwnerIDs.firstIndex(of: ownerID) else { return }
        let targetIndex = min(max(index + offset, 0), orderedSharedOwnerIDs.count - 1)
        guard targetIndex != index else { return }
        var ids = orderedSharedOwnerIDs
        let owner = ids.remove(at: index)
        ids.insert(owner, at: targetIndex)
        applySharedOwnerOrder(ids)
    }

    private func shuffleSharedOwnerOrder() {
        applySharedOwnerOrder(orderedSharedOwnerIDs.shuffled())
    }

    private func applySharedOwnerOrder(_ ownerIDs: [String]) {
        orderedSharedOwnerIDs = ownerIDs
        selectedOwnerID = ownerIDs.first ?? initialOwnerID
        selectedEntry = nil
    }

    private func overlayRows(
        for selectedEntry: ComparisonLadderNodeEntry,
        owners: [ComparisonOwnerColumn]
    ) -> [ComparisonOverlayRow] {
        owners.enumerated().map { index, owner in
            ComparisonOverlayRow(
                id: owner.id,
                ownerName: owner.name,
                node: owner.nodes.first { $0.productKey == selectedEntry.node.productKey },
                accent: ComparisonOwnerPalette.color(index: index),
                isFocused: owner.id == selectedEntry.ownerID
            )
        }
    }

    private func matchedGroups(
        for owners: [ComparisonOwnerSource]
    ) -> [(ComparisonOwnerSource, [String: [LadderDrinkDisplayItem]])] {
        var rawGroupsByOwner: [(ComparisonOwnerSource, [RawComparisonProductGroup])] = []
        rawGroupsByOwner.reserveCapacity(owners.count)

        for (ownerIndex, owner) in owners.enumerated() {
            let items: [LadderDrinkDisplayItem] = switch owner {
            case .local:
                localDrinks.map(LadderDrinkDisplayItem.init(drink:))
            case .shared(let compendium):
                compendium.drinks.map { LadderDrinkDisplayItem(sharedDrink: $0, ownerID: compendium.ownerID) }
            }
            let groups = Dictionary(grouping: items, by: DrinkProductMatcher.productKey(for:))
                .filter { !$0.key.isEmpty }
                .map { key, items in
                    let representative = representativeItem(from: items)
                    return RawComparisonProductGroup(
                        ownerIndex: ownerIndex,
                        key: key,
                        items: items,
                        representative: representative,
                        fallbackNameKey: representative.map(DrinkProductMatcher.normalizedName(for:)) ?? "",
                        fallbackBrandKey: representative.map(DrinkProductMatcher.normalizedBrand(for:)) ?? ""
                    )
                }
            rawGroupsByOwner.append((owner, groups))
        }
        let rawGroups = rawGroupsByOwner.flatMap(\.1)
        let canonicalKeyByRawGroup = canonicalProductKeys(for: rawGroups)

        return rawGroupsByOwner.map { owner, groups in
            var canonicalGroups: [String: [LadderDrinkDisplayItem]] = [:]
            for group in groups {
                let canonicalKey = canonicalKeyByRawGroup[group.id] ?? group.key
                canonicalGroups[canonicalKey, default: []].append(contentsOf: group.items)
            }
            return (owner, canonicalGroups)
        }
    }

    private func representativeItem(from items: [LadderDrinkDisplayItem]) -> LadderDrinkDisplayItem? {
        items.sorted { first, second in
            if first.consumedAt == second.consumedAt {
                return first.createdAt > second.createdAt
            }
            return first.consumedAt > second.consumedAt
        }.first
    }

    private func canonicalProductKeys(for groups: [RawComparisonProductGroup]) -> [String: String] {
        var parent = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.id) })
        var ownerIndexesByRoot = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Set([$0.ownerIndex])) })

        func root(_ id: String) -> String {
            var current = id
            var path: [String] = []
            while parent[current] != current, let next = parent[current] {
                path.append(current)
                current = next
            }
            for node in path {
                parent[node] = current
            }
            return current
        }

        func union(_ first: String, _ second: String) {
            var firstRoot = root(first)
            var secondRoot = root(second)
            guard firstRoot != secondRoot else { return }
            guard var firstOwnerIndexes = ownerIndexesByRoot[firstRoot],
                  let secondOwnerIndexes = ownerIndexesByRoot[secondRoot],
                  firstOwnerIndexes.isDisjoint(with: secondOwnerIndexes) else { return }
            if firstOwnerIndexes.count < secondOwnerIndexes.count {
                swap(&firstRoot, &secondRoot)
                firstOwnerIndexes = secondOwnerIndexes
            }
            parent[secondRoot] = firstRoot
            firstOwnerIndexes.formUnion(ownerIndexesByRoot[secondRoot] ?? [])
            ownerIndexesByRoot[firstRoot] = firstOwnerIndexes
            ownerIndexesByRoot[secondRoot] = nil
        }

        for sameKeyGroups in Dictionary(grouping: groups, by: \.key).values {
            for leftIndex in sameKeyGroups.indices {
                for rightIndex in sameKeyGroups.indices where rightIndex > leftIndex {
                    let left = sameKeyGroups[leftIndex]
                    let right = sameKeyGroups[rightIndex]
                    guard left.ownerIndex != right.ownerIndex else { continue }
                    union(left.id, right.id)
                }
            }
        }

        let fallbackGroupsByName = Dictionary(grouping: groups.filter { !$0.fallbackNameKey.isEmpty }, by: \.fallbackNameKey)
        for sameNameGroups in fallbackGroupsByName.values {
            for leftIndex in sameNameGroups.indices {
                for rightIndex in sameNameGroups.indices where rightIndex > leftIndex {
                    let left = sameNameGroups[leftIndex]
                    let right = sameNameGroups[rightIndex]
                    guard left.ownerIndex != right.ownerIndex,
                          left.key != right.key,
                          DrinkProductMatcher.areFallbackBrandsCompatible(left.fallbackBrandKey, right.fallbackBrandKey) else { continue }
                    union(left.id, right.id)
                }
            }
        }

        let groupsByRoot = Dictionary(grouping: groups, by: { root($0.id) })
        let canonicalKeyByRoot = groupsByRoot.mapValues { componentGroups in
            componentGroups
                .map(\.key)
                .sorted { first, second in
                    if first.count == second.count {
                        return first.localizedStandardCompare(second) == .orderedAscending
                    }
                    return first.count < second.count
                }
                .first ?? ""
        }

        return Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.id, canonicalKeyByRoot[root(group.id)] ?? group.key)
        })
    }

    var body: some View {
        let owners = comparisonOwners
        let rows = comparisonRows(owners: owners)
        let matchedProductCount = rows.count
        let partyMembers = comparisonPartyMembers
        ZStack(alignment: .top) {
            if owners.count < 2 || matchedProductCount == 0 {
                emptyState(title: "还没有共同喝过", subtitle: "至少需要两个人记录过同一款饮品。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                comparisonScoreBands(rows: rows)
            }

            header(matchedProductCount: matchedProductCount, partyMembers: partyMembers)
                .padding(.horizontal, 14)
                .padding(.top, 10)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if let selectedEntry {
                ComparisonDrinkCardOverlay(
                    selectedEntry: selectedEntry,
                    rows: overlayRows(for: selectedEntry, owners: owners),
                    onClose: {
                        withAnimation(.easeOut(duration: 0.12)) {
                            self.selectedEntry = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(30)
            }
        }
    }

    private func comparisonScoreBands(rows: [ComparisonSharedDrinkRow]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    ComparisonSharedDrinkRowView(
                        row: row,
                        isSelected: selectedEntry?.node.productKey == row.productKey
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeOut(duration: 0.12)) {
                            selectedEntry = row.selectedEntry
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 136)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .accessibilityLabel("共饮评分带")
    }

    private func header(matchedProductCount: Int, partyMembers: [PixelPartyMember]) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.055))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        shuffleSharedOwnerOrder()
                    } label: {
                        Label("随机重排", systemImage: "shuffle")
                    }

                    Divider()

                    ForEach(Array(orderedSharedCompendiums.enumerated()), id: \.element.ownerID) { index, compendium in
                        Menu {
                            Button {
                                moveSharedOwnerToFront(compendium.ownerID)
                            } label: {
                                Label("移到最前", systemImage: "arrow.up.to.line")
                            }
                            .disabled(index == 0)

                            Button {
                                moveSharedOwner(compendium.ownerID, by: -1)
                            } label: {
                                Label("前移", systemImage: "arrow.up")
                            }
                            .disabled(index == 0)

                            Button {
                                moveSharedOwner(compendium.ownerID, by: 1)
                            } label: {
                                Label("后移", systemImage: "arrow.down")
                            }
                            .disabled(index == orderedSharedCompendiums.count - 1)
                        } label: {
                            Text("\(index + 1). \(compendium.ownerName)")
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            PixelPartyLineView(members: partyMembers, maxVisible: 10)
                                .frame(height: 42)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(matchedProductCount) 款共同饮品 · \(partyMembers.count) 人")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        .frame(maxWidth: 560)
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.and.right.circle")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline.weight(.black))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
    }

    private func comparisonRows(owners: [ComparisonOwnerColumn]) -> [ComparisonSharedDrinkRow] {
        let productKeys = Set(owners.flatMap { $0.nodes.map(\.productKey) })
        return productKeys.compactMap { productKey in
            let participants = owners.enumerated().compactMap { ownerIndex, owner -> ComparisonParticipantScore? in
                guard let node = owner.nodes.first(where: { $0.productKey == productKey }) else { return nil }
                let entry = comparisonEntry(
                    node: node,
                    owner: owner,
                    ownerIndex: ownerIndex
                )
                return ComparisonParticipantScore(
                    id: entry.id,
                    ownerID: owner.id,
                    ownerIndex: ownerIndex,
                    ownerName: owner.name,
                    rating: node.aggregateRating,
                    color: ComparisonOwnerPalette.scorePointColor(index: ownerIndex),
                    node: node,
                    entry: entry
                )
            }
            guard participants.count >= 2,
                  let representative = participants.first?.node else {
                return nil
            }
            let ratings = participants.map(\.rating)
            let average = ratings.reduce(0, +) / Double(ratings.count)
            let standardDeviation = ratingStandardDeviation(ratings: ratings, average: average)
            let lowest = ratings.min() ?? average
            let highest = ratings.max() ?? average
            return ComparisonSharedDrinkRow(
                id: productKey,
                productKey: productKey,
                displayBrand: representative.displayBrand,
                displayName: representative.displayName,
                representative: representative.representative,
                participants: participants,
                averageRating: average,
                lowestRating: lowest,
                highestRating: highest,
                ratingStandardDeviation: standardDeviation,
                totalCupCount: participants.reduce(0) { $0 + $1.node.totalCupCount },
                selectedEntry: participants[0].entry
            )
        }
        .sorted { first, second in
            if abs(first.averageRating - second.averageRating) > 0.0001 {
                return first.averageRating > second.averageRating
            }
            if abs(first.ratingStandardDeviation - second.ratingStandardDeviation) > 0.0001 {
                return first.ratingStandardDeviation > second.ratingStandardDeviation
            }
            let nameComparison = first.displayName.localizedStandardCompare(second.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return first.displayBrand.localizedStandardCompare(second.displayBrand) == .orderedAscending
        }
    }

    private func ratingStandardDeviation(ratings: [Double], average: Double) -> Double {
        guard !ratings.isEmpty else { return 0 }
        let variance = ratings.reduce(0) { partial, rating in
            let delta = rating - average
            return partial + delta * delta
        } / Double(ratings.count)
        return sqrt(variance)
    }

    private func comparisonEntry(
        node: ComparisonDrinkNode,
        owner: ComparisonOwnerColumn,
        ownerIndex: Int
    ) -> ComparisonLadderNodeEntry {
        ComparisonLadderNodeEntry(
            id: node.id,
            node: node,
            position: .zero,
            ownerID: owner.id,
            ownerIndex: ownerIndex,
            ownerName: owner.name,
            clusterID: "\(owner.id)-\(node.productKey)",
            clusterCount: 1,
            clusterIndex: 0,
            isClusterExpanded: true,
            isClusterRepresentative: true,
            accessibilityLabel: "\(owner.name)，\(node.displayBrand)，\(node.displayName)，评分 \(String(format: "%.2f", node.aggregateRating))"
        )
    }

    private func makeNode(
        owner: ComparisonOwnerSource,
        key: String,
        items: [LadderDrinkDisplayItem]
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
            id: "\(owner.id)-\(key)",
            side: owner.isLocal ? .local : .peer,
            productKey: key,
            representative: representative,
            items: sortedItems,
            aggregateRating: min(5, max(0, aggregateRating)),
            totalCupCount: max(1, totalCupCount),
            consumedCount: sortedItems.count,
            matchedPairID: nil
        )
    }
}

private enum ComparisonOwnerSource {
    case local(String)
    case shared(SharedCompendium)

    var id: String {
        switch self {
        case .local:
            return "local"
        case .shared(let compendium):
            return "shared-\(compendium.ownerID)"
        }
    }

    var name: String {
        switch self {
        case .local(let name):
            return name
        case .shared(let compendium):
            return compendium.ownerName
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

private struct ComparisonOwnerColumn: Identifiable {
    let id: String
    let name: String
    let nodes: [ComparisonDrinkNode]
}

private struct RawComparisonProductGroup: Identifiable {
    let ownerIndex: Int
    let key: String
    let items: [LadderDrinkDisplayItem]
    let representative: LadderDrinkDisplayItem?
    let fallbackNameKey: String
    let fallbackBrandKey: String

    var id: String {
        "\(ownerIndex)#\(key)"
    }
}

private enum ComparisonOwnerPalette {
    private static let localScoreUIColor = UIColor(red: 0.13, green: 0.46, blue: 0.31, alpha: 1)
    private static let peerScoreUIColor = UIColor(red: 0.58, green: 0.56, blue: 0.52, alpha: 1)
    private static let uiColors = [
        UIColor(red: 0.52, green: 0.38, blue: 0.25, alpha: 1),
        UIColor(red: 0.28, green: 0.50, blue: 0.34, alpha: 1),
        UIColor(red: 0.72, green: 0.54, blue: 0.18, alpha: 1),
        UIColor(red: 0.68, green: 0.32, blue: 0.31, alpha: 1),
        UIColor(red: 0.36, green: 0.55, blue: 0.45, alpha: 1),
        UIColor(red: 0.58, green: 0.42, blue: 0.30, alpha: 1),
        UIColor(red: 0.50, green: 0.49, blue: 0.25, alpha: 1),
        UIColor(red: 0.62, green: 0.39, blue: 0.20, alpha: 1)
    ]

    static func uiColor(index: Int) -> UIColor {
        uiColors[max(0, index) % uiColors.count]
    }

    static func color(index: Int) -> Color {
        Color(uiColor(index: index))
    }

    static func scorePointColor(index: Int) -> Color {
        Color(index == 0 ? localScoreUIColor : peerScoreUIColor)
    }
}

private struct ComparisonSharedDrinkRow: Identifiable {
    let id: String
    let productKey: String
    let displayBrand: String
    let displayName: String
    let representative: LadderDrinkDisplayItem
    let participants: [ComparisonParticipantScore]
    let averageRating: Double
    let lowestRating: Double
    let highestRating: Double
    let ratingStandardDeviation: Double
    let totalCupCount: Int
    let selectedEntry: ComparisonLadderNodeEntry
}

private struct ComparisonParticipantScore: Identifiable {
    let id: String
    let ownerID: String
    let ownerIndex: Int
    let ownerName: String
    let rating: Double
    let color: Color
    let node: ComparisonDrinkNode
    let entry: ComparisonLadderNodeEntry
}

private struct ComparisonSharedDrinkRowView: View {
    let row: ComparisonSharedDrinkRow
    let isSelected: Bool
    let onTap: () -> Void

    private var standardDeviationColor: Color {
        Self.standardDeviationColor(for: row.ratingStandardDeviation)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(row.displayBrand)
                            .font(.system(size: 8.8, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Text(String(format: "%.2f", row.averageRating))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.82))
                        .frame(width: 34, alignment: .trailing)
                }

                ComparisonScoreBandView(
                    participants: row.participants,
                    averageRating: row.averageRating,
                    lowestRating: row.lowestRating,
                    highestRating: row.highestRating,
                    standardDeviationColor: standardDeviationColor
                )
                .frame(height: 18)
            }
            .padding(.vertical, 3.5)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(standardDeviationColor.opacity(0.84))
                        .frame(width: 2, height: 30)
                        .offset(x: -7)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.displayBrand)，\(row.displayName)，均分 \(String(format: "%.2f", row.averageRating))，标准差 \(String(format: "%.2f", row.ratingStandardDeviation))")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(standardDeviationColor.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(standardDeviationColor.opacity(0.16), lineWidth: 0.8)
                )
        } else {
            Color.clear
        }
    }

    static func standardDeviationColor(for standardDeviation: Double) -> Color {
        switch standardDeviation {
        case 1.10...:
            return Color(red: 0.86, green: 0.12, blue: 0.19)
        case 0.60..<1.10:
            return Color(red: 0.91, green: 0.62, blue: 0.06)
        default:
            return Color(red: 0.10, green: 0.57, blue: 0.31)
        }
    }
}

private struct ComparisonScoreBandView: View {
    let participants: [ComparisonParticipantScore]
    let averageRating: Double
    let lowestRating: Double
    let highestRating: Double
    let standardDeviationColor: Color

    private let pointSize: CGFloat = 8
    private let clusterThreshold: CGFloat = 0.18

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let trackStart = pointSize / 2
            let trackWidth = max(1, width - pointSize)
            let centerY = proxy.size.height * 0.50
            let pointGroups = scorePointGroups(width: width)
            let lowX = trackStart + CGFloat(clampedRating(lowestRating)) / 5 * trackWidth
            let highX = trackStart + CGFloat(clampedRating(highestRating)) / 5 * trackWidth
            let rangeWidth = max(4, highX - lowX)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(standardDeviationColor.opacity(0.08))
                    .frame(width: rangeWidth + 12, height: 10)
                    .position(x: (lowX + highX) / 2, y: centerY)
                    .blur(radius: 3)

                Capsule()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: trackWidth, height: 1.2)
                    .position(x: trackStart + trackWidth / 2, y: centerY)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                standardDeviationColor.opacity(0.08),
                                standardDeviationColor.opacity(0.58),
                                standardDeviationColor.opacity(0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: rangeWidth, height: 2.2)
                    .position(x: (lowX + highX) / 2, y: centerY)

                ForEach([0, 1, 2, 3, 4, 5], id: \.self) { score in
                    Circle()
                        .fill(Color.black.opacity(score == 0 || score == 5 ? 0.16 : 0.09))
                        .frame(width: score == 0 || score == 5 ? 2.2 : 1.6, height: score == 0 || score == 5 ? 2.2 : 1.6)
                        .position(x: trackStart + CGFloat(score) / 5 * trackWidth, y: centerY)
                }

                Capsule()
                    .fill(standardDeviationColor.opacity(0.78))
                    .frame(width: 1.4, height: 11)
                    .position(x: trackStart + CGFloat(clampedRating(averageRating)) / 5 * trackWidth, y: centerY)

                ForEach(pointGroups) { group in
                    if group.isAggregate {
                        AggregateScorePointView(participants: group.participants)
                            .position(x: group.x, y: centerY)
                            .accessibilityLabel(aggregateAccessibilityLabel(for: group))
                    } else if let participant = group.participants.first {
                        Circle()
                            .fill(participant.color.opacity(0.84))
                            .frame(width: pointSize, height: pointSize)
                            .overlay(
                                Circle()
                                    .stroke(Color(.systemBackground).opacity(0.94), lineWidth: 1)
                            )
                            .overlay(
                                Circle()
                                    .stroke(participant.color.opacity(0.28), lineWidth: 0.7)
                            )
                            .shadow(color: participant.color.opacity(0.10), radius: 1.5, y: 0.5)
                            .position(x: group.x, y: centerY + group.yOffset)
                            .accessibilityLabel("\(participant.ownerName) 评分 \(String(format: "%.2f", participant.rating))")
                    }
                }
            }
            .frame(width: width, height: proxy.size.height)
        }
    }

    private func scorePointGroups(width: CGFloat) -> [ScorePointGroup] {
        let sorted = participants.sorted {
            if abs($0.rating - $1.rating) > 0.0001 {
                return $0.rating < $1.rating
            }
            return $0.ownerIndex < $1.ownerIndex
        }
        var clusters: [[ComparisonParticipantScore]] = []
        for participant in sorted {
            if let lastCluster = clusters.last,
               let anchor = lastCluster.first,
               abs(participant.rating - anchor.rating) <= clusterThreshold {
                clusters[clusters.count - 1].append(participant)
            } else {
                clusters.append([participant])
            }
        }

        return clusters.flatMap { cluster in
            if cluster.count >= 4 {
                let averageRating = cluster.map(\.rating).reduce(0, +) / Double(cluster.count)
                let markerWidth = aggregatePointWidth(for: cluster.count)
                let rawX = pointSize / 2 + CGFloat(clampedRating(averageRating)) / 5 * max(1, width - pointSize)
                return [
                    ScorePointGroup(
                        id: cluster.map(\.id).joined(separator: "-"),
                        participants: cluster,
                        x: min(width - markerWidth / 2, max(markerWidth / 2, rawX)),
                        yOffset: 0,
                        isAggregate: true
                    )
                ]
            }
            let offsets = verticalOffsets(for: cluster.count)
            return cluster.enumerated().map { index, participant in
                ScorePointGroup(
                    id: participant.id,
                    participants: [participant],
                    x: pointSize / 2 + CGFloat(clampedRating(participant.rating)) / 5 * max(1, width - pointSize),
                    yOffset: offsets[index],
                    isAggregate: false
                )
            }
        }
    }

    private func verticalOffsets(for count: Int) -> [CGFloat] {
        switch count {
        case 0, 1:
            return [0]
        case 2:
            return [-4.5, 4.5]
        case 3:
            return [-5, 0, 5]
        case 4:
            return [-6, -2, 2, 6]
        default:
            let center = CGFloat(count - 1) / 2
            return (0..<count).map { (CGFloat($0) - center) * 3.6 }
        }
    }

    private func clampedRating(_ rating: Double) -> Double {
        min(5, max(0, rating))
    }

    private func aggregatePointWidth(for count: Int) -> CGFloat {
        AggregateScorePointView.width(for: count)
    }

    private func aggregateAccessibilityLabel(for group: ScorePointGroup) -> String {
        let names = group.participants.map(\.ownerName).joined(separator: "、")
        let rating = group.participants.first?.rating ?? 0
        return "\(group.participants.count) 人评分约 \(String(format: "%.2f", rating))：\(names)"
    }
}

private struct AggregateScorePointView: View {
    let participants: [ComparisonParticipantScore]

    private var width: CGFloat {
        Self.width(for: participants.count)
    }

    static func width(for count: Int) -> CGFloat {
        min(26, max(18, CGFloat(count) * 2.4 + 9))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color(.systemBackground).opacity(0.94))
                .overlay(
                    Capsule()
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.7)
                )

            Capsule()
                .fill(
                    LinearGradient(
                        colors: participantStripeColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            .frame(height: 1.6)
            .clipShape(Capsule())

            Text("\(participants.count)")
                .font(.system(size: 7.2, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.82))
                .offset(y: -2.2)
        }
        .frame(width: width, height: 12)
    }

    private var participantStripeColors: [Color] {
        let colors = participants.prefix(6).map { $0.color.opacity(0.74) }
        return colors.isEmpty ? [Color.black.opacity(0.14)] : colors
    }
}

private struct ScorePointGroup: Identifiable {
    let id: String
    let participants: [ComparisonParticipantScore]
    let x: CGFloat
    let yOffset: CGFloat
    let isAggregate: Bool
}

private struct ComparisonLadderNodeEntry {
    let id: String
    let node: ComparisonDrinkNode
    let position: CGPoint
    let ownerID: String
    let ownerIndex: Int
    let ownerName: String
    let clusterID: String
    let clusterCount: Int
    let clusterIndex: Int
    let isClusterExpanded: Bool
    let isClusterRepresentative: Bool
    let accessibilityLabel: String
}

private struct ComparisonOverlayRow: Identifiable {
    let id: String
    let ownerName: String
    let node: ComparisonDrinkNode?
    let accent: Color
    let isFocused: Bool
}

struct PixelPartyMember: Identifiable, Hashable {
    let id: String
    let name: String
    let pixelPerson: PixelPersonProfile
    var isFocused: Bool = false
}

struct PixelPartyLineView: View {
    let members: [PixelPartyMember]
    var maxVisible: Int = 10
    private let personWidth: CGFloat = 29
    private let personHeight: CGFloat = 36
    private let personSpacing: CGFloat = -2

    private var visibleMembers: [PixelPartyMember] {
        Array(members.prefix(maxVisible))
    }

    private var remainingCount: Int {
        max(0, members.count - visibleMembers.count)
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                handLinkLayer

                HStack(spacing: personSpacing) {
                    ForEach(visibleMembers) { member in
                        PixelTinyPersonView(profile: member.pixelPerson, isFocused: member.isFocused)
                            .frame(width: personWidth, height: personHeight)
                            .accessibilityLabel("\(member.name) 的像素小小人")
                    }
                }
            }
            .frame(width: partyWidth, height: personHeight)

            if remainingCount > 0 {
                Text("+\(remainingCount)")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.92))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.black.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var partyWidth: CGFloat {
        guard visibleMembers.count > 0 else { return 0 }
        return CGFloat(visibleMembers.count) * personWidth + CGFloat(max(visibleMembers.count - 1, 0)) * personSpacing
    }

    private var handLinkLayer: some View {
        Canvas { context, _ in
            guard visibleMembers.count > 1 else { return }
            for index in 0..<(visibleMembers.count - 1) {
                let left = visibleMembers[index].pixelPerson
                let startX = CGFloat(index) * (personWidth + personSpacing) + personWidth - 3
                let endX = CGFloat(index + 1) * (personWidth + personSpacing) + 3
                let y = personHeight * 0.50
                let skin = Color(pixelHex: left.skinHex)
                let link = CGRect(x: startX, y: y, width: max(1, endX - startX), height: 3)
                context.fill(Path(link), with: .color(skin))
                context.stroke(Path(link), with: .color(.black.opacity(0.16)), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

struct PixelTinyPersonView: View {
    let profile: PixelPersonProfile
    var isFocused = false

    var body: some View {
        Canvas { context, size in
            let unit = max(1, floor(min(size.width / 16, size.height / 19)))
            let origin = CGPoint(
                x: floor((size.width - unit * 16) / 2),
                y: floor((size.height - unit * 19) / 2)
            )

            func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ color: Color) {
                let frame = CGRect(
                    x: origin.x + CGFloat(x) * unit,
                    y: origin.y + CGFloat(y) * unit,
                    width: CGFloat(width) * unit,
                    height: CGFloat(height) * unit
                )
                context.fill(Path(frame), with: .color(color))
            }

            let skin = Color(pixelHex: profile.skinHex)
            let hair = Color(pixelHex: profile.hairHex)
            let top = Color(pixelHex: profile.topHex)
            let bottom = Color(pixelHex: profile.bottomHex)
            let accent = Color(pixelHex: profile.accentHex)
            let outline = Color.black.opacity(0.72)
            let cheek = Color.red.opacity(0.36)

            rect(0, 10, 5, 2, skin)
            rect(11, 10, 5, 2, skin)
            rect(1, 11, 3, 1, skin)
            rect(12, 11, 3, 1, skin)

            rect(5, 13, 6, 3, bottom)
            rect(6, 12, 4, 2, top)
            rect(5, 9, 6, 4, top)
            rect(7, 8, 2, 2, accent)

            rect(5, 16, 2, 2, bottom)
            rect(9, 16, 2, 2, bottom)
            rect(4, 18, 3, 1, outline)
            rect(9, 18, 3, 1, outline)

            rect(5, 4, 6, 6, skin)
            rect(5, 3, 6, 2, hair)
            switch profile.hairStyle {
            case 0:
                rect(4, 4, 2, 3, hair)
                rect(10, 4, 1, 2, hair)
            case 1:
                rect(4, 4, 7, 2, hair)
                rect(5, 6, 1, 1, hair)
            case 2:
                rect(5, 2, 5, 2, hair)
                rect(4, 4, 1, 2, hair)
                rect(10, 4, 1, 3, hair)
            default:
                rect(4, 3, 3, 3, hair)
                rect(8, 3, 3, 2, hair)
            }

            rect(6, 6, 1, 1, outline)
            rect(9, 6, 1, 1, outline)
            switch profile.faceStyle {
            case 0:
                rect(7, 8, 2, 1, outline)
            case 1:
                rect(7, 8, 1, 1, outline)
                rect(9, 8, 1, 1, outline)
            default:
                rect(7, 8, 2, 1, cheek)
            }

            switch profile.accessoryStyle {
            case 0:
                rect(11, 6, 2, 1, accent)
                rect(12, 7, 1, 2, accent)
            case 1:
                rect(4, 6, 1, 1, accent)
                rect(11, 6, 1, 1, accent)
            case 2:
                rect(7, 2, 2, 1, accent)
            default:
                rect(11, 9, 2, 3, accent)
                rect(12, 8, 1, 1, Color.white.opacity(0.88))
            }

            if isFocused {
                rect(3, 1, 10, 1, accent)
                rect(2, 2, 1, 2, accent)
                rect(13, 2, 1, 2, accent)
            }
        }
        .drawingGroup(opaque: false, colorMode: .nonLinear)
    }
}

private extension Color {
    init(pixelHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private struct ComparisonDrinkCardOverlay: View {
    let selectedEntry: ComparisonLadderNodeEntry
    let rows: [ComparisonOverlayRow]
    let onClose: () -> Void

    private static let cardPadding: CGFloat = 14
    private static let headerHeight: CGFloat = 40
    private static let headerListSpacing: CGFloat = 12
    private static let listBottomPadding: CGFloat = 2
    private static let rowSpacing: CGFloat = 8
    private static let recordedRowHeight: CGFloat = 140
    private static let missingRowHeight: CGFloat = 76
    private static let topClearance: CGFloat = 118
    private static let bottomClearance: CGFloat = 34

    private var selectedNode: ComparisonDrinkNode {
        selectedEntry.node
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 28, 430)
            let maxCardHeight = max(280, proxy.size.height - Self.topClearance - Self.bottomClearance)
            let cardHeight = cardHeight(maxCardHeight: maxCardHeight)
            let listHeight = max(
                1,
                cardHeight - Self.cardPadding * 2 - Self.headerHeight - Self.headerListSpacing
            )
            ZStack {
                Color.black.opacity(0.1)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                cardContent(listHeight: listHeight)
                .padding(Self.cardPadding)
                .frame(width: width)
                .frame(height: cardHeight, alignment: .top)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 28, y: 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, Self.topClearance)
                .onTapGesture {}
            }
        }
    }

    private func cardHeight(maxCardHeight: CGFloat) -> CGFloat {
        min(maxCardHeight, naturalCardHeight)
    }

    private var naturalCardHeight: CGFloat {
        let listRowsHeight = rows.reduce(CGFloat.zero) { partial, row in
            partial + (row.node == nil ? Self.missingRowHeight : Self.recordedRowHeight)
        }
        let listSpacing = CGFloat(max(0, rows.count - 1)) * Self.rowSpacing
        return Self.cardPadding * 2
            + Self.headerHeight
            + Self.headerListSpacing
            + listRowsHeight
            + listSpacing
            + Self.listBottomPadding
    }

    private func cardContent(listHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Self.headerListSpacing) {
            cardHeader

            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(rows) { row in
                        ComparisonStackCard(
                            ownerName: row.ownerName,
                            node: row.node,
                            accent: row.accent,
                            isFocused: row.isFocused
                        )
                    }
                }
                .padding(.bottom, Self.listBottomPadding)
            }
            .frame(height: listHeight, alignment: .top)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedNode.displayName)
                    .font(.headline.weight(.black))
                    .lineLimit(1)
                Text(summaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: Self.headerHeight, alignment: .top)
    }

    private var summaryText: String {
        let recordedNodes = rows.compactMap(\.node)
        guard recordedNodes.count >= 2 else { return "\(selectedEntry.ownerName) 记录过" }
        return "\(recordedNodes.count) 人记录"
    }
}

private struct ComparisonStackCard: View {
    let ownerName: String
    let node: ComparisonDrinkNode?
    let accent: Color
    let isFocused: Bool

    var body: some View {
        Group {
            if let node {
                recordedCard(for: node)
            } else {
                missingCard
            }
        }
        .padding(9)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFocused ? accent.opacity(0.76) : .black.opacity(0.06), lineWidth: isFocused ? 1.6 : 1)
        )
    }

    private func recordedCard(for node: ComparisonDrinkNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                sticker
                    .frame(width: 58, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(ownerName)
                            .font(.caption.weight(.black))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(Color.white)
                            .background(accent)
                            .clipShape(Capsule())
                        Spacer()
                        Text(String(format: "%.2f", node.aggregateRating))
                            .font(.subheadline.weight(.black).monospacedDigit())
                            .lineLimit(1)
                    }

                    Text(node.displayBrand)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(node.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            }

            bottomInfo(for: node)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var missingCard: some View {
        HStack(alignment: .center, spacing: 10) {
            sticker
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text(ownerName)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text("未记录这杯")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text("这本图鉴里暂时没有对应饮品。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 58, alignment: .center)
    }

    @ViewBuilder
    private var sticker: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white)
            if let image = node?.representative.stickerImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: node == nil ? "questionmark.circle" : "cup.and.saucer.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bottomInfo(for node: ComparisonDrinkNode) -> some View {
        let edgeInset: CGFloat = 13
        let textInset: CGFloat = 7

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                infoPill("甜度", node.representative.sweetness, textAlignment: .leading, frameAlignment: .leading)
                infoPill("冰度", node.representative.iceLevel, textAlignment: .leading, frameAlignment: .center)
                infoPill("杯数", "\(node.totalCupCount)", textAlignment: .leading, frameAlignment: .trailing)
            }
            .padding(.horizontal, edgeInset)

            Text(displayNote(for: node))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, edgeInset + textInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50, alignment: .top)
    }

    private func infoPill(
        _ title: String,
        _ value: String,
        textAlignment: HorizontalAlignment = .leading,
        frameAlignment: Alignment = .leading
    ) -> some View {
        VStack(alignment: textAlignment, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private func displayNote(for node: ComparisonDrinkNode) -> String {
        let note = node.representative.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        let location = node.representative.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty { return location }
        return node.consumedCount > 1 ? "共 \(node.consumedCount) 条记录" : "无备注"
    }
}
