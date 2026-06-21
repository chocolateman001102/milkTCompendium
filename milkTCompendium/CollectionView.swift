import Combine
import SwiftData
import SwiftUI
import UIKit

private struct CollectionDerivedData {
    var displayItems: [LadderDrinkDisplayItem]
    var filteredItems: [LadderDrinkDisplayItem]
    var sortedItems: [LadderDrinkDisplayItem]
    var brandOptions: [String]
}

private final class CollectionDerivedDataCache: ObservableObject {
    private var cachedKey: String?
    private var cachedData: CollectionDerivedData?

    func snapshot(for key: String, build: () -> CollectionDerivedData) -> CollectionDerivedData {
        if cachedKey == key, let cachedData {
            return cachedData
        }

        let data = build()
        cachedKey = key
        cachedData = data
        return data
    }
}

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Drink.createdAt, order: .reverse) private var drinks: [Drink]
    @ObservedObject var sharedStore: SharedCompendiumStore
    @ObservedObject var tasteStatsStore: TasteExchangeStatsStore
    @State private var selectedCompendiumID = "mine"
    @State private var showingTransfer = false
    @State private var draggingItem: LadderDrinkDisplayItem?
    @State private var dragTranslation: CGSize = .zero
    @State private var isOverDeleteTarget = false
    @State private var selectedItem: LadderDrinkDisplayItem?
    @State private var editingDrink: Drink?
    @State private var ladderScale: CGFloat = Self.defaultLadderScale
    @State private var searchText = ""
    @State private var selectedBrandFilter: String?
    @State private var selectedRatingBand: LadderRatingBand = .all
    @State private var isFilterPanelExpanded = false
    @StateObject private var derivedDataCache = CollectionDerivedDataCache()
    @StateObject private var ladderLayoutCache = LadderLayoutCache()
    let onStartCapture: () -> Void
    let onStartPhotoImport: () -> Void

    fileprivate static let defaultLadderScale: CGFloat = 0.44
    fileprivate static let labelFadeStartScale: CGFloat = 0.9
    fileprivate static let labelRevealScale: CGFloat = 1.1
    private let ladderTopControlClearance: CGFloat = 142
    private static let preferredSameColumnRatingGap: Double = 0.20
    private static let iconCollisionTolerance: CGFloat = 4

    /// Stickers are always visible, so they are laid out against the largest
    /// content-space size they can reach at the minimum zoom.
    private static let layoutCounterScale: CGFloat = 1 / pow(defaultLadderScale, 0.46)
    private static let labelLayoutCounterScale: CGFloat = 1 / pow(labelRevealScale, 0.46)

    private var isShowingMine: Bool {
        selectedCompendiumID == "mine"
    }

    private var activeSharedCompendium: SharedCompendium? {
        sharedStore.compendiums.first { $0.id == selectedCompendiumID }
    }

    private var displayItems: [LadderDrinkDisplayItem] {
        derivedData.displayItems
    }

    private var filteredDisplayItems: [LadderDrinkDisplayItem] {
        derivedData.filteredItems
    }

    private var sortedItems: [LadderDrinkDisplayItem] {
        derivedData.sortedItems
    }

    private var brandFilterOptions: [String] {
        derivedData.brandOptions
    }

    private var derivedData: CollectionDerivedData {
        let items: [LadderDrinkDisplayItem]
        if let activeSharedCompendium, !isShowingMine {
            items = activeSharedCompendium.drinks.map {
                LadderDrinkDisplayItem(sharedDrink: $0, ownerID: activeSharedCompendium.ownerID)
            }
        } else {
            items = drinks.map(LadderDrinkDisplayItem.init(drink:))
        }

        let key = derivedDataCacheKey(for: items)
        return derivedDataCache.snapshot(for: key) {
            let brandOptions = Self.brandOptions(from: items)
            let normalizedQuery = normalizedSearchText
            let rankByID = Self.searchRanks(for: items, normalizedQuery: normalizedQuery)
            let filteredItems = items
                .filter { item in
                    matchesActiveFilters(item, brandOptions: brandOptions, normalizedQuery: normalizedQuery, rankByID: rankByID)
                }
                .sorted { first, second in
                    filteredSort(first, second, rankByID: rankByID)
                }
            let sortedItems = filteredItems.sorted { first, second in
                if first.rating == second.rating {
                    let firstScore = rankByID[first.id] ?? 0
                    let secondScore = rankByID[second.id] ?? 0
                    if firstScore != secondScore {
                        return firstScore > secondScore
                    }
                    return first.createdAt > second.createdAt
                }
                return first.rating > second.rating
            }

            return CollectionDerivedData(
                displayItems: items,
                filteredItems: filteredItems,
                sortedItems: sortedItems,
                brandOptions: brandOptions
            )
        }
    }

    private func derivedDataCacheKey(for items: [LadderDrinkDisplayItem]) -> String {
        let filterKey = [
            selectedCompendiumID,
            normalizedSearchText,
            selectedBrandFilter ?? "*",
            selectedRatingBand.id
        ].joined(separator: "#")
        let itemKey = items.map { item in
            [
                item.id,
                String(format: "%.3f", item.rating),
                item.brand,
                item.name,
                item.sweetness,
                item.iceLevel,
                String(format: "%.3f", item.consumedAt.timeIntervalSince1970),
                item.location,
                item.note,
                item.isLimited ? "1" : "0",
                "\(item.cupCount)",
                item.stickerImageName ?? item.stickerFileURL?.lastPathComponent ?? "",
                String(format: "%.3f", item.createdAt.timeIntervalSince1970)
            ].joined(separator: "#")
        }
        .joined(separator: "|")
        return "\(filterKey):\(itemKey)"
    }

    private static func brandOptions(from items: [LadderDrinkDisplayItem]) -> [String] {
        Array(
            Set(
                items
                    .map { $0.brand.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedBrandFilter != nil
            || selectedRatingBand != .all
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if displayItems.isEmpty {
                    Text(isShowingMine ? "拉动右下角的小标记录" : "这本图鉴暂时没有记录")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredDisplayItems.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("没有匹配的饮品")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ratingLadder
                }
            }

            LadderTopDock(
                searchText: $searchText,
                selectedBrand: $selectedBrandFilter,
                selectedRatingBand: $selectedRatingBand,
                isFilterPanelExpanded: $isFilterPanelExpanded,
                isShowingMine: isShowingMine,
                selectedCompendiumID: selectedCompendiumID,
                currentCompendiumTitle: currentCompendiumTitle,
                currentCompendiumSubtitle: currentCompactSubtitle,
                sharedCompendiums: sharedStore.compendiums,
                brandOptions: brandFilterOptions,
                filteredCount: filteredDisplayItems.count,
                totalCount: displayItems.count,
                hasItems: !displayItems.isEmpty,
                hasActiveFilter: hasActiveFilter,
                onSwitchCompendium: switchCompendium,
                onOpenProfile: { showingTransfer = true },
                onClear: clearFilters
            )
            .padding(.top, 12)
            .padding(.horizontal, 12)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedCompendiumID) { _, _ in
            validateBrandFilter()
        }
        .onChange(of: brandFilterOptions) { _, _ in
            validateBrandFilter()
        }
        .overlay(alignment: .bottomTrailing) {
            CaptureBookmark(onCapture: {
                onStartCapture()
            }, onPhotoImport: {
                onStartPhotoImport()
            })
            .padding(.bottom, 48)
        }
        .overlay(alignment: .bottom) {
            if draggingItem != nil {
                DeleteDropZone(isActive: isOverDeleteTarget)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let selectedItem {
                FloatingDrinkCardOverlay(
                    item: selectedItem,
                    onClose: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            self.selectedItem = nil
                        }
                    },
                    onEdit: {
                        editingDrink = selectedItem.localDrink
                        self.selectedItem = nil
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(20)
            }
        }
        .navigationDestination(isPresented: editingDrinkBinding) {
            if let editingDrink {
                DrinkFormView(mode: .edit(editingDrink)) {}
            }
        }
        .sheet(isPresented: $showingTransfer) {
            NearbyTransferView(drinks: drinks, sharedStore: sharedStore, tasteStatsStore: tasteStatsStore) { compendium in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    switchCompendium(to: compendium.id)
                }
            }
        }
    }

    private var ratingLadder: some View {
        GeometryReader { proxy in
            let layoutKey = ladderLayoutCacheKey(for: proxy.size)
            let layout = ladderLayoutCache.snapshot(for: layoutKey) {
                let canvasSize = ladderCanvasSize(for: proxy.size)
                let metrics = LadderMetrics(size: canvasSize, topClearance: ladderTopControlClearance)
                let entries = ladderEntries(in: metrics)
                return LadderLayoutSnapshot(
                    canvasSize: canvasSize,
                    metrics: metrics,
                    entries: entries,
                    contentSignature: layoutKey
                )
            }

            ZoomableLadderView(
                zoomScale: $ladderScale,
                contentSize: layout.canvasSize,
                metrics: layout.metrics,
                entries: layout.entries,
                contentSignature: layout.contentSignature,
                allowsDragging: isShowingMine,
                draggedItemID: draggingItem?.id,
                dragTranslation: dragTranslation,
                isOverDeleteTarget: isOverDeleteTarget,
                onTapItem: { item in
                    guard draggingItem == nil, dragTranslation == .zero else { return }
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        selectedItem = item
                    }
                },
                onDragChanged: { item, translation, isOverDelete in
                    guard item.localDrink != nil else { return }
                    let isStartingDrag = draggingItem?.id != item.id
                    if isStartingDrag {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectedItem = nil
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.68)) {
                            draggingItem = item
                        }
                    } else {
                        draggingItem = item
                    }

                    var dragTransaction = Transaction(animation: nil)
                    dragTransaction.disablesAnimations = true
                    withTransaction(dragTransaction) {
                        dragTranslation = translation
                    }

                    guard isOverDelete != isOverDeleteTarget else { return }
                    UIImpactFeedbackGenerator(style: isOverDelete ? .medium : .light).impactOccurred()
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.68)) {
                        isOverDeleteTarget = isOverDelete
                    }
                },
                onDragEnded: { item, shouldDelete in
                    if shouldDelete, let drink = item?.localDrink {
                        delete(drink)
                    }

                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        draggingItem = nil
                        dragTranslation = .zero
                        isOverDeleteTarget = false
                    }
                }
            )
            .background(Color(.systemGroupedBackground))
            .accessibilityLabel("评分天梯图")
        }
    }

    private var topControls: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    switchCompendium(to: "mine")
                } label: {
                    Label("我的", systemImage: selectedCompendiumID == "mine" ? "checkmark" : "cup.and.saucer")
                }

                ForEach(sharedStore.compendiums) { compendium in
                    Button {
                        switchCompendium(to: compendium.id)
                    } label: {
                        Label(compendium.ownerName, systemImage: selectedCompendiumID == compendium.id ? "checkmark" : "book")
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(currentCompendiumTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 204, alignment: .leading)

                        Text(currentCompendiumSubtitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            Button {
                showingTransfer = true
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 36)
                    .background(.black.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(LeverControlButtonStyle())
        }
        .padding(5)
        .leverGlassSurface(cornerRadius: 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var currentCompendiumTitle: String {
        if let activeSharedCompendium, !isShowingMine {
            return activeSharedCompendium.ownerName
        }
        return "我的"
    }

    private var currentCompendiumSubtitle: String {
        if isShowingMine {
            let cupCount = TasteScoreCalculator.effectiveCupCount(drinks: drinks)
            let collectionCount = drinks.count
            return "\(tasteScore.levelName) · \(String(format: "%.2f", tasteScore.score)) · \(cupCount) 杯 · \(collectionCount) 项"
        }

        return "共享图鉴 · \(displayItems.count) 项"
    }

    private var currentCompactSubtitle: String {
        if isShowingMine {
            return "\(String(format: "%.2f", tasteScore.score)) · \(drinks.count) 项"
        }

        return "\(displayItems.count) 项"
    }

    private var tasteScore: TasteScoreResult {
        TasteScoreCalculator.calculate(localDrinks: drinks, stats: tasteStatsStore.stats)
    }

    private var normalizedSearchText: String {
        Self.normalizedSearch(searchText)
    }

    private func matchesActiveFilters(_ item: LadderDrinkDisplayItem) -> Bool {
        matchesActiveFilters(
            item,
            brandOptions: brandFilterOptions,
            normalizedQuery: normalizedSearchText,
            rankByID: [item.id: searchRank(for: item)]
        )
    }

    private func matchesActiveFilters(
        _ item: LadderDrinkDisplayItem,
        brandOptions: [String],
        normalizedQuery query: String,
        rankByID: [String: Int]
    ) -> Bool {
        if let selectedBrandFilter,
           brandOptions.contains(selectedBrandFilter),
           item.brand.trimmingCharacters(in: .whitespacesAndNewlines) != selectedBrandFilter {
            return false
        }

        guard selectedRatingBand.contains(item.rating) else {
            return false
        }

        guard !query.isEmpty else {
            return true
        }

        return (rankByID[item.id] ?? 0) > 0
    }

    private func filteredSort(_ first: LadderDrinkDisplayItem, _ second: LadderDrinkDisplayItem) -> Bool {
        filteredSort(first, second, rankByID: [
            first.id: searchRank(for: first),
            second.id: searchRank(for: second)
        ])
    }

    private func filteredSort(
        _ first: LadderDrinkDisplayItem,
        _ second: LadderDrinkDisplayItem,
        rankByID: [String: Int]
    ) -> Bool {
        let firstScore = rankByID[first.id] ?? 0
        let secondScore = rankByID[second.id] ?? 0
        if firstScore != secondScore {
            return firstScore > secondScore
        }
        if first.rating != second.rating {
            return first.rating > second.rating
        }
        return first.createdAt > second.createdAt
    }

    private func searchRank(for item: LadderDrinkDisplayItem) -> Int {
        let query = normalizedSearchText
        guard !query.isEmpty else { return 0 }
        return Self.searchRank(for: item, normalizedQuery: query)
    }

    private static func searchRanks(for items: [LadderDrinkDisplayItem], normalizedQuery query: String) -> [String: Int] {
        guard !query.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, searchRank(for: item, normalizedQuery: query))
        })
    }

    private static func searchRank(for item: LadderDrinkDisplayItem, normalizedQuery query: String) -> Int {
        let fields = [
            item.name,
            item.brand,
            item.sweetness,
            item.iceLevel,
            item.location,
            item.note
        ]
        .map(normalizedSearch)
        .filter { !$0.isEmpty }

        var bestScore = 0
        for (index, field) in fields.enumerated() {
            let priority = max(0, 6 - index)
            if field == query {
                bestScore = max(bestScore, 120 + priority)
            } else if field.hasPrefix(query) {
                bestScore = max(bestScore, 96 + priority)
            } else if field.contains(query) {
                bestScore = max(bestScore, 78 + priority)
            } else if orderedCharacterMatch(query: query, in: field) {
                bestScore = max(bestScore, 46 + priority)
            } else {
                let overlap = characterOverlap(query: query, field: field)
                if overlap > 0 {
                    bestScore = max(bestScore, min(36, overlap * 8) + priority)
                }
            }
        }
        return bestScore
    }

    private static func normalizedSearch(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isNewline && !$0.isPunctuation }
    }

    private static func orderedCharacterMatch(query: String, in field: String) -> Bool {
        guard !query.isEmpty else { return true }
        var searchStart = field.startIndex
        for character in query {
            guard let foundIndex = field[searchStart...].firstIndex(of: character) else {
                return false
            }
            searchStart = field.index(after: foundIndex)
        }
        return true
    }

    private static func characterOverlap(query: String, field: String) -> Int {
        let fieldCharacters = Set(field)
        return Set(query).filter { fieldCharacters.contains($0) }.count
    }

    private func switchCompendium(to id: String) {
        guard selectedCompendiumID != id else { return }
        selectedCompendiumID = id
        selectedItem = nil
        draggingItem = nil
        dragTranslation = .zero
        isOverDeleteTarget = false
        ladderScale = Self.defaultLadderScale
    }

    private func clearFilters() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            searchText = ""
            selectedBrandFilter = nil
            selectedRatingBand = .all
            isFilterPanelExpanded = false
        }
    }

    private func validateBrandFilter() {
        guard let selectedBrandFilter else { return }
        if !brandFilterOptions.contains(selectedBrandFilter) {
            self.selectedBrandFilter = nil
        }
    }

    private var editingDrinkBinding: Binding<Bool> {
        Binding {
            editingDrink != nil
        } set: { isPresented in
            if !isPresented {
                editingDrink = nil
            }
        }
    }

    fileprivate static func clampedLadderScale(_ scale: CGFloat) -> CGFloat {
        min(2.4, max(defaultLadderScale, scale))
    }

    fileprivate static func nodeCounterScale(for scale: CGFloat) -> CGFloat {
        1 / pow(max(clampedLadderScale(scale), 0.01), 0.46)
    }

    fileprivate static func labelRevealProgress(for scale: CGFloat) -> CGFloat {
        let rawProgress = (clampedLadderScale(scale) - labelFadeStartScale) / (labelRevealScale - labelFadeStartScale)
        let clamped = min(1, max(0, rawProgress))
        return clamped * clamped * (3 - 2 * clamped)
    }

    fileprivate static func settledLabelOpacity(for scale: CGFloat) -> CGFloat {
        labelRevealProgress(for: scale) > 0 ? 1 : 0
    }

    private func ladderLayoutCacheKey(for viewport: CGSize) -> String {
        let viewportKey = "\(Int(viewport.width.rounded()))x\(Int(viewport.height.rounded()))"
        let itemKey = filteredDisplayItems.map { item in
            [
                item.id,
                String(format: "%.3f", item.rating),
                item.brand,
                item.name,
                item.sweetness,
                item.iceLevel,
                String(format: "%.3f", item.consumedAt.timeIntervalSince1970),
                item.location,
                item.note,
                item.isLimited ? "1" : "0",
                "\(item.cupCount)",
                item.stickerImageName ?? item.stickerFileURL?.lastPathComponent ?? "",
                String(format: "%.3f", item.createdAt.timeIntervalSince1970)
            ].joined(separator: "#")
        }
        .joined(separator: "|")
        let filterKey = [
            normalizedSearchText,
            selectedBrandFilter ?? "*",
            selectedRatingBand.id
        ].joined(separator: "#")
        return "\(selectedCompendiumID):\(viewportKey):\(filterKey):\(itemKey)"
    }

    private func ladderCanvasSize(for viewport: CGSize) -> CGSize {
        let drinkCount = CGFloat(max(filteredDisplayItems.count, 1))
        let densityHeight = 920 + drinkCount * 13
        let iconProfile = LadderLayoutProfile.stable.scaled(by: Self.layoutCounterScale)
        let labelProfile = LadderLayoutProfile.stable.scaledSizes(by: Self.labelLayoutCounterScale)
        let iconCollisionHeight = iconProfile.compactNodeSize.height + iconProfile.compactCollisionPadding.height
        let labelCollisionHeight = labelProfile.labelBubbleSize.height + labelProfile.labelCollisionPadding.height
        let requiredPlotHeight = iconCollisionHeight * 5 / Self.preferredSameColumnRatingGap
        let requiredHeight = ladderTopControlClearance + requiredPlotHeight + 34
        let baseHeight = max(viewport.height * 2.28, densityHeight, requiredHeight)
        let estimatedPlotBottom = max(ladderTopControlClearance + 720, baseHeight - 34)
        let estimatedPlotHeight = max(1, estimatedPlotBottom - ladderTopControlClearance)
        let ratingWindow = Double(max(iconCollisionHeight, labelCollisionHeight) / estimatedPlotHeight * 5)
        let requiredColumnsPerSide = max(2, Int(ceil(CGFloat(maxRatingClusterCount(in: ratingWindow)) / 2)))
        let columnSpacing = iconProfile.columnSpacing
        let requiredSideLaneWidth = columnSpacing * 0.4
            + CGFloat(max(0, requiredColumnsPerSide - 1)) * columnSpacing
            + 48
        let densityWidth = (requiredSideLaneWidth + 48) * 2
        let baseWidth = max(viewport.width * 2.42, 960, densityWidth)
        return CGSize(
            width: baseWidth,
            height: baseHeight
        )
    }

    private func ladderEntries(in metrics: LadderMetrics) -> [LadderDrinkEntry] {
        var iconFrames: [CGRect] = []
        var placements: [String: LadderPlacement] = [:]
        let rows = ratingRows()
        let profile = LadderLayoutProfile.stable
        let iconProfile = profile.scaled(by: Self.layoutCounterScale)
        let labelProfile = profile.scaledSizes(by: Self.labelLayoutCounterScale)
        let iconSize = iconProfile.compactNodeSize
        let iconPadding = iconProfile.compactCollisionPadding
        let labelHeight = labelProfile.labelBubbleSize.height
        let labelPadding = labelProfile.labelCollisionPadding
        let columnSpacing = iconProfile.columnSpacing
        let nearestColumnDistance = columnSpacing * 0.43
        let entryMetrics = Dictionary(uniqueKeysWithValues: sortedItems.map { item in
            (item.id, LadderDrinkEntryMetrics(item: item))
        })

        rows.forEach { row in
            let anchorY = yPosition(for: row.rating, metrics: metrics)
            let startsRight = row.key.isMultiple(of: 2)

            row.items.enumerated().forEach { index, item in
                let preferredSide = alternatingSide(index: index, startsRight: startsRight)
                let secondarySide = preferredSide == .left ? LadderSide.right : .left
                let preferredColumn = index / 2
                let labelWidth = (entryMetrics[item.id]?.labelWidth ?? labelWidth(for: item)) * Self.labelLayoutCounterScale

                let placement = bestPlacement(
                    anchorY: anchorY,
                    preferredSides: [preferredSide, secondarySide],
                    preferredColumn: preferredColumn,
                    metrics: metrics,
                    nearestColumnDistance: nearestColumnDistance,
                    columnSpacing: columnSpacing,
                    iconSize: iconSize,
                    iconPadding: iconPadding,
                    labelSize: CGSize(width: labelWidth, height: labelHeight),
                    labelPadding: labelPadding,
                    iconFrames: iconFrames,
                    labelFrames: []
                )

                let position = CGPoint(
                    x: min(max(34, placement.position.x), metrics.size.width - 34),
                    y: anchorY
                )
                placements[item.id] = LadderPlacement(
                    position: position,
                    side: placement.side,
                    canShowLabel: false
                )
                let iconFrame = iconCollisionFrame(
                    for: position,
                    iconSize: iconSize,
                    iconPadding: iconPadding
                )
                iconFrames.append(iconFrame)
            }
        }

        rows.forEach { row in
            row.items.forEach { item in
                guard let placement = placements[item.id] else { return }
                placements[item.id] = LadderPlacement(
                    position: placement.position,
                    side: placement.side,
                    canShowLabel: true
                )
            }
        }

        return sortedItems.map { item in
            let placement = placements[item.id] ?? LadderPlacement(
                position: CGPoint(
                    x: metrics.centerX,
                    y: yPosition(for: item.rating, metrics: metrics)
                ),
                side: .right,
                canShowLabel: false
            )
            return LadderDrinkEntry(
                item: item,
                position: placement.position,
                side: placement.side,
                canShowLabel: placement.canShowLabel,
                metrics: entryMetrics[item.id] ?? LadderDrinkEntryMetrics(item: item)
            )
        }
    }

    private func ratingRows() -> [LadderRatingRow] {
        Dictionary(grouping: sortedItems, by: ratingRowKey(for:))
            .map { key, items in
                LadderRatingRow(
                    key: key,
                    rating: Double(key) / 100,
                    items: items.sorted {
                        if $0.createdAt == $1.createdAt {
                            return stableHash(for: $0) < stableHash(for: $1)
                        }
                        return $0.createdAt > $1.createdAt
                    }
                )
            }
            .sorted {
                if $0.key == $1.key {
                    return $0.items.count > $1.items.count
                }
                return $0.key > $1.key
            }
    }

    private func ratingRowKey(for item: LadderDrinkDisplayItem) -> Int {
        Int((min(5, max(0, item.rating)) * 100).rounded())
    }

    private func alternatingSide(index: Int, startsRight: Bool) -> LadderSide {
        let isRight = index.isMultiple(of: 2) == startsRight
        return isRight ? .right : .left
    }

    private func bestPlacement(
        anchorY: CGFloat,
        preferredSides: [LadderSide],
        preferredColumn: Int,
        metrics: LadderMetrics,
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat,
        iconSize: CGSize,
        iconPadding: CGSize,
        labelSize: CGSize,
        labelPadding: CGSize,
        iconFrames: [CGRect],
        labelFrames: [CGRect]
    ) -> LadderPlacement {
        let maxColumn = max(0, Int((metrics.sideLaneWidth - nearestColumnDistance) / columnSpacing))
        let candidates = placementCandidates(
            anchorY: anchorY,
            sides: preferredSides,
            preferredColumn: preferredColumn,
            metrics: metrics,
            maxColumn: maxColumn,
            nearestColumnDistance: nearestColumnDistance,
            columnSpacing: columnSpacing
        )

        let safeCandidates = candidates.compactMap { candidate -> LadderCandidate? in
            let position = candidate.position
            let iconFrame = iconCollisionFrame(
                for: position,
                iconSize: iconSize,
                iconPadding: iconPadding
            )
            guard isIconSafe(iconFrame, iconFrames: iconFrames, labelFrames: labelFrames) else { return nil }
            let labelFrame = labelCollisionFrame(
                for: position,
                nodeSize: labelSize,
                padding: labelPadding
            )
            let canShowLabel = isLabelSafe(labelFrame, iconFrames: iconFrames, labelFrames: labelFrames)
            return LadderCandidate(
                position: position,
                column: candidate.column,
                side: candidate.side,
                verticalOffset: candidate.verticalOffset,
                canShowLabel: canShowLabel
            )
        }

        if let best = bestLabelCandidate(safeCandidates) ?? bestCompactCandidate(safeCandidates) {
            return LadderPlacement(position: best.position, side: best.side, canShowLabel: best.canShowLabel)
        }

        return edgePlacement(
            anchorY: anchorY,
            preferredSide: preferredSides.first ?? .right,
            metrics: metrics,
            nearestColumnDistance: nearestColumnDistance,
            columnSpacing: columnSpacing
        )
    }

    private func placementCandidates(
        anchorY: CGFloat,
        sides: [LadderSide],
        preferredColumn: Int,
        metrics: LadderMetrics,
        maxColumn: Int,
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat
    ) -> [LadderCandidate] {
        columnOrder(preferredColumn: preferredColumn, maxColumn: maxColumn).flatMap { column in
            sides.map { side in
                LadderCandidate(
                    position: CGPoint(
                        x: xPosition(for: side, column: column, metrics: metrics, nearestColumnDistance: nearestColumnDistance, columnSpacing: columnSpacing),
                        y: anchorY
                    ),
                    column: column,
                    side: side,
                    verticalOffset: 0,
                    canShowLabel: false
                )
            }
        }
    }

    private func columnOrder(preferredColumn: Int, maxColumn: Int) -> [Int] {
        let clampedPreferred = min(max(0, preferredColumn), maxColumn)
        return (0...maxColumn)
            .sorted {
                let firstDistance = abs($0 - clampedPreferred)
                let secondDistance = abs($1 - clampedPreferred)
                if firstDistance == secondDistance {
                    return $0 < $1
                }
                return firstDistance < secondDistance
            }
    }

    private func bestCompactCandidate(_ candidates: [LadderCandidate]) -> LadderCandidate? {
        candidates.min { first, second in
            placementScore(for: first) < placementScore(for: second)
        }
    }

    private func bestLabelCandidate(_ candidates: [LadderCandidate]) -> LadderCandidate? {
        candidates
            .filter(\.canShowLabel)
            .min { first, second in
                placementScore(for: first) < placementScore(for: second)
            }
    }

    private func placementScore(for candidate: LadderCandidate) -> CGFloat {
        var score = CGFloat(candidate.column) * 100
        score += candidate.canShowLabel ? 0 : 12
        return score
    }

    private func edgePlacement(
        anchorY: CGFloat,
        preferredSide: LadderSide,
        metrics: LadderMetrics,
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat
    ) -> LadderPlacement {
        let maxColumn = max(0, Int((metrics.sideLaneWidth - nearestColumnDistance) / columnSpacing))
        return LadderPlacement(
            position: CGPoint(
                x: xPosition(for: preferredSide, column: maxColumn, metrics: metrics, nearestColumnDistance: nearestColumnDistance, columnSpacing: columnSpacing),
                y: anchorY
            ),
            side: preferredSide,
            canShowLabel: false
        )
    }

    private func isIconSafe(_ frame: CGRect, iconFrames: [CGRect], labelFrames: [CGRect]) -> Bool {
        !iconFrames.contains(where: { collisionFramesOverlap($0, frame, tolerance: Self.iconCollisionTolerance) })
            && !labelFrames.contains(where: { $0.intersects(frame) })
    }

    private func isLabelSafe(_ frame: CGRect, iconFrames: [CGRect], labelFrames: [CGRect]) -> Bool {
        !iconFrames.contains(where: { $0.intersects(frame) })
            && !labelFrames.contains(where: { $0.intersects(frame) })
    }

    private func collisionFramesOverlap(_ first: CGRect, _ second: CGRect, tolerance: CGFloat) -> Bool {
        first.insetBy(dx: tolerance, dy: tolerance).intersects(second.insetBy(dx: tolerance, dy: tolerance))
    }

    private func iconCollisionFrame(
        for position: CGPoint,
        iconSize: CGSize,
        iconPadding: CGSize
    ) -> CGRect {
        collisionFrame(
            centeredAt: iconCenter(for: position),
            nodeSize: iconSize,
            padding: iconPadding
        )
    }

    private func labelCollisionFrame(
        for position: CGPoint,
        nodeSize: CGSize,
        padding: CGSize
    ) -> CGRect {
        collisionFrame(
            centeredAt: labelCenter(for: position),
            nodeSize: nodeSize,
            padding: padding
        )
    }

    private func iconCenter(for position: CGPoint) -> CGPoint {
        CGPoint(
            x: position.x,
            y: position.y + LadderLayoutProfile.iconCenterYOffset * Self.layoutCounterScale
        )
    }

    private func labelCenter(for position: CGPoint) -> CGPoint {
        return CGPoint(
            x: position.x,
            y: position.y + LadderLayoutProfile.labelCenterYOffset * Self.labelLayoutCounterScale
        )
    }

    private func collisionFrame(centeredAt position: CGPoint, nodeSize: CGSize, padding: CGSize) -> CGRect {
        CGRect(
            x: position.x - nodeSize.width / 2 - padding.width / 2,
            y: position.y - nodeSize.height / 2 - padding.height / 2,
            width: nodeSize.width + padding.width,
            height: nodeSize.height + padding.height
        )
    }

    private func xPosition(
        for side: LadderSide,
        column: Int,
        metrics: LadderMetrics,
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat
    ) -> CGFloat {
        let distance = min(metrics.sideLaneWidth, nearestColumnDistance + CGFloat(column) * columnSpacing)
        return side == .left ? metrics.centerX - distance : metrics.centerX + distance
    }

    private func yPosition(for rating: Double, metrics: LadderMetrics) -> CGFloat {
        let clamped = min(5, max(0, rating))
        return metrics.plotTop + (5 - clamped) / 5 * metrics.plotHeight
    }

    private func labelWidth(for item: LadderDrinkDisplayItem) -> CGFloat {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = item.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? "未命名" : name
        let displayBrand = brand.isEmpty ? "未知品牌" : brand
        let longest = max(displayName.count, displayBrand.count)
        return min(156, max(76, CGFloat(longest) * 10 + 24))
    }

    private func maxRatingClusterCount(in ratingWindow: Double) -> Int {
        let ratings = filteredDisplayItems.map { min(5, max(0, $0.rating)) }.sorted()
        guard !ratings.isEmpty else { return 1 }
        var maxCount = 1
        var start = 0
        for end in ratings.indices {
            while ratings[end] - ratings[start] > ratingWindow {
                start += 1
            }
            maxCount = max(maxCount, end - start + 1)
        }
        return maxCount
    }

    private func stableHash(for item: LadderDrinkDisplayItem) -> Int {
        let key = "\(item.brand)|\(item.name)|\(item.createdAt.timeIntervalSince1970)"
        return key.unicodeScalars.reduce(0) { partial, scalar in
            abs((partial * 31 + Int(scalar.value)) % 10_000)
        }
    }

    private func delete(_ drink: Drink) {
        ImageStore.delete(drink.originalImageName)
        ImageStore.delete(drink.stickerImageName)
        modelContext.delete(drink)
        try? modelContext.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private enum LadderRatingBand: String, CaseIterable, Identifiable, Equatable {
    case all
    case zeroToOne
    case oneToTwo
    case twoToThree
    case threeToFour
    case fourToFive

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            return "全部分数"
        case .zeroToOne:
            return "0-1"
        case .oneToTwo:
            return "1-2"
        case .twoToThree:
            return "2-3"
        case .threeToFour:
            return "3-4"
        case .fourToFive:
            return "4-5"
        }
    }

    func contains(_ rating: Double) -> Bool {
        let clamped = min(5, max(0, rating))
        switch self {
        case .all:
            return true
        case .zeroToOne:
            return clamped >= 0 && clamped < 1
        case .oneToTwo:
            return clamped >= 1 && clamped < 2
        case .twoToThree:
            return clamped >= 2 && clamped < 3
        case .threeToFour:
            return clamped >= 3 && clamped < 4
        case .fourToFive:
            return clamped >= 4 && clamped <= 5
        }
    }
}

