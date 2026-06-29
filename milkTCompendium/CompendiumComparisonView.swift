import SwiftUI
import UIKit

struct CompendiumComparisonView: View {
    fileprivate static let minimumZoomScale: CGFloat = 0.18
    fileprivate static let initialZoomScale: CGFloat = 0.40
    private static let ladderTopControlClearance: CGFloat = 176
    private static let ladderBottomControlClearance: CGFloat = 42
    private static let ladderCanvasVerticalSafePadding: CGFloat = 64

    let localDrinks: [Drink]
    let sharedCompendiums: [SharedCompendium]
    let initialOwnerID: String
    let localOwnerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOwnerID: String
    @State private var orderedSharedOwnerIDs: [String]
    @State private var zoomScale: CGFloat = Self.initialZoomScale
    @State private var centerResetToken = 0
    @State private var selectedEntry: ComparisonLadderNodeEntry?
    @StateObject private var layoutCache = ComparisonLadderLayoutCache()

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

    private var sharedCompendium: SharedCompendium {
        orderedSharedCompendiums.first
            ?? sharedCompendiums.first { $0.ownerID == selectedOwnerID }
            ?? sharedCompendiums.first
            ?? SharedCompendium(ownerID: initialOwnerID, ownerName: "TA", exportedAt: .distantPast, drinks: [])
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

    private func currentInitialZoomScale(for owners: [ComparisonOwnerColumn]) -> CGFloat {
        Self.initialZoomScale(forOwnerCount: owners.count)
    }

    private func comparisonMatchedProductCount(in owners: [ComparisonOwnerColumn]) -> Int {
        Set(owners.flatMap { owner in owner.nodes.map(\.productKey) }).count
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
        zoomScale = Self.initialZoomScale(forOwnerCount: ownerIDs.count + 1)
        centerResetToken += 1
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
        let matchedProductCount = comparisonMatchedProductCount(in: owners)
        let partyMembers = comparisonPartyMembers
        ZStack(alignment: .top) {
            if owners.count < 2 || matchedProductCount == 0 {
                emptyState(title: "还没有共同喝过", subtitle: "至少需要两个人记录过同一款饮品。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                comparisonLadder(owners: owners)
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
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            self.selectedEntry = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(30)
            }
        }
    }

    private func comparisonLadder(owners: [ComparisonOwnerColumn]) -> some View {
        GeometryReader { proxy in
            let contentKey = layoutCacheKey(viewport: proxy.size, owners: owners)
            let layoutKey = contentKey
            let layout = layoutCache.snapshot(for: layoutKey) {
                let canvasSize = canvasSize(for: proxy.size, owners: owners)
                let metrics = ComparisonLadderMetrics(
                    size: canvasSize,
                    topClearance: Self.ladderTopControlClearance + Self.ladderCanvasVerticalSafePadding,
                    bottomClearance: Self.ladderBottomControlClearance + Self.ladderCanvasVerticalSafePadding
                )
                let nodes = nodeEntries(metrics: metrics, owners: owners)
                return ComparisonLadderLayoutSnapshot(
                    canvasSize: canvasSize,
                    metrics: metrics,
                    nodes: nodes,
                    connections: connectionEntries(nodes: nodes, owners: owners),
                    contentSignature: contentKey,
                    layoutSignature: layoutKey
                )
            }

            ZoomableComparisonLadderView(
                zoomScale: $zoomScale,
                contentSize: layout.canvasSize,
                metrics: layout.metrics,
                nodes: layout.nodes,
                connections: layout.connections,
                selectedNodeID: selectedEntry?.id,
                selectedProductKey: selectedEntry?.node.productKey,
                contentSignature: layout.contentSignature,
                layoutSignature: layout.layoutSignature,
                initialZoomScale: currentInitialZoomScale(for: owners),
                centerResetToken: centerResetToken,
                onTapNode: { entry in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        selectedEntry = entry
                    }
                },
                onTapCluster: { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedEntry = nil
                },
                onTapBlank: {
                    selectedEntry = nil
                }
            )
            // Switching the compared owner replaces the canvas, not merely its
            // pixels. Give it a fresh native scroll view so no offset, inset,
            // or gesture state leaks across compendiums.
            .id(layout.contentSignature)
            .background(Color(.systemGroupedBackground))
            .accessibilityLabel("图鉴对比天梯")
        }
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

    private func layoutCacheKey(viewport: CGSize, owners: [ComparisonOwnerColumn]) -> String {
        let viewportKey = "\(Int(viewport.width.rounded()))x\(Int(viewport.height.rounded()))"
        let ownerKey = owners.map { owner in
            "\(owner.id)#\(owner.name)"
        }.joined(separator: "|")
        let nodeKey = owners.flatMap(\.nodes).map { node in
            [
                node.id,
                String(format: "%.3f", node.aggregateRating),
                "\(node.totalCupCount)",
                node.representative.stickerImageName ?? node.representative.stickerFileURL?.lastPathComponent ?? ""
            ].joined(separator: "#")
        }.joined(separator: "|")
        return "\(sharedCompendium.ownerID):matched-only:user-axis-layout-v3:\(viewportKey):\(ownerKey):\(nodeKey)"
    }

    private func canvasSize(for viewport: CGSize, owners: [ComparisonOwnerColumn]) -> CGSize {
        let count = CGFloat(max(owners.map(\.nodes.count).max() ?? 1, 1))
        let ownerCount = CGFloat(max(owners.count, 2))
        let initialZoomScale = currentInitialZoomScale(for: owners)
        let overviewWidth = viewport.width / initialZoomScale * 0.98
        let overviewHeight = viewport.height / initialZoomScale * 0.98
        let ownerWidth = (ownerCount - 1) * ComparisonLadderMetrics.ownerLaneSpacing + 420
        let densityHeight = 940 + count * 11 + Self.ladderCanvasVerticalSafePadding * 2
        return CGSize(
            width: max(overviewWidth, ownerWidth, 1040),
            height: max(overviewHeight, densityHeight)
        )
    }

    private static func initialZoomScale(forOwnerCount ownerCount: Int) -> CGFloat {
        guard ownerCount > 3 else { return initialZoomScale }
        let scaled = initialZoomScale / sqrt(CGFloat(ownerCount) / 3)
        return min(initialZoomScale, max(0.20, scaled))
    }

    private func nodeEntries(metrics: ComparisonLadderMetrics, owners: [ComparisonOwnerColumn]) -> [ComparisonLadderNodeEntry] {
        owners.enumerated().flatMap { index, owner in
            entries(for: owner.nodes, owner: owner, ownerIndex: index, ownerCount: owners.count, metrics: metrics)
        }
        .sorted { first, second in
            if first.position.y == second.position.y {
                return first.node.id < second.node.id
            }
            return first.position.y < second.position.y
        }
    }

    private func entries(
        for nodes: [ComparisonDrinkNode],
        owner: ComparisonOwnerColumn,
        ownerIndex: Int,
        ownerCount: Int,
        metrics: ComparisonLadderMetrics
    ) -> [ComparisonLadderNodeEntry] {
        let grouped = Dictionary(grouping: nodes) { node in
            Int((node.aggregateRating * 100).rounded())
        }
        var entries: [ComparisonLadderNodeEntry] = []
        let anchorX = metrics.ownerAnchorX(index: ownerIndex, count: ownerCount)

        for key in grouped.keys.sorted(by: >) {
            let rowNodes = (grouped[key] ?? []).sorted { first, second in
                if first.aggregateRating == second.aggregateRating {
                    return first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
                }
                return first.aggregateRating > second.aggregateRating
            }
            let clusterID = ComparisonLadderClusterID(ownerID: owner.id, ratingKey: key).rawValue
            let baseY = yPosition(for: Double(key) / 100, metrics: metrics)
            for (index, node) in rowNodes.enumerated() {
                let horizontalOffset = sameScoreHorizontalOffset(
                    index: index,
                    count: rowNodes.count,
                    ownerIndex: ownerIndex,
                    ownerCount: ownerCount
                )
                let position = CGPoint(
                    x: anchorX + horizontalOffset.width,
                    y: min(max(metrics.plotTop + 24, baseY + horizontalOffset.height), metrics.plotBottom - 24)
                )
                entries.append(ComparisonLadderNodeEntry(
                    id: node.id,
                    node: node,
                    position: position,
                    ownerID: owner.id,
                    ownerIndex: ownerIndex,
                    ownerName: owner.name,
                    clusterID: clusterID,
                    clusterCount: rowNodes.count,
                    clusterIndex: index,
                    isClusterExpanded: true,
                    isClusterRepresentative: true,
                    accessibilityLabel: "\(owner.name)，\(node.displayBrand)，\(node.displayName)，评分 \(String(format: "%.2f", node.aggregateRating))"
                ))
            }
        }
        return entries
    }

    private func sameScoreHorizontalOffset(
        index: Int,
        count: Int,
        ownerIndex: Int,
        ownerCount: Int
    ) -> CGSize {
        guard count > 1 else { return .zero }
        let spacing: CGFloat
        if count <= 3 {
            spacing = 122
        } else if count <= 5 {
            spacing = 106
        } else {
            spacing = 92
        }
        let centerIndex = CGFloat(count - 1) / 2
        let rawX = (CGFloat(index) - centerIndex) * spacing
        let edgeBias: CGFloat
        if ownerCount > 2, ownerIndex == 0 {
            edgeBias = -min(46, CGFloat(count - 1) * 10)
        } else if ownerCount > 2, ownerIndex == ownerCount - 1 {
            edgeBias = min(46, CGFloat(count - 1) * 10)
        } else {
            edgeBias = 0
        }
        return CGSize(width: rawX + edgeBias, height: 0)
    }

    private func connectionEntries(
        nodes nodeEntries: [ComparisonLadderNodeEntry],
        owners: [ComparisonOwnerColumn]
    ) -> [ComparisonLadderConnectionEntry] {
        let entriesByOwner = Dictionary(grouping: nodeEntries, by: \.ownerID)
        let varianceByProduct = productRatingVarianceByKey(from: nodeEntries)
        let coverageByProduct = productCoverageByKey(from: nodeEntries, ownerCount: owners.count)
        var connections: [ComparisonLadderConnectionEntry] = []
        for leftIndex in owners.indices {
            for rightIndex in owners.indices where rightIndex > leftIndex {
                let leftOwner = owners[leftIndex]
                let rightOwner = owners[rightIndex]
                let leftByProduct = Dictionary(uniqueKeysWithValues: (entriesByOwner[leftOwner.id] ?? []).map { ($0.node.productKey, $0) })
                let rightByProduct = Dictionary(uniqueKeysWithValues: (entriesByOwner[rightOwner.id] ?? []).map { ($0.node.productKey, $0) })
                for productKey in Set(leftByProduct.keys).intersection(rightByProduct.keys).sorted() {
                    guard let start = leftByProduct[productKey], let end = rightByProduct[productKey] else { continue }
                    let variance = varianceByProduct[productKey] ?? 0
                    let coverage = coverageByProduct[productKey] ?? 1
                    let id = "connection-\(leftOwner.id)-\(rightOwner.id)-\(productKey)"
                    connections.append(ComparisonLadderConnectionEntry(
                        id: id,
                        productKey: productKey,
                        startNodeID: start.id,
                        endNodeID: end.id,
                        ratingVariance: variance,
                        coverageRatio: coverage,
                        start: start.position,
                        end: end.position,
                        color: connectionUIColor(forVariance: variance),
                        lineWidth: connectionLineWidth(forVariance: variance)
                    ))
                }
            }
        }
        return connections
    }

    private func productRatingVarianceByKey(from entries: [ComparisonLadderNodeEntry]) -> [String: Double] {
        Dictionary(grouping: entries, by: { $0.node.productKey })
            .mapValues { productEntries in
                let ratings = productEntries.map(\.node.aggregateRating)
                guard !ratings.isEmpty else { return 0 }
                let mean = ratings.reduce(0, +) / Double(ratings.count)
                return ratings.reduce(0) { partial, rating in
                    let delta = rating - mean
                    return partial + delta * delta
                } / Double(ratings.count)
            }
    }

    private func productCoverageByKey(from entries: [ComparisonLadderNodeEntry], ownerCount rawOwnerCount: Int) -> [String: CGFloat] {
        let ownerCount = max(rawOwnerCount, 1)
        return Dictionary(grouping: entries, by: { $0.node.productKey })
            .mapValues { productEntries in
                let drinkerCount = Set(productEntries.map(\.ownerID)).count
                return min(1, max(0, CGFloat(drinkerCount) / CGFloat(ownerCount)))
            }
    }

    private func yPosition(for rating: Double, metrics: ComparisonLadderMetrics) -> CGFloat {
        metrics.plotTop + CGFloat(5 - min(5, max(0, rating))) / 5 * metrics.plotHeight
    }

    private func connectionUIColor(forVariance variance: Double) -> UIColor {
        switch variance {
        case 1.20...:
            return UIColor(red: 0.93, green: 0.18, blue: 0.16, alpha: 1)
        case 0.35..<1.20:
            return UIColor(red: 0.88, green: 0.68, blue: 0.18, alpha: 1)
        default:
            return UIColor(red: 0.05, green: 0.62, blue: 0.28, alpha: 1)
        }
    }

    private func connectionLineWidth(forVariance variance: Double) -> CGFloat {
        switch variance {
        case 1.20...:
            return 3.9
        case 0.35..<1.20:
            return 3.35
        default:
            return 3.0
        }
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
    private static let uiColors = [
        UIColor(red: 0.70, green: 0.48, blue: 0.30, alpha: 1),
        UIColor(red: 0.38, green: 0.48, blue: 0.76, alpha: 1),
        UIColor(red: 0.24, green: 0.50, blue: 0.38, alpha: 1)
    ]

    static func uiColor(index: Int) -> UIColor {
        uiColors[max(0, index) % uiColors.count]
    }

    static func color(index: Int) -> Color {
        Color(uiColor(index: index))
    }
}

private final class ComparisonLadderLayoutCache: ObservableObject {
    private var cachedKey: String?
    private var cachedSnapshot: ComparisonLadderLayoutSnapshot?

    func snapshot(for key: String, build: () -> ComparisonLadderLayoutSnapshot) -> ComparisonLadderLayoutSnapshot {
        if cachedKey == key, let cachedSnapshot {
            return cachedSnapshot
        }
        let snapshot = build()
        cachedKey = key
        cachedSnapshot = snapshot
        return snapshot
    }
}

private struct ComparisonLadderLayoutSnapshot {
    let canvasSize: CGSize
    let metrics: ComparisonLadderMetrics
    let nodes: [ComparisonLadderNodeEntry]
    let connections: [ComparisonLadderConnectionEntry]
    let contentSignature: String
    let layoutSignature: String
}

private struct ComparisonLadderMetrics {
    static let ownerLaneSpacing: CGFloat = 250

    let size: CGSize
    let topClearance: CGFloat
    let plotTop: CGFloat
    let plotBottom: CGFloat
    let centerX: CGFloat
    let localAnchorX: CGFloat
    let peerAnchorX: CGFloat
    let axisLineGap: CGFloat = 82

    init(size: CGSize, topClearance: CGFloat, bottomClearance: CGFloat = 42) {
        self.size = size
        self.topClearance = topClearance
        plotTop = topClearance
        plotBottom = max(topClearance + 1, size.height - bottomClearance)
        centerX = size.width / 2
        localAnchorX = centerX - min(250, max(154, size.width * 0.22))
        peerAnchorX = centerX + min(250, max(154, size.width * 0.22))
    }

    var plotHeight: CGFloat {
        max(1, plotBottom - plotTop)
    }

    func ownerAnchorX(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return centerX }
        let usableWidth = min(size.width - 220, CGFloat(count - 1) * Self.ownerLaneSpacing)
        let startX = centerX - usableWidth / 2
        return startX + CGFloat(index) / CGFloat(count - 1) * usableWidth
    }
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

private struct ComparisonLadderClusterID {
    let ownerID: String
    let ratingKey: Int

    var rawValue: String {
        "\(ownerID)-\(ratingKey)"
    }
}

private struct ComparisonLadderConnectionEntry {
    let id: String
    let productKey: String
    let startNodeID: String
    let endNodeID: String
    let ratingVariance: Double
    let coverageRatio: CGFloat
    let start: CGPoint
    let end: CGPoint
    let color: UIColor
    let lineWidth: CGFloat
}

private struct ZoomableComparisonLadderView: UIViewRepresentable {
    @Binding var zoomScale: CGFloat
    let contentSize: CGSize
    let metrics: ComparisonLadderMetrics
    let nodes: [ComparisonLadderNodeEntry]
    let connections: [ComparisonLadderConnectionEntry]
    let selectedNodeID: String?
    let selectedProductKey: String?
    let contentSignature: String
    let layoutSignature: String
    let initialZoomScale: CGFloat
    let centerResetToken: Int
    let onTapNode: (ComparisonLadderNodeEntry) -> Void
    let onTapCluster: (String) -> Void
    let onTapBlank: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, onTapNode: onTapNode, onTapCluster: onTapCluster, onTapBlank: onTapBlank)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomCanvasScrollView()
        let coordinator = context.coordinator
        scrollView.onLayoutSubviews = { [weak coordinator] in
            coordinator?.handleScrollViewLayout()
        }
        scrollView.delegate = context.coordinator
        scrollView.pinchGestureRecognizer?.delegate = context.coordinator
        scrollView.minimumZoomScale = CompendiumComparisonView.minimumZoomScale
        scrollView.maximumZoomScale = 2.35
        scrollView.zoomScale = initialZoomScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.layer.drawsAsynchronously = true

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        let canvasView = ComparisonLadderCanvasUIView()
        canvasView.backgroundColor = .clear
        canvasView.layer.drawsAsynchronously = true
        canvasView.frame = CGRect(origin: .zero, size: contentSize)
        canvasView.configure(
            metrics: metrics,
            nodes: nodes,
            connections: connections,
            contentSize: contentSize,
            contentSignature: contentSignature,
            displayScale: initialZoomScale
        )
        canvasView.applyZoom(scale: initialZoomScale, mode: .settled)
        canvasView.updateSelection(nodeID: selectedNodeID, productKey: selectedProductKey)
        scrollView.addSubview(canvasView)
        scrollView.contentSize = contentSize

        context.coordinator.scrollView = scrollView
        context.coordinator.canvasView = canvasView
        context.coordinator.nodes = nodes
        context.coordinator.contentSize = contentSize
        context.coordinator.contentSignature = contentSignature
        context.coordinator.layoutSignature = layoutSignature
        context.coordinator.initialZoomScale = initialZoomScale
        context.coordinator.centerResetToken = centerResetToken
        context.coordinator.viewport.attach(scrollView)
        context.coordinator.viewport.update(
            canvasSize: contentSize,
            focusPoint: CGPoint(
                x: metrics.centerX,
                y: (metrics.plotTop + metrics.plotBottom) / 2
            )
        )
        context.coordinator.resetViewport(to: initialZoomScale)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let contentDidChange = context.coordinator.contentSignature != contentSignature
        let layoutDidChange = context.coordinator.layoutSignature != layoutSignature
        let sizeDidChange = context.coordinator.contentSize != contentSize
        let centerResetDidChange = context.coordinator.centerResetToken != centerResetToken

        context.coordinator.zoomScale = $zoomScale
        context.coordinator.onTapNode = onTapNode
        context.coordinator.onTapCluster = onTapCluster
        context.coordinator.onTapBlank = onTapBlank
        context.coordinator.nodes = nodes
        context.coordinator.contentSize = contentSize
        context.coordinator.initialZoomScale = initialZoomScale
        context.coordinator.viewport.update(
            canvasSize: contentSize,
            focusPoint: CGPoint(
                x: metrics.centerX,
                y: (metrics.plotTop + metrics.plotBottom) / 2
            )
        )
        if contentDidChange {
            context.coordinator.contentSignature = contentSignature
        }
        if layoutDidChange {
            context.coordinator.layoutSignature = layoutSignature
        }
        if centerResetDidChange {
            context.coordinator.centerResetToken = centerResetToken
        }
        if sizeDidChange {
            scrollView.contentSize = contentSize
            context.coordinator.canvasView?.frame = CGRect(origin: .zero, size: contentSize)
        }
        let shouldResetViewport = centerResetDidChange || sizeDidChange || contentDidChange
        if contentDidChange || sizeDidChange || layoutDidChange {
            context.coordinator.canvasView?.configure(
                metrics: metrics,
                nodes: nodes,
                connections: connections,
                contentSize: contentSize,
                contentSignature: contentSignature,
                displayScale: shouldResetViewport ? initialZoomScale : scrollView.zoomScale
            )
            if !centerResetDidChange {
                context.coordinator.viewport.clampContentOffset()
            }
        }

        if shouldResetViewport {
            context.coordinator.resetViewport(to: initialZoomScale)
        } else if !context.coordinator.isZooming,
                  abs(scrollView.zoomScale - zoomScale) > 0.001 {
            context.coordinator.setZoomScale(zoomScale, on: scrollView)
        }
        context.coordinator.canvasView?.applyZoom(scale: scrollView.zoomScale, mode: context.coordinator.isZooming ? .preview : .settled)
        context.coordinator.canvasView?.updateSelection(nodeID: selectedNodeID, productKey: selectedProductKey)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var zoomScale: Binding<CGFloat>
        var onTapNode: (ComparisonLadderNodeEntry) -> Void
        var onTapCluster: (String) -> Void
        var onTapBlank: () -> Void
        weak var canvasView: ComparisonLadderCanvasUIView?
        weak var scrollView: UIScrollView?
        let viewport = ZoomCanvasViewportController()
        var nodes: [ComparisonLadderNodeEntry] = []
        var contentSize: CGSize = .zero
        var contentSignature = ""
        var layoutSignature = ""
        var initialZoomScale = CompendiumComparisonView.initialZoomScale
        var centerResetToken = 0
        var isZooming = false
        private var lastReportedZoomScale: CGFloat = 0
        private var isApplyingProgrammaticViewportChange = false

        init(
            zoomScale: Binding<CGFloat>,
            onTapNode: @escaping (ComparisonLadderNodeEntry) -> Void,
            onTapCluster: @escaping (String) -> Void,
            onTapBlank: @escaping () -> Void
        ) {
            self.zoomScale = zoomScale
            self.onTapNode = onTapNode
            self.onTapCluster = onTapCluster
            self.onTapBlank = onTapBlank
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvasView
        }

        func handleScrollViewLayout() {
            isApplyingProgrammaticViewportChange = true
            viewport.handleLayout()
            isApplyingProgrammaticViewportChange = false
        }

        func resetViewport(to scale: CGFloat) {
            isZooming = false
            lastReportedZoomScale = scale
            isApplyingProgrammaticViewportChange = true
            viewport.requestReset(zoomScale: scale)
            isApplyingProgrammaticViewportChange = false
        }

        func setZoomScale(_ scale: CGFloat, on scrollView: UIScrollView) {
            lastReportedZoomScale = scale
            isApplyingProgrammaticViewportChange = true
            scrollView.setZoomScale(scale, animated: false)
            isApplyingProgrammaticViewportChange = false
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let scrollView else { return }
            guard let entry = entry(at: recognizer.location(in: scrollView)) else {
                onTapBlank()
                return
            }
            if entry.clusterCount > 1, !entry.isClusterExpanded {
                onTapCluster(entry.clusterID)
            } else {
                onTapNode(entry)
            }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isZooming = true
            viewport.cancelPendingReset()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            viewport.cancelPendingReset()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let scale = scrollView.zoomScale
            if !isApplyingProgrammaticViewportChange, abs(scale - lastReportedZoomScale) > 0.015 {
                lastReportedZoomScale = scale
                reportZoomScale(scale)
            }
            viewport.updateContentInsets()
            canvasView?.applyZoom(scale: scale, mode: .preview)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZooming = false
            let settledScale = scrollView.zoomScale
            reportZoomScale(settledScale)
            lastReportedZoomScale = settledScale
            viewport.updateContentInsets()
            viewport.clampContentOffset()
            canvasView?.applyZoom(scale: settledScale, mode: .settled, animatesLabel: true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                viewport.clampContentOffset()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            viewport.clampContentOffset()
        }

        private func reportZoomScale(_ scale: CGFloat) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.zoomScale.wrappedValue = scale
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            gestureRecognizer is UITapGestureRecognizer
        }

        private func entry(at scrollViewPoint: CGPoint) -> ComparisonLadderNodeEntry? {
            guard let scrollView, let canvasView else { return nil }
            let contentPoint = canvasView.convert(scrollViewPoint, from: scrollView)
            let counterScale = ComparisonLadderCanvasUIView.nodeCounterScale(for: scrollView.zoomScale)
            let hitSize = CGSize(width: 58 * counterScale, height: 64 * counterScale)
            return nodes.reversed().first { entry in
                guard entry.isClusterExpanded || entry.isClusterRepresentative else { return false }
                return CGRect(
                    x: entry.position.x - hitSize.width / 2,
                    y: entry.position.y - hitSize.height / 2,
                    width: hitSize.width,
                    height: hitSize.height
                ).insetBy(dx: -5, dy: -5).contains(contentPoint)
            }
        }
    }
}

private final class ComparisonLadderCanvasUIView: UIView {
    enum LabelMode {
        case preview
        case settled
    }

