import SwiftUI

struct DrinkCardView: View {
    let drink: Drink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.brown.opacity(0.08))

                if let image = ImageStore.load(drink.stickerImageName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                } else {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.brown.opacity(0.55))
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(drink.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)

            Text(String(format: "%.2f", drink.rating))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(drink.brand)，\(drink.name)，评分 \(String(format: "%.2f", drink.rating))")
    }
}
