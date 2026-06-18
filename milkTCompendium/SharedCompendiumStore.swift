import Foundation
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
    var stickerFileName: String?
    var createdAt: Date
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
    var createdAt: Date
    var stickerData: Data?
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
    var createdAt: Date
    var stickerImageName: String?
}

@MainActor
final class SharedCompendiumStore: ObservableObject {
    @Published private(set) var compendiums: [SharedCompendium] = []

    private static let manifestName = "manifest.json"
    nonisolated private static let packageVersion = 1

    nonisolated private static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("SharedCompendiums", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        load()
    }

    func load() {
        let root = Self.rootDirectory
        guard let ownerDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            compendiums = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        compendiums = ownerDirectories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent(Self.manifestName)
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            return try? decoder.decode(SharedCompendium.self, from: data)
        }
        .sorted { $0.exportedAt > $1.exportedAt }
    }

    func importArchiveData(_ data: Data) throws -> SharedCompendium {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(SharedCompendiumArchive.self, from: data)
        guard archive.version == Self.packageVersion else {
            throw SharedCompendiumError.unsupportedVersion
        }

        let ownerDirectory = Self.ownerDirectory(ownerID: archive.ownerID)
        if FileManager.default.fileExists(atPath: ownerDirectory.path) {
            try FileManager.default.removeItem(at: ownerDirectory)
        }
        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)

        let drinks = try archive.drinks.map { archivedDrink in
            var stickerFileName: String?
            if let stickerData = archivedDrink.stickerData {
                let fileName = archivedDrink.id + ".png"
                try stickerData.write(to: ownerDirectory.appendingPathComponent(fileName), options: .atomic)
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
        try manifestData.write(to: ownerDirectory.appendingPathComponent(Self.manifestName), options: .atomic)

        load()
        return compendium
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
                createdAt: drink.createdAt,
                stickerImageName: drink.stickerImageName
            )
        }
    }

    static func exportArchiveData(from snapshots: [DrinkExportSnapshot], ownerName: String) async throws -> Data {
        let ownerID = localOwnerID
        return try await Task.detached(priority: .userInitiated) {
            let archive = SharedCompendiumArchive(
                version: packageVersion,
                ownerID: ownerID,
                ownerName: ownerName,
                exportedAt: .now,
                drinks: snapshots.sorted { $0.createdAt < $1.createdAt }.map { snapshot in
                    SharedDrinkArchive(
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
                        createdAt: snapshot.createdAt,
                        stickerData: ImageStore.data(snapshot.stickerImageName)
                    )
                }
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(archive)
        }.value
    }

    nonisolated static func stickerURL(ownerID: String, fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return ownerDirectory(ownerID: ownerID).appendingPathComponent(fileName)
    }

    nonisolated private static func ownerDirectory(ownerID: String) -> URL {
        rootDirectory.appendingPathComponent(ownerID, isDirectory: true)
    }

    private static var localOwnerID: String {
        let key = "SharedCompendiumLocalOwnerID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }
}

enum SharedCompendiumError: LocalizedError {
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "这个图鉴包版本暂时无法导入。"
        }
    }
}
