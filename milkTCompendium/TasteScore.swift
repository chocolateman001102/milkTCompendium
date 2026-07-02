import Foundation
import UIKit

struct PixelPersonProfile: Codable, Hashable {
    var skinHex: String
    var hairHex: String
    var topHex: String
    var bottomHex: String
    var accentHex: String
    var hairStyle: Int
    var faceStyle: Int
    var accessoryStyle: Int
    var cupStyle: Int

    static func make(ownerID: String, ownerName: String, drinks: [Drink]) -> PixelPersonProfile {
        make(
            ownerID: ownerID,
            ownerName: ownerName,
            profile: TasteScoreCalculator.profile(from: drinks),
            photoColorHexes: drinks.compactMap { photoColorHex(imageName: $0.stickerImageName) }
        )
    }

    static func make(ownerID: String, ownerName: String, snapshots: [DrinkExportSnapshot]) -> PixelPersonProfile {
        let profile = snapshots.map {
            TasteProfileDrink(brand: $0.brand, name: $0.name, rating: $0.rating, cupCount: max(1, $0.cupCount))
        }
        return make(
            ownerID: ownerID,
            ownerName: ownerName,
            profile: profile,
            photoColorHexes: snapshots.compactMap { photoColorHex(imageName: $0.stickerImageName) }
        )
    }

    static func make(ownerID: String, ownerName: String, archivedDrinks: [SharedDrinkArchive]) -> PixelPersonProfile {
        let profile = archivedDrinks.map {
            TasteProfileDrink(brand: $0.brand, name: $0.name, rating: $0.rating, cupCount: max(1, $0.cupCount))
        }
        return make(
            ownerID: ownerID,
            ownerName: ownerName,
            profile: profile,
            photoColorHexes: archivedDrinks.compactMap { photoColorHex(data: $0.stickerData) }
        )
    }

    static func make(compendium: SharedCompendium) -> PixelPersonProfile {
        make(
            ownerID: compendium.ownerID,
            ownerName: compendium.ownerName,
            profile: TasteScoreCalculator.profile(from: compendium),
            photoColorHexes: compendium.drinks.compactMap {
                photoColorHex(url: SharedCompendiumStore.stickerURL(ownerID: compendium.ownerID, fileName: $0.stickerFileName))
            }
        )
    }

    static func make(
        ownerID: String,
        ownerName: String,
        profile: [TasteProfileDrink],
        photoColorHexes: [String] = []
    ) -> PixelPersonProfile {
        let seedText = ([ownerID, ownerName] + profile.flatMap {
            [$0.brand, $0.name, String(format: "%.2f", $0.rating), "\($0.cupCount)"]
        } + photoColorHexes).joined(separator: "|")
        let seed = stableHash(seedText)
        let favoriteColor = photoColorHexes.first ?? paletteColor(seed: seed, offset: 8)
        let accent = photoColorHexes.dropFirst().first ?? paletteColor(seed: seed, offset: 24)
        return PixelPersonProfile(
            skinHex: skinTones[Int(seed % UInt64(skinTones.count))],
            hairHex: hairColors[Int((seed >> 5) % UInt64(hairColors.count))],
            topHex: favoriteColor,
            bottomHex: pantColors[Int((seed >> 13) % UInt64(pantColors.count))],
            accentHex: accent,
            hairStyle: Int((seed >> 21) % 4),
            faceStyle: Int((seed >> 25) % 3),
            accessoryStyle: Int((seed >> 29) % 4),
            cupStyle: Int((seed >> 33) % 4)
        )
    }

    private static let skinTones = ["#F5C7A9", "#DFA176", "#B8754C", "#F1D0B8", "#8F5E3F"]
    private static let hairColors = ["#2C1F1A", "#5B3828", "#101820", "#7A4B2B", "#D8B36A", "#4B5563"]
    private static let pantColors = ["#243B53", "#374151", "#31572C", "#6D597A", "#1F2937"]
    private static let fallbackPalette = ["#E85D75", "#2A9D8F", "#F4A261", "#457B9D", "#7B2CBF", "#118AB2", "#06D6A0"]

