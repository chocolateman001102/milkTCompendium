import SwiftData
import SwiftUI
import UIKit

struct CollectionView: View {
    fileprivate enum SortMode: String, CaseIterable, Identifiable {
        case brand = "品牌"
        case rating = "评分"

        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Drink.createdAt, order: .reverse) private var drinks: [Drink]
    @AppStorage("collectionSortMode") private var sortModeRaw = SortMode.rating.rawValue
    @State private var draggingDrink: Drink?
    @State private var dragTranslation: CGSize = .zero
    @State private var isOverDeleteTarget = false
    let onStartCapture: () -> Void
    let onStartPhotoImport: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 16)
    ]

    private var sortMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .rating
    }

    private var sortModeBinding: Binding<SortMode> {
        Binding {
            sortMode
        } set: { newValue in
            sortModeRaw = newValue.rawValue
        }
    }

    private var groupedDrinks: [(title: String, drinks: [Drink])] {
        switch sortMode {
        case .brand:
            return Dictionary(grouping: drinks) {
                $0.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分类品牌" : $0.brand
            }
            .map {
                (
                    title: $0.key,
                    drinks: $0.value.sorted { $0.rating == $1.rating ? $0.createdAt > $1.createdAt : $0.rating > $1.rating }
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        case .rating:
            return Dictionary(grouping: drinks) { ratingGroupTitle(for: $0.rating) }
                .map {
                    (
                        title: $0.key,
                        drinks: $0.value.sorted { $0.rating == $1.rating ? $0.createdAt > $1.createdAt : $0.rating > $1.rating }
                    )
                }
                .sorted { ratingGroupRank($0.title) > ratingGroupRank($1.title) }
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(groupedDrinks, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(group.title)
                                        .font(.title2.bold())
                                    Text("\(group.drinks.count) 杯")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                LazyVGrid(columns: columns, spacing: 20) {
                                    ForEach(group.drinks) { drink in
                                        NavigationLink {
                                            DrinkFormView(mode: .edit(drink)) {}
                                        } label: {
                                            DrinkCardView(drink: drink)
                                        }
                                        .buttonStyle(.plain)
                                        .scaleEffect(draggingDrink === drink ? 1.05 : 1)
                                        .offset(draggingDrink === drink ? dragTranslation : .zero)
                                        .rotationEffect(.degrees(draggingDrink === drink ? -2 : 0))
                                        .shadow(
                                            color: draggingDrink === drink ? .black.opacity(0.16) : .clear,
                                            radius: draggingDrink === drink ? 18 : 0,
                                            y: draggingDrink === drink ? 10 : 0
                                        )
                                        .zIndex(draggingDrink === drink ? 10 : 0)
                                        .highPriorityGesture(deleteGesture(for: drink))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 96)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) {
            if !drinks.isEmpty {
                SortMenu(selection: sortModeBinding)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
            }
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
            if draggingDrink != nil {
                DeleteDropZone(isActive: isOverDeleteTarget)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private func ratingGroupTitle(for rating: Double) -> String {
        if rating >= 5 {
            return "5 分"
        }
        return "\(Int(floor(rating))) 分段"
    }

    private func ratingGroupRank(_ title: String) -> Int {
        Int(title.prefix(1)) ?? -1
    }

    private func deleteGesture(for drink: Drink) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    if draggingDrink == nil {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                        draggingDrink = drink
                    }

                case .second(true, let drag?):
                    draggingDrink = drink
                    dragTranslation = drag.translation
                    let isActive = drag.translation.height > 150
                    if isActive != isOverDeleteTarget {
                        UIImpactFeedbackGenerator(style: isActive ? .medium : .light).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        isOverDeleteTarget = isActive
                    }

                default:
                    break
                }
            }
            .onEnded { value in
                let shouldDelete: Bool
                if case .second(true, let drag?) = value {
                    shouldDelete = drag.translation.height > 150
                } else {
                    shouldDelete = false
                }

                if shouldDelete {
                    delete(drink)
                }

                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    draggingDrink = nil
                    dragTranslation = .zero
                    isOverDeleteTarget = false
                }
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

private struct SortMenu: View {
    @Binding var selection: CollectionView.SortMode

    var body: some View {
        Menu {
            Picker("排列", selection: $selection) {
                ForEach(CollectionView.SortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                Text(selection.rawValue)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.92))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
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
