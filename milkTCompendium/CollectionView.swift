import SwiftData
import SwiftUI
import UIKit

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Drink.createdAt, order: .reverse) private var drinks: [Drink]
    @ObservedObject var sharedStore: SharedCompendiumStore
    @State private var selectedCompendiumID = "mine"
    @State private var showingTransfer = false
    @State private var draggingItem: LadderDrinkDisplayItem?
    @State private var dragTranslation: CGSize = .zero
    @State private var isOverDeleteTarget = false
    @State private var selectedItem: LadderDrinkDisplayItem?
    @State private var editingDrink: Drink?
    @State private var ladderScale: CGFloat = 0.52
    let onStartCapture: () -> Void
    let onStartPhotoImport: () -> Void

    private var effectiveLadderScale: CGFloat {
        min(2.4, max(0.52, ladderScale))
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
            NearbyTransferView(drinks: drinks, sharedStore: sharedStore) { compendium in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    selectedCompendiumID = compendium.id
                    selectedItem = nil
                    draggingItem = nil
                }
            }
        }
    }

    private var ratingLadder: some View {
        GeometryReader { proxy in
            let canvasSize = ladderCanvasSize(for: proxy.size)
            let metrics = LadderMetrics(size: canvasSize)
            let entries = ladderEntries(in: metrics)

            ZoomableLadderView(
                zoomScale: $ladderScale,
                contentSize: canvasSize,
                entries: entries,
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
                        LadderDrinkNode(item: entry.item, showsLabel: showsLabels)
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
        HStack(spacing: 10) {
            Menu {
                Button {
                    selectedCompendiumID = "mine"
                    selectedItem = nil
                } label: {
                    Label("我的", systemImage: selectedCompendiumID == "mine" ? "checkmark" : "")
                }

                ForEach(sharedStore.compendiums) { compendium in
                    Button {
                        selectedCompendiumID = compendium.id
                        selectedItem = nil
                    } label: {
                        Label(compendium.ownerName, systemImage: selectedCompendiumID == compendium.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentCompendiumTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(.primary)
                .background(.white.opacity(0.96))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
            }

            Button {
                showingTransfer = true
            } label: {
                Text("互传")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(.black)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            }
        }
    }

    private var currentCompendiumTitle: String {
        if let activeSharedCompendium, !isShowingMine {
            return activeSharedCompendium.ownerName
        }
        return "我的"
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
        1 / pow(max(effectiveLadderScale, 0.01), 0.52)
    }

    private var showsLabels: Bool {
        effectiveLadderScale >= 1.18
    }

    private func ladderCanvasSize(for viewport: CGSize) -> CGSize {
        let drinkCount = CGFloat(max(displayItems.count, 1))
        let densityHeight = 920 + drinkCount * 13
        return CGSize(
            width: max(viewport.width * 2.65, 980),
            height: max(viewport.height * 2.28, densityHeight)
        )
    }

    private func ladderEntries(in metrics: LadderMetrics) -> [LadderDrinkEntry] {
        var leftColumnBottoms: [CGFloat] = []
        var rightColumnBottoms: [CGFloat] = []
        let minimumVerticalSpacing: CGFloat = 76
        let columnSpacing: CGFloat = 118
        let nearestColumnDistance: CGFloat = 69

        return sortedItems.map { item in
            let y = yPosition(for: item.rating, metrics: metrics)
            let hash = stableHash(for: item)
            let preferRight = hash.isMultiple(of: 2)
            let preferredSide: LadderSide = preferRight ? .right : .left

            let placement: CGPoint
            if preferredSide == .left {
                placement = bestPlacement(
                    preferredY: y,
                    preferredSide: .left,
                    metrics: metrics,
                    preferredColumnBottoms: &leftColumnBottoms,
                    alternateColumnBottoms: &rightColumnBottoms,
                    nearestColumnDistance: nearestColumnDistance,
                    columnSpacing: columnSpacing,
                    minimumVerticalSpacing: minimumVerticalSpacing
                )
            } else {
                placement = bestPlacement(
                    preferredY: y,
                    preferredSide: .right,
                    metrics: metrics,
                    preferredColumnBottoms: &rightColumnBottoms,
                    alternateColumnBottoms: &leftColumnBottoms,
                    nearestColumnDistance: nearestColumnDistance,
                    columnSpacing: columnSpacing,
                    minimumVerticalSpacing: minimumVerticalSpacing
                )
            }

            return LadderDrinkEntry(
                item: item,
                position: CGPoint(
                    x: min(max(34, placement.x), metrics.size.width - 34),
                    y: min(max(metrics.plotTop, placement.y), metrics.plotBottom)
                )
            )
        }
    }

    private func bestPlacement(
        preferredY: CGFloat,
        preferredSide: LadderSide,
        metrics: LadderMetrics,
        preferredColumnBottoms: inout [CGFloat],
        alternateColumnBottoms: inout [CGFloat],
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat,
        minimumVerticalSpacing: CGFloat
    ) -> CGPoint {
        let maxColumn = max(0, Int((metrics.sideLaneWidth - nearestColumnDistance) / columnSpacing))

        if let placement = placementPosition(
            preferredY: preferredY,
            side: preferredSide,
            metrics: metrics,
            columnBottoms: &preferredColumnBottoms,
            maxColumn: maxColumn,
            nearestColumnDistance: nearestColumnDistance,
            columnSpacing: columnSpacing,
            minimumVerticalSpacing: minimumVerticalSpacing,
            allowsFallbackShift: false
        ) {
            return placement
        }

        let alternateSide: LadderSide = preferredSide == .left ? .right : .left
        if let placement = placementPosition(
            preferredY: preferredY,
            side: alternateSide,
            metrics: metrics,
            columnBottoms: &alternateColumnBottoms,
            maxColumn: maxColumn,
            nearestColumnDistance: nearestColumnDistance,
            columnSpacing: columnSpacing,
            minimumVerticalSpacing: minimumVerticalSpacing,
            allowsFallbackShift: false
        ) {
            return placement
        }

        return placementPosition(
            preferredY: preferredY,
            side: preferredSide,
            metrics: metrics,
            columnBottoms: &preferredColumnBottoms,
            maxColumn: maxColumn,
            nearestColumnDistance: nearestColumnDistance,
            columnSpacing: columnSpacing,
            minimumVerticalSpacing: minimumVerticalSpacing,
            allowsFallbackShift: true
        ) ?? CGPoint(
            x: xPosition(for: preferredSide, column: maxColumn, metrics: metrics, nearestColumnDistance: nearestColumnDistance, columnSpacing: columnSpacing),
            y: preferredY
        )
    }

    private func placementPosition(
        preferredY: CGFloat,
        side: LadderSide,
        metrics: LadderMetrics,
        columnBottoms: inout [CGFloat],
        maxColumn: Int,
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat,
        minimumVerticalSpacing: CGFloat,
        allowsFallbackShift: Bool
    ) -> CGPoint? {
        for column in 0...maxColumn {
            if column >= columnBottoms.count {
                columnBottoms.append(-.greatestFiniteMagnitude)
            }

            if preferredY - columnBottoms[column] >= minimumVerticalSpacing {
                columnBottoms[column] = preferredY
                return CGPoint(
                    x: xPosition(for: side, column: column, metrics: metrics, nearestColumnDistance: nearestColumnDistance, columnSpacing: columnSpacing),
                    y: preferredY
                )
            }
        }

        guard allowsFallbackShift else { return nil }
        let fallbackColumn = maxColumn
        let adjustedY = min(metrics.plotBottom, columnBottoms[fallbackColumn] + minimumVerticalSpacing)
        columnBottoms[fallbackColumn] = adjustedY
        return CGPoint(
            x: xPosition(for: side, column: fallbackColumn, metrics: metrics, nearestColumnDistance: nearestColumnDistance, columnSpacing: columnSpacing),
            y: adjustedY
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

        scrollView.minimumZoomScale = 0.52
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

        DispatchQueue.main.async {
            context.coordinator.centerInitialPositionIfNeeded()
        }
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
        var lastReportedZoomScale: CGFloat = 0
        var longPressedItem: LadderDrinkDisplayItem?
        var longPressStartPoint: CGPoint = .zero
        var lastZoomInteractionAt = Date.distantPast
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
            if abs(scrollView.zoomScale - lastReportedZoomScale) > 0.12 || crossedLabelThreshold(scrollView.zoomScale, lastReportedZoomScale) {
                zoomScale.wrappedValue = scrollView.zoomScale
                lastReportedZoomScale = scrollView.zoomScale
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZooming = false
            lastZoomInteractionAt = Date()
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

        private func crossedLabelThreshold(_ current: CGFloat, _ previous: CGFloat) -> Bool {
            (current >= 1.18 && previous < 1.18) || (current < 1.18 && previous >= 1.18)
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

private struct LadderMetrics {
    let size: CGSize
    let plotTop: CGFloat
    let plotBottom: CGFloat
    let centerX: CGFloat
    let sideLaneWidth: CGFloat

    init(size: CGSize) {
        self.size = size
        plotTop = 30
        plotBottom = max(plotTop + 720, size.height - 34)
        centerX = size.width / 2
        sideLaneWidth = max(340, min(620, size.width * 0.48))
    }

    var plotHeight: CGFloat {
        plotBottom - plotTop
    }
}

private struct LadderDrinkEntry: Identifiable {
    let item: LadderDrinkDisplayItem
    let position: CGPoint

    var id: String {
        item.id
    }
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

                if score != 1 && score != 5 {
                    Path { path in
                        path.move(to: CGPoint(x: 18, y: y))
                        path.addLine(to: CGPoint(x: metrics.centerX - 102, y: y))
                        path.move(to: CGPoint(x: metrics.centerX - 54, y: y))
                        path.addLine(to: CGPoint(x: metrics.size.width - 18, y: y))
                    }
                    .stroke(.black.opacity(score == 0 ? 0.76 : 0.2), style: StrokeStyle(lineWidth: score == 0 ? 1.4 : 0.85, lineCap: .round, dash: score == 0 ? [] : [8, 12]))
                }

                if score > 0 {
                    let midY = metrics.plotTop + CGFloat(5 - score) / 5 * metrics.plotHeight + metrics.plotHeight / 10
                    Path { path in
                        path.move(to: CGPoint(x: metrics.centerX - 28, y: midY))
                        path.addLine(to: CGPoint(x: metrics.centerX + 28, y: midY))
                    }
                    .stroke(.black.opacity(0.12), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                }

                Text("\(score)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.52))
                    .frame(width: 24)
                    .position(x: metrics.centerX - 78, y: y)
            }
        }
    }
}

private struct LadderDrinkNode: View {
    let item: LadderDrinkDisplayItem
    let showsLabel: Bool

    var body: some View {
        VStack(spacing: 3) {
            stickerBadge

            if showsLabel {
                labelView
                    .transition(.opacity)
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
                .opacity(1 - delayedFadeOut(morphProgress, delay: 0.18))

            leverShape
                .stroke(isPhotoImportGesture ? .blue : .black, lineWidth: 1.5)
                .frame(width: leverWidth, height: leverHeight)
                .opacity(1 - min(1, morphProgress * 1.85))

            BubbleMorphView(
                progress: morphProgress,
                previousTarget: previousIcon,
                target: targetIcon,
                targetTransitionStartedAt: iconTransitionStartedAt,
                isHighlighted: isPhotoImportGesture,
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
                    let horizontalProgress = min(1, abs(horizontal) / abs(captureThreshold))
                    let verticalProgress = min(1, abs(vertical) / abs(importThreshold))

                    if isImporting != isPhotoImportGesture {
                        UIImpactFeedbackGenerator(style: isImporting ? .medium : .light).impactOccurred()
                    }

                    dragOffset = CGSize(width: horizontal, height: vertical)
                    isPhotoImportGesture = isImporting
                    updateTargetIcon(verticalProgress > 0.2 ? .photo : .camera)
                    morphProgress = max(horizontalProgress, verticalProgress)
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
    }

    private var animationHeight: CGFloat {
        54
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
    let isHighlighted: Bool
    let size: CGSize
    let barHeight: CGFloat

    private let particleCount = 92
    private let barWidth: CGFloat = 88
    private let targetTransitionDuration: TimeInterval = 0.38

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let easedProgress = easeInOut(progress)
                let targetTransition = transitionProgress(at: timeline.date)
                let bubbleColor = isHighlighted ? Color.blue : Color.black

                for index in 0..<particleCount {
                    let start = startPoint(index: index, size: size)
                    let finish = morphedTargetPoint(index: index, size: size, targetTransition: targetTransition)
                    let delay = CGFloat((index % 11)) * 0.012
                    let localProgress = min(1, max(0, (easedProgress - delay) / (1 - delay)))
                    let drift = driftOffset(index: index, elapsed: elapsed, progress: localProgress)
                    let point = CGPoint(
                        x: start.x + (finish.x - start.x) * localProgress + drift.width,
                        y: start.y + (finish.y - start.y) * localProgress + drift.height
                    )
                    let radius = 0.8 + seeded(index, salt: 8) * 1.1 + localProgress * 0.7
                    let breakIn = min(1, max(0, easedProgress / 0.16))
                    let opacity = Double(breakIn) * (0.34 + Double(localProgress) * 0.6)
                    let rect = CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )

                    context.opacity = opacity
                    context.fill(Path(ellipseIn: rect), with: .color(bubbleColor))
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
        let jitter = (seeded(index, salt: 11) - 0.5) * 0.58
        var distance = (CGFloat(index) / CGFloat(particleCount)) * perimeter

        if distance < straightRight - straightLeft {
            return CGPoint(
                x: straightLeft + distance,
                y: top + jitter
            )
        }

        distance -= straightRight - straightLeft
        if distance < barHeight {
            return CGPoint(
                x: straightRight + jitter,
                y: top + distance
            )
        }

        distance -= barHeight
        if distance < straightRight - straightLeft {
            return CGPoint(
                x: straightRight - distance,
                y: bottom + jitter
            )
        }

        distance -= straightRight - straightLeft
        let angle = .pi / 2 + (distance / (.pi * leftRadius)) * .pi
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
        let progress = iconEase(targetTransition)
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
        points += sampleLine(from: CGPoint(x: left + 5, y: top), to: CGPoint(x: right - 5, y: top), count: 18)
        points += sampleLine(from: CGPoint(x: right, y: top + 5), to: CGPoint(x: right, y: bottom - 5), count: 10)
        points += sampleLine(from: CGPoint(x: right - 5, y: bottom), to: CGPoint(x: left + 5, y: bottom), count: 18)
        points += sampleLine(from: CGPoint(x: left, y: bottom - 5), to: CGPoint(x: left, y: top + 5), count: 10)
        points += sampleLine(from: CGPoint(x: left + 8, y: top - 5), to: CGPoint(x: left + 18, y: top - 5), count: 8)
        points += sampleCircle(center: center, radius: lensRadius, count: 22)
        points += sampleCircle(center: CGPoint(x: right - 8, y: top + 7), radius: 2.2, count: 6)
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
        points += sampleLine(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: top), count: 18)
        points += sampleLine(from: CGPoint(x: right, y: top), to: CGPoint(x: right, y: bottom), count: 12)
        points += sampleLine(from: CGPoint(x: right, y: bottom), to: CGPoint(x: left, y: bottom), count: 18)
        points += sampleLine(from: CGPoint(x: left, y: bottom), to: CGPoint(x: left, y: top), count: 12)
        points += sampleLine(from: CGPoint(x: left + 5, y: bottom - 5), to: CGPoint(x: left + 15, y: bottom - 15), count: 9)
        points += sampleLine(from: CGPoint(x: left + 15, y: bottom - 15), to: CGPoint(x: left + 24, y: bottom - 7), count: 8)
        points += sampleLine(from: CGPoint(x: left + 24, y: bottom - 7), to: CGPoint(x: right - 7, y: bottom - 17), count: 10)
        points += sampleLine(from: CGPoint(x: right - 7, y: bottom - 17), to: CGPoint(x: right - 3, y: bottom - 5), count: 7)
        points += sampleCircle(center: CGPoint(x: right - 10, y: top + 8), radius: 2.4, count: 7)
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
        let phase = elapsed * (1.4 + Double(seeded(index, salt: 3)) * 1.6) + Double(index) * 0.7
        let looseness = sin(.pi * Double(progress))
        return CGSize(
            width: cos(phase) * looseness * 2.4,
            height: sin(phase * 1.17) * looseness * 2.1
        )
    }

    private func easeInOut(_ value: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func iconEase(_ value: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func seeded(_ index: Int, salt: Int) -> CGFloat {
        let value = (index * 73 + salt * 151) % 997
        return CGFloat(value) / 996
    }
}