private struct LadderTopDock: View {
    @Binding var searchText: String
    @Binding var selectedBrand: String?
    @Binding var selectedRatingBand: LadderRatingBand
    @Binding var isFilterPanelExpanded: Bool

    let isShowingMine: Bool
    let selectedCompendiumID: String
    let currentCompendiumTitle: String
    let currentCompendiumSubtitle: String
    let sharedCompendiums: [SharedCompendium]
    let brandOptions: [String]
    let filteredCount: Int
    let totalCount: Int
    let hasItems: Bool
    let hasActiveFilter: Bool
    let onSwitchCompendium: (String) -> Void
    let onOpenProfile: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                compendiumMenu

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("搜索品牌、品名、口味", text: $searchText)
                    .font(.caption.weight(.medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                if hasItems {
                    Text("\(filteredCount)/\(totalCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(hasActiveFilter ? .primary : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(hasActiveFilter ? 0.09 : 0.045))
                        .clipShape(Capsule())
                }

                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        isFilterPanelExpanded.toggle()
                    }
                } label: {
                    dockIcon(
                        systemName: "slider.horizontal.3",
                        isActive: isFilterPanelExpanded || hasActiveFilter
                    )
                }
                .disabled(!hasItems)
                .buttonStyle(LeverControlButtonStyle())

                if hasActiveFilter {
                    Button(action: onClear) {
                        dockIcon(systemName: "xmark", isActive: true)
                    }
                    .buttonStyle(LeverControlButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }

                Button(action: onOpenProfile) {
                    dockIcon(systemName: "dot.radiowaves.left.and.right", isActive: true)
                }
                .buttonStyle(LeverControlButtonStyle())
            }
            .padding(5)
            .background(.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.black.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 10, y: 5)

            if isFilterPanelExpanded && hasItems {
                filterPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 560)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isFilterPanelExpanded)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: hasActiveFilter)
    }

    private var compendiumMenu: some View {
        Menu {
            Button {
                onSwitchCompendium("mine")
            } label: {
                Label("我的", systemImage: isShowingMine ? "checkmark" : "cup.and.saucer")
            }

            ForEach(sharedCompendiums) { compendium in
                Button {
                    onSwitchCompendium(compendium.id)
                } label: {
                    Label(compendium.ownerName, systemImage: selectedCompendiumID == compendium.id ? "checkmark" : "book")
                }
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(currentCompendiumTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(currentCompendiumSubtitle)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 82, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var filterPanel: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    selectedBrand = nil
                } label: {
                    filterMenuTitle("全部品牌", isSelected: selectedBrand == nil)
                }

                ForEach(brandOptions, id: \.self) { brand in
                    Button {
                        selectedBrand = brand
                    } label: {
                        filterMenuTitle(brand, isSelected: selectedBrand == brand)
                    }
                }
            } label: {
                filterChip(
                    title: selectedBrand ?? "全部品牌",
                    isActive: selectedBrand != nil
                )
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(LadderRatingBand.allCases) { band in
                    Button {
                        selectedRatingBand = band
                    } label: {
                        filterMenuTitle(band.title, isSelected: selectedRatingBand == band)
                    }
                }
            } label: {
                filterChip(
                    title: selectedRatingBand.title,
                    isActive: selectedRatingBand != .all
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(7)
        .background(.white.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    private func dockIcon(systemName: String, isActive: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isActive ? .white : .primary)
            .frame(width: 30, height: 30)
            .background(isActive ? Color.black.opacity(0.9) : Color.black.opacity(0.055))
            .clipShape(Capsule())
    }

    private func filterMenuTitle(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    private func filterChip(title: String, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.68)
        }
        .foregroundStyle(isActive ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Color.black.opacity(0.88) : Color.black.opacity(0.06))
        .clipShape(Capsule())
    }
}

private struct LadderLayoutSnapshot {
    let canvasSize: CGSize
    let metrics: LadderMetrics
    let entries: [LadderDrinkEntry]
    let contentSignature: String
}

private final class LadderLayoutCache: ObservableObject {
    private var snapshots: [String: LadderLayoutSnapshot] = [:]
    private var accessOrder: [String] = []
    private let capacity = 12

    func snapshot(for key: String, build: () -> LadderLayoutSnapshot) -> LadderLayoutSnapshot {
        if let cachedSnapshot = snapshots[key] {
            markRecentlyUsed(key)
            return cachedSnapshot
        }

        let snapshot = build()
        snapshots[key] = snapshot
        markRecentlyUsed(key)
        trimIfNeeded()
        return snapshot
    }

    private func markRecentlyUsed(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimIfNeeded() {
        while accessOrder.count > capacity, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            snapshots[oldest] = nil
        }
    }
}

private struct ZoomableLadderView: UIViewRepresentable {
    @Binding var zoomScale: CGFloat
    let contentSize: CGSize
    let metrics: LadderMetrics
    let entries: [LadderDrinkEntry]
    let contentSignature: String
    let allowsDragging: Bool
    let draggedItemID: String?
    let dragTranslation: CGSize
    let isOverDeleteTarget: Bool
    let onTapItem: (LadderDrinkDisplayItem) -> Void
    let onDragChanged: (LadderDrinkDisplayItem, CGSize, Bool) -> Void
    let onDragEnded: (LadderDrinkDisplayItem?, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            zoomScale: $zoomScale,
            allowsDragging: allowsDragging,
            onTapItem: onTapItem,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.pinchGestureRecognizer?.delegate = context.coordinator
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.28
        longPressGesture.allowableMovement = 44
        longPressGesture.delegate = context.coordinator
        longPressGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(longPressGesture)

        scrollView.minimumZoomScale = CollectionView.defaultLadderScale
        scrollView.maximumZoomScale = 2.4
        scrollView.zoomScale = zoomScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.layer.drawsAsynchronously = true

        let canvasView = LadderCanvasUIView()
        canvasView.backgroundColor = .clear
        canvasView.layer.drawsAsynchronously = true
        canvasView.frame = CGRect(origin: .zero, size: contentSize)
        canvasView.configure(metrics: metrics, entries: entries, contentSize: contentSize)
        canvasView.applyZoom(scale: zoomScale, mode: .settled)
        canvasView.updateDragState(draggedItemID: draggedItemID, translation: dragTranslation, isOverDeleteTarget: isOverDeleteTarget)
        scrollView.addSubview(canvasView)
        scrollView.contentSize = contentSize
        context.coordinator.canvasView = canvasView

        context.coordinator.scrollView = scrollView
        context.coordinator.contentSize = contentSize
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let contentDidChange = context.coordinator.contentSignature != contentSignature
        let sizeDidChange = context.coordinator.contentSize != contentSize
        if contentDidChange {
            context.coordinator.contentSignature = contentSignature
            context.coordinator.didCenterInitialPosition = false
        }

        context.coordinator.zoomScale = $zoomScale
        context.coordinator.entries = entries
        context.coordinator.allowsDragging = allowsDragging
        context.coordinator.contentSize = contentSize
        if sizeDidChange {
            scrollView.contentSize = contentSize
            context.coordinator.canvasView?.frame = CGRect(origin: .zero, size: contentSize)
        }

        if contentDidChange || sizeDidChange {
            context.coordinator.canvasView?.configure(metrics: metrics, entries: entries, contentSize: contentSize)
        }
        context.coordinator.canvasView?.updateDragState(
            draggedItemID: draggedItemID,
            translation: dragTranslation,
            isOverDeleteTarget: isOverDeleteTarget
        )

        if !context.coordinator.isZooming,
           abs(scrollView.zoomScale - zoomScale) > 0.001 {
            scrollView.setZoomScale(zoomScale, animated: false)
        }
        context.coordinator.canvasView?.applyZoom(
            scale: scrollView.zoomScale,
            mode: context.coordinator.isZooming ? .preview : .settled
        )

        if !context.coordinator.isZooming || contentDidChange || sizeDidChange {
            scrollView.layoutIfNeeded()
        }
        context.coordinator.centerInitialPositionIfNeeded()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var zoomScale: Binding<CGFloat>
        var entries: [LadderDrinkEntry] = []
        var allowsDragging: Bool
        let onTapItem: (LadderDrinkDisplayItem) -> Void
        let onDragChanged: (LadderDrinkDisplayItem, CGSize, Bool) -> Void
        let onDragEnded: (LadderDrinkDisplayItem?, Bool) -> Void
        weak var canvasView: LadderCanvasUIView?
        weak var scrollView: UIScrollView?
        var isZooming = false
        var didCenterInitialPosition = false
        var contentSize: CGSize = .zero
        var contentSignature = ""
        var lastReportedZoomScale: CGFloat = 0
        var longPressedItem: LadderDrinkDisplayItem?
        var longPressStartContentPoint: CGPoint = .zero
        var lastZoomInteractionAt: TimeInterval = 0
        private let zoomGestureCooldown: TimeInterval = 0.3

        init(
            zoomScale: Binding<CGFloat>,
            allowsDragging: Bool,
            onTapItem: @escaping (LadderDrinkDisplayItem) -> Void,
            onDragChanged: @escaping (LadderDrinkDisplayItem, CGSize, Bool) -> Void,
            onDragEnded: @escaping (LadderDrinkDisplayItem?, Bool) -> Void
        ) {
            self.zoomScale = zoomScale
            self.allowsDragging = allowsDragging
            self.onTapItem = onTapItem
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvasView
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  canStartDrinkGesture,
                  let scrollView,
                  let entry = entry(at: recognizer.location(in: scrollView)) else {
                return
            }
            onTapItem(entry.item)
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard allowsDragging, canStartDrinkGesture, let scrollView else { return }
            let point = recognizer.location(in: scrollView)

            switch recognizer.state {
            case .began:
                guard let entry = entry(at: point), entry.item.localDrink != nil else { return }
                longPressedItem = entry.item
                longPressStartContentPoint = contentPoint(for: point)
                scrollView.isScrollEnabled = false
                onDragChanged(entry.item, .zero, isPointOverDeleteTarget(point, in: scrollView))

            case .changed:
                guard let item = longPressedItem else { return }
                onDragChanged(item, contentTranslation(to: point), isPointOverDeleteTarget(point, in: scrollView))

            case .ended:
                onDragEnded(longPressedItem, isPointOverDeleteTarget(point, in: scrollView))
                longPressedItem = nil
                scrollView.isScrollEnabled = true

            case .cancelled, .failed:
                onDragEnded(longPressedItem, false)
                longPressedItem = nil
                scrollView.isScrollEnabled = true

            default:
                break
            }
        }

        private func contentTranslation(to scrollViewPoint: CGPoint) -> CGSize {
            let contentPoint = contentPoint(for: scrollViewPoint)
            return CGSize(
                width: contentPoint.x - longPressStartContentPoint.x,
                height: contentPoint.y - longPressStartContentPoint.y
            )
        }

        private func contentPoint(for scrollViewPoint: CGPoint) -> CGPoint {
            guard let scrollView, let canvasView else { return scrollViewPoint }
            return canvasView.convert(scrollViewPoint, from: scrollView)
        }

        private func isPointOverDeleteTarget(_ point: CGPoint, in scrollView: UIScrollView) -> Bool {
            point.y >= scrollView.bounds.height - 150
        }

        private func entry(at scrollViewPoint: CGPoint) -> LadderDrinkEntry? {
            guard let scrollView, let canvasView else { return nil }
            let contentPoint = canvasView.convert(scrollViewPoint, from: scrollView)
            return entries
                .reversed()
                .first { entry in
                    let size = hitSize(for: entry)
                    let frame = CGRect(
                        x: entry.position.x - size.width / 2,
                        y: entry.position.y - size.height / 2,
                        width: size.width,
                        height: size.height
                    ).insetBy(dx: -4, dy: -4)
                    return frame.contains(contentPoint)
                }
        }

        private func hitSize(for entry: LadderDrinkEntry) -> CGSize {
            let scale = scrollView?.zoomScale ?? zoomScale.wrappedValue
            let labelOpacity = CollectionView.settledLabelOpacity(for: scale)
            let counterScale = CollectionView.nodeCounterScale(for: scale)
            let shouldIncludeLabel = entry.canShowLabel && labelOpacity > 0.2
            let baseWidth = shouldIncludeLabel ? entry.metrics.labelWidth : 52
            return CGSize(
                width: baseWidth * counterScale,
                height: 64 * counterScale
            )
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer {
                guard canStartDrinkGesture, let scrollView else { return false }
                guard let entry = entry(at: touch.location(in: scrollView)) else { return false }
                if gestureRecognizer is UILongPressGestureRecognizer {
                    return allowsDragging && entry.item.localDrink != nil
                }
                return true
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if isDrinkGesture(gestureRecognizer) || isDrinkGesture(otherGestureRecognizer) {
                return false
            }
            return gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isZooming = true
            let now = CACurrentMediaTime()
            lastZoomInteractionAt = now
            lastReportedZoomScale = scrollView.zoomScale
            canvasView?.applyZoom(scale: scrollView.zoomScale, mode: .preview)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            lastZoomInteractionAt = CACurrentMediaTime()
            canvasView?.applyZoom(scale: scrollView.zoomScale, mode: .preview)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZooming = false
            lastZoomInteractionAt = CACurrentMediaTime()
            canvasView?.applyZoom(scale: scale, mode: .settled, animatesLabel: true)
            reportZoomScale(scale)
            lastReportedZoomScale = scale
        }

        private func reportZoomScale(_ scale: CGFloat) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                zoomScale.wrappedValue = scale
            }
        }

        private var canStartDrinkGesture: Bool {
            guard !isZooming else { return false }
            guard CACurrentMediaTime() - lastZoomInteractionAt > zoomGestureCooldown else { return false }
            guard let pinchState = scrollView?.pinchGestureRecognizer?.state else { return true }
            return pinchState == .possible || pinchState == .failed || pinchState == .cancelled
        }

        private func isDrinkGesture(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer
        }

        func centerInitialPositionIfNeeded() {
            guard !didCenterInitialPosition,
                  let scrollView,
                  scrollView.bounds.width > 0,
                  scrollView.bounds.height > 0,
                  contentSize.width > 0,
                  contentSize.height > 0 else {
                return
            }

            scrollView.layoutIfNeeded()
            let scaledWidth = contentSize.width * scrollView.zoomScale
            let scaledHeight = contentSize.height * scrollView.zoomScale
            let targetX = max(0, (scaledWidth - scrollView.bounds.width) / 2)
            let targetY = max(0, (scaledHeight - scrollView.bounds.height) / 2)
            scrollView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: false)
            lastReportedZoomScale = scrollView.zoomScale
            didCenterInitialPosition = true
            canvasView?.applyZoom(scale: scrollView.zoomScale, mode: .settled)
        }
    }
}

