import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

struct SharedCompendium: Codable, Identifiable {
    let ownerID: String
    var ownerName: String
    var exportedAt: Date
    var drinks: [SharedDrink]

    var id: String {
        ownerID
    }
}

struct SharedDrink: Codable, Identifiable {
    let id: String
    var brand: String
    var name: String
    var sweetness: String
    var iceLevel: String
    var rating: Double
    var consumedAt: Date
    var location: String
    var note: String
    var isLimited: Bool
    var cupCount: Int
    var stickerFileName: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case brand
        case name
        case sweetness
        case iceLevel
        case rating
        case consumedAt
        case location
        case note
        case isLimited
        case cupCount
        case stickerFileName
        case createdAt
    }

    init(
        id: String,
        brand: String,
        name: String,
        sweetness: String,
        iceLevel: String,
        rating: Double,
        consumedAt: Date,
        location: String,
        note: String,
        isLimited: Bool,
        cupCount: Int,
        stickerFileName: String?,
        createdAt: Date
    ) {
        self.id = id
        self.brand = brand
        self.name = name
        self.sweetness = sweetness
        self.iceLevel = iceLevel
        self.rating = rating
        self.consumedAt = consumedAt
        self.location = location
        self.note = note
        self.isLimited = isLimited
        self.cupCount = max(1, cupCount)
        self.stickerFileName = stickerFileName
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        brand = try container.decode(String.self, forKey: .brand)
        name = try container.decode(String.self, forKey: .name)
        sweetness = try container.decode(String.self, forKey: .sweetness)
        iceLevel = try container.decode(String.self, forKey: .iceLevel)
        rating = try container.decode(Double.self, forKey: .rating)
        consumedAt = try container.decode(Date.self, forKey: .consumedAt)
        location = try container.decode(String.self, forKey: .location)
        note = try container.decode(String.self, forKey: .note)
        isLimited = try container.decode(Bool.self, forKey: .isLimited)
        cupCount = max(1, try container.decodeIfPresent(Int.self, forKey: .cupCount) ?? 1)
        stickerFileName = try container.decodeIfPresent(String.self, forKey: .stickerFileName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct SharedCompendiumArchive: Codable {
    var version: Int
    var ownerID: String
    var ownerName: String
    var exportedAt: Date
    var drinks: [SharedDrinkArchive]
}

struct SharedDrinkArchive: Codable {
    var id: String
    var brand: String
    var name: String
    var sweetness: String
    var iceLevel: String
    var rating: Double
    var consumedAt: Date
    var location: String
    var note: String
    var isLimited: Bool
    var cupCount: Int
    var createdAt: Date
    var stickerData: Data?
    var stickerImageFormat: String?
    var stickerPixelWidth: Int?
    var stickerPixelHeight: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case brand
        case name
        case sweetness
        case iceLevel
        case rating
        case consumedAt
        case location
        case note
        case isLimited
        case cupCount
        case createdAt
        case stickerData
        case stickerImageFormat
        case stickerPixelWidth
        case stickerPixelHeight
    }

    init(
        id: String,
        brand: String,
        name: String,
        sweetness: String,
        iceLevel: String,
        rating: Double,
        consumedAt: Date,
        location: String,
        note: String,
        isLimited: Bool,
        cupCount: Int,
        createdAt: Date,
        stickerData: Data?,
        stickerImageFormat: String?,
        stickerPixelWidth: Int?,
        stickerPixelHeight: Int?
    ) {
        self.id = id
        self.brand = brand
        self.name = name
        self.sweetness = sweetness
        self.iceLevel = iceLevel
        self.rating = rating
        self.consumedAt = consumedAt
        self.location = location
        self.note = note
        self.isLimited = isLimited
        self.cupCount = max(1, cupCount)
        self.createdAt = createdAt
        self.stickerData = stickerData
        self.stickerImageFormat = stickerImageFormat
        self.stickerPixelWidth = stickerPixelWidth
        self.stickerPixelHeight = stickerPixelHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        brand = try container.decode(String.self, forKey: .brand)
        name = try container.decode(String.self, forKey: .name)
        sweetness = try container.decode(String.self, forKey: .sweetness)
        iceLevel = try container.decode(String.self, forKey: .iceLevel)
        rating = try container.decode(Double.self, forKey: .rating)
        consumedAt = try container.decode(Date.self, forKey: .consumedAt)
        location = try container.decode(String.self, forKey: .location)
        note = try container.decode(String.self, forKey: .note)
        isLimited = try container.decode(Bool.self, forKey: .isLimited)
        cupCount = max(1, try container.decodeIfPresent(Int.self, forKey: .cupCount) ?? 1)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        stickerData = try container.decodeIfPresent(Data.self, forKey: .stickerData)
        stickerImageFormat = try container.decodeIfPresent(String.self, forKey: .stickerImageFormat)
        stickerPixelWidth = try container.decodeIfPresent(Int.self, forKey: .stickerPixelWidth)
        stickerPixelHeight = try container.decodeIfPresent(Int.self, forKey: .stickerPixelHeight)
    }
}

struct DrinkExportSnapshot: Sendable {
    var brand: String
    var name: String
    var sweetness: String
    var iceLevel: String
    var rating: Double
    var consumedAt: Date
    var location: String
    var note: String
    var isLimited: Bool
    var cupCount: Int
    var createdAt: Date
    var stickerImageName: String?
}

@MainActor
final class SharedCompendiumStore: ObservableObject {
    @Published private(set) var compendiums: [SharedCompendium] = []

    nonisolated private static let manifestName = "manifest.json"
    nonisolated static let packageVersion = 3
    nonisolated private static let minimumSupportedPackageVersion = 1
    nonisolated private static let maxArchiveByteCount = 50 * 1024 * 1024
    nonisolated private static let maxDrinkCount = 2_000
    nonisolated private static let maxStickerByteCount = 2 * 1024 * 1024
    nonisolated private static let maxTotalStickerByteCount = 80 * 1024 * 1024
    nonisolated private static let maxStickerPixelDimension = 2_000

    nonisolated private struct StoredCompendium {
        let directory: URL
        let compendium: SharedCompendium
    }

    nonisolated private static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SharedCompendiums", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        Task { await reload() }
    }

    func reload() async {
        let compendiums = await Self.loadCompendiums()
        self.compendiums = compendiums
    }

    func load() {
        compendiums = Self.loadCompendiumsSync()
    }

    nonisolated private static func loadCompendiums() async -> [SharedCompendium] {
        await Task.detached(priority: .utility) {
            loadCompendiumsSync()
        }.value
    }

    nonisolated private static func loadCompendiumsSync() -> [SharedCompendium] {
        let root = rootDirectory
        guard let ownerDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let storedCompendiums = ownerDirectories.compactMap { directory -> StoredCompendium? in
            let manifestURL = directory.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            guard let compendium = try? decoder.decode(SharedCompendium.self, from: data) else { return nil }
            return StoredCompendium(directory: directory, compendium: compendium)
        }

        return deduplicatedStoredCompendiums(storedCompendiums)
            .map(\.compendium)
        .sorted { $0.exportedAt > $1.exportedAt }
    }

    nonisolated private static func deduplicatedStoredCompendiums(_ storedCompendiums: [StoredCompendium]) -> [StoredCompendium] {
        var kept: [StoredCompendium] = []
        for candidate in storedCompendiums.sorted(by: { $0.compendium.exportedAt > $1.compendium.exportedAt }) {
            let candidateName = normalizedOwnerName(candidate.compendium.ownerName)
            let isDuplicate = kept.contains { existing in
                existing.compendium.ownerID == candidate.compendium.ownerID
                    || (
                        !candidateName.isEmpty
                            && normalizedOwnerName(existing.compendium.ownerName) == candidateName
                            && likelySameCompendium(existing.compendium.drinks, candidate.compendium.drinks)
                    )
            }

            if isDuplicate {
                try? FileManager.default.removeItem(at: candidate.directory)
            } else {
                kept.append(candidate)
            }
        }
        return kept
    }

    func importArchive(at url: URL) async throws -> SharedCompendium {
        try Self.validateArchiveFileSize(at: url)
        let compendium = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try Self.importArchiveDataSync(data)
        }.value
        await reload()
        return compendium
    }

    func importArchiveData(_ data: Data) throws -> SharedCompendium {
        let compendium = try Self.importArchiveDataSync(data)
        load()
        return compendium
    }

    nonisolated static func decodeArchiveData(_ data: Data) throws -> SharedCompendiumArchive {
        guard data.count <= maxArchiveByteCount else {
            throw SharedCompendiumError.archiveTooLarge
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(SharedCompendiumArchive.self, from: data)
        try validate(archive: archive)
        return archive
    }

    nonisolated private static func importArchiveDataSync(_ data: Data) throws -> SharedCompendium {
        let archive = try decodeArchiveData(data)

        let ownerDirectory = ownerDirectory(ownerID: archive.ownerID)
        let temporaryDirectory = rootDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        do {
            let drinks = try archive.drinks.map { archivedDrink in
                var stickerFileName: String?
                if let stickerData = archivedDrink.stickerData {
                    let fileName = archivedDrink.id + "." + fileExtension(for: archivedDrink.stickerImageFormat)
                    try stickerData.write(to: temporaryDirectory.appendingPathComponent(fileName), options: .atomic)
                    stickerFileName = fileName
                }

                return SharedDrink(
                    id: archivedDrink.id,
                    brand: archivedDrink.brand,
                    name: archivedDrink.name,
                    sweetness: archivedDrink.sweetness,
                    iceLevel: archivedDrink.iceLevel,
                    rating: archivedDrink.rating,
                    consumedAt: archivedDrink.consumedAt,
                    location: archivedDrink.location,
                    note: archivedDrink.note,
                    isLimited: archivedDrink.isLimited,
                    cupCount: max(1, archivedDrink.cupCount),
                    stickerFileName: stickerFileName,
                    createdAt: archivedDrink.createdAt
                )
            }

            let compendium = SharedCompendium(
                ownerID: archive.ownerID,
                ownerName: archive.ownerName,
                exportedAt: archive.exportedAt,
                drinks: drinks
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(compendium)
            try manifestData.write(to: temporaryDirectory.appendingPathComponent(manifestName), options: .atomic)

            for duplicateDirectory in duplicateOwnerDirectories(for: archive, replacing: ownerDirectory) {
                try? FileManager.default.removeItem(at: duplicateDirectory)
            }
            if FileManager.default.fileExists(atPath: ownerDirectory.path) {
                try FileManager.default.removeItem(at: ownerDirectory)
            }
            try FileManager.default.moveItem(at: temporaryDirectory, to: ownerDirectory)
            return compendium
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    nonisolated private static func duplicateOwnerDirectories(
        for archive: SharedCompendiumArchive,
        replacing ownerDirectory: URL
    ) -> [URL] {
        let root = rootDirectory
        guard let ownerDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incomingName = normalizedOwnerName(archive.ownerName)
        guard !incomingName.isEmpty else { return [] }

        return ownerDirectories.compactMap { directory in
            guard directory.path != ownerDirectory.path else { return nil }
            let manifestURL = directory.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let existing = try? decoder.decode(SharedCompendium.self, from: data),
                  existing.ownerID != archive.ownerID,
                  normalizedOwnerName(existing.ownerName) == incomingName,
                  likelySameCompendium(existing.drinks, archive.drinks) else {
                return nil
            }
            return directory
        }
    }

    nonisolated private static func normalizedOwnerName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    nonisolated private static func likelySameCompendium(
        _ existingDrinks: [SharedDrink],
        _ incomingDrinks: [SharedDrinkArchive]
    ) -> Bool {
        likelySameProductKeySet(
            existingDrinks.compactMap { drink in
                let key = normalizedProductKey(brand: drink.brand, name: drink.name)
                return key.isEmpty ? nil : key
            },
            incomingDrinks.compactMap { drink in
                let key = normalizedProductKey(brand: drink.brand, name: drink.name)
                return key.isEmpty ? nil : key
            }
        )
    }

    nonisolated private static func likelySameCompendium(
        _ existingDrinks: [SharedDrink],
        _ incomingDrinks: [SharedDrink]
    ) -> Bool {
        likelySameProductKeySet(
            existingDrinks.compactMap { drink in
                let key = normalizedProductKey(brand: drink.brand, name: drink.name)
                return key.isEmpty ? nil : key
            },
            incomingDrinks.compactMap { drink in
                let key = normalizedProductKey(brand: drink.brand, name: drink.name)
                return key.isEmpty ? nil : key
            }
        )
    }

    nonisolated private static func likelySameProductKeySet(_ firstKeys: [String], _ secondKeys: [String]) -> Bool {
        let firstKeys = Set(firstKeys)
        let secondKeys = Set(secondKeys)
        guard !firstKeys.isEmpty, !secondKeys.isEmpty else { return false }

        let overlap = firstKeys.intersection(secondKeys).count
        let smallerCount = min(firstKeys.count, secondKeys.count)
        return Double(overlap) / Double(smallerCount) >= 0.45
    }

    nonisolated private static func normalizedProductKey(brand: String, name: String) -> String {
        let normalizedBrand = normalizedProductText(brand)
        let normalizedName = normalizedProductText(name)
        guard !normalizedBrand.isEmpty || !normalizedName.isEmpty else { return "" }
        return "\(normalizedBrand)#\(normalizedName)"
    }

    nonisolated private static func normalizedProductText(_ text: String) -> String {
        let skippedCharacters = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let scalars = text
            .lowercased()
            .unicodeScalars
            .filter { !skippedCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func exportSnapshots(from drinks: [Drink]) -> [DrinkExportSnapshot] {
        drinks.map { drink in
            DrinkExportSnapshot(
                brand: drink.brand,
                name: drink.name,
                sweetness: drink.sweetness,
                iceLevel: drink.iceLevel,
                rating: drink.rating,
                consumedAt: drink.consumedAt,
                location: drink.location,
                note: drink.note,
                isLimited: drink.isLimited,
                cupCount: max(1, drink.cupCount),
                createdAt: drink.createdAt,
                stickerImageName: drink.stickerImageName
            )
        }
    }

    static func exportArchiveData(from snapshots: [DrinkExportSnapshot], ownerName: String) async throws -> Data {
        guard snapshots.count <= maxDrinkCount else {
            throw SharedCompendiumError.tooManyDrinks
        }
        let ownerID = localOwnerID
        return try await Task.detached(priority: .userInitiated) {
            let archive = SharedCompendiumArchive(
                version: packageVersion,
                ownerID: ownerID,
                ownerName: ownerName,
                exportedAt: .now,
                drinks: snapshots.sorted { $0.createdAt < $1.createdAt }.map { snapshot in
                    let sticker = Self.exportStickerData(snapshot.stickerImageName)
                    return SharedDrinkArchive(
                        id: UUID().uuidString,
                        brand: snapshot.brand,
                        name: snapshot.name,
                        sweetness: snapshot.sweetness,
                        iceLevel: snapshot.iceLevel,
                        rating: snapshot.rating,
                        consumedAt: snapshot.consumedAt,
                        location: snapshot.location,
                        note: snapshot.note,
                        isLimited: snapshot.isLimited,
                        cupCount: max(1, snapshot.cupCount),
                        createdAt: snapshot.createdAt,
                        stickerData: sticker?.data,
                        stickerImageFormat: sticker?.format,
                        stickerPixelWidth: sticker?.width,
                        stickerPixelHeight: sticker?.height
                    )
                }
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(archive)
            guard data.count <= maxArchiveByteCount else {
                throw SharedCompendiumError.archiveTooLarge
            }
            return data
        }.value
    }

    nonisolated static func stickerURL(ownerID: String, fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return ownerDirectory(ownerID: ownerID).appendingPathComponent(fileName)
    }

    nonisolated private static func ownerDirectory(ownerID: String) -> URL {
        rootDirectory.appendingPathComponent(ownerID, isDirectory: true)
    }

    nonisolated private static func exportStickerData(_ name: String?) -> (data: Data, format: String, width: Int, height: Int)? {
        guard let image = ImageStore.load(name),
              let resized = image.resizedForSharing(maxPixel: 720).cgImage else {
            return nil
        }

        if let webP = encode(cgImage: resized, type: "org.webmproject.webp", quality: 0.88) {
            return (webP, "webp", resized.width, resized.height)
        }
        if let heic = encode(cgImage: resized, type: UTType.heic.identifier, quality: 0.88) {
            return (heic, "heic", resized.width, resized.height)
        }
        if let png = encode(cgImage: resized, type: UTType.png.identifier, quality: 1) {
            return (png, "png", resized.width, resized.height)
        }
        return nil
    }

    nonisolated private static func encode(cgImage: CGImage, type: String, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    nonisolated private static func validateArchiveFileSize(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maxArchiveByteCount {
            throw SharedCompendiumError.archiveTooLarge
        }
    }

    nonisolated private static func validate(archive: SharedCompendiumArchive) throws {
        guard archive.version >= minimumSupportedPackageVersion,
              archive.version <= packageVersion else {
            throw SharedCompendiumError.unsupportedVersion
        }
        guard archive.drinks.count <= maxDrinkCount else {
            throw SharedCompendiumError.tooManyDrinks
        }

        var seenDrinkIDs = Set<String>()
        var totalStickerBytes = 0
        for drink in archive.drinks {
            guard seenDrinkIDs.insert(drink.id).inserted else {
                throw SharedCompendiumError.invalidDrinkMetadata
            }
            if let stickerData = drink.stickerData {
                guard stickerData.count <= maxStickerByteCount else {
                    throw SharedCompendiumError.stickerTooLarge
                }
                totalStickerBytes += stickerData.count
                guard totalStickerBytes <= maxTotalStickerByteCount else {
                    throw SharedCompendiumError.stickerTooLarge
                }
            }
            if let width = drink.stickerPixelWidth,
               width > maxStickerPixelDimension {
                throw SharedCompendiumError.invalidStickerMetadata
            }
            if let height = drink.stickerPixelHeight,
               height > maxStickerPixelDimension {
                throw SharedCompendiumError.invalidStickerMetadata
            }
        }
    }

    nonisolated private static func fileExtension(for format: String?) -> String {
        switch format {
        case "webp":
            return "webp"
        case "heic":
            return "heic"
        default:
            return "png"
        }
    }

    nonisolated static func stickerFileExtension(for format: String?) -> String {
        fileExtension(for: format)
    }

    static var localOwnerID: String {
        let key = "SharedCompendiumLocalOwnerID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        if let legacyPeerID = UserDefaults.standard.string(forKey: "NearbyTransferStablePeerID") {
            UserDefaults.standard.set(legacyPeerID, forKey: key)
            return legacyPeerID
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
}

private extension UIImage {
    func resizedForSharing(maxPixel: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxPixel else { return self }

        let ratio = maxPixel / longestSide
        let targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

enum SharedCompendiumError: LocalizedError {
    case unsupportedVersion
    case archiveTooLarge
    case tooManyDrinks
    case stickerTooLarge
    case invalidStickerMetadata
    case invalidDrinkMetadata

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "这个图鉴包版本暂时无法导入。"
        case .archiveTooLarge:
            "这个图鉴包太大，无法导入或分享。"
        case .tooManyDrinks:
            "这个图鉴包含的饮品太多，无法导入或分享。"
        case .stickerTooLarge:
            "这个图鉴包里的贴图太大，无法导入或分享。"
        case .invalidStickerMetadata:
            "这个图鉴包里的贴图信息异常，无法导入。"
        case .invalidDrinkMetadata:
            "这个图鉴包里的饮品信息异常，无法导入。"
        }
    }
}