    private static func paletteColor(seed: UInt64, offset: UInt64) -> String {
        fallbackPalette[Int(((seed >> offset) ^ seed) % UInt64(fallbackPalette.count))]
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func photoColorHex(imageName: String?) -> String? {
        guard let image = ImageStore.thumbnail(imageName, maxPixel: 28) else { return nil }
        return averageColorHex(from: image)
    }

    private static func photoColorHex(url: URL?) -> String? {
        guard let image = ImageStore.thumbnail(at: url, maxPixel: 28) else { return nil }
        return averageColorHex(from: image)
    }

    private static func photoColorHex(data: Data?) -> String? {
        guard let data, let image = UIImage(data: data) else { return nil }
        return averageColorHex(from: image)
    }

    private static func averageColorHex(from image: UIImage) -> String? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let sample = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard let cgImage = sample.cgImage,
              let providerData = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            return nil
        }
        let red = Int(bytes[0])
        let green = Int(bytes[1])
        let blue = Int(bytes[2])
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

struct TasteProfileDrink: Codable, Hashable {
    var brand: String
    var name: String
    var rating: Double
    var cupCount: Int = 1

    enum CodingKeys: String, CodingKey {
        case brand
        case name
        case rating
        case cupCount
    }

    init(brand: String, name: String, rating: Double, cupCount: Int = 1) {
        self.brand = brand
        self.name = name
        self.rating = rating
        self.cupCount = max(1, cupCount)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        brand = try container.decode(String.self, forKey: .brand)
        name = try container.decode(String.self, forKey: .name)
        rating = try container.decode(Double.self, forKey: .rating)
        cupCount = max(1, try container.decodeIfPresent(Int.self, forKey: .cupCount) ?? 1)
    }
}

struct TastePeerSnapshot: Codable, Identifiable {
    var ownerID: String
    var ownerName: String
    var drinkCount: Int
    var effectiveDrinkCount: Int
    var averageRating: Double
    var lastExchangedAt: Date
    var profile: [TasteProfileDrink]
    var pixelPerson: PixelPersonProfile?

    enum CodingKeys: String, CodingKey {
        case ownerID
        case ownerName
        case drinkCount
        case effectiveDrinkCount
        case averageRating
        case lastExchangedAt
        case profile
        case pixelPerson
    }

    var id: String {
        ownerID
    }

    init(
        ownerID: String,
        ownerName: String,
        drinkCount: Int,
        effectiveDrinkCount: Int,
        averageRating: Double,
        lastExchangedAt: Date,
        profile: [TasteProfileDrink],
        pixelPerson: PixelPersonProfile? = nil
    ) {
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.drinkCount = max(0, drinkCount)
        self.effectiveDrinkCount = max(0, effectiveDrinkCount)
        self.averageRating = averageRating
        self.lastExchangedAt = lastExchangedAt
        self.profile = profile
        self.pixelPerson = pixelPerson
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ownerID = try container.decode(String.self, forKey: .ownerID)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        let decodedProfile = try container.decodeIfPresent([TasteProfileDrink].self, forKey: .profile) ?? []
        profile = decodedProfile
        let decodedDrinkCount = try container.decode(Int.self, forKey: .drinkCount)
        if !decodedProfile.isEmpty {
            drinkCount = TasteScoreCalculator.totalActualCupCount(profile: decodedProfile)
            effectiveDrinkCount = TasteScoreCalculator.effectiveCupCount(profile: decodedProfile)
        } else {
            drinkCount = max(0, decodedDrinkCount)
            effectiveDrinkCount = max(
                0,
                try container.decodeIfPresent(Int.self, forKey: .effectiveDrinkCount) ?? decodedDrinkCount
            )
        }
        averageRating = try container.decode(Double.self, forKey: .averageRating)
        lastExchangedAt = try container.decode(Date.self, forKey: .lastExchangedAt)
        pixelPerson = try container.decodeIfPresent(PixelPersonProfile.self, forKey: .pixelPerson)
    }
}

struct TasteExchangeStats: Codable {
    var successfulExchangeCount: Int
    var peers: [TastePeerSnapshot]

