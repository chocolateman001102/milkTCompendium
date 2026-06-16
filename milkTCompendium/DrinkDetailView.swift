import SwiftUI

struct FloatingDrinkCardOverlay: View {
    let drink: Drink
    let onClose: () -> Void
    let onEdit: () -> Void

    private let goldenRatio: CGFloat = 1.618

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(proxy.size.width - 28, 398)
            let cardHeight = cardWidth / goldenRatio

            ZStack {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                floatingContent(width: cardWidth, height: cardHeight)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.46)
                    .onTapGesture {}
            }
        }
    }

    private func floatingContent(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            card(width: width, height: height)
                .frame(width: width, height: height)

            Button("修改") {
                onEdit()
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(.black)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
            .padding(.trailing, 6)
        }
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 14) {
            stickerPanel(width: height * 0.48, height: height - 26)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayBrand)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(displayName)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }

                    Spacer(minLength: 4)
                    limitedBadge
                }

                HStack(spacing: 8) {
                    infoPill(title: "甜度", value: drink.sweetness)
                    infoPill(title: "冰度", value: drink.iceLevel)
                }

                noteView

                HStack {
                    Text(String(format: "%.2f", drink.rating))
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    Text("/ 5")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(13)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 24, y: 14)
    }

    private func stickerPanel(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))

            if let image = ImageStore.load(drink.stickerImageName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
    }

    private var limitedBadge: some View {
        Text(drink.isLimited ? "限定" : "常规")
            .font(.caption2.weight(.black))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(drink.isLimited ? .white : .secondary)
            .background(drink.isLimited ? Color.black : Color(.secondarySystemGroupedBackground))
            .clipShape(Capsule())
    }

    private func infoPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var noteView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("备注")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(displayNote)
                .font(.caption)
                .foregroundStyle(drink.note.isEmpty ? .tertiary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
        }
        .padding(.horizontal, 10)
    }

    private var displayBrand: String {
        let cleaned = drink.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未知品牌" : cleaned
    }

    private var displayName: String {
        let cleaned = drink.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    private var displayNote: String {
        let cleaned = drink.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "无" : cleaned
    }
}
