import UIKit

final class ZoomCanvasScrollView: UIScrollView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

final class ZoomCanvasViewportController {
    weak var scrollView: UIScrollView?
    private var canvasSize: CGSize = .zero
    private var focusPoint: CGPoint = .zero
    private var centeringGeneration = 0
    private var pendingResetZoomScale: CGFloat?

    func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func update(canvasSize: CGSize, focusPoint: CGPoint) {
        self.canvasSize = canvasSize
        self.focusPoint = focusPoint
    }

    func handleLayout() {
        updateContentInsets()
        guard pendingResetZoomScale != nil else { return }
        applyPendingReset(markComplete: false)
    }

    func requestReset(zoomScale: CGFloat) {
        pendingResetZoomScale = zoomScale
        centeringGeneration += 1
        let generation = centeringGeneration
        let delays: [TimeInterval] = [0, 0.05, 0.18, 0.36, 0.7]

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.centeringGeneration == generation else { return }
                self.applyPendingReset(markComplete: index == delays.count - 1)
            }
        }
    }

    func cancelPendingReset() {
        pendingResetZoomScale = nil
        centeringGeneration += 1
    }

    func updateContentInsets() {
        guard let scrollView, hasUsableGeometry(scrollView) else { return }
        let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        let inset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        guard scrollView.contentInset != inset else { return }
        scrollView.contentInset = inset
        scrollView.scrollIndicatorInsets = inset
    }

    func clampContentOffset() {
        guard let scrollView, hasUsableGeometry(scrollView) else { return }
        updateContentInsets()
        let clamped = clampedOffset(scrollView.contentOffset, in: scrollView)
        guard clamped != scrollView.contentOffset else { return }
        scrollView.setContentOffset(clamped, animated: false)
    }

    private func applyPendingReset(markComplete: Bool) {
        guard let scrollView,
              let resetZoomScale = pendingResetZoomScale,
              hasUsableGeometry(scrollView),
              scrollView.window != nil,
              !scrollView.isDragging,
              !scrollView.isDecelerating else {
            return
        }

        let targetScale = min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, resetZoomScale))
        let visibleSize = CGSize(
            width: min(canvasSize.width, scrollView.bounds.width / targetScale),
            height: min(canvasSize.height, scrollView.bounds.height / targetScale)
        )
        let visibleOrigin = CGPoint(
            x: min(max(focusPoint.x - visibleSize.width / 2, 0), max(0, canvasSize.width - visibleSize.width)),
            y: min(max(focusPoint.y - visibleSize.height / 2, 0), max(0, canvasSize.height - visibleSize.height))
        )
        let visibleRect = CGRect(origin: visibleOrigin, size: visibleSize)
        scrollView.zoom(to: visibleRect, animated: false)

        updateContentInsets()
        clampContentOffset()
        if markComplete {
            pendingResetZoomScale = nil
        }
    }

    private func hasUsableGeometry(_ scrollView: UIScrollView) -> Bool {
        scrollView.bounds.width > 1
            && scrollView.bounds.height > 1
            && canvasSize.width > 1
            && canvasSize.height > 1
    }

    private func clampedOffset(_ offset: CGPoint, in scrollView: UIScrollView) -> CGPoint {
        let minX = -scrollView.contentInset.left
        let minY = -scrollView.contentInset.top
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }
}
