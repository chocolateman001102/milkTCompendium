import UIKit

final class ZoomCanvasScrollView: UIScrollView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

/// Owns the coordinate conversion between a zoomed canvas and its scroll view.
///
/// `UIScrollView.contentSize` is briefly stale while a zoomable subview is being
/// resized or replaced.  That is particularly visible when SwiftUI reuses a
/// representable for a different compendium: using the stale value to derive
/// insets makes the next pinch start from the previous canvas's bounds.  All
/// geometry in this type is therefore derived from the source canvas size and
/// the active zoom scale instead of `contentSize`.
final class ZoomCanvasViewportController {
    weak var scrollView: UIScrollView?

    private var canvasSize: CGSize = .zero
    private var focusPoint: CGPoint = .zero
    private var pendingReset: PendingReset?
    private var isReconcilingGeometry = false

    private struct PendingReset {
        let zoomScale: CGFloat
    }

    func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func update(canvasSize: CGSize, focusPoint: CGPoint) {
        self.canvasSize = canvasSize
        self.focusPoint = focusPoint
        if pendingReset != nil {
            applyPendingReset()
        }
    }

    /// Applies a queued reset as soon as Auto Layout has supplied a real viewport.
    /// There is deliberately no timed retry loop: a later compendium must never
    /// be affected by a delayed reset created for an earlier one.
    func handleLayout() {
        if pendingReset != nil {
            applyPendingReset()
        } else {
            updateContentInsets()
        }
    }

    func requestReset(zoomScale: CGFloat) {
        pendingReset = PendingReset(zoomScale: zoomScale)
        applyPendingReset()
    }

    func cancelPendingReset() {
        pendingReset = nil
    }

    func zoom(
        to zoomScale: CGFloat,
        centeredAtContentPoint contentPoint: CGPoint,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard let scrollView, hasUsableGeometry else {
            completion?()
            return
        }

        pendingReset = nil
        let scale = clampedZoomScale(zoomScale, in: scrollView)
        let focus = clampedContentPoint(contentPoint)
        let targetSize = CGSize(
            width: scrollView.bounds.width / scale,
            height: scrollView.bounds.height / scale
        )
        let targetRect = CGRect(
            x: focus.x - targetSize.width / 2,
            y: focus.y - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )

        guard animated else {
            scrollView.zoom(to: targetRect, animated: false)
            reconcileGeometry(clampLargeContent: true)
            completion?()
            return
        }

        scrollView.zoom(to: targetRect, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.reconcileGeometry(clampLargeContent: true)
            completion?()
        }
    }

    /// Keeps an undersized canvas centered without changing the user's valid
    /// pan position on axes that are larger than the viewport.
    func updateContentInsets() {
        reconcileGeometry(clampLargeContent: false)
    }

    /// Restores the valid pan range after a zoom or a canvas-size change.
    func clampContentOffset() {
        reconcileGeometry(clampLargeContent: true)
    }

    private func applyPendingReset() {
        guard let scrollView,
              let reset = pendingReset,
              canApplyReset(in: scrollView) else {
            return
        }

        let scale = clampedZoomScale(reset.zoomScale, in: scrollView)
        pendingReset = nil

        // Set the scale directly, then derive the offset from stable
        // source-space geometry instead of the scroll view's transient
        // contentSize.
        scrollView.setZoomScale(scale, animated: false)
        reconcileGeometry(clampLargeContent: false)

        let inset = contentInset(for: scrollView, scale: scale)
        setContentOffset(
            centeredOffset(on: focusPoint, in: scrollView, scale: scale, inset: inset),
            on: scrollView
        )
    }

    private func reconcileGeometry(clampLargeContent: Bool) {
        guard let scrollView, hasUsableGeometry, !isReconcilingGeometry else { return }

        isReconcilingGeometry = true
        defer { isReconcilingGeometry = false }

        let scale = clampedZoomScale(scrollView.zoomScale, in: scrollView)
        let inset = contentInset(for: scrollView, scale: scale)
        if !insetsAreEqual(scrollView.contentInset, inset) {
            scrollView.contentInset = inset
            scrollView.scrollIndicatorInsets = inset
        }

        let scaledSize = scaledCanvasSize(for: scale)
        var targetOffset = scrollView.contentOffset
        if scaledSize.width <= scrollView.bounds.width {
            targetOffset.x = -inset.left
        } else if clampLargeContent {
            targetOffset.x = clampedOffset(targetOffset, in: scrollView, scale: scale, inset: inset).x
        }

        if scaledSize.height <= scrollView.bounds.height {
            targetOffset.y = -inset.top
        } else if clampLargeContent {
            targetOffset.y = clampedOffset(targetOffset, in: scrollView, scale: scale, inset: inset).y
        }
        setContentOffset(targetOffset, on: scrollView)
    }

    private var hasUsableGeometry: Bool {
        guard let scrollView else { return false }
        return scrollView.bounds.width > 1
            && scrollView.bounds.height > 1
            && canvasSize.width > 1
            && canvasSize.height > 1
    }

    private func canApplyReset(in scrollView: UIScrollView) -> Bool {
        hasUsableGeometry
            && scrollView.window != nil
            && !scrollView.isDragging
            && !scrollView.isDecelerating
    }

    private func clampedZoomScale(_ scale: CGFloat, in scrollView: UIScrollView) -> CGFloat {
        min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scale))
    }

    private func scaledCanvasSize(for scale: CGFloat) -> CGSize {
        CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
    }

    private func clampedContentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), canvasSize.width),
            y: min(max(point.y, 0), canvasSize.height)
        )
    }

    private func centeredOffset(
        on contentPoint: CGPoint,
        in scrollView: UIScrollView,
        scale: CGFloat,
        inset: UIEdgeInsets
    ) -> CGPoint {
        let desiredOffset = CGPoint(
            x: contentPoint.x * scale - scrollView.bounds.midX,
            y: contentPoint.y * scale - scrollView.bounds.midY
        )
        return clampedOffset(desiredOffset, in: scrollView, scale: scale, inset: inset)
    }

    private func contentInset(for scrollView: UIScrollView, scale: CGFloat) -> UIEdgeInsets {
        let scaledSize = scaledCanvasSize(for: scale)
        return UIEdgeInsets(
            top: max(0, (scrollView.bounds.height - scaledSize.height) / 2),
            left: max(0, (scrollView.bounds.width - scaledSize.width) / 2),
            bottom: max(0, (scrollView.bounds.height - scaledSize.height) / 2),
            right: max(0, (scrollView.bounds.width - scaledSize.width) / 2)
        )
    }

    private func clampedOffset(
        _ offset: CGPoint,
        in scrollView: UIScrollView,
        scale: CGFloat,
        inset: UIEdgeInsets
    ) -> CGPoint {
        let scaledSize = scaledCanvasSize(for: scale)
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scaledSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(minY, scaledSize.height - scrollView.bounds.height + inset.bottom)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }

    private func setContentOffset(_ offset: CGPoint, on scrollView: UIScrollView) {
        guard abs(scrollView.contentOffset.x - offset.x) > 0.01
                || abs(scrollView.contentOffset.y - offset.y) > 0.01 else {
            return
        }
        scrollView.setContentOffset(offset, animated: false)
    }

    private func insetsAreEqual(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) < 0.01
            && abs(lhs.left - rhs.left) < 0.01
            && abs(lhs.bottom - rhs.bottom) < 0.01
            && abs(lhs.right - rhs.right) < 0.01
    }
}
