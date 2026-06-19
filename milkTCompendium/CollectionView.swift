import SwiftData
import SwiftUI
import UIKit

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
    let onStartCapture: () -> Void
    let onStartPhotoImport: () -> Void

    fileprivate static let defaultLadderScale: CGFloat = 0.44
    private static let labelFadeStartScale: CGFloat = 0.9
    private static let labelRevealScale: CGFloat = 1.1
    private let ladderTopControlClearance: CGFloat = 200

    /// Stickers are always visible, so they are laid out against the largest
    /// content-space size they can reach at the minimum zoom.
    private static let layoutCounterScale: CGFloat = 1 / pow(defaultLadderScale, 0.46)
    private static let labelLayoutCounterScale: CGFloat = 1 / pow(labelFadeStartScale, 0.46)

    private var effectiveLadderScale: CGFloat {
        min(2.4, max(Self.defaultLadderScale, ladderScale))
    }

    private var isShowingMine: Bool {
        selectedCompendiumID == "mine"
    }

    private var activeSharedCompendium: SharedCompendium? {
        sharedStore.compendiums.first { $0.id == selectedCompendiumID }
    }

    private var displayItems: [LadderDrinkDisplayItem] {
        if let activeSharedCompendium, !isShowingMine {
            return activeSharedCompendium.drinks.map {
                LadderDrinkDisplayItem(sharedDrink: $0, ownerID: activeSharedCompendium.ownerID)
            }
        }
        return drinks.map(LadderDrinkDisplayItem.init(drink:))
    }

    private var sortedItems: [LadderDrinkDisplayItem] {
        displayItems.sorted {
            if $0.rating == $1.rating {
                return $0.createdAt > $1.createdAt
            }
            return $0.rating > $1.rating
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if displayItems.isEmpty {
                    Text(isShowingMine ? "拉动右下角的小标记录" : "这本图鉴暂时没有记录")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ratingLadder
                }
            }

            topControls
                .padding(.top, 12)
                .padding(.horizontal, 18)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
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
            let canvasSize = ladderCanvasSize(for: proxy.size)
            let metrics = LadderMetrics(size: canvasSize, topClearance: ladderTopControlClearance)
            let entries = ladderEntries(in: metrics)

            ZoomableLadderView(
                zoomScale: $ladderScale,
                contentSize: canvasSize,
                entries: entries,
                contentSignature: ladderContentSignature(entries: entries),
                allowsDragging: isShowingMine,
                onTapItem: { item in
                    guard draggingItem == nil, dragTranslation == .zero else { return }
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        selectedItem = item
                    }
                },
                onDragChanged: { item, translation, isOverDelete in
                    guard item.localDrink != nil else { return }
                    if draggingItem == nil {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }

                    draggingItem = item
                    dragTranslation = translation
                    if isOverDelete != isOverDeleteTarget {
                        UIImpactFeedbackGenerator(style: isOverDelete ? .medium : .light).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
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
            ) {
                ZStack {
                    LadderAxisView(metrics: metrics)

                    ForEach(entries) { entry in
                        LadderDrinkNode(
                            item: entry.item,
                            labelSide: entry.side,
                            labelOpacity: entry.canShowLabel ? labelRevealProgress : 0
                        )
                            .scaleEffect(nodeCounterScale)
                            .scaleEffect(draggingItem?.id == entry.item.id ? 1.12 : 1)
                            .offset(draggingItem?.id == entry.item.id ? dragTranslation : .zero)
                            .shadow(
                                color: draggingItem?.id == entry.item.id ? .black.opacity(0.18) : .clear,
                                radius: draggingItem?.id == entry.item.id ? 16 : 0,
                                y: draggingItem?.id == entry.item.id ? 9 : 0
                            )
                            .position(entry.position)
                            .zIndex(draggingItem?.id == entry.item.id ? 10 : 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .contentShape(Rectangle())
            }
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
        let count = displayItems.count
        return isShowingMine ? "\(tasteScore.levelName) · \(String(format: "%.2f", tasteScore.score)) · \(count) 杯" : "共享图鉴 · \(count) 杯"
    }

    private var tasteScore: TasteScoreResult {
        TasteScoreCalculator.calculate(localDrinks: drinks, stats: tasteStatsStore.stats)
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

    private var editingDrinkBinding: Binding<Bool> {
        Binding {
            editingDrink != nil
        } set: { isPresented in
            if !isPresented {
                editingDrink = nil
            }
        }
    }

    private var nodeCounterScale: CGFloat {
        1 / pow(max(effectiveLadderScale, 0.01), 0.46)
    }

    private var labelRevealProgress: CGFloat {
        let rawProgress = (effectiveLadderScale - Self.labelFadeStartScale) / (Self.labelRevealScale - Self.labelFadeStartScale)
        let clamped = min(1, max(0, rawProgress))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func ladderContentSignature(entries: [LadderDrinkEntry]) -> String {
        let compendiumKey = selectedCompendiumID
        let entryKey = entries.map(\.id).joined(separator: "|")
        return "\(compendiumKey):\(entryKey)"
    }

    private func ladderCanvasSize(for viewport: CGSize) -> CGSize {
        let drinkCount = CGFloat(max(displayItems.count, 1))
        let densityHeight = 920 + drinkCount * 13
        let baseHeight = max(viewport.height * 2.28, densityHeight)
        let estimatedPlotBottom = max(ladderTopControlClearance + 720, baseHeight - 34)
        let estimatedPlotHeight = max(1, estimatedPlotBottom - ladderTopControlClearance)
        let iconCollisionHeight = (LadderLayoutProfile.stable.compactNodeSize.height + LadderLayoutProfile.stable.compactCollisionPadding.height)
            * Self.layoutCounterScale
        let labelCollisionHeight = (LadderLayoutProfile.stable.labelNodeSize.height + LadderLayoutProfile.stable.labelCollisionPadding.height)
            * Self.labelLayoutCounterScale
        let ratingWindow = Double(max(iconCollisionHeight, labelCollisionHeight) / estimatedPlotHeight * 5)
        let requiredColumnsPerSide = max(2, Int(ceil(CGFloat(maxRatingClusterCount(in: ratingWindow)) / 2)))
        let requiredSideLaneWidth = LadderLayoutProfile.stable.columnSpacing * 0.4
            + CGFloat(max(0, requiredColumnsPerSide - 1)) * LadderLayoutProfile.stable.columnSpacing
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
        var labelFrames: [CGRect] = []
        var placements: [String: LadderPlacement] = [:]
        let profile = LadderLayoutProfile.stable
        let iconProfile = profile.scaledSizes(by: Self.layoutCounterScale)
        let labelProfile = profile.scaledSizes(by: Self.labelLayoutCounterScale)
        let iconSize = iconProfile.compactNodeSize
        let iconPadding = iconProfile.compactCollisionPadding
        let labelHeight = labelProfile.labelNodeSize.height
        let labelPadding = labelProfile.labelCollisionPadding
        let columnSpacing = profile.columnSpacing
        let nearestColumnDistance = columnSpacing * 0.43
        let clusterWindow = max(
            iconSize.height + iconPadding.height,
            (labelHeight + labelPadding.height) * 0.72
        )
        let verticalStep = labelHeight + labelPadding.height + 6

        layoutClusters(in: metrics, clusterWindow: clusterWindow).forEach { cluster in
            let centerHash = cluster.reduce(0) { $0 + stableHash(for: $1) }
            let startsRight = centerHash.isMultiple(of: 2)
            let clusterOffsets = cluster.count > 1 ? verticalOffsetSequence(count: cluster.count, step: verticalStep) : [CGFloat.zero]

            cluster.enumerated().forEach { index, item in
                let anchorY = yPosition(for: item.rating, metrics: metrics)
                let preferredSide = alternatingSide(index: index, startsRight: startsRight)
                let secondarySide = preferredSide == .left ? LadderSide.right : .left
                let verticalOffsets = orderedOffsets(preferred: clusterOffsets[min(index, clusterOffsets.count - 1)], allOffsets: clusterOffsets)
                let labelWidth = labelWidth(for: item) * Self.labelLayoutCounterScale

                let placement = bestPlacement(
                    anchorY: anchorY,
                    preferredSides: [preferredSide, secondarySide],
                    verticalOffsets: verticalOffsets,
                    metrics: metrics,
                    nearestColumnDistance: nearestColumnDistance,
                    columnSpacing: columnSpacing,
                    iconSize: iconSize,
                    iconPadding: iconPadding,
                    labelSize: CGSize(width: labelWidth, height: labelHeight),
                    labelPadding: labelPadding,
                    iconFrames: iconFrames,
                    labelFrames: labelFrames
                )

                let position = CGPoint(
                    x: min(max(34, placement.position.x), metrics.size.width - 34),
                    y: min(max(metrics.plotTop, placement.position.y), metrics.plotBottom)
                )
                let resolvedPlacement = LadderPlacement(
                    position: position,
                    side: placement.side,
                    canShowLabel: placement.canShowLabel
                )
                iconFrames.append(
                    collisionFrame(
                        centeredAt: position,
                        nodeSize: iconSize,
                        padding: iconPadding
                    )
                )
                if resolvedPlacement.canShowLabel {
                    labelFrames.append(
                        collisionFrame(
                            centeredAt: labelCenter(
                                for: position,
                                side: resolvedPlacement.side,
                                labelWidth: labelWidth
                            ),
                            nodeSize: CGSize(width: labelWidth, height: labelHeight),
                            padding: labelPadding
                        )
                    )
                }
                placements[item.id] = resolvedPlacement
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
                canShowLabel: placement.canShowLabel
            )
        }
    }

    private func layoutClusters(in metrics: LadderMetrics, clusterWindow: CGFloat) -> [[LadderDrinkDisplayItem]] {
        let orderedItems = sortedItems.sorted {
            if $0.rating == $1.rating {
                return stableHash(for: $0) < stableHash(for: $1)
            }
            return $0.rating > $1.rating
        }
        var clusters: [[LadderDrinkDisplayItem]] = []
        var currentCluster: [LadderDrinkDisplayItem] = []
        var previousY: CGFloat?

        orderedItems.forEach { item in
            let y = yPosition(for: item.rating, metrics: metrics)
            if let previousY, abs(y - previousY) > clusterWindow, !currentCluster.isEmpty {
                clusters.append(currentCluster)
                currentCluster = [item]
            } else {
                currentCluster.append(item)
            }
            previousY = y
        }

        if !currentCluster.isEmpty {
            clusters.append(currentCluster)
        }
        return clusters
    }

    private func verticalOffsetSequence(count: Int, step: CGFloat) -> [CGFloat] {
        (0..<count).map { index in
            guard index > 0 else { return 0 }
            let magnitude = CGFloat((index + 1) / 2) * step
            return index.isMultiple(of: 2) ? magnitude : -magnitude
        }
    }

    private func orderedOffsets(preferred: CGFloat, allOffsets: [CGFloat]) -> [CGFloat] {
        ([preferred] + allOffsets + [0]).reduce(into: [CGFloat]()) { result, offset in
            guard !result.contains(where: { abs($0 - offset) < 0.5 }) else { return }
            result.append(offset)
        }
    }

    private func alternatingSide(index: Int, startsRight: Bool) -> LadderSide {
        let isRight = index.isMultiple(of: 2) == startsRight
        return isRight ? .right : .left
    }

    private func bestPlacement(
        anchorY: CGFloat,
        preferredSides: [LadderSide],
        verticalOffsets: [CGFloat],
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
            verticalOffsets: verticalOffsets,
            metrics: metrics,
            maxColumn: maxColumn,
            nearestColumnDistance: nearestColumnDistance,
            columnSpacing: columnSpacing
        )

        let safeCandidates = candidates.compactMap { candidate -> LadderCandidate? in
            let position = candidate.position
            let iconFrame = collisionFrame(centeredAt: position, nodeSize: iconSize, padding: iconPadding)
            guard isIconSafe(iconFrame, iconFrames: iconFrames, labelFrames: labelFrames) else { return nil }
            let labelFrame = collisionFrame(
                centeredAt: labelCenter(for: position, side: candidate.side, labelWidth: labelSize.width),
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

        if let best = bestCompactCandidate(safeCandidates) {
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
        verticalOffsets: [CGFloat],
        metrics: LadderMetrics,
        maxColumn: Int,
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat
    ) -> [LadderCandidate] {
        verticalOffsets.flatMap { verticalOffset in
            (0...maxColumn).flatMap { column in
                sides.map { side in
                LadderCandidate(
                    position: CGPoint(
                        x: xPosition(for: side, column: column, metrics: metrics, nearestColumnDistance: nearestColumnDistance, columnSpacing: columnSpacing),
                        y: min(max(metrics.plotTop, anchorY + verticalOffset), metrics.plotBottom)
                    ),
                        column: column,
                        side: side,
                        verticalOffset: verticalOffset,
                        canShowLabel: false
                    )
                }
            }
        }
    }

    private func bestCompactCandidate(_ candidates: [LadderCandidate]) -> LadderCandidate? {
        candidates.min { first, second in
            placementScore(for: first) < placementScore(for: second)
        }
    }

    private func placementScore(for candidate: LadderCandidate) -> CGFloat {
        var score = CGFloat(candidate.column) * 100
        score += abs(candidate.verticalOffset) * 0.9
        if candidate.canShowLabel {
            score -= 240
        }
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
        !iconFrames.contains(where: { $0.intersects(frame) })
            && !labelFrames.contains(where: { $0.intersects(frame) })
    }

    private func isLabelSafe(_ frame: CGRect, iconFrames: [CGRect], labelFrames: [CGRect]) -> Bool {
        !iconFrames.contains(where: { $0.intersects(frame) })
            && !labelFrames.contains(where: { $0.intersects(frame) })
    }

    private func labelCenter(for position: CGPoint, side: LadderSide, labelWidth: CGFloat) -> CGPoint {
        let offset = min(56 * Self.labelLayoutCounterScale, labelWidth * 0.36)
        return CGPoint(
            x: position.x + (side == .left ? -offset : offset),
            y: position.y
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
        let ratings = displayItems.map { min(5, max(0, $0.rating)) }.sorted()
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

private struct ZoomableLadderView<Content: View>: UIViewRepresentable {
    @Binding var zoomScale: CGFloat
    let contentSize: CGSize
    let entries: [LadderDrinkEntry]
    let contentSignature: String
    let allowsDragging: Bool
    let onTapItem: (LadderDrinkDisplayItem) -> Void
    let onDragChanged: (LadderDrinkDisplayItem, CGSize, Bool) -> Void
    let onDragEnded: (LadderDrinkDisplayItem?, Bool) -> Void
    @ViewBuilder var content: Content

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
        longPressGesture.minimumPressDuration = 0.35
        longPressGesture.delegate = context.coordinator
        longPressGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(longPressGesture)

        if let pinchGesture = scrollView.pinchGestureRecognizer {
            tapGesture.require(toFail: pinchGesture)
            longPressGesture.require(toFail: pinchGesture)
        }

        scrollView.minimumZoomScale = CollectionView.defaultLadderScale
        scrollView.maximumZoomScale = 2.4
        scrollView.zoomScale = zoomScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.layer.drawsAsynchronously = true

        let hostingController = context.coordinator.hostingController
        hostingController.view.backgroundColor = .clear
        hostingController.view.layer.drawsAsynchronously = true
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostingController.view)
        context.coordinator.hostedView = hostingController.view

        let widthConstraint = hostingController.view.widthAnchor.constraint(equalToConstant: contentSize.width)
        let heightConstraint = hostingController.view.heightAnchor.constraint(equalToConstant: contentSize.height)
        context.coordinator.widthConstraint = widthConstraint
        context.coordinator.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            widthConstraint,
            heightConstraint
        ])

        context.coordinator.scrollView = scrollView
        context.coordinator.contentSize = contentSize
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let contentDidChange = context.coordinator.contentSignature != contentSignature
        if contentDidChange {
            context.coordinator.contentSignature = contentSignature
            context.coordinator.didCenterInitialPosition = false
        }

        context.coordinator.hostingController.rootView = AnyView(content)
        context.coordinator.zoomScale = $zoomScale
        context.coordinator.entries = entries
        context.coordinator.allowsDragging = allowsDragging
        context.coordinator.contentSize = contentSize
        context.coordinator.widthConstraint?.constant = contentSize.width
        context.coordinator.heightConstraint?.constant = contentSize.height

        if !context.coordinator.isZooming,
           abs(scrollView.zoomScale - zoomScale) > 0.001 {
            scrollView.setZoomScale(zoomScale, animated: false)
        }

        scrollView.layoutIfNeeded()
        context.coordinator.centerInitialPositionIfNeeded()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var zoomScale: Binding<CGFloat>
        var entries: [LadderDrinkEntry] = []
        var allowsDragging: Bool
        let onTapItem: (LadderDrinkDisplayItem) -> Void
        let onDragChanged: (LadderDrinkDisplayItem, CGSize, Bool) -> Void
        let onDragEnded: (LadderDrinkDisplayItem?, Bool) -> Void
        let hostingController: UIHostingController<AnyView>
        weak var hostedView: UIView?
        weak var scrollView: UIScrollView?
        weak var widthConstraint: NSLayoutConstraint?
        weak var heightConstraint: NSLayoutConstraint?
        var isZooming = false
        var didCenterInitialPosition = false
        var contentSize: CGSize = .zero
        var contentSignature = ""
        var lastReportedZoomScale: CGFloat = 0
        var longPressedItem: LadderDrinkDisplayItem?
        var longPressStartPoint: CGPoint = .zero
        var lastZoomInteractionAt = Date.distantPast
        var lastLiveZoomUpdateAt = Date.distantPast
        private let zoomGestureCooldown: TimeInterval = 0.3
        private let liveZoomUpdateInterval: TimeInterval = 1.0 / 30.0
        private let liveZoomScaleStep: CGFloat = 0.035

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
            hostingController = UIHostingController(rootView: AnyView(EmptyView()))
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostedView
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
                longPressStartPoint = point

            case .changed:
                guard let item = longPressedItem else { return }
                let translation = CGSize(
                    width: point.x - longPressStartPoint.x,
                    height: point.y - longPressStartPoint.y
                )
                onDragChanged(item, translation, translation.height > 150)

            case .ended:
                let translation = CGSize(
                    width: point.x - longPressStartPoint.x,
                    height: point.y - longPressStartPoint.y
                )
                onDragEnded(longPressedItem, translation.height > 150)
                longPressedItem = nil

            case .cancelled, .failed:
                onDragEnded(longPressedItem, false)
                longPressedItem = nil

            default:
                break
            }
        }

        private func entry(at scrollViewPoint: CGPoint) -> LadderDrinkEntry? {
            guard let scrollView, let hostedView else { return nil }
            let contentPoint = hostedView.convert(scrollViewPoint, from: scrollView)
            return entries
                .reversed()
                .first { entry in
                    let size = CGSize(width: 44, height: 44)
                    let frame = CGRect(
                        x: entry.position.x - size.width / 2,
                        y: entry.position.y - size.height / 2 + 2,
                        width: size.width,
                        height: size.height
                    ).insetBy(dx: -4, dy: -4)
                    return frame.contains(contentPoint)
                }
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
            if isDrinkGesture(gestureRecognizer), otherGestureRecognizer is UIPinchGestureRecognizer {
                return true
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            !(gestureRecognizer is UIPinchGestureRecognizer)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isZooming = true
            lastZoomInteractionAt = Date()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            lastZoomInteractionAt = Date()
            let now = Date()
            let scale = scrollView.zoomScale
            guard now.timeIntervalSince(lastLiveZoomUpdateAt) >= liveZoomUpdateInterval,
                  abs(scale - lastReportedZoomScale) > liveZoomScaleStep else {
                return
            }
            zoomScale.wrappedValue = scale
            lastReportedZoomScale = scale
            lastLiveZoomUpdateAt = now
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZooming = false
            lastZoomInteractionAt = Date()
            lastLiveZoomUpdateAt = Date()
            zoomScale.wrappedValue = scale
            lastReportedZoomScale = scale
        }

        private var canStartDrinkGesture: Bool {
            guard !isZooming else { return false }
            guard Date().timeIntervalSince(lastZoomInteractionAt) > zoomGestureCooldown else { return false }
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
        }
    }
}

private enum LadderSide {
    case left
    case right
}

private struct LadderCandidate {
    let position: CGPoint
    let column: Int
    let side: LadderSide
    let verticalOffset: CGFloat
    let canShowLabel: Bool
}

private struct LadderLayoutProfile {
    let labelNodeSize: CGSize
    let compactNodeSize: CGSize
    let labelCollisionPadding: CGSize
    let compactCollisionPadding: CGSize
    let columnSpacing: CGFloat

    static let stable = LadderLayoutProfile(
        labelNodeSize: CGSize(width: 156, height: 58),
        compactNodeSize: CGSize(width: 52, height: 46),
        labelCollisionPadding: CGSize(width: 10, height: 8),
        compactCollisionPadding: CGSize(width: 8, height: 8),
        columnSpacing: 104
    )

    /// Inflate every dimension by the rendering counter-scale so collision frames
    /// match the on-screen node size. Column spacing grows too, otherwise inflated
    /// nodes in adjacent columns would still touch.
    func scaled(by factor: CGFloat) -> LadderLayoutProfile {
        LadderLayoutProfile(
            labelNodeSize: CGSize(width: labelNodeSize.width * factor, height: labelNodeSize.height * factor),
            compactNodeSize: CGSize(width: compactNodeSize.width * factor, height: compactNodeSize.height * factor),
            labelCollisionPadding: CGSize(width: labelCollisionPadding.width * factor, height: labelCollisionPadding.height * factor),
            compactCollisionPadding: CGSize(width: compactCollisionPadding.width * factor, height: compactCollisionPadding.height * factor),
            columnSpacing: columnSpacing * factor
        )
    }

    func scaledSizes(by factor: CGFloat) -> LadderLayoutProfile {
        LadderLayoutProfile(
            labelNodeSize: CGSize(width: labelNodeSize.width * factor, height: labelNodeSize.height * factor),
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

private struct LadderDrinkEntry: Identifiable {
    let item: LadderDrinkDisplayItem
    let position: CGPoint
    let side: LadderSide
    let canShowLabel: Bool

    var id: String {
        item.id
    }
}

private struct LadderPlacement {
    let position: CGPoint
    let side: LadderSide
    let canShowLabel: Bool
}

private struct LadderAxisView: View {
    let metrics: LadderMetrics

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: metrics.centerX, y: metrics.plotTop))
                path.addLine(to: CGPoint(x: metrics.centerX, y: metrics.plotBottom))
            }
            .stroke(.black.opacity(0.26), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [5, 10]))

            ForEach(0...5, id: \.self) { score in
                let y = metrics.plotTop + CGFloat(5 - score) / 5 * metrics.plotHeight

                if score != 5 {
                    Path { path in
                        path.move(to: CGPoint(x: 18, y: y))
                        path.addLine(to: CGPoint(x: metrics.centerX - metrics.axisLineGap, y: y))
                        path.move(to: CGPoint(x: metrics.centerX + metrics.axisLineGap, y: y))
                        path.addLine(to: CGPoint(x: metrics.size.width - 18, y: y))
                    }
                    .stroke(.black.opacity(0.2), style: StrokeStyle(lineWidth: 0.85, lineCap: .round, dash: [8, 12]))
                }

                if score > 1 {
                    let midY = metrics.plotTop + CGFloat(5 - score) / 5 * metrics.plotHeight + metrics.plotHeight / 10
                    Path { path in
                        path.move(to: CGPoint(x: metrics.centerX - 28, y: midY))
                        path.addLine(to: CGPoint(x: metrics.centerX + 28, y: midY))
                    }
                    .stroke(.black.opacity(0.12), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                }

            }
        }
    }
}

private struct LadderDrinkNode: View {
    let item: LadderDrinkDisplayItem
    let labelSide: LadderSide
    let labelOpacity: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            stickerBadge

            labelView
                .opacity(max(0.0001, labelOpacity))
                .offset(x: labelHorizontalOffset, y: -3 * (1 - labelOpacity))
                .allowsHitTesting(labelOpacity > 0.95)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .frame(width: labelWidth, height: 58, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityLabel("\(displayBrand)，\(displayName)，评分 \(String(format: "%.2f", item.rating))")
    }

    private var labelView: some View {
        VStack(spacing: 1) {
            Text(displayName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(displayBrand)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        .frame(width: labelWidth)
    }

    @ViewBuilder
    private var stickerBadge: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.94))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            if let image = item.stickerThumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(.brown.opacity(0.62))
            }
        }
        .frame(width: 34, height: 34)
        .overlay(
            Circle()
                .stroke(.black.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            Text(String(format: "%.2f", item.rating))
                .font(.system(size: 7, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1.5)
                .background(.black.opacity(0.78))
                .clipShape(Capsule())
                .offset(x: 5, y: 3)
        }
    }

    private var displayName: String {
        let cleaned = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    private var displayBrand: String {
        let cleaned = item.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未知品牌" : cleaned
    }

    private var labelWidth: CGFloat {
        let longest = max(displayName.count, displayBrand.count)
        return min(156, max(76, CGFloat(longest) * 10 + 24))
    }

    private var labelHorizontalOffset: CGFloat {
        let offset = min(56, labelWidth * 0.36)
        return labelSide == .left ? -offset : offset
    }

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
            Text("删除")
                .font(.headline)
        }
        .foregroundStyle(isActive ? .white : .red)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(isActive ? Color.red : Color.white.opacity(0.96))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
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