private enum LadderSide {
    case left
    case right
}

private struct LadderRatingRow {
    let key: Int
    let rating: Double
    let items: [LadderDrinkDisplayItem]
}

private struct LadderCandidate {
    let position: CGPoint
    let column: Int
    let side: LadderSide
    let verticalOffset: CGFloat
    let canShowLabel: Bool
}

private struct LadderLayoutProfile {
    let labelBubbleSize: CGSize
    let compactNodeSize: CGSize
    let labelCollisionPadding: CGSize
    let compactCollisionPadding: CGSize
    let columnSpacing: CGFloat
    static let iconCenterYOffset: CGFloat = -11
    static let labelCenterYOffset: CGFloat = 17

    static let stable = LadderLayoutProfile(
        labelBubbleSize: CGSize(width: 156, height: 28),
        compactNodeSize: CGSize(width: 48, height: 40),
        labelCollisionPadding: CGSize(width: 6, height: 4),
        compactCollisionPadding: CGSize(width: 4, height: 4),
        columnSpacing: 96
    )

    /// Inflate every dimension by the rendering counter-scale so collision frames
    /// match the on-screen node size. Column spacing grows too, otherwise inflated
    /// nodes in adjacent columns would still touch.
    func scaled(by factor: CGFloat) -> LadderLayoutProfile {
        LadderLayoutProfile(
            labelBubbleSize: CGSize(width: labelBubbleSize.width * factor, height: labelBubbleSize.height * factor),
            compactNodeSize: CGSize(width: compactNodeSize.width * factor, height: compactNodeSize.height * factor),
            labelCollisionPadding: CGSize(width: labelCollisionPadding.width * factor, height: labelCollisionPadding.height * factor),
            compactCollisionPadding: CGSize(width: compactCollisionPadding.width * factor, height: compactCollisionPadding.height * factor),
            columnSpacing: columnSpacing * factor
        )
    }

