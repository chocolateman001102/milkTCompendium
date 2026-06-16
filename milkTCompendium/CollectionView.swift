import SwiftData
import SwiftUI
import UIKit

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Drink.createdAt, order: .reverse) private var drinks: [Drink]
    @State private var showsLadderLabels = false
    @State private var draggingDrink: Drink?
    @State private var dragTranslation: CGSize = .zero
    @State private var isOverDeleteTarget = false
    @State private var editingDrink: Drink?
    @State private var ladderScale: CGFloat = 0.9
    let onStartCapture: () -> Void
    let onStartPhotoImport: () -> Void

    private var effectiveLadderScale: CGFloat {
        min(2.4, max(0.52, ladderScale))
    }

    private var sortedDrinks: [Drink] {
        drinks.sorted {
            if $0.rating == $1.rating {
                return $0.createdAt > $1.createdAt
            }
            return $0.rating > $1.rating
        }
    }

    var body: some View {
        Group {
            if drinks.isEmpty {
                Text("拉动右下角的小标记录")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ratingLadder
            }
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
            if draggingDrink != nil {
                DeleteDropZone(isActive: isOverDeleteTarget)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .navigationDestination(isPresented: editingDrinkBinding) {
            if let editingDrink {
                DrinkFormView(mode: .edit(editingDrink)) {}
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
                showsLabels: $showsLadderLabels,
                contentSize: canvasSize,
                entries: entries,
                onTapDrink: { drink in
                    guard draggingDrink == nil, dragTranslation == .zero else { return }
                    editingDrink = drink
                },
                onDragChanged: { drink, translation, isOverDelete in
                    if draggingDrink == nil {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }

                    draggingDrink = drink
                    dragTranslation = translation
                    if isOverDelete != isOverDeleteTarget {
                        UIImpactFeedbackGenerator(style: isOverDelete ? .medium : .light).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        isOverDeleteTarget = isOverDelete
                    }
                },
                onDragEnded: { drink, shouldDelete in
                    if shouldDelete, let drink {
                        delete(drink)
                    }

                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        draggingDrink = nil
                        dragTranslation = .zero
                        isOverDeleteTarget = false
                    }
                }
            ) {
                ZStack {
                    LadderAxisView(metrics: metrics)

                    ForEach(entries) { entry in
                        LadderDrinkNode(drink: entry.drink, showsLabels: showsLadderLabels)
                            .scaleEffect(nodeCounterScale)
                            .scaleEffect(draggingDrink === entry.drink ? 1.12 : 1)
                            .offset(draggingDrink === entry.drink ? dragTranslation : .zero)
                            .shadow(
                                color: draggingDrink === entry.drink ? .black.opacity(0.18) : .clear,
                                radius: draggingDrink === entry.drink ? 16 : 0,
                                y: draggingDrink === entry.drink ? 9 : 0
                            )
                            .position(entry.position)
                            .zIndex(draggingDrink === entry.drink ? 10 : 1)
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

    private func ladderCanvasSize(for viewport: CGSize) -> CGSize {
        let drinkCount = CGFloat(max(drinks.count, 1))
        let densityHeight = 920 + drinkCount * 13
        return CGSize(
            width: max(viewport.width * 2.65, 980),
            height: max(viewport.height * 2.28, densityHeight)
        )
    }

    private func ladderEntries(in metrics: LadderMetrics) -> [LadderDrinkEntry] {
        var bandUsage: [Int: (left: Int, right: Int)] = [:]
        var leftColumnBottoms: [CGFloat] = []
        var rightColumnBottoms: [CGFloat] = []
        let minimumVerticalSpacing: CGFloat = 76
        let columnSpacing: CGFloat = 172
        let nearestColumnDistance: CGFloat = 102

        return sortedDrinks.map { drink in
            let y = yPosition(for: drink.rating, metrics: metrics)
            let band = Int((y - metrics.plotTop) / 52)
            let usage = bandUsage[band, default: (left: 0, right: 0)]
            let hash = stableHash(for: drink)
            let preferRight = hash.isMultiple(of: 2)
            let side: LadderSide

            if usage.left == usage.right {
                side = preferRight ? .right : .left
            } else {
                side = usage.left < usage.right ? .left : .right
            }

            if side == .left {
                bandUsage[band] = (left: usage.left + 1, right: usage.right)
            } else {
                bandUsage[band] = (left: usage.left, right: usage.right + 1)
            }

            let placement: CGPoint
            if side == .left {
                placement = placementPosition(
                    preferredY: y,
                    side: side,
                    metrics: metrics,
                    columnBottoms: &leftColumnBottoms,
                    nearestColumnDistance: nearestColumnDistance,
                    columnSpacing: columnSpacing,
                    minimumVerticalSpacing: minimumVerticalSpacing
                )
            } else {
                placement = placementPosition(
                    preferredY: y,
                    side: side,
                    metrics: metrics,
                    columnBottoms: &rightColumnBottoms,
                    nearestColumnDistance: nearestColumnDistance,
                    columnSpacing: columnSpacing,
                    minimumVerticalSpacing: minimumVerticalSpacing
                )
            }

            return LadderDrinkEntry(
                drink: drink,
                position: CGPoint(
                    x: min(max(34, placement.x), metrics.size.width - 34),
                    y: min(max(metrics.plotTop, placement.y), metrics.plotBottom)
                )
            )
        }
    }

    private func placementPosition(
        preferredY: CGFloat,
        side: LadderSide,
        metrics: LadderMetrics,
        columnBottoms: inout [CGFloat],
        nearestColumnDistance: CGFloat,
        columnSpacing: CGFloat,
        minimumVerticalSpacing: CGFloat
    ) -> CGPoint {
        let maxColumn = max(0, Int((metrics.sideLaneWidth - nearestColumnDistance) / columnSpacing))

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

    private func stableHash(for drink: Drink) -> Int {
        let key = "\(drink.brand)|\(drink.name)|\(drink.createdAt.timeIntervalSince1970)"
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
    @Binding var showsLabels: Bool
    let contentSize: CGSize
    let entries: [LadderDrinkEntry]
    let onTapDrink: (Drink) -> Void
    let onDragChanged: (Drink, CGSize, Bool) -> Void
    let onDragEnded: (Drink?, Bool) -> Void
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(
            zoomScale: $zoomScale,
            showsLabels: $showsLabels,
            onTapDrink: onTapDrink,
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
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.35
        longPressGesture.delegate = context.coordinator
        longPressGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(longPressGesture)

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
        context.coordinator.showsLabels = $showsLabels
        context.coordinator.entries = entries
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
        var showsLabels: Binding<Bool>
        var entries: [LadderDrinkEntry] = []
        let onTapDrink: (Drink) -> Void
        let onDragChanged: (Drink, CGSize, Bool) -> Void
        let onDragEnded: (Drink?, Bool) -> Void
        let hostingController: UIHostingController<AnyView>
        weak var hostedView: UIView?
        weak var scrollView: UIScrollView?
        weak var widthConstraint: NSLayoutConstraint?
        weak var heightConstraint: NSLayoutConstraint?
        var isZooming = false
        var didCenterInitialPosition = false
        var contentSize: CGSize = .zero
        var lastReportedZoomScale: CGFloat = 0
        var longPressedDrink: Drink?
        var longPressStartPoint: CGPoint = .zero

        init(
            zoomScale: Binding<CGFloat>,
            showsLabels: Binding<Bool>,
            onTapDrink: @escaping (Drink) -> Void,
            onDragChanged: @escaping (Drink, CGSize, Bool) -> Void,
            onDragEnded: @escaping (Drink?, Bool) -> Void
        ) {
            self.zoomScale = zoomScale
            self.showsLabels = showsLabels
            self.onTapDrink = onTapDrink
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
            hostingController = UIHostingController(rootView: AnyView(EmptyView()))
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostedView
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  recognizer.numberOfTouches <= 1,
                  !isZooming,
                  let scrollView,
                  let entry = entry(at: recognizer.location(in: scrollView)) else {
                return
            }
            onTapDrink(entry.drink)
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard !isZooming, let scrollView else { return }
            let point = recognizer.location(in: scrollView)

            switch recognizer.state {
            case .began:
                guard let entry = entry(at: point) else { return }
                longPressedDrink = entry.drink
                longPressStartPoint = point

            case .changed:
                guard let drink = longPressedDrink else { return }
                let translation = CGSize(
                    width: point.x - longPressStartPoint.x,
                    height: point.y - longPressStartPoint.y
                )
                onDragChanged(drink, translation, translation.height > 150)

            case .ended:
                let translation = CGSize(
                    width: point.x - longPressStartPoint.x,
                    height: point.y - longPressStartPoint.y
                )
                onDragEnded(longPressedDrink, translation.height > 150)
                longPressedDrink = nil

            case .cancelled, .failed:
                onDragEnded(longPressedDrink, false)
                longPressedDrink = nil

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
                    let size = showsLabels.wrappedValue ? CGSize(width: 160, height: 62) : CGSize(width: 38, height: 38)
                    let frame = CGRect(
                        x: entry.position.x - size.width / 2,
                        y: entry.position.y - size.height / 2,
                        width: size.width,
                        height: size.height
                    ).insetBy(dx: -10, dy: -10)
                    return frame.contains(contentPoint)
                }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer {
                guard let scrollView else { return false }
                return entry(at: touch.location(in: scrollView)) != nil
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            !(gestureRecognizer is UIPinchGestureRecognizer)
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isZooming = true
            hostedView?.layer.rasterizationScale = UIScreen.main.scale
            hostedView?.layer.shouldRasterize = true
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if abs(scrollView.zoomScale - lastReportedZoomScale) > 0.045 {
                zoomScale.wrappedValue = scrollView.zoomScale
                lastReportedZoomScale = scrollView.zoomScale
            }

            let shouldShowLabels = scrollView.zoomScale > 1.32
            if showsLabels.wrappedValue != shouldShowLabels {
                showsLabels.wrappedValue = shouldShowLabels
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            hostedView?.layer.shouldRasterize = false
            isZooming = false
            zoomScale.wrappedValue = scale
            lastReportedZoomScale = scale

            let shouldShowLabels = scale > 1.32
            if showsLabels.wrappedValue != shouldShowLabels {
                showsLabels.wrappedValue = shouldShowLabels
            }
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
    let drink: Drink
    let position: CGPoint

    var id: ObjectIdentifier {
        ObjectIdentifier(drink)
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
            .stroke(.black.opacity(0.78), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

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
    let drink: Drink
    let showsLabels: Bool

    var body: some View {
        VStack(spacing: 3) {
            stickerBadge

            if showsLabels {
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
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                .frame(width: labelWidth)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: showsLabels ? labelWidth : 32, height: showsLabels ? 58 : 32, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityLabel("\(displayBrand)，\(displayName)，评分 \(String(format: "%.2f", drink.rating))")
    }

    @ViewBuilder
    private var stickerBadge: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.94))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            if let image = ImageStore.load(drink.stickerImageName) {
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
            Text(String(format: "%.2f", drink.rating))
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
        let cleaned = drink.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    private var displayBrand: String {
        let cleaned = drink.brand.trimmingCharacters(in: .whitespacesAndNewlines)
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