    static let empty = TasteExchangeStats(successfulExchangeCount: 0, peers: [])
}

struct TasteScoreComponents {
    var totalCup: Double
    var exchange: Double
    var agreement: Double
    var hasAgreementSample: Bool
    var authority: Double
    var totalCupCount: Int
    var successfulExchangeCount: Int
}

struct TasteScoreResult {
    var score: Double
    var components: TasteScoreComponents

    var levelName: String {
        switch score {
        case ..<1:
            return "t5"
        case ..<2:
            return "t4"
        case ..<3:
            return "t3"
        case ..<4:
            return "t2"
        default:
            return "t1"
        }
    }
}

@MainActor
final class TasteExchangeStatsStore: ObservableObject {
    @Published private(set) var stats: TasteExchangeStats = .empty

    private static let fileName = "taste-exchange-stats.json"

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            stats = .empty
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stats = (try? decoder.decode(TasteExchangeStats.self, from: data)) ?? .empty
        normalizePeerSnapshots()
    }

    func recordSuccessfulExchange(
        ownerID: String,
        ownerName: String,
        drinkCount: Int,
        effectiveDrinkCount: Int,
        averageRating: Double,
        profile: [TasteProfileDrink]? = nil,
        pixelPerson: PixelPersonProfile? = nil
    ) {
        guard !ownerID.isEmpty, ownerID != SharedCompendiumStore.localOwnerID else { return }

        let existingProfile = stats.peers.first { $0.ownerID == ownerID }?.profile ?? []
        let existingPixelPerson = stats.peers.first { $0.ownerID == ownerID }?.pixelPerson
        let incomingProfile = profile ?? existingProfile
        let snapshot = TastePeerSnapshot(
            ownerID: ownerID,
            ownerName: ownerName,
            drinkCount: max(0, drinkCount),
            effectiveDrinkCount: max(0, effectiveDrinkCount),
            averageRating: averageRating,
            lastExchangedAt: .now,
            profile: incomingProfile,
            pixelPerson: pixelPerson ?? existingPixelPerson ?? PixelPersonProfile.make(
                ownerID: ownerID,
                ownerName: ownerName,
                profile: incomingProfile
            )
        )

        stats.peers.removeAll { peer in
            peer.ownerID == ownerID
        }
        stats.peers.append(snapshot)
        stats.peers.sort { $0.lastExchangedAt > $1.lastExchangedAt }
        stats.successfulExchangeCount = stats.peers.count
        save()
    }

    func recordImportedCompendiumsIfMissing(_ compendiums: [SharedCompendium]) {
        let existingOwnerIDs = Set(stats.peers.map(\.ownerID))
        let missingCompendiums = compendiums.filter { compendium in
            !compendium.ownerID.isEmpty
                && compendium.ownerID != SharedCompendiumStore.localOwnerID
                && !existingOwnerIDs.contains(compendium.ownerID)
        }
        guard !missingCompendiums.isEmpty else { return }

        for compendium in missingCompendiums {
            let profile = TasteScoreCalculator.profile(from: compendium)
            stats.peers.append(
                TastePeerSnapshot(
                    ownerID: compendium.ownerID,
                    ownerName: compendium.ownerName,
                    drinkCount: TasteScoreCalculator.totalActualCupCount(profile: profile),
                    effectiveDrinkCount: TasteScoreCalculator.effectiveCupCount(profile: profile),
                    averageRating: TasteScoreCalculator.averageRating(profile: profile),
                    lastExchangedAt: compendium.exportedAt,
                    profile: profile,
                    pixelPerson: compendium.pixelPerson ?? PixelPersonProfile.make(compendium: compendium)
                )
            )
        }

        stats.peers.sort { $0.lastExchangedAt > $1.lastExchangedAt }
        stats.successfulExchangeCount = stats.peers.count
        save()
    }