    func scaledSizes(by factor: CGFloat) -> LadderLayoutProfile {
        LadderLayoutProfile(
            labelBubbleSize: CGSize(width: labelBubbleSize.width * factor, height: labelBubbleSize.height * factor),
            compactNodeSize: CGSize(width: compactNodeSize.width * factor, height: compactNodeSize.height * factor),
            labelCollisionPadding: CGSize(width: labelCollisionPadding.width * factor, height: labelCollisionPadding.height * factor),
            compactCollisionPadding: CGSize(width: compactCollisionPadding.width * factor, height: compactCollisionPadding.height * factor),
            columnSpacing: columnSpacing
        )
    }
}

private struct LadderMetrics {
    let size: CGSize
    let plotTop: CGFloat
    let plotBottom: CGFloat
    let centerX: CGFloat
    let sideLaneWidth: CGFloat
    let axisLineGap: CGFloat

    init(size: CGSize, topClearance: CGFloat = 30) {
        self.size = size
        plotTop = topClearance
        plotBottom = max(plotTop + 720, size.height - 34)
        centerX = size.width / 2
        sideLaneWidth = max(340, size.width / 2 - 48)
        axisLineGap = 34
    }

    var plotHeight: CGFloat {
        plotBottom - plotTop
    }
}

private struct LadderDrinkEntryMetrics {
    let displayName: String
    let displayBrand: String
    let labelWidth: CGFloat
    let accessibilityLabel: String