    private let axisLayer = CALayer()
    private let connectionContainerLayer = CALayer()
    private let nodeContainerLayer = CALayer()
    private var nodeLayers: [String: ComparisonNodeLayer] = [:]
    private var connectionLayers: [String: CAShapeLayer] = [:]
    private var currentScale: CGFloat = 0.48
    private var currentMode = LabelMode.settled
    private var contentSignature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        layer.addSublayer(axisLayer)
        layer.addSublayer(connectionContainerLayer)
        layer.addSublayer(nodeContainerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        metrics: ComparisonLadderMetrics,
        nodes: [ComparisonLadderNodeEntry],
        connections: [ComparisonLadderConnectionEntry],
        contentSize: CGSize,
        contentSignature: String,
        displayScale: CGFloat
    ) {
        let isInitialRender = self.contentSignature.isEmpty
        let contentDidChange = !isInitialRender && self.contentSignature != contentSignature
        self.contentSignature = contentSignature
        currentScale = displayScale
        comparisonWithoutLayerActions {
            bounds = CGRect(origin: .zero, size: contentSize)
            axisLayer.frame = bounds
            connectionContainerLayer.frame = bounds
            nodeContainerLayer.frame = bounds
            rebuildAxis(metrics: metrics)
            rebuildConnections(metrics: metrics, connections: connections, animatesLayout: !isInitialRender && !contentDidChange)
            rebuildNodes(nodes: nodes, animatesLayout: !isInitialRender && !contentDidChange)
            applyZoom(scale: currentScale, mode: currentMode)
        }
        if isInitialRender || contentDidChange {
            runEntranceAnimation(connectionCount: connections.count)
        }
    }

