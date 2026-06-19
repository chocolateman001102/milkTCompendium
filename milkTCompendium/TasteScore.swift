import Foundation

struct TasteProfileDrink: Codable, Hashable {
    var brand: String
    var name: String
    var rating: Double
}

struct TastePeerSnapshot: Codable, Identifiable {
    var ownerID: String
    var ownerName: String
    var drinkCount: Int
    var averageRating: Double
    var lastExchangedAt: Date
    var profile: [TasteProfileDrink]

    var id: String {
        ownerID
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
            return "异喝癖"
        case ..<2:
            return "最不会喝的"
        case ..<3:
            return "喝的大众"
        case ..<4:
            return "会喝之人"
        default:
            return "喝者"
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
    }

    func recordSuccessfulExchange(
        ownerID: String,
        ownerName: String,
        drinkCount: Int,
        averageRating: Double,
        profile: [TasteProfileDrink]? = nil
    ) {
        guard !ownerID.isEmpty else { return }

        stats.successfulExchangeCount += 1
        let existingProfile = stats.peers.first { $0.ownerID == ownerID }?.profile ?? []
        let snapshot = TastePeerSnapshot(
            ownerID: ownerID,
            ownerName: ownerName,
            drinkCount: max(0, drinkCount),
            averageRating: averageRating,
            lastExchangedAt: .now,
            profile: profile ?? existingProfile
        )

        stats.peers.removeAll { $0.ownerID == ownerID }
        stats.peers.append(snapshot)
        stats.peers.sort { $0.lastExchangedAt > $1.lastExchangedAt }
        save()
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
    private static let idealLogitMean = 0.925871272
    private static let idealLogitStandardDeviation = 0.564801108
    private static let targetScoreMean = 2.5
    private static let targetScoreStandardDeviation = 1.1
    private static let totalCupCeiling = 2200
    private static let exchangeCeiling = 70

    static func calculate(localDrinks: [Drink], stats: TasteExchangeStats) -> TasteScoreResult {
        let localProfile = localDrinks.map {
            TasteProfileDrink(brand: $0.brand, name: $0.name, rating: $0.rating)
        }
        return calculate(localProfile: localProfile, stats: stats)
    }

    static func profile(from compendium: SharedCompendium) -> [TasteProfileDrink] {
        compendium.drinks.map {
            TasteProfileDrink(brand: $0.brand, name: $0.name, rating: $0.rating)
        }
    }

    static func averageRating(profile: [TasteProfileDrink]) -> Double {
        guard !profile.isEmpty else { return 0 }
        return profile.map(\.rating).reduce(0, +) / Double(profile.count)
    }

    private static func calculate(localProfile: [TasteProfileDrink], stats: TasteExchangeStats) -> TasteScoreResult {
        let totalCupCount = localProfile.count + stats.peers.map(\.drinkCount).reduce(0, +)
        let totalCupComponent = normalizedLog(value: totalCupCount, ceiling: totalCupCeiling)
        let exchangeComponent = normalizedLog(value: stats.successfulExchangeCount, ceiling: exchangeCeiling)
        let agreement = agreementScore(localProfile: localProfile, peers: stats.peers)
        let authorityComponent = authorityScore(localProfile: localProfile)

        let weighted =
            totalCupComponent * 0.38 +
            exchangeComponent * 0.32 +
            agreement.value * 0.15 +
            authorityComponent * 0.15

        let score = calibratedScore(from: weighted)
        return TasteScoreResult(
            score: score,
            components: TasteScoreComponents(
                totalCup: totalCupComponent,
                exchange: exchangeComponent,
                agreement: agreement.value,
                hasAgreementSample: agreement.hasSample,
                authority: authorityComponent,
                totalCupCount: totalCupCount,
                successfulExchangeCount: stats.successfulExchangeCount
            )
        )
    }

    private static func normalizedLog(value: Int, ceiling: Int) -> Double {
        guard ceiling > 0 else { return 0 }
        return clamp(log1p(Double(max(0, value))) / log1p(Double(ceiling)), lower: 0, upper: 1)
    }

    private static func calibratedScore(from rawAbility: Double) -> Double {
        let boundedAbility = clamp(rawAbility, lower: 0.001, upper: 0.999)
        let logitAbility = log(boundedAbility / (1 - boundedAbility))
        let zScore = (logitAbility - idealLogitMean) / idealLogitStandardDeviation
        return clamp(
            targetScoreMean + zScore * targetScoreStandardDeviation,
            lower: 0,
            upper: 5
        )
    }

    private static func authorityScore(localProfile: [TasteProfileDrink]) -> Double {
        guard !localProfile.isEmpty else { return 0.28 }
        let average = averageRating(profile: localProfile)
        let sampleConfidence = 1 - exp(-Double(localProfile.count) / 36)
        let centeredness = exp(-pow((average - 2.5) / 1.18, 2))
        let rawAuthority = sampleConfidence * centeredness
        return min(rawAuthority, authorityCap(for: localProfile.count))
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

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