    init(item: LadderDrinkDisplayItem) {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = item.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = name.isEmpty ? "未命名" : name
        displayBrand = brand.isEmpty ? "未知品牌" : brand
        let nameWidth = displayName.size(withAttributes: [.font: UIFont.systemFont(ofSize: 9, weight: .semibold)]).width
        let brandWidth = displayBrand.size(withAttributes: [.font: UIFont.systemFont(ofSize: 8)]).width
        labelWidth = min(156, max(44, ceil(max(nameWidth, brandWidth)) + 16))
        accessibilityLabel = "\(displayBrand)，\(displayName)，评分 \(String(format: "%.2f", item.rating))"
    }
}

private struct LadderDrinkEntry: Identifiable {
    let item: LadderDrinkDisplayItem
    let position: CGPoint
    let side: LadderSide
    let canShowLabel: Bool
    let metrics: LadderDrinkEntryMetrics

    var id: String {
        item.id
    }
}

private struct LadderPlacement {
    let position: CGPoint
    let side: LadderSide
    let canShowLabel: Bool
}

private final class LadderCanvasUIView: UIView {
    enum LabelMode {
        case preview
        case settled
    }

    private let axisLayer = CALayer()
    private let nodeContainerLayer = CALayer()
    private var nodeLayers: [String: LadderNodeLayer] = [:]
    private var draggedItemID: String?
    private var dragTranslation: CGSize = .zero
    private var isOverDeleteTarget = false
    private var currentScale = CollectionView.defaultLadderScale
    private var currentLabelMode = LabelMode.settled

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        layer.addSublayer(axisLayer)
        layer.addSublayer(nodeContainerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(metrics: LadderMetrics, entries: [LadderDrinkEntry], contentSize: CGSize) {
        withoutLayerActions {
            bounds = CGRect(origin: .zero, size: contentSize)
            axisLayer.frame = bounds
            nodeContainerLayer.frame = bounds
            rebuildAxis(metrics: metrics)
            rebuildNodes(entries: entries)
            applyZoom(scale: currentScale, mode: currentLabelMode)
        }
    }

    func updateDragState(draggedItemID: String?, translation: CGSize, isOverDeleteTarget: Bool) {
        self.draggedItemID = draggedItemID
        dragTranslation = translation
        self.isOverDeleteTarget = isOverDeleteTarget
        applyZoom(scale: currentScale, mode: currentLabelMode)
    }

    func applyZoom(scale: CGFloat, mode: LabelMode, animatesLabel: Bool = false) {
        currentScale = scale
        currentLabelMode = mode
        let counterScale = CollectionView.nodeCounterScale(for: scale)
        let labelOpacity: CGFloat = switch mode {
        case .preview:
            CollectionView.labelRevealProgress(for: scale)
        case .settled:
            CollectionView.settledLabelOpacity(for: scale)
        }
        withoutLayerActions {
            nodeLayers.values.forEach { nodeLayer in
                let isDragged = nodeLayer.entry.item.id == draggedItemID
                nodeLayer.apply(
                    counterScale: counterScale,
                    labelOpacity: labelOpacity,
                    isDragged: isDragged,
                    dragTranslation: dragTranslation,
                    isOverDeleteTarget: isOverDeleteTarget,
                    animatesLabel: animatesLabel
                )
            }
        }
    }

    private func rebuildAxis(metrics: LadderMetrics) {
        axisLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let verticalPath = UIBezierPath()
        verticalPath.move(to: CGPoint(x: metrics.centerX, y: metrics.plotTop))
        verticalPath.addLine(to: CGPoint(x: metrics.centerX, y: metrics.plotBottom))
        axisLayer.addSublayer(shapeLayer(
            path: verticalPath.cgPath,
            color: UIColor.black.withAlphaComponent(0.26),
            lineWidth: 1.2,
            dashPattern: [5, 10]
        ))

        let horizontalPath = UIBezierPath()
        let midPath = UIBezierPath()
        for score in 0...5 {
            let y = metrics.plotTop + CGFloat(5 - score) / 5 * metrics.plotHeight
            if score != 5 {
                horizontalPath.move(to: CGPoint(x: 18, y: y))
                horizontalPath.addLine(to: CGPoint(x: metrics.centerX - metrics.axisLineGap, y: y))
                horizontalPath.move(to: CGPoint(x: metrics.centerX + metrics.axisLineGap, y: y))
                horizontalPath.addLine(to: CGPoint(x: metrics.size.width - 18, y: y))
            }
            if score > 1 {
                let midY = y + metrics.plotHeight / 10
                midPath.move(to: CGPoint(x: metrics.centerX - 28, y: midY))
                midPath.addLine(to: CGPoint(x: metrics.centerX + 28, y: midY))
            }
        }

        axisLayer.addSublayer(shapeLayer(
            path: horizontalPath.cgPath,
            color: UIColor.black.withAlphaComponent(0.2),
            lineWidth: 0.85,
            dashPattern: [8, 12]
        ))
        axisLayer.addSublayer(shapeLayer(
            path: midPath.cgPath,
            color: UIColor.black.withAlphaComponent(0.12),
            lineWidth: 0.7,
            dashPattern: nil
        ))
    }

    private func rebuildNodes(entries: [LadderDrinkEntry]) {
        nodeContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        nodeLayers = Dictionary(entries.map { entry in
            let nodeLayer = LadderNodeLayer(entry: entry)
            nodeContainerLayer.addSublayer(nodeLayer)
            return (entry.item.id, nodeLayer)
        }, uniquingKeysWith: { _, latest in latest })
    }

    private func shapeLayer(path: CGPath, color: UIColor, lineWidth: CGFloat, dashPattern: [NSNumber]?) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = color.cgColor
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.lineDashPattern = dashPattern
        layer.contentsScale = UIScreen.main.scale
        return layer
    }
}