    func applyZoom(scale: CGFloat, mode: LabelMode, animatesLabel: Bool = false) {
        currentScale = scale
        currentMode = mode
        let counterScale = Self.nodeCounterScale(for: scale)
        let labelOpacity: CGFloat = switch mode {
        case .preview:
            Self.labelRevealProgress(for: scale)
        case .settled:
            Self.labelRevealProgress(for: scale) > 0 ? 1 : 0
        }
        comparisonWithoutLayerActions {
            nodeLayers.values.forEach { $0.apply(counterScale: counterScale, labelOpacity: labelOpacity, animatesLabel: animatesLabel) }
        }
    }

    func updateSelection(nodeID: String?, productKey: String?) {
        comparisonWithoutLayerActions {
            nodeLayers.values.forEach { layer in
                let isSelected = nodeID == layer.entry.id
                let isSameProduct = productKey != nil && productKey == layer.entry.node.productKey
                let shouldDim = productKey != nil && !isSameProduct
                layer.updateSelection(isSelected: isSelected, isDimmed: shouldDim)
            }
            connectionLayers.forEach { id, layer in
                let connectedToSelectedNode = nodeID != nil && (
                    layer.value(forKey: "startNodeID") as? String == nodeID ||
                    layer.value(forKey: "endNodeID") as? String == nodeID
                )
                let layerProductKey = layer.value(forKey: "productKey") as? String
                let isSameProduct = productKey != nil && productKey == layerProductKey
                let isSelected = isSameProduct || connectedToSelectedNode
                let shouldDim = productKey != nil && !isSelected
                layer.opacity = shouldDim ? 0.12 : (isSelected ? 0.95 : 0.46)
                layer.lineWidth = isSelected ? 5.1 : (layer.value(forKey: "baseLineWidth") as? CGFloat ?? 2.7)
                layer.zPosition = isSelected ? 100 : 0
            }
        }
    }

