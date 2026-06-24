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
    private var pendingResetZoomScale: CGFloat?
    private var isReconcilingGeometry = false

    func attach(_ scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func update(canvasSize: CGSize, focusPoint: CGPoint) {
        self.canvasSize = canvasSize
        self.focusPoint = focusPoint
    }

    /// Applies a queued reset as soon as Auto Layout has supplied a real viewport.
    /// There is deliberately no timed retry loop: a later compendium must never
    /// be affected by a delayed reset created for an earlier one.
    func handleLayout() {
        guard hasUsableGeometry else { return }
        if pendingResetZoomScale != nil {
            applyPendingReset()
        } else {
            updateContentInsets()
        }
    }

    func requestReset(zoomScale: CGFloat) {
        pendingResetZoomScale = zoomScale
        applyPendingReset()
    }

    func cancelPendingReset() {
        pendingResetZoomScale = nil
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
              let requestedScale = pendingResetZoomScale,
              hasUsableGeometry,
              scrollView.window != nil,
              !scrollView.isDragging,
              !scrollView.isDecelerating else {
            return
        }

        let scale = clampedZoomScale(requestedScale, in: scrollView)
        pendingResetZoomScale = nil

        // `zoom(to:)` derives its scale from the scroll view's transient
        // contentSize.  Set the scale directly, then set a content offset from
        // stable source-space geometry instead.
        scrollView.setZoomScale(scale, animated: false)
        reconcileGeometry(clampLargeContent: false)

        let inset = contentInset(for: scrollView, scale: scale)
        let desiredOffset = CGPoint(
            x: focusPoint.x * scale - scrollView.bounds.midX - inset.left,
            y: focusPoint.y * scale - scrollView.bounds.midY - inset.top
        )
        setContentOffset(
            clampedOffset(desiredOffset, in: scrollView, scale: scale, inset: inset),
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

    private func clampedZoomScale(_ scale: CGFloat, in scrollView: UIScrollView) -> CGFloat {
        min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scale))
    }

    private func scaledCanvasSize(for scale: CGFloat) -> CGSize {
        CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
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
