import Foundation
import SwiftData

@MainActor
final class DataMigrationManager {

    // MARK: - Export

    static func exportAllData(drinks: [Drink]) async throws -> URL {
        let snapshots = SharedCompendiumStore.exportSnapshots(from: drinks)
        let data = try await SharedCompendiumStore.exportArchiveData(
            from: snapshots,
            ownerName: NearbyDisplayNameStore.displayName
        )

        let timestamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let outputFileName = "奶茶图鉴备份_\(timestamp).mtcpack"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputFileName)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    // MARK: - Import

    static func importBackup(
        from packageURL: URL,
        existingDrinks: [Drink],
        modelContext: ModelContext
    ) async throws -> LocalArchiveImportResult {
        let data = try Data(contentsOf: packageURL)
        let archive = try SharedCompendiumStore.decodeArchiveData(data)
        return try LocalArchiveImporter.importArchive(
            archive,
            existingDrinks: existingDrinks,
            into: modelContext
        )
    }
}