    static func nodeCounterScale(for scale: CGFloat) -> CGFloat {
        1 / pow(max(min(2.35, max(CompendiumComparisonView.minimumZoomScale, scale)), 0.01), 0.46)
    }

    private static func labelRevealProgress(for scale: CGFloat) -> CGFloat {
        let raw = (min(2.35, max(CompendiumComparisonView.minimumZoomScale, scale)) - 0.82) / (1.06 - 0.82)
        let clamped = min(1, max(0, raw))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func rebuildAxis(metrics: ComparisonLadderMetrics) {
        axisLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let verticalPath = UIBezierPath()
        verticalPath.move(to: CGPoint(x: metrics.centerX, y: metrics.plotTop))
        verticalPath.addLine(to: CGPoint(x: metrics.centerX, y: metrics.plotBottom))
        axisLayer.addSublayer(shapeLayer(path: verticalPath.cgPath, color: UIColor.black.withAlphaComponent(0.24), lineWidth: 1.2, dashPattern: [5, 10]))

        let horizontalPath = UIBezierPath()
        let scoreTextLayer = CALayer()
        scoreTextLayer.frame = axisLayer.bounds
        for score in 0...5 {
            let y = metrics.plotTop + CGFloat(5 - score) / 5 * metrics.plotHeight
            horizontalPath.move(to: CGPoint(x: 22, y: y))
            horizontalPath.addLine(to: CGPoint(x: metrics.centerX - metrics.axisLineGap, y: y))
            horizontalPath.move(to: CGPoint(x: metrics.centerX + metrics.axisLineGap, y: y))
            horizontalPath.addLine(to: CGPoint(x: metrics.size.width - 22, y: y))

            let text = CATextLayer()
            text.string = "\(score)"
            text.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            text.fontSize = 12
            text.foregroundColor = UIColor.secondaryLabel.cgColor
            text.alignmentMode = .center
            text.contentsScale = UIScreen.main.scale
            text.frame = CGRect(x: metrics.centerX - 18, y: y - 9, width: 36, height: 18)
            scoreTextLayer.addSublayer(text)
        }
        axisLayer.addSublayer(shapeLayer(path: horizontalPath.cgPath, color: UIColor.black.withAlphaComponent(0.16), lineWidth: 0.85, dashPattern: [8, 12]))
        axisLayer.addSublayer(scoreTextLayer)
    }

    private func rebuildConnections(
        metrics: ComparisonLadderMetrics,
        connections: [ComparisonLadderConnectionEntry],
        animatesLayout: Bool
    ) {
        let liveIDs = Set(connections.map(\.id))
        for (id, layer) in connectionLayers where !liveIDs.contains(id) {
            layer.removeFromSuperlayer()
            connectionLayers[id] = nil
        }
        for connection in connections {
            let path = connectionPath(connection: connection)
            let layer: CAShapeLayer
            if let existing = connectionLayers[connection.id] {
                layer = existing
                if animatesLayout {
                    animate(layer: layer, keyPath: "path", to: path)
                }
                layer.path = path
                layer.strokeColor = connection.color.withAlphaComponent(connectionAlpha(forVariance: connection.ratingVariance, coverage: connection.coverageRatio)).cgColor
                layer.lineDashPattern = lineDashPattern(forCoverage: connection.coverageRatio)
            } else {
                layer = shapeLayer(
                    path: path,
                    color: connection.color.withAlphaComponent(connectionAlpha(forVariance: connection.ratingVariance, coverage: connection.coverageRatio)),
                    lineWidth: connection.lineWidth,
                    dashPattern: lineDashPattern(forCoverage: connection.coverageRatio)
                )
                connectionContainerLayer.addSublayer(layer)
                connectionLayers[connection.id] = layer
            }
            layer.opacity = 0.46
            layer.lineWidth = connection.lineWidth
            layer.setValue(connection.lineWidth, forKey: "baseLineWidth")
            layer.setValue(connection.productKey, forKey: "productKey")
            layer.setValue(connection.startNodeID, forKey: "startNodeID")
            layer.setValue(connection.endNodeID, forKey: "endNodeID")
        }
    }

    private func connectionAlpha(forVariance variance: Double, coverage: CGFloat) -> CGFloat {
        let baseAlpha: CGFloat = switch variance {
        case 1.20...:
            0.82
        case 0.35..<1.20:
            0.76
        default:
            0.70
        }
        return baseAlpha * (0.78 + min(1, max(0, coverage)) * 0.22)
    }

    private func lineDashPattern(forCoverage coverage: CGFloat) -> [NSNumber]? {
        let clamped = min(1, max(0, coverage))
        guard clamped < 0.999 else { return nil }
        if clamped >= 0.75 {
            return [18, 6]
        }
        if clamped >= 0.5 {
            return [10, 8]
        }
        return [4, 9]
    }

    private func rebuildNodes(nodes: [ComparisonLadderNodeEntry], animatesLayout: Bool) {
        let liveIDs = Set(nodes.map(\.id))
        for (id, layer) in nodeLayers where !liveIDs.contains(id) {
            layer.removeFromSuperlayer()
            nodeLayers[id] = nil
        }
        for entry in nodes {
            if let layer = nodeLayers[entry.id] {
                layer.updateEntry(entry, animatesLayout: animatesLayout)
            } else {
                let layer = ComparisonNodeLayer(entry: entry)
                nodeContainerLayer.addSublayer(layer)
                nodeLayers[entry.id] = layer
            }
        }
    }

    private func connectionPath(connection: ComparisonLadderConnectionEntry) -> CGPath {
        let path = UIBezierPath()
        path.move(to: connection.start)
        let horizontalDistance = abs(connection.end.x - connection.start.x)
        let direction: CGFloat = connection.end.x >= connection.start.x ? 1 : -1
        let controlDistance = max(76, horizontalDistance * 0.42)
        path.addCurve(
            to: connection.end,
            controlPoint1: CGPoint(x: connection.start.x + direction * controlDistance, y: connection.start.y),
            controlPoint2: CGPoint(x: connection.end.x - direction * controlDistance, y: connection.end.y)
        )
        return path.cgPath
    }

    private func animate(layer: CALayer, keyPath: String, to value: Any) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.mass = 0.55
        animation.stiffness = 380
        animation.damping = 34
        animation.initialVelocity = 0
        animation.duration = min(0.34, animation.settlingDuration)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "layout.\(keyPath)")
    }

