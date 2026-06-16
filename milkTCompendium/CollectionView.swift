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

    private let leverWidth: CGFloat = 88
    private let leverHeight: CGFloat = 18
    private let tuckedOffset: CGFloat = 54
    private let maxReveal: CGFloat = 42
    private let maxLift: CGFloat = 58
    private let captureThreshold: CGFloat = -26
    private let importThreshold: CGFloat = -34

    var body: some View {
        ZStack(alignment: .leading) {
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: leverHeight / 2,
                    bottomLeading: leverHeight / 2,
                    bottomTrailing: 4,
                    topTrailing: 4
                ),
                style: .continuous
            )
                .fill(.white)
                .frame(width: leverWidth, height: leverHeight)
                .overlay {
                    UnevenRoundedRectangle(
                        cornerRadii: RectangleCornerRadii(
                            topLeading: leverHeight / 2,
                            bottomLeading: leverHeight / 2,
                            bottomTrailing: 4,
                            topTrailing: 4
                        ),
                        style: .continuous
                    )
                    .stroke(isPhotoImportGesture ? .blue : .black, lineWidth: 1.5)
                }

        }
        .frame(width: leverWidth, height: leverHeight, alignment: .leading)
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

                    if isImporting != isPhotoImportGesture {
                        UIImpactFeedbackGenerator(style: isImporting ? .medium : .light).impactOccurred()
                    }

                    dragOffset = CGSize(width: horizontal, height: vertical)
                    isPhotoImportGesture = isImporting
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
                    }
                }
        )
        .onTapGesture {
            onCapture()
        }
        .accessibilityLabel("拍一杯")
        .accessibilityHint("点按或向左拉动打开相机，拉出后向上推打开相册")
    }
}
