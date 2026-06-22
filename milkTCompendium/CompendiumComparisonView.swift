import SwiftUI
import UIKit

struct CompendiumComparisonView: View {
    fileprivate static let minimumZoomScale: CGFloat = 0.44
    fileprivate static let initialZoomScale: CGFloat = minimumZoomScale
    private static let ladderTopControlClearance: CGFloat = 154
    private static let ladderBottomControlClearance: CGFloat = 42
    private static let ladderCanvasVerticalSafePadding: CGFloat = 96

    let localDrinks: [Drink]
    let sharedCompendiums: [SharedCompendium]
    let initialOwnerID: String
    let localOwnerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOwnerID: String
    @State private var zoomScale: CGFloat = Self.initialZoomScale
    @State private var centerResetToken = 0
    @State private var selectedNode: ComparisonDrinkNode?
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
        _selectedOwnerID = State(initialValue: initialOwnerID)
    }

    private var sharedCompendium: SharedCompendium {
        sharedCompendiums.first { $0.ownerID == selectedOwnerID }
            ?? sharedCompendiums.first
            ?? SharedCompendium(ownerID: initialOwnerID, ownerName: "TA", exportedAt: .distantPast, drinks: [])
    }

    private var comparison: CompendiumComparison {
        CompendiumComparisonBuilder.build(
            localDrinks: localDrinks,
            sharedCompendium: sharedCompendium,
            localOwnerName: localOwnerName
        )
    }

    private var visibleLocalNodes: [ComparisonDrinkNode] {
        comparison.pairs.map(\.local)
    }

    private var visiblePeerNodes: [ComparisonDrinkNode] {
        comparison.pairs.map(\.peer)
    }

    private var visiblePairs: [ComparisonDrinkPair] {
        comparison.pairs
    }

    private var selectedPair: ComparisonDrinkPair? {
        guard let selectedNode, let pairID = selectedNode.matchedPairID else { return nil }
        return comparison.pairs.first { $0.id == pairID }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if comparison.pairs.isEmpty {
                emptyState(title: "还没有共同喝过", subtitle: "你和 \(sharedCompendium.ownerName) 暂时没有双方都记录过的饮品。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                comparisonLadder
            }

            header
                .padding(.horizontal, 14)
                .padding(.top, 10)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if let selectedNode {
                ComparisonDrinkCardOverlay(
                    node: selectedNode,
                    pair: selectedPair,
                    localOwnerName: comparison.localOwnerName,
                    peerOwnerName: comparison.peerOwnerName,
                    onClose: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            self.selectedNode = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(30)
            }
        }
        .onChange(of: selectedOwnerID) { _, _ in
            selectedNode = nil
            zoomScale = Self.initialZoomScale
            centerResetToken += 1
        }
    }

    private var comparisonLadder: some View {
        GeometryReader { proxy in
            let layoutKey = layoutCacheKey(viewport: proxy.size)
            let layout = layoutCache.snapshot(for: layoutKey) {
                let canvasSize = canvasSize(for: proxy.size)
                let metrics = ComparisonLadderMetrics(
                    size: canvasSize,
                    topClearance: Self.ladderTopControlClearance + Self.ladderCanvasVerticalSafePadding,
                    bottomClearance: Self.ladderBottomControlClearance + Self.ladderCanvasVerticalSafePadding
                )
                return ComparisonLadderLayoutSnapshot(
                    canvasSize: canvasSize,
                    metrics: metrics,
                    nodes: nodeEntries(metrics: metrics),
                    connections: connectionEntries(metrics: metrics),
                    contentSignature: layoutKey
                )
            }

            ZoomableComparisonLadderView(
                zoomScale: $zoomScale,
                contentSize: layout.canvasSize,
                metrics: layout.metrics,
                nodes: layout.nodes,
                connections: layout.connections,
                selectedNodeID: selectedNode?.id,
                selectedPairID: selectedPair?.id,
                contentSignature: layout.contentSignature,
                centerResetToken: centerResetToken,
                onTapNode: { node in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                        selectedNode = node
                    }
                }
            )
            .background(Color(.systemGroupedBackground))
            .accessibilityLabel("图鉴对比天梯")
        }
    }

    private var header: some View {
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
                    ForEach(sharedCompendiums) { compendium in
                        Button {
                            selectedOwnerID = compendium.ownerID
                        } label: {
                            HStack {
                                Text(compendium.ownerName)
                                if compendium.ownerID == selectedOwnerID {
                                    Spacer()
                                    Text("当前")
                                }
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("\(comparison.localOwnerName) × \(comparison.peerOwnerName)")
                                .font(.headline.weight(.black))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                        }
                        Text("共同 \(comparison.matchedCount) · 可切换共饮对象")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)
                Button {
                    zoomScale = Self.initialZoomScale
                    centerResetToken += 1
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 32)
                        .background(Color.black.opacity(0.055))
                        .clipShape(Capsule())
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

    private func layoutCacheKey(viewport: CGSize) -> String {
        let viewportKey = "\(Int(viewport.width.rounded()))x\(Int(viewport.height.rounded()))"
        let nodeKey = (visibleLocalNodes + visiblePeerNodes).map { node in
            [
                node.id,
                String(format: "%.3f", node.aggregateRating),
                "\(node.totalCupCount)",
                node.representative.stickerImageName ?? node.representative.stickerFileURL?.lastPathComponent ?? ""
            ].joined(separator: "#")
        }.joined(separator: "|")
        return "\(sharedCompendium.ownerID):matched-only:overview-layout-v1:\(viewportKey):\(nodeKey)"
    }

    private func canvasSize(for viewport: CGSize) -> CGSize {
        let count = CGFloat(max(visibleLocalNodes.count, visiblePeerNodes.count, 1))
        let overviewWidth = viewport.width / Self.initialZoomScale * 0.98
        let overviewHeight = viewport.height / Self.initialZoomScale * 0.98
        let densityHeight = 940 + count * 11 + Self.ladderCanvasVerticalSafePadding * 2
        return CGSize(
            width: max(overviewWidth, 1040),
            height: max(overviewHeight, densityHeight)
        )
    }

    private func nodeEntries(metrics: ComparisonLadderMetrics) -> [ComparisonLadderNodeEntry] {
        let local = entries(for: visibleLocalNodes, side: .local, metrics: metrics)
        let peer = entries(for: visiblePeerNodes, side: .peer, metrics: metrics)
        return (local + peer).sorted { first, second in
            if first.position.y == second.position.y {
                return first.node.id < second.node.id
            }
            return first.position.y < second.position.y
        }
    }

    private func entries(
        for nodes: [ComparisonDrinkNode],
        side: ComparisonSide,
        metrics: ComparisonLadderMetrics
    ) -> [ComparisonLadderNodeEntry] {
        let grouped = Dictionary(grouping: nodes) { node in
            Int((node.aggregateRating * 10).rounded())
        }
        var entries: [ComparisonLadderNodeEntry] = []
        let laneDirection: CGFloat = side == .local ? -1 : 1
        let anchorX = side == .local ? metrics.localAnchorX : metrics.peerAnchorX
        let columnSpacing: CGFloat = 58
        let verticalSpacing: CGFloat = 34

        for key in grouped.keys.sorted(by: >) {
            let rowNodes = (grouped[key] ?? []).sorted { first, second in
                if first.aggregateRating == second.aggregateRating {
                    return first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
                }
                return first.aggregateRating > second.aggregateRating
            }
            let baseY = yPosition(for: Double(key) / 10, metrics: metrics)
            for (index, node) in rowNodes.enumerated() {
                let column = index / 3
                let rowOffset = CGFloat(index % 3 - 1) * verticalSpacing
                let position = CGPoint(
                    x: anchorX + laneDirection * CGFloat(column) * columnSpacing,
                    y: min(max(metrics.plotTop + 24, baseY + rowOffset), metrics.plotBottom - 24)
                )
                let ownerName = side == .local ? comparison.localOwnerName : comparison.peerOwnerName
                entries.append(ComparisonLadderNodeEntry(
                    id: node.id,
                    node: node,
                    position: position,
                    ownerName: ownerName,
                    accessibilityLabel: "\(ownerName)，\(node.displayBrand)，\(node.displayName)，评分 \(String(format: "%.2f", node.aggregateRating))"
                ))
            }
        }
        return entries
    }

    private func connectionEntries(metrics: ComparisonLadderMetrics) -> [ComparisonLadderConnectionEntry] {
        let nodeByID = Dictionary(uniqueKeysWithValues: nodeEntries(metrics: metrics).map { ($0.id, $0) })
        return visiblePairs.compactMap { pair in
            guard let local = nodeByID[pair.local.id], let peer = nodeByID[pair.peer.id] else { return nil }
            return ComparisonLadderConnectionEntry(
                id: pair.id,
                pair: pair,
                start: local.position,
                end: peer.position,
                color: connectionUIColor(for: pair.id, fallbackKey: pair.productKey, delta: pair.ratingDelta),
                lineWidth: pair.ratingDelta > 1.5 ? 2.25 : 1.75
            )
        }
    }

    private func yPosition(for rating: Double, metrics: ComparisonLadderMetrics) -> CGFloat {
        metrics.plotTop + CGFloat(5 - min(5, max(0, rating))) / 5 * metrics.plotHeight
    }

    private func connectionUIColor(for pairID: String?, fallbackKey: String, delta: Double) -> UIColor {
        let palette = [
            UIColor.black.withAlphaComponent(0.78),
            UIColor(red: 0.30, green: 0.22, blue: 0.16, alpha: 1),
            UIColor(red: 0.44, green: 0.34, blue: 0.24, alpha: 1),
            UIColor(red: 0.56, green: 0.46, blue: 0.34, alpha: 1),
            UIColor(red: 0.24, green: 0.28, blue: 0.25, alpha: 1),
            UIColor(red: 0.36, green: 0.30, blue: 0.27, alpha: 1)
        ]
        let seed = (pairID ?? fallbackKey).unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        var color = palette[abs(seed) % palette.count]
        if delta > 1.5 {
            color = color.blended(with: UIColor.black, amount: 0.18)
        } else if delta <= 0.5 {
            color = color.blended(with: UIColor.white, amount: 0.12)
        }
        return color
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
}

private struct ComparisonLadderMetrics {
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
}

private struct ComparisonLadderNodeEntry {
    let id: String
    let node: ComparisonDrinkNode
    let position: CGPoint
    let ownerName: String
    let accessibilityLabel: String
}

private struct ComparisonLadderConnectionEntry {
    let id: String
    let pair: ComparisonDrinkPair
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
    let selectedPairID: String?
    let contentSignature: String
    let centerResetToken: Int
    let onTapNode: (ComparisonDrinkNode) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, onTapNode: onTapNode)
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
        scrollView.zoomScale = zoomScale
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
        canvasView.configure(metrics: metrics, nodes: nodes, connections: connections, contentSize: contentSize, contentSignature: contentSignature)
        canvasView.applyZoom(scale: zoomScale, mode: .settled)
        canvasView.updateSelection(nodeID: selectedNodeID, pairID: selectedPairID)
        scrollView.addSubview(canvasView)
        scrollView.contentSize = contentSize

        context.coordinator.scrollView = scrollView
        context.coordinator.canvasView = canvasView
        context.coordinator.nodes = nodes
        context.coordinator.contentSize = contentSize
        context.coordinator.viewport.attach(scrollView)
        context.coordinator.viewport.update(
            canvasSize: contentSize,
            focusPoint: CGPoint(
                x: metrics.centerX,
                y: (metrics.plotTop + metrics.plotBottom) / 2
            )
        )
        context.coordinator.viewport.requestReset(zoomScale: CompendiumComparisonView.initialZoomScale)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let contentDidChange = context.coordinator.contentSignature != contentSignature
        let sizeDidChange = context.coordinator.contentSize != contentSize
        let centerResetDidChange = context.coordinator.centerResetToken != centerResetToken

        context.coordinator.zoomScale = $zoomScale
        context.coordinator.nodes = nodes
        context.coordinator.contentSize = contentSize
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
        if centerResetDidChange {
            context.coordinator.centerResetToken = centerResetToken
        }
        if sizeDidChange {
            scrollView.contentSize = contentSize
            context.coordinator.canvasView?.frame = CGRect(origin: .zero, size: contentSize)
        }
        if contentDidChange || sizeDidChange {
            context.coordinator.canvasView?.configure(metrics: metrics, nodes: nodes, connections: connections, contentSize: contentSize, contentSignature: contentSignature)
            if !centerResetDidChange {
                context.coordinator.viewport.clampContentOffset()
            }
        }

        if centerResetDidChange || sizeDidChange || contentDidChange {
            context.coordinator.viewport.requestReset(zoomScale: CompendiumComparisonView.initialZoomScale)
        } else if !context.coordinator.isZooming,
                  abs(scrollView.zoomScale - zoomScale) > 0.001 {
            scrollView.setZoomScale(zoomScale, animated: false)
        }
        context.coordinator.canvasView?.applyZoom(scale: scrollView.zoomScale, mode: context.coordinator.isZooming ? .preview : .settled)
        context.coordinator.canvasView?.updateSelection(nodeID: selectedNodeID, pairID: selectedPairID)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var zoomScale: Binding<CGFloat>
        let onTapNode: (ComparisonDrinkNode) -> Void
        weak var canvasView: ComparisonLadderCanvasUIView?
        weak var scrollView: UIScrollView?
        let viewport = ZoomCanvasViewportController()
        var nodes: [ComparisonLadderNodeEntry] = []
        var contentSize: CGSize = .zero
        var contentSignature = ""
        var centerResetToken = 0
        var isZooming = false
        private var lastReportedZoomScale: CGFloat = 0

        init(zoomScale: Binding<CGFloat>, onTapNode: @escaping (ComparisonDrinkNode) -> Void) {
            self.zoomScale = zoomScale
            self.onTapNode = onTapNode
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvasView
        }

        func handleScrollViewLayout() {
            viewport.handleLayout()
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let scrollView,
                  let entry = entry(at: recognizer.location(in: scrollView)) else { return }
            onTapNode(entry.node)
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
            if abs(scale - lastReportedZoomScale) > 0.015 {
                lastReportedZoomScale = scale
                zoomScale.wrappedValue = scale
            }
            viewport.updateContentInsets()
            canvasView?.applyZoom(scale: scale, mode: .preview)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isZooming = false
            let settledScale = scrollView.zoomScale
            zoomScale.wrappedValue = settledScale
            viewport.updateContentInsets()
            viewport.clampContentOffset()
            canvasView?.applyZoom(scale: settledScale, mode: .settled, animatesLabel: true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer is UITapGestureRecognizer, let scrollView else { return true }
            return entry(at: touch.location(in: scrollView)) != nil
        }

        private func entry(at scrollViewPoint: CGPoint) -> ComparisonLadderNodeEntry? {
            guard let scrollView, let canvasView else { return nil }
            let contentPoint = canvasView.convert(scrollViewPoint, from: scrollView)
            let counterScale = ComparisonLadderCanvasUIView.nodeCounterScale(for: scrollView.zoomScale)
            let hitSize = CGSize(width: 58 * counterScale, height: 64 * counterScale)
            return nodes.reversed().first { entry in
                CGRect(
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
        contentSignature: String
    ) {
        let shouldAnimate = self.contentSignature != contentSignature
        self.contentSignature = contentSignature
        comparisonWithoutLayerActions {
            bounds = CGRect(origin: .zero, size: contentSize)
            axisLayer.frame = bounds
            connectionContainerLayer.frame = bounds
            nodeContainerLayer.frame = bounds
            rebuildAxis(metrics: metrics)
            rebuildConnections(metrics: metrics, connections: connections)
            rebuildNodes(nodes: nodes)
            applyZoom(scale: currentScale, mode: currentMode)
        }
        if shouldAnimate {
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

    func updateSelection(nodeID: String?, pairID: String?) {
        comparisonWithoutLayerActions {
            nodeLayers.values.forEach { layer in
                let isSelected = nodeID == layer.entry.id || pairID == layer.entry.node.matchedPairID
                let shouldDim = nodeID != nil && !isSelected
                layer.updateSelection(isSelected: isSelected, isDimmed: shouldDim)
            }
            connectionLayers.forEach { id, layer in
                let isSelected = pairID == id
                let shouldDim = pairID != nil && !isSelected
                layer.opacity = shouldDim ? 0.12 : (isSelected ? 0.95 : 0.46)
                layer.lineWidth = isSelected ? 3.4 : (layer.value(forKey: "baseLineWidth") as? CGFloat ?? 1.8)
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

    private func rebuildConnections(metrics: ComparisonLadderMetrics, connections: [ComparisonLadderConnectionEntry]) {
        connectionContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        connectionLayers = [:]
        for connection in connections {
            let path = UIBezierPath()
            path.move(to: connection.start)
            path.addCurve(
                to: connection.end,
                controlPoint1: CGPoint(x: metrics.centerX - 78, y: connection.start.y),
                controlPoint2: CGPoint(x: metrics.centerX + 78, y: connection.end.y)
            )
            let layer = shapeLayer(
                path: path.cgPath,
                color: connection.color.withAlphaComponent(connection.pair.ratingDelta > 1.5 ? 0.62 : 0.52),
                lineWidth: connection.lineWidth,
                dashPattern: connection.pair.ratingDelta > 1.5 ? [8, 7] : nil
            )
            layer.opacity = 0.46
            layer.setValue(connection.lineWidth, forKey: "baseLineWidth")
            connectionContainerLayer.addSublayer(layer)
            connectionLayers[connection.id] = layer
        }
    }

    private func rebuildNodes(nodes: [ComparisonLadderNodeEntry]) {
        nodeContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        nodeLayers = Dictionary(nodes.map { entry in
            let layer = ComparisonNodeLayer(entry: entry)
            nodeContainerLayer.addSublayer(layer)
            return (entry.id, layer)
        }, uniquingKeysWith: { _, latest in latest })
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

        for (index, connectionLayer) in connectionLayers.values.enumerated() {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = connectionCount > 80 ? 0.34 : 0.62
            draw.beginTime = CACurrentMediaTime() + (connectionCount > 80 ? 0 : min(0.22, Double(index) * 0.012))
            draw.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            connectionLayer.add(draw, forKey: "strokeReveal")
        }

        for (index, nodeLayer) in nodeLayers.values.enumerated() {
            let group = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = nodeLayer.opacity
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.9
            scale.toValue = 1
            group.animations = [fade, scale]
            group.duration = 0.26
            group.beginTime = CACurrentMediaTime() + min(0.18, Double(index) * 0.006)
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            nodeLayer.add(group, forKey: "nodeReveal")
        }
    }
}

private final class ComparisonNodeLayer: CALayer {
    let entry: ComparisonLadderNodeEntry
    private let badgeLayer = CALayer()
    private let badgeCircleLayer = CAShapeLayer()
    private let stickerLayer = CALayer()
    private let ratingBadgeLayer = CALayer()
    private let ratingTextLayer = CATextLayer()
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

    func apply(counterScale: CGFloat, labelOpacity: CGFloat, animatesLabel: Bool) {
        position = entry.position
        transform = CATransform3DMakeScale(counterScale, counterScale, 1)
        zPosition = 10_000 - entry.position.y
        let renderedOpacity = Float(labelOpacity > 0 ? max(0.003, labelOpacity) : 0)
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
        opacity = isDimmed ? 0.38 : 1
        badgeCircleLayer.lineWidth = isSelected ? 2.4 : 1
        badgeCircleLayer.strokeColor = UIColor.black.withAlphaComponent(isSelected ? 0.72 : 0.12).cgColor
        zPosition = isSelected ? 20_000 : 10_000 - entry.position.y
        shadowColor = UIColor.black.cgColor
        shadowOpacity = isSelected ? 0.2 : 0
        shadowRadius = isSelected ? 15 : 0
        shadowOffset = CGSize(width: 0, height: isSelected ? 8 : 0)
    }

    private func setupBadge() {
        badgeLayer.frame = CGRect(x: (bounds.width - badgeSize) / 2, y: 0, width: badgeSize, height: badgeSize)
        badgeCircleLayer.frame = badgeLayer.bounds
        badgeCircleLayer.path = UIBezierPath(ovalIn: badgeLayer.bounds).cgPath
        badgeCircleLayer.fillColor = UIColor.white.withAlphaComponent(0.96).cgColor
        badgeCircleLayer.strokeColor = UIColor.black.withAlphaComponent(0.12).cgColor
        badgeCircleLayer.lineWidth = 1
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

        let rating = String(format: "%.2f", entry.node.aggregateRating)
        let ratingFont = UIFont.monospacedDigitSystemFont(ofSize: 6.8, weight: .bold)
        let ratingWidth = max(23, rating.size(withAttributes: [.font: ratingFont]).width + 6)
        ratingBadgeLayer.frame = CGRect(x: badgeLayer.bounds.maxX - ratingWidth + 5, y: badgeLayer.bounds.maxY - 9, width: ratingWidth, height: 12)
        ratingBadgeLayer.backgroundColor = UIColor.black.withAlphaComponent(0.78).cgColor
        ratingBadgeLayer.cornerRadius = 6
        ratingBadgeLayer.masksToBounds = true
        badgeLayer.addSublayer(ratingBadgeLayer)

        ratingTextLayer.frame = CGRect(x: 3, y: 1.5, width: ratingWidth - 6, height: 9)
        configureTextLayer(ratingTextLayer, text: rating, font: ratingFont, color: .white, alignment: .center)
        ratingBadgeLayer.addSublayer(ratingTextLayer)
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
}

private struct ComparisonDrinkCardOverlay: View {
    let node: ComparisonDrinkNode
    let pair: ComparisonDrinkPair?
    let localOwnerName: String
    let peerOwnerName: String
    let onClose: () -> Void

    private var localNode: ComparisonDrinkNode? {
        if let pair { return pair.local }
        return node.side == .local ? node : nil
    }

    private var peerNode: ComparisonDrinkNode? {
        if let pair { return pair.peer }
        return node.side == .peer ? node : nil
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
                            Text(pair?.local.displayName ?? node.displayName)
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

                    ComparisonStackCard(ownerName: localOwnerName, node: localNode, accent: .black)
                    ComparisonStackCard(ownerName: peerOwnerName, node: peerNode, accent: .blue)
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
        if let pair {
            return "共同喝过 · 评分差 \(String(format: "%.2f", pair.ratingDelta))"
        }
        return node.side == .local ? "只在我的图鉴里记录" : "只在 \(peerOwnerName) 的图鉴里记录"
    }
}

private struct ComparisonStackCard: View {
    let ownerName: String
    let node: ComparisonDrinkNode?
    let accent: Color

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
                .stroke(.black.opacity(0.06), lineWidth: 1)
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