    private func shapeLayer(path: CGPath, color: UIColor, lineWidth: CGFloat, dashPattern: [NSNumber]?) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = color.cgColor
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.lineDashPattern = dashPattern
        layer.contentsScale = UIScreen.main.scale
        return layer
    }

    private func runEntranceAnimation(connectionCount: Int) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            layer.add(fade, forKey: "reducedEntranceFade")
            return
        }

        let entranceBeginTime = CACurrentMediaTime() + 0.35
        let nodeRevealScale = Self.nodeCounterScale(for: currentScale)

        for (index, connectionLayer) in connectionLayers.values.enumerated() {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = connectionCount > 80 ? 0.51 : 0.93
            draw.beginTime = entranceBeginTime + (connectionCount > 80 ? 0 : min(0.22, Double(index) * 0.012))
            draw.fillMode = .backwards
            draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            connectionLayer.add(draw, forKey: "strokeReveal")
        }

        for (index, nodeLayer) in nodeLayers.values.enumerated() {
            let group = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = nodeLayer.opacity
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = nodeRevealScale * 0.9
            scale.toValue = nodeRevealScale
            group.animations = [fade, scale]
            group.duration = 0.26
            group.beginTime = entranceBeginTime + min(0.18, Double(index) * 0.006)
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            nodeLayer.add(group, forKey: "nodeReveal")
        }
    }
}