private final class LadderNodeLayer: CALayer {
    let entry: LadderDrinkEntry
    private let badgeLayer = CALayer()
    private let badgeCircleLayer = CAShapeLayer()
    private let stickerLayer = CALayer()
    private let ratingBadgeLayer = CALayer()
    private let ratingTextLayer = CATextLayer()
    private let labelContainerLayer = CALayer()
    private let nameTextLayer = CATextLayer()
    private let brandTextLayer = CATextLayer()
    private let nodeHeight: CGFloat = 54
    private let badgeSize: CGFloat = 31
    private let labelHeight: CGFloat = 24

    init(entry: LadderDrinkEntry) {
        self.entry = entry
        super.init()
        contentsScale = UIScreen.main.scale
        bounds = CGRect(x: 0, y: 0, width: entry.metrics.labelWidth, height: nodeHeight)
        position = entry.position
        isGeometryFlipped = false
        setupBadge()
        setupLabel()
        addSublayer(badgeLayer)
        addSublayer(labelContainerLayer)
        accessibilityLabel = entry.metrics.accessibilityLabel
    }

    override init(layer: Any) {
        guard let layer = layer as? LadderNodeLayer else {
            fatalError("Unsupported layer copy")
        }
        entry = layer.entry
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(
        counterScale: CGFloat,
        labelOpacity: CGFloat,
        isDragged: Bool,
        dragTranslation: CGSize,
        isOverDeleteTarget: Bool,
        animatesLabel: Bool
    ) {
        let liftScale: CGFloat = isDragged ? (isOverDeleteTarget ? 1.2 : 1.14) : 1
        let liftOffset: CGFloat = isDragged ? -12 : 0
        position = CGPoint(
            x: entry.position.x + (isDragged ? dragTranslation.width : 0),
            y: entry.position.y + liftOffset + (isDragged ? dragTranslation.height : 0)
        )
        transform = CATransform3DMakeScale(counterScale * liftScale, counterScale * liftScale, 1)
        zPosition = isDragged ? 20_000 : 10_000 - entry.position.y

        if isDragged {
            shadowColor = (isOverDeleteTarget ? UIColor.red : UIColor.black).cgColor
            shadowOpacity = isOverDeleteTarget ? 0.26 : 0.22
            shadowRadius = isOverDeleteTarget ? 22 : 16
            shadowOffset = CGSize(width: 0, height: isOverDeleteTarget ? 12 : 9)
        } else {
            shadowOpacity = 0
            shadowRadius = 0
            shadowOffset = .zero
        }

        let visibleLabelOpacity = entry.canShowLabel ? labelOpacity : 0
        let renderedLabelOpacity = Float(entry.canShowLabel && visibleLabelOpacity > 0 ? max(0.003, visibleLabelOpacity) : 0)
        if animatesLabel, labelContainerLayer.opacity != renderedLabelOpacity {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = labelContainerLayer.presentation()?.opacity ?? labelContainerLayer.opacity
            animation.toValue = renderedLabelOpacity
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            labelContainerLayer.opacity = renderedLabelOpacity
            labelContainerLayer.add(animation, forKey: "settledLabelOpacity")
        } else {
            labelContainerLayer.opacity = renderedLabelOpacity
        }
        labelContainerLayer.frame.origin.y = 34 - 3 * (1 - visibleLabelOpacity)
    }

    private func setupBadge() {
        badgeLayer.frame = CGRect(
            x: (bounds.width - badgeSize) / 2,
            y: 0,
            width: badgeSize,
            height: badgeSize
        )

        badgeCircleLayer.frame = badgeLayer.bounds
        badgeCircleLayer.path = UIBezierPath(ovalIn: badgeLayer.bounds).cgPath
        badgeCircleLayer.fillColor = UIColor.white.withAlphaComponent(0.94).cgColor
        badgeCircleLayer.strokeColor = UIColor.black.withAlphaComponent(0.12).cgColor
        badgeCircleLayer.lineWidth = 1
        badgeCircleLayer.shadowColor = UIColor.black.cgColor
        badgeCircleLayer.shadowOpacity = 0.12
        badgeCircleLayer.shadowRadius = 8
        badgeCircleLayer.shadowOffset = CGSize(width: 0, height: 4)
        badgeLayer.addSublayer(badgeCircleLayer)

        stickerLayer.frame = badgeLayer.bounds.insetBy(dx: 5, dy: 5)
        stickerLayer.contentsGravity = .resizeAspect
        stickerLayer.contentsScale = UIScreen.main.scale
        stickerLayer.contents = stickerContents()
        badgeLayer.addSublayer(stickerLayer)

        let ratingText = String(format: "%.2f", entry.item.rating)
        let ratingFont = UIFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .bold)
        let ratingWidth = max(22, ratingText.size(withAttributes: [.font: ratingFont]).width + 6)
        ratingBadgeLayer.frame = CGRect(
            x: badgeLayer.bounds.maxX - ratingWidth + 5,
            y: badgeLayer.bounds.maxY - 9,
            width: ratingWidth,
            height: 12
        )
        ratingBadgeLayer.backgroundColor = UIColor.black.withAlphaComponent(0.78).cgColor
        ratingBadgeLayer.cornerRadius = 6
        ratingBadgeLayer.masksToBounds = true
        badgeLayer.addSublayer(ratingBadgeLayer)

        ratingTextLayer.frame = CGRect(x: 3, y: 1.5, width: ratingWidth - 6, height: 9)
        configureTextLayer(
            ratingTextLayer,
            text: ratingText,
            font: ratingFont,
            color: .white,
            alignment: .center
        )
        ratingBadgeLayer.addSublayer(ratingTextLayer)
    }