    func removePeer(ownerID: String) {
        guard !ownerID.isEmpty else { return }
        let originalPeerCount = stats.peers.count
        stats.peers.removeAll { peer in
            peer.ownerID == ownerID
        }
        stats.successfulExchangeCount = stats.peers.count
        if stats.peers.count != originalPeerCount {
            save()
        }
    }

    private func normalizePeerSnapshots() {
        let originalPeerCount = stats.peers.count
        let originalExchangeCount = stats.successfulExchangeCount
        var normalizedPeers: [TastePeerSnapshot] = []

        for peer in stats.peers.sorted(by: { $0.lastExchangedAt > $1.lastExchangedAt }) {
            guard peer.ownerID != SharedCompendiumStore.localOwnerID else { continue }
            let isDuplicate = normalizedPeers.contains { existing in
                existing.ownerID == peer.ownerID
            }
            if !isDuplicate {
                normalizedPeers.append(peer)
            }
        }

        stats.peers = normalizedPeers
        stats.successfulExchangeCount = normalizedPeers.count
        if normalizedPeers.count != originalPeerCount || stats.successfulExchangeCount != originalExchangeCount {
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stats) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

enum TasteScoreCalculator {
    private static let scoreBaseline = 2.46
    private static let scoreSpread = 2.0
    private static let totalCupCenter = 350
    private static let totalCupLogSpread = 0.62
    private static let exchangeCenter = 10
    private static let exchangeSpread = 4.2
    private static let agreementCenter = 0.68
    private static let agreementSpread = 0.15
    private static let missingAgreementSignal = -0.5
    private static let authorityCenter = 0.66
    private static let authoritySpread = 0.17
    private static let authorityRatingCenter = 3.0

    static func calculate(localDrinks: [Drink], stats: TasteExchangeStats) -> TasteScoreResult {
        let localProfile = profile(from: localDrinks)
        return calculate(localProfile: localProfile, stats: stats)
    }

    static func profile(from drinks: [Drink]) -> [TasteProfileDrink] {
        drinks.map {
            TasteProfileDrink(brand: $0.brand, name: $0.name, rating: $0.rating, cupCount: max(1, $0.cupCount))
        }
    }

    static func profile(from compendium: SharedCompendium) -> [TasteProfileDrink] {
        compendium.drinks.map {
            TasteProfileDrink(brand: $0.brand, name: $0.name, rating: $0.rating, cupCount: max(1, $0.cupCount))
        }
    }

    static func totalActualCupCount(drinks: [Drink]) -> Int {
        drinks.map { max(1, $0.cupCount) }.reduce(0, +)
    }

    static func totalActualCupCount(profile: [TasteProfileDrink]) -> Int {
        profile.map { max(1, $0.cupCount) }.reduce(0, +)
    }

    static func effectiveCupCount(drinks: [Drink]) -> Int {
        drinks.map { effectiveCupContribution(for: $0.cupCount) }.reduce(0, +)
    }

    static func effectiveCupCount(profile: [TasteProfileDrink]) -> Int {
        profile.map { effectiveCupContribution(for: $0.cupCount) }.reduce(0, +)
    }

    static func averageRating(profile: [TasteProfileDrink]) -> Double {
        guard !profile.isEmpty else { return 0 }
        return profile.map(\.rating).reduce(0, +) / Double(profile.count)
    }

    static func fuzzyUniqueProductCount(localDrinks: [Drink], peers: [TastePeerSnapshot]) -> Int {
        fuzzyUniqueProductCount(profile: profile(from: localDrinks) + peers.flatMap(\.profile))
    }

    static func fuzzyUniqueProductCount(profile: [TasteProfileDrink]) -> Int {
        var namesByBrand: [String: [String]] = [:]
        var count = 0

        for drink in profile {
            let brand = normalizedProductText(drink.brand)
            let name = normalizedProductText(drink.name)
            guard !brand.isEmpty || !name.isEmpty else { continue }

            let brandKey = brand.isEmpty ? "*" : brand
            let existingNames = namesByBrand[brandKey, default: []]
            if existingNames.contains(where: { fuzzySameProductName(name, $0) }) {
                continue
            }

            namesByBrand[brandKey, default: []].append(name)
            count += 1
        }

        return count
    }

    private static func calculate(localProfile: [TasteProfileDrink], stats: TasteExchangeStats) -> TasteScoreResult {
        let totalCupCount = effectiveCupCount(profile: localProfile) + stats.peers.map(\.effectiveDrinkCount).reduce(0, +)
        let agreement = agreementScore(localProfile: localProfile, peers: stats.peers)
        let authorityComponent = authorityScore(localProfile: localProfile)
        let totalCupSignal = centeredLogSignal(value: totalCupCount, center: totalCupCenter, spread: totalCupLogSpread)
        let exchangeSignal = centeredLinearSignal(value: stats.successfulExchangeCount, center: exchangeCenter, spread: exchangeSpread)
        let agreementSignal = agreement.hasSample
            ? centeredValueSignal(value: agreement.value, center: agreementCenter, spread: agreementSpread)
            : missingAgreementSignal
        let authoritySignal = centeredValueSignal(value: authorityComponent, center: authorityCenter, spread: authoritySpread)

        let weightedSignal =
            totalCupSignal * 0.34 +
            exchangeSignal * 0.26 +
            agreementSignal * 0.17 +
            authoritySignal * 0.23

        let score = clamp(scoreBaseline + weightedSignal * scoreSpread, lower: 0, upper: 5)
        return TasteScoreResult(
            score: score,
            components: TasteScoreComponents(
                totalCup: componentValue(from: totalCupSignal),
                exchange: componentValue(from: exchangeSignal),
                agreement: agreement.value,
                hasAgreementSample: agreement.hasSample,
                authority: authorityComponent,
                totalCupCount: totalCupCount,
                successfulExchangeCount: stats.successfulExchangeCount
            )
        )
    }

    private static func centeredLogSignal(value: Int, center: Int, spread: Double) -> Double {
        guard center > 0, spread > 0 else { return 0 }
        let signal = (log1p(Double(max(0, value))) - log1p(Double(center))) / spread
        return clamp(signal, lower: -1.2, upper: 2.4)
    }

    private static func centeredLinearSignal(value: Int, center: Int, spread: Double) -> Double {
        guard spread > 0 else { return 0 }
        let signal = (Double(max(0, value)) - Double(center)) / spread
        return clamp(signal, lower: -1.0, upper: 2.4)
    }

    private static func centeredValueSignal(value: Double, center: Double, spread: Double) -> Double {
        guard spread > 0 else { return 0 }
        let signal = (value - center) / spread
        return clamp(signal, lower: -2.4, upper: 2.4)
    }

    private static func normalizedProductText(_ text: String) -> String {
        let skippedCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let scalars = text
            .lowercased()
            .unicodeScalars
            .filter { !skippedCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func fuzzySameProductName(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        guard !first.isEmpty, !second.isEmpty else { return false }

        let firstCharacters = Array(first)
        let secondCharacters = Array(second)
        guard min(firstCharacters.count, secondCharacters.count) >= 3 else { return false }
        let countDifference = abs(firstCharacters.count - secondCharacters.count)
        guard countDifference <= 1 else { return false }

        if firstCharacters.count == secondCharacters.count {
            let mismatches = zip(firstCharacters, secondCharacters).filter { $0 != $1 }.count
            return mismatches <= 1
        }

        let shorter = firstCharacters.count < secondCharacters.count ? firstCharacters : secondCharacters
        let longer = firstCharacters.count < secondCharacters.count ? secondCharacters : firstCharacters
        var shortIndex = 0
        var longIndex = 0
        var skipped = 0

        while shortIndex < shorter.count, longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else {
                skipped += 1
                guard skipped <= 1 else { return false }
                longIndex += 1
            }
        }

        return true
    }

    private static func componentValue(from signal: Double) -> Double {
        clamp(0.5 + signal / 4.8, lower: 0, upper: 1)
    }

    private static func authorityScore(localProfile: [TasteProfileDrink]) -> Double {
        guard !localProfile.isEmpty else { return 0.28 }
        let average = averageRating(profile: localProfile)
        let sampleConfidence = 1 - exp(-Double(effectiveCupCount(profile: localProfile)) / 36)
        let centeredness = exp(-pow((average - authorityRatingCenter) / 1.05, 2))
        let rawAuthority = sampleConfidence * centeredness
        return min(rawAuthority, authorityCap(for: effectiveCupCount(profile: localProfile)))
    }

    private static func authorityCap(for localDrinkCount: Int) -> Double {
        guard localDrinkCount < 50 else { return 1 }
        let progress = clamp(Double(localDrinkCount) / 50, lower: 0, upper: 1)
        return 0.5 + pow(progress, 0.72) * 0.5
    }

    private static func agreementScore(localProfile: [TasteProfileDrink], peers: [TastePeerSnapshot]) -> (value: Double, hasSample: Bool) {
        let peerProfile = peers.flatMap(\.profile)
        guard !localProfile.isEmpty, !peerProfile.isEmpty else { return (0.1, false) }

        let drinkMatch = drinkMatchScore(localProfile: localProfile, peerProfile: peerProfile)
        let brandMatch = brandMatchScore(localProfile: localProfile, peerProfile: peerProfile)

        switch (drinkMatch, brandMatch) {
        case let (drink?, brand?):
            return (drink * 0.7 + brand * 0.3, true)
        case let (drink?, nil):
            return (drink, true)
        case let (nil, brand?):
            return (brand, true)
        case (nil, nil):
            return (0.1, false)
        }
    }

    private static func drinkMatchScore(localProfile: [TasteProfileDrink], peerProfile: [TasteProfileDrink]) -> Double? {
        let peerByDrink = Dictionary(grouping: peerProfile, by: drinkKey)
        let similarities = localProfile.compactMap { local -> Double? in
            guard let peers = peerByDrink[drinkKey(local)] else { return nil }
            let peerAverage = peers.map(\.rating).reduce(0, +) / Double(peers.count)
            return similarity(local.rating, peerAverage)
        }
        guard !similarities.isEmpty else { return nil }
        return similarities.reduce(0, +) / Double(similarities.count)
    }

    private static func brandMatchScore(localProfile: [TasteProfileDrink], peerProfile: [TasteProfileDrink]) -> Double? {
        let localBrands = brandAverages(profile: localProfile)
        let peerBrands = brandAverages(profile: peerProfile)
        let similarities = localBrands.compactMap { brand, localAverage -> Double? in
            guard let peerAverage = peerBrands[brand] else { return nil }
            return similarity(localAverage, peerAverage)
        }
        guard !similarities.isEmpty else { return nil }
        return similarities.reduce(0, +) / Double(similarities.count)
    }

    private static func brandAverages(profile: [TasteProfileDrink]) -> [String: Double] {
        Dictionary(grouping: profile, by: { normalized($0.brand) })
            .compactMapValues { drinks in
                guard !drinks.isEmpty else { return nil }
                return drinks.map(\.rating).reduce(0, +) / Double(drinks.count)
            }
    }

    private static func drinkKey(_ drink: TasteProfileDrink) -> String {
        "\(normalized(drink.brand))|\(normalized(drink.name))"
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "·", with: "")
            .replacingOccurrences(of: "・", with: "")
    }

    private static func similarity(_ first: Double, _ second: Double) -> Double {
        clamp(1 - abs(first - second) / 5, lower: 0, upper: 1)
    }

    private static func effectiveCupContribution(for cupCount: Int) -> Int {
        let actual = max(1, cupCount)
        return max(1, Int((sqrt(Double(8 * actual + 1)) - 1) / 2))
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