private final class ComparisonNodeLayer: CALayer {
    private(set) var entry: ComparisonLadderNodeEntry
    private let badgeLayer = CALayer()
    private let stackContainerLayer = CALayer()
    private let badgeCircleLayer = CAShapeLayer()
    private let dotContainerLayer = CALayer()
    private let stickerLayer = CALayer()
    private let labelContainerLayer = CALayer()
    private let nameTextLayer = CATextLayer()
    private let brandTextLayer = CATextLayer()
    private let sideTextLayer = CATextLayer()
    private let nodeHeight: CGFloat = 58
    private let badgeSize: CGFloat = 34
    private let labelWidth: CGFloat = 86

    init(entry: ComparisonLadderNodeEntry) {
        self.entry = entry
        super.init()
        contentsScale = UIScreen.main.scale
        bounds = CGRect(x: 0, y: 0, width: labelWidth, height: nodeHeight)
        position = entry.position
        setupBadge()
        setupLabel()
        addSublayer(badgeLayer)
        addSublayer(labelContainerLayer)
        accessibilityLabel = entry.accessibilityLabel
    }

    override init(layer: Any) {
        guard let layer = layer as? ComparisonNodeLayer else {
            fatalError("Unsupported layer copy")
        }
        entry = layer.entry
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func updateEntry(_ entry: ComparisonLadderNodeEntry, animatesLayout: Bool) {
        let oldPosition = presentation()?.position ?? position
        let wasRenderable = self.entry.isClusterExpanded || self.entry.isClusterRepresentative
        self.entry = entry
        let isRenderable = entry.isClusterExpanded || entry.isClusterRepresentative
        accessibilityLabel = entry.accessibilityLabel
        updateVisualContent()
        if animatesLayout {
            let animation = CASpringAnimation(keyPath: "position")
            animation.fromValue = oldPosition
            animation.toValue = entry.position
            animation.mass = 0.55
            animation.stiffness = 380
            animation.damping = 34
            animation.duration = min(0.34, animation.settlingDuration)
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            add(animation, forKey: "layout.position")

            if wasRenderable != isRenderable {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = presentation()?.opacity ?? (wasRenderable ? 1 : 0)
                fade.toValue = isRenderable ? 1 : 0
                fade.duration = isRenderable ? 0.11 : 0.08
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                add(fade, forKey: "layout.opacity")
            }
        }
        position = entry.position
    }

    func apply(counterScale: CGFloat, labelOpacity: CGFloat, animatesLabel: Bool) {
        position = entry.position
        transform = CATransform3DMakeScale(counterScale, counterScale, 1)
        zPosition = 10_000 - entry.position.y
        let isRenderable = entry.isClusterExpanded || entry.isClusterRepresentative
        opacity = isRenderable ? 1 : 0
        let canShowLabel = entry.isClusterExpanded || entry.clusterCount == 1
        let renderedOpacity = Float(canShowLabel && labelOpacity > 0 ? max(0.003, labelOpacity) : 0)
        if animatesLabel, labelContainerLayer.opacity != renderedOpacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = labelContainerLayer.presentation()?.opacity ?? labelContainerLayer.opacity
            animation.toValue = renderedOpacity
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            labelContainerLayer.opacity = renderedOpacity
            labelContainerLayer.add(animation, forKey: "labelOpacity")
        } else {
            labelContainerLayer.opacity = renderedOpacity
        }
    }