    private func setupLabel() {
        labelContainerLayer.frame = CGRect(x: 0, y: 34, width: bounds.width, height: labelHeight)
        labelContainerLayer.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        labelContainerLayer.cornerRadius = 8
        labelContainerLayer.shadowColor = UIColor.black.cgColor
        labelContainerLayer.shadowOpacity = 0.05
        labelContainerLayer.shadowRadius = 4
        labelContainerLayer.shadowOffset = CGSize(width: 0, height: 2)

        nameTextLayer.frame = CGRect(x: 6, y: 3, width: bounds.width - 12, height: 11)
        configureTextLayer(
            nameTextLayer,
            text: entry.metrics.displayName,
            font: .systemFont(ofSize: 9, weight: .semibold),
            color: .label,
            alignment: .center
        )
        labelContainerLayer.addSublayer(nameTextLayer)

        brandTextLayer.frame = CGRect(x: 6, y: 14, width: bounds.width - 12, height: 10)
        configureTextLayer(
            brandTextLayer,
            text: entry.metrics.displayBrand,
            font: .systemFont(ofSize: 8),
            color: .secondaryLabel,
            alignment: .center
        )
        labelContainerLayer.addSublayer(brandTextLayer)
    }

    private func configureTextLayer(
        _ layer: CATextLayer,
        text: String,
        font: UIFont,
        color: UIColor,
        alignment: CATextLayerAlignmentMode
    ) {
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
        if let cgImage = entry.item.stickerThumbnailImage?.cgImage {
            return cgImage
        }
        guard let image = UIImage(systemName: "cup.and.saucer.fill")?
            .withTintColor(UIColor.brown.withAlphaComponent(0.62), renderingMode: .alwaysOriginal) else {
            return nil
        }
        return UIGraphicsImageRenderer(size: stickerLayer.bounds.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: stickerLayer.bounds.size))
        }.cgImage
    }
}

private func withoutLayerActions(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    changes()
    CATransaction.commit()
}

private struct LeverGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.black.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 10, y: 5)
    }
}

private extension View {
    func leverGlassSurface(cornerRadius: CGFloat) -> some View {
        modifier(LeverGlassSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct LeverControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private struct DeleteDropZone: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "trash.fill" : "trash")
                .font(.system(size: 18, weight: .semibold))
                .symbolEffect(.bounce, value: isActive)

            Text(isActive ? "松手删除" : "删除")
                .font(.headline)
                .contentTransition(.opacity)
        }
        .foregroundStyle(isActive ? .white : .red)
        .padding(.horizontal, isActive ? 32 : 28)
        .padding(.vertical, 16)
        .background(
            Capsule()
                .fill(isActive ? Color.red : Color.white.opacity(0.96))
        )
        .overlay(
            Capsule()
                .stroke(isActive ? Color.red.opacity(0.32) : Color.red.opacity(0.16), lineWidth: isActive ? 8 : 1)
                .scaleEffect(isActive ? 1.18 : 1)
                .opacity(isActive ? 0.55 : 1)
        )
        .clipShape(Capsule())
        .scaleEffect(isActive ? 1.08 : 1)
        .offset(y: isActive ? -6 : 0)
        .shadow(color: isActive ? .red.opacity(0.28) : .black.opacity(0.14), radius: isActive ? 24 : 18, y: isActive ? 12 : 8)
        .animation(.spring(response: 0.2, dampingFraction: 0.68), value: isActive)
    }
}

private struct CaptureBookmark: View {
    let onCapture: () -> Void
    let onPhotoImport: () -> Void
    @State private var dragOffset: CGSize = .zero
    @State private var isPhotoImportGesture = false
    @State private var isCaptureGesture = false
    @State private var morphProgress: CGFloat = 0
    @State private var previousIcon: CaptureMorphIcon = .camera
    @State private var targetIcon: CaptureMorphIcon = .camera
    @State private var iconTransitionStartedAt = Date.distantPast

    private let leverWidth: CGFloat = 88
    private let leverHeight: CGFloat = 18
    private let tuckedOffset: CGFloat = 54
    private let maxReveal: CGFloat = 42
    private let maxLift: CGFloat = 58
    private let captureThreshold: CGFloat = -26
    private let importThreshold: CGFloat = -34

