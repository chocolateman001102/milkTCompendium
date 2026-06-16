import SwiftData
import SwiftUI

struct CollectionView: View {
    @Query(sort: \Drink.createdAt, order: .reverse) private var drinks: [Drink]
    @Binding var showingNewDrink: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 16)
    ]

    private var groupedDrinks: [(brand: String, drinks: [Drink])] {
        Dictionary(grouping: drinks) {
            $0.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分类品牌" : $0.brand
        }
        .map { (brand: $0.key, drinks: $0.value) }
        .sorted { $0.brand.localizedStandardCompare($1.brand) == .orderedAscending }
    }

    var body: some View {
        Group {
            if drinks.isEmpty {
                ContentUnavailableView {
                    Label("图鉴还是空的", systemImage: "cup.and.saucer")
                } description: {
                    Text("记录第一杯奶茶，它会变成一张透明背景小贴图。")
                } actions: {
                    Button("记录第一杯") {
                        showingNewDrink = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brown)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(groupedDrinks, id: \.brand) { group in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(group.brand)
                                        .font(.title2.bold())
                                    Text("\(group.drinks.count) 杯")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                LazyVGrid(columns: columns, spacing: 20) {
                                    ForEach(group.drinks) { drink in
                                        DrinkCardView(drink: drink)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("奶茶图鉴")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewDrink = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("记录新饮品")
            }
        }
    }
}