    func updateSelection(isSelected: Bool, isDimmed: Bool) {
        let isRenderable = entry.isClusterExpanded || entry.isClusterRepresentative
        opacity = !isRenderable ? 0 : (isDimmed ? 0.38 : 1)
        badgeCircleLayer.lineWidth = isSelected ? 2.4 : 1.15
        badgeCircleLayer.strokeColor = (isSelected ? nodeColor.blended(with: .black, amount: 0.2) : badgeStrokeColor).cgColor
        zPosition = isSelected ? 20_000 : 10_000 - entry.position.y
        shadowColor = UIColor.black.cgColor
        shadowOpacity = isSelected ? 0.2 : 0
        shadowRadius = isSelected ? 15 : 0
        shadowOffset = CGSize(width: 0, height: isSelected ? 8 : 0)
    }

    private func setupBadge() {
        badgeLayer.frame = CGRect(x: (bounds.width - badgeSize) / 2, y: 0, width: badgeSize, height: badgeSize)
        stackContainerLayer.frame = badgeLayer.bounds
        badgeLayer.addSublayer(stackContainerLayer)
        badgeCircleLayer.frame = badgeLayer.bounds
        badgeCircleLayer.path = UIBezierPath(ovalIn: badgeLayer.bounds).cgPath
        badgeCircleLayer.fillColor = UIColor.white.withAlphaComponent(0.96).cgColor
        badgeCircleLayer.strokeColor = badgeStrokeColor.cgColor
        badgeCircleLayer.lineWidth = 1.15
        badgeCircleLayer.shadowColor = UIColor.black.cgColor
        badgeCircleLayer.shadowOpacity = 0.13
        badgeCircleLayer.shadowRadius = 8
        badgeCircleLayer.shadowOffset = CGSize(width: 0, height: 4)
        badgeLayer.addSublayer(badgeCircleLayer)
        stickerLayer.frame = badgeLayer.bounds.insetBy(dx: 5, dy: 5)
        stickerLayer.contentsGravity = .resizeAspect
        stickerLayer.contentsScale = UIScreen.main.scale
        stickerLayer.minificationFilter = .trilinear
        stickerLayer.magnificationFilter = .linear
        stickerLayer.contents = stickerContents()
        badgeLayer.addSublayer(stickerLayer)
        dotContainerLayer.frame = badgeLayer.bounds
        badgeLayer.addSublayer(dotContainerLayer)
        renderStack()
    }

    private func updateVisualContent() {
        sideTextLayer.string = entry.ownerName
        nameTextLayer.string = entry.node.displayName
        brandTextLayer.string = entry.node.displayBrand
        stickerLayer.contents = stickerContents()
        badgeCircleLayer.strokeColor = badgeStrokeColor.cgColor
        renderStack()
    }