    var body: some View {
        ZStack {
            leverShape
                .fill(.white)
                .frame(width: leverWidth, height: leverHeight)
                .opacity(1 - delayedFadeOut(morphProgress, delay: 0.16))

            leverShape
                .stroke(isPhotoImportGesture ? .blue : .black, lineWidth: 1.5)
                .frame(width: leverWidth, height: leverHeight)
                .opacity(1 - min(1, morphProgress * 1.7))

            gripMarks
                .opacity(1 - min(1, morphProgress * 1.25))

            BubbleMorphView(
                progress: morphProgress,
                previousTarget: previousIcon,
                target: targetIcon,
                targetTransitionStartedAt: iconTransitionStartedAt,
                highlightProgress: liftProgress,
                size: CGSize(width: leverWidth, height: animationHeight),
                barHeight: leverHeight
            )

        }
        .frame(width: leverWidth, height: animationHeight)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
        .offset(x: tuckedOffset + dragOffset.width, y: dragOffset.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let horizontal = max(-maxReveal, min(0, value.translation.width))
                    let canLift = horizontal < -maxReveal * 0.72
                    let vertical = canLift ? max(-maxLift, min(0, value.translation.height)) : 0
                    let isImporting = vertical < importThreshold
                    let isCapturing = horizontal < captureThreshold && !isImporting
                    let horizontalProgress = min(1, abs(horizontal) / abs(captureThreshold))
                    let verticalProgress = min(1, abs(vertical) / abs(importThreshold))

                    if isCapturing != isCaptureGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    if isImporting != isPhotoImportGesture {
                        UIImpactFeedbackGenerator(style: isImporting ? .medium : .light).impactOccurred()
                    }

                    dragOffset = CGSize(width: horizontal, height: vertical)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        isCaptureGesture = isCapturing
                        isPhotoImportGesture = isImporting
                        morphProgress = max(horizontalProgress, verticalProgress)
                    }
                    updateTargetIcon(verticalProgress > 0.2 ? .photo : .camera)
                }
                .onEnded { value in
                    let horizontal = max(-maxReveal, min(0, value.translation.width))
                    let canLift = horizontal < -maxReveal * 0.72
                    let vertical = canLift ? max(-maxLift, min(0, value.translation.height)) : 0

                    if vertical < importThreshold {
                        onPhotoImport()
                    } else if horizontal < captureThreshold {
                        onCapture()
                    }

                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        dragOffset = .zero
                        isCaptureGesture = false
                        isPhotoImportGesture = false
                        morphProgress = 0
                        previousIcon = .camera
                        targetIcon = .camera
                        iconTransitionStartedAt = .distantPast
                    }
                }
        )
        .onTapGesture {
            onCapture()
        }
        .accessibilityLabel("拍一杯")
        .accessibilityHint("点按或向左拉动打开相机，拉出后向上推打开相册")
        .accessibilityAction(named: "打开相机") {
            onCapture()
        }
        .accessibilityAction(named: "打开相册") {
            onPhotoImport()
        }
    }

    private var animationHeight: CGFloat {
        54
    }

    private var revealProgress: CGFloat {
        min(1, abs(dragOffset.width) / maxReveal)
    }

    private var liftProgress: CGFloat {
        min(1, abs(dragOffset.height) / maxLift)
    }

    private var gripMarks: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(.black.opacity(0.18))
                    .frame(width: 2.5, height: 2.5)
            }
        }
        .offset(x: -22)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }


    private var leverShape: some Shape {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: leverHeight / 2,
                bottomLeading: leverHeight / 2,
                bottomTrailing: 4,
                topTrailing: 4
            ),
            style: .continuous
        )
    }

    private func delayedFadeOut(_ value: CGFloat, delay: CGFloat) -> CGFloat {
        let adjusted = max(0, min(1, (value - delay) / (1 - delay)))
        return adjusted * adjusted * (3 - 2 * adjusted)
    }

    private func updateTargetIcon(_ newTarget: CaptureMorphIcon) {
        guard newTarget != targetIcon else { return }
        previousIcon = targetIcon
        targetIcon = newTarget
        iconTransitionStartedAt = Date()
    }
}

private enum CaptureMorphIcon {
    case camera
    case photo
}

private struct BubbleMorphView: View {
    let progress: CGFloat
    let previousTarget: CaptureMorphIcon
    let target: CaptureMorphIcon
    let targetTransitionStartedAt: Date
    let highlightProgress: CGFloat
    let size: CGSize
    let barHeight: CGFloat

    private let particleCount = 140
    private let barWidth: CGFloat = 88
    private let targetTransitionDuration: TimeInterval = 0.32

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let easedProgress = easeInOut(progress)
                let targetTransition = transitionProgress(at: timeline.date)

                for index in 0..<particleCount {
                    let start = startPoint(index: index, size: size)
                    let finish = morphedTargetPoint(index: index, size: size, targetTransition: targetTransition)
                    let delay = CGFloat(index % 11) * 0.01
                    let localProgress = min(1, max(0, (easedProgress - delay) / (1 - delay)))
                    let drift = driftOffset(index: index, elapsed: elapsed, progress: localProgress)
                    let point = CGPoint(
                        x: start.x + (finish.x - start.x) * localProgress + drift.width,
                        y: start.y + (finish.y - start.y) * localProgress + drift.height
                    )
                    let radius = 1.05 + localProgress * 0.5
                    let breakIn = min(1, max(0, easedProgress / 0.14))
                    let opacity = Double(breakIn) * (0.34 + Double(localProgress) * 0.62)
                    let colorMix = min(1, max(0, highlightProgress))
                    let color = Color(
                        red: 0.02 + 0.02 * colorMix,
                        green: 0.02 + 0.32 * colorMix,
                        blue: 0.02 + 0.88 * colorMix
                    )
                    let rect = CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )

                    context.opacity = opacity
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func startPoint(index: Int, size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let leftRadius = barHeight / 2
        let leftCenter = CGPoint(x: center.x - barWidth / 2 + leftRadius, y: center.y)
        let right = center.x + barWidth / 2
        let top = center.y - barHeight / 2
        let bottom = center.y + barHeight / 2
        let straightLeft = leftCenter.x
        let straightRight = right - 4
        let perimeter = (straightRight - straightLeft) * 2 + barHeight + .pi * leftRadius
        let jitter = (seeded(index, salt: 11) - 0.5) * 0.28
        var distance = CGFloat(index) / CGFloat(particleCount) * perimeter

        if distance < straightRight - straightLeft {
            return CGPoint(x: straightLeft + distance, y: top + jitter)
        }

        distance -= straightRight - straightLeft
        if distance < barHeight {
            return CGPoint(x: straightRight + jitter, y: top + distance)
        }

        distance -= barHeight
        if distance < straightRight - straightLeft {
            return CGPoint(x: straightRight - distance, y: bottom + jitter)
        }

        distance -= straightRight - straightLeft
        let angle = .pi / 2 + distance / (.pi * leftRadius) * .pi
        return CGPoint(
            x: leftCenter.x + cos(angle) * leftRadius + jitter,
            y: leftCenter.y + sin(angle) * leftRadius
        )
    }

    private func targetPoint(index: Int, target: CaptureMorphIcon, size: CGSize) -> CGPoint {
        let points = target == .camera ? cameraPoints(in: size) : photoPoints(in: size)
        return points[index % points.count]
    }

    private func morphedTargetPoint(index: Int, size: CGSize, targetTransition: CGFloat) -> CGPoint {
        let from = targetPoint(index: index, target: previousTarget, size: size)
        let to = targetPoint(index: index, target: target, size: size)
        let progress = easeInOut(targetTransition)
        return CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
    }

    private func transitionProgress(at date: Date) -> CGFloat {
        guard previousTarget != target else { return 1 }
        let elapsed = date.timeIntervalSince(targetTransitionStartedAt)
        return min(1, max(0, CGFloat(elapsed / targetTransitionDuration)))
    }

    private func cameraPoints(in size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width * 0.45, y: size.height / 2)
        let w: CGFloat = 42
        let h: CGFloat = 26
        let left = center.x - w / 2
        let right = center.x + w / 2
        let top = center.y - h / 2
        let bottom = center.y + h / 2
        let lensRadius: CGFloat = 7.5

        var points: [CGPoint] = []
        points += sampleLine(from: CGPoint(x: left + 5, y: top), to: CGPoint(x: right - 5, y: top), count: 22)
        points += sampleLine(from: CGPoint(x: right, y: top + 5), to: CGPoint(x: right, y: bottom - 5), count: 14)
        points += sampleLine(from: CGPoint(x: right - 5, y: bottom), to: CGPoint(x: left + 5, y: bottom), count: 22)
        points += sampleLine(from: CGPoint(x: left, y: bottom - 5), to: CGPoint(x: left, y: top + 5), count: 14)
        points += sampleLine(from: CGPoint(x: left + 8, y: top - 5), to: CGPoint(x: left + 18, y: top - 5), count: 12)
        points += sampleCircle(center: center, radius: lensRadius, count: 44)
        points += sampleCircle(center: CGPoint(x: right - 8, y: top + 7), radius: 2.2, count: 12)
        return points
    }

    private func photoPoints(in size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width * 0.45, y: size.height / 2)
        let w: CGFloat = 42
        let h: CGFloat = 28
        let left = center.x - w / 2
        let right = center.x + w / 2
        let top = center.y - h / 2
        let bottom = center.y + h / 2

        var points: [CGPoint] = []
        points += sampleLine(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: top), count: 26)
        points += sampleLine(from: CGPoint(x: right, y: top), to: CGPoint(x: right, y: bottom), count: 18)
        points += sampleLine(from: CGPoint(x: right, y: bottom), to: CGPoint(x: left, y: bottom), count: 26)
        points += sampleLine(from: CGPoint(x: left, y: bottom), to: CGPoint(x: left, y: top), count: 18)
        points += sampleLine(from: CGPoint(x: left + 5, y: bottom - 5), to: CGPoint(x: left + 15, y: bottom - 15), count: 13)
        points += sampleLine(from: CGPoint(x: left + 15, y: bottom - 15), to: CGPoint(x: left + 24, y: bottom - 7), count: 12)
        points += sampleLine(from: CGPoint(x: left + 24, y: bottom - 7), to: CGPoint(x: right - 7, y: bottom - 17), count: 16)
        points += sampleLine(from: CGPoint(x: right - 7, y: bottom - 17), to: CGPoint(x: right - 3, y: bottom - 5), count: 10)
        points += sampleCircle(center: CGPoint(x: right - 10, y: top + 8), radius: 2.4, count: 12)
        return points
    }

    private func sampleLine(from start: CGPoint, to end: CGPoint, count: Int) -> [CGPoint] {
        guard count > 1 else { return [start] }
        return (0..<count).map { index in
            let progress = CGFloat(index) / CGFloat(count - 1)
            return CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
        }
    }

    private func sampleCircle(center: CGPoint, radius: CGFloat, count: Int) -> [CGPoint] {
        (0..<count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
    }

    private func driftOffset(index: Int, elapsed: TimeInterval, progress: CGFloat) -> CGSize {
        let phase = elapsed * (1.2 + Double(seeded(index, salt: 3)) * 1.4) + Double(index) * 0.7
        let looseness = sin(.pi * Double(progress))
        let settling = max(0, 1 - Double(progress))
        return CGSize(
            width: cos(phase) * looseness * settling * 1.7,
            height: sin(phase * 1.17) * looseness * settling * 1.5
        )
    }

    private func easeInOut(_ value: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func seeded(_ index: Int, salt: Int) -> CGFloat {
        let value = (index * 73 + salt * 151) % 997
        return CGFloat(value) / 996
    }
}
