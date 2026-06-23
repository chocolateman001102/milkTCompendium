import Foundation
import SwiftData
import UIKit
import UniformTypeIdentifiers

@MainActor
final class DataMigrationManager {

    struct ExportPackage: Codable {
        let drinks: [ExportedDrink]
        let exportDate: Date
        let appVersion: String
    }

    struct ExportedDrink: Codable {
        let brand: String
        let name: String
        let sweetness: String
        let iceLevel: String
        let rating: Double
        let consumedAt: Date
        let location: String
        let note: String
        let isLimited: Bool
        let cupCount: Int
        let originalImageName: String?
        let stickerImageName: String?
        let createdAt: Date
    }

    // MARK: - Export

    static func exportAllData(drinks: [Drink]) async throws -> URL {
        // 1. 准备导出数据
        let exportedDrinks = drinks.map { drink in
            ExportedDrink(
                brand: drink.brand,
                name: drink.name,
                sweetness: drink.sweetness,
                iceLevel: drink.iceLevel,
                rating: drink.rating,
                consumedAt: drink.consumedAt,
                location: drink.location,
                note: drink.note,
                isLimited: drink.isLimited,
                cupCount: drink.cupCount,
                originalImageName: drink.originalImageName,
                stickerImageName: drink.stickerImageName,
                createdAt: drink.createdAt
            )
        }

        let package = ExportPackage(
            drinks: exportedDrinks,
            exportDate: Date(),
            appVersion: "1.0"
        )

        // 2. 创建临时目录
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 3. 保存 JSON 数据
        let jsonData = try JSONEncoder().encode(package)
        let jsonURL = tempDir.appendingPathComponent("data.json")
        try jsonData.write(to: jsonURL)

        // 4. 复制所有图片
        let imagesDir = tempDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let imageNames = Set(drinks.compactMap { $0.originalImageName } + drinks.compactMap { $0.stickerImageName })
        let sourceImageDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DrinkImages")

        for imageName in imageNames {
            let sourceURL = sourceImageDir.appendingPathComponent(imageName)
            let destURL = imagesDir.appendingPathComponent(imageName)

            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
        }

        // 5. 打包成 zip
        let timestamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let outputFileName = "奶茶图鉴备份_\(timestamp).zip"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputFileName)

        try await zipDirectory(at: tempDir, to: outputURL)

        // 6. 清理临时目录
        try? FileManager.default.removeItem(at: tempDir)

        return outputURL
    }

    // MARK: - Import

    static func importBackup(from zipURL: URL, modelContext: ModelContext) async throws -> Int {
        // 1. 解压到临时目录
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await unzipFile(at: zipURL, to: tempDir)

        // 2. 读取 JSON 数据
        let jsonURL = tempDir.appendingPathComponent("data.json")
        let jsonData = try Data(contentsOf: jsonURL)
        let package = try JSONDecoder().decode(ExportPackage.self, from: jsonData)

        // 3. 复制图片到目标目录
        let imagesDir = tempDir.appendingPathComponent("images")
        let destImageDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DrinkImages")
        try? FileManager.default.createDirectory(at: destImageDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: imagesDir.path) {
            let imageFiles = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path)
            for imageName in imageFiles {
                let sourceURL = imagesDir.appendingPathComponent(imageName)
                let destURL = destImageDir.appendingPathComponent(imageName)

                // 如果文件已存在就跳过
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.copyItem(at: sourceURL, to: destURL)
                }
            }
        }

        // 4. 导入饮品数据
        var importCount = 0
        for exported in package.drinks {
            let drink = Drink(
                brand: exported.brand,
                name: exported.name,
                sweetness: exported.sweetness,
                iceLevel: exported.iceLevel,
                rating: exported.rating,
                consumedAt: exported.consumedAt,
                location: exported.location,
                note: exported.note,
                isLimited: exported.isLimited,
                cupCount: exported.cupCount,
                originalImageName: exported.originalImageName,
                stickerImageName: exported.stickerImageName
            )
            drink.createdAt = exported.createdAt

            modelContext.insert(drink)
            importCount += 1
        }

        try modelContext.save()

        return importCount
    }

    // MARK: - Zip Utilities

    private static func zipDirectory(at sourceURL: URL, to destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let coordinator = NSFileCoordinator()
                    var error: NSError?

                    coordinator.coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &error) { zipURL in
                        do {
                            if FileManager.default.fileExists(atPath: destinationURL.path) {
                                try FileManager.default.removeItem(at: destinationURL)
                            }
                            try FileManager.default.copyItem(at: zipURL, to: destinationURL)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }

                    if let error = error {
                        continuation.resume(throwing: error)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func unzipFile(at sourceURL: URL, to destinationURL: URL) async throws {
        // 使用 Coordinator 的 forUploading 选项会自动解压 zip 文件
        // 我们直接读取已解压的内容
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var unzipError: Error?

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { url in
                do {
                    // 创建目标目录
                    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

                    // 使用 Archive 解压 (需要导入 ZIPFoundation 或使用系统 API)
                    // iOS 上使用 NSFileCoordinator 配合 .forUploading 来处理 zip
                    let tempCoordinator = NSFileCoordinator()
                    var tempError: NSError?

                    tempCoordinator.coordinate(readingItemAt: sourceURL, options: .forUploading, error: &tempError) { zipURL in
                        // zipURL 现在指向解压后的目录
                        do {
                            let contents = try FileManager.default.contentsOfDirectory(
                                at: zipURL,
                                includingPropertiesForKeys: nil
                            )

                            for itemURL in contents {
                                let destItemURL = destinationURL.appendingPathComponent(itemURL.lastPathComponent)
                                if FileManager.default.fileExists(atPath: destItemURL.path) {
                                    try FileManager.default.removeItem(at: destItemURL)
                                }
                                try FileManager.default.copyItem(at: itemURL, to: destItemURL)
                            }

                            continuation.resume()
                        } catch {
                            unzipError = error
                            continuation.resume(throwing: error)
                        }
                    }

                    if let tempError = tempError {
                        throw tempError
                    }
                } catch {
                    unzipError = error
                    continuation.resume(throwing: error)
                }
            }

            if let coordinatorError = coordinatorError {
                continuation.resume(throwing: coordinatorError)
            }
        }
    }
}