    private func renderStack() {
        stackContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        dotContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard entry.clusterCount > 1, !entry.isClusterExpanded else { return }

        let visibleBackplates = min(entry.clusterCount - 1, 2)
        for index in 0..<visibleBackplates {
            let progress = CGFloat(index + 1)
            let scale = 1 - progress * 0.10
            let offsetX = (index == 0 ? -7 : 7)
            let offsetY = CGFloat(visibleBackplates - index) * 4.5
            let inset = badgeSize * (1 - scale) / 2
            let plate = CAShapeLayer()
            plate.frame = badgeLayer.bounds
                .insetBy(dx: inset, dy: inset)
                .offsetBy(dx: CGFloat(offsetX), dy: offsetY)
            plate.path = UIBezierPath(ovalIn: plate.bounds).cgPath
            plate.fillColor = UIColor.white.withAlphaComponent(0.94 - CGFloat(index) * 0.08).cgColor
            plate.strokeColor = UIColor.black.withAlphaComponent(0.12).cgColor
            plate.lineWidth = 1
            plate.shadowColor = UIColor.black.cgColor
            plate.shadowOpacity = 0.075
            plate.shadowRadius = 4
            plate.shadowOffset = CGSize(width: 0, height: 2)
            stackContainerLayer.addSublayer(plate)

            let accentDot = CAShapeLayer()
            accentDot.frame = CGRect(
                x: plate.bounds.midX - 3,
                y: plate.bounds.midY - 3,
                width: 6,
                height: 6
            )
            accentDot.path = UIBezierPath(ovalIn: accentDot.bounds).cgPath
            accentDot.fillColor = nodeColor.withAlphaComponent(0.38 - CGFloat(index) * 0.08).cgColor
            plate.addSublayer(accentDot)
        }

        let countBadge = CALayer()
        countBadge.frame = CGRect(x: badgeLayer.bounds.maxX - 14, y: badgeLayer.bounds.maxY - 13, width: 17, height: 17)
        countBadge.backgroundColor = nodeColor.withAlphaComponent(0.94).cgColor
        countBadge.cornerRadius = 8.5
        countBadge.masksToBounds = true
        dotContainerLayer.addSublayer(countBadge)

        let countText = CATextLayer()
        countText.frame = CGRect(x: 0, y: 2.1, width: 17, height: 12)
        configureTextLayer(
            countText,
            text: "\(entry.clusterCount)",
            font: .systemFont(ofSize: 8.2, weight: .black),
            color: .white,
            alignment: .center
        )
        countBadge.addSublayer(countText)
    }

    private func setupLabel() {
        labelContainerLayer.frame = CGRect(x: 0, y: 37, width: labelWidth, height: 28)
        labelContainerLayer.backgroundColor = UIColor.white.withAlphaComponent(0.92).cgColor
        labelContainerLayer.cornerRadius = 9
        labelContainerLayer.shadowColor = UIColor.black.cgColor
        labelContainerLayer.shadowOpacity = 0.06
        labelContainerLayer.shadowRadius = 4
        labelContainerLayer.shadowOffset = CGSize(width: 0, height: 2)

        sideTextLayer.frame = CGRect(x: 6, y: 2, width: labelWidth - 12, height: 8)
        configureTextLayer(sideTextLayer, text: entry.ownerName, font: .systemFont(ofSize: 7, weight: .bold), color: .secondaryLabel, alignment: .center)
        labelContainerLayer.addSublayer(sideTextLayer)

        nameTextLayer.frame = CGRect(x: 6, y: 9, width: labelWidth - 12, height: 10)
        configureTextLayer(nameTextLayer, text: entry.node.displayName, font: .systemFont(ofSize: 8.5, weight: .semibold), color: .label, alignment: .center)
        labelContainerLayer.addSublayer(nameTextLayer)

        brandTextLayer.frame = CGRect(x: 6, y: 18, width: labelWidth - 12, height: 9)
        configureTextLayer(brandTextLayer, text: entry.node.displayBrand, font: .systemFont(ofSize: 7.5), color: .secondaryLabel, alignment: .center)
        labelContainerLayer.addSublayer(brandTextLayer)
    }

    private func configureTextLayer(_ layer: CATextLayer, text: String, font: UIFont, color: UIColor, alignment: CATextLayerAlignmentMode) {
        layer.string = text
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.alignmentMode = alignment
        layer.contentsScale = UIScreen.main.scale
        layer.truncationMode = .end
        layer.isWrapped = false
    }

    private func stickerContents() -> CGImage? {
        if let cgImage = entry.node.representative.stickerRenderImage?.cgImage {
            return cgImage
        }
        guard let image = UIImage(systemName: "cup.and.saucer.fill")?.withTintColor(UIColor.brown.withAlphaComponent(0.62), renderingMode: .alwaysOriginal) else {
            return nil
        }
        return UIGraphicsImageRenderer(size: stickerLayer.bounds.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: stickerLayer.bounds.size))
        }.cgImage
    }

    private var nodeColor: UIColor {
        ComparisonOwnerPalette.uiColor(index: entry.ownerIndex)
    }

    private var badgeStrokeColor: UIColor {
        UIColor.black.withAlphaComponent(0.18)
    }
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

    private var selectedNode: ComparisonDrinkNode {
        selectedEntry.node
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 28, 430)
            ZStack {
                Color.black.opacity(0.1)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedNode.displayName)
                                .font(.title3.weight(.black))
                                .lineLimit(1)
                            Text(summaryText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
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

                    ForEach(rows) { row in
                        ComparisonStackCard(
                            ownerName: row.ownerName,
                            node: row.node,
                            accent: row.accent,
                            isFocused: row.isFocused
                        )
                    }
                }
                .padding(16)
                .frame(width: width)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 28, y: 16)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.48)
                .onTapGesture {}
            }
        }
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
        HStack(spacing: 12) {
            sticker
                .frame(width: 72, height: 86)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(ownerName)
                        .font(.caption.weight(.black))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(node == nil ? Color.secondary : Color.white)
                        .background(node == nil ? Color(.secondarySystemGroupedBackground) : accent)
                        .clipShape(Capsule())
                    Spacer()
                    if let node {
                        Text(String(format: "%.2f", node.aggregateRating))
                            .font(.headline.weight(.black).monospacedDigit())
                    }
                }

                if let node {
                    Text(node.displayBrand)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(node.displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        infoPill("甜度", node.representative.sweetness)
                        infoPill("冰度", node.representative.iceLevel)
                        infoPill("杯数", "\(node.totalCupCount)")
                    }
                    Text(displayNote(for: node))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("未记录这杯")
                        .font(.subheadline.weight(.bold))
                    Text("这本图鉴里暂时没有对应饮品。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isFocused ? accent.opacity(0.76) : .black.opacity(0.06), lineWidth: isFocused ? 1.6 : 1)
        )
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

    private func infoPill(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.white.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func displayNote(for node: ComparisonDrinkNode) -> String {
        let note = node.representative.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        let location = node.representative.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty { return location }
        return node.consumedCount > 1 ? "共 \(node.consumedCount) 条记录" : "无备注"
    }
}

private func comparisonWithoutLayerActions(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
}

private extension UIColor {
    func blended(with color: UIColor, amount: CGFloat) -> UIColor {
        let clamped = min(1, max(0, amount))
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 * (1 - clamped) + r2 * clamped,
            green: g1 * (1 - clamped) + g2 * clamped,
            blue: b1 * (1 - clamped) + b2 * clamped,
            alpha: a1 * (1 - clamped) + a2 * clamped
        )
    }
}
