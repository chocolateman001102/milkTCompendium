import Foundation
import ImageIO
import UIKit

struct PendingDrinkDraft: Identifiable, Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var originalImageName: String
    var stickerImageName: String
    var brand: String
    var name: String
    var sweetness: String
    var iceLevel: String
    var rating: Double
    var consumedAt: Date
    var note: String
    var isLimited: Bool
    var cupCount: Int
}

struct PendingDrinkDraftInput {
    var existingDraft: PendingDrinkDraft?
    var originalImage: UIImage
    var stickerImage: UIImage
    var brand: String
    var name: String
    var sweetness: String
    var iceLevel: String
    var rating: Double
    var consumedAt: Date
    var note: String
    var isLimited: Bool
    var cupCount: Int
}

@MainActor
final class PendingDrinkDraftStore: ObservableObject {
    @Published private(set) var drafts: [PendingDrinkDraft] = []

    private let fileManager: FileManager
    private let imageCache = NSCache<NSString, UIImage>()
    private let thumbnailCache = NSCache<NSString, UIImage>()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        imageCache.countLimit = 40
        imageCache.totalCostLimit = 80 * 1024 * 1024
        thumbnailCache.countLimit = 80
        thumbnailCache.totalCostLimit = 30 * 1024 * 1024
        loadDrafts()
    }

    @discardableResult
    func saveDraft(input: PendingDrinkDraftInput) throws -> PendingDrinkDraft {
        try ensureDirectoryExists()

        let originalName = UUID().uuidString + ".jpg"
        let stickerName = UUID().uuidString + ".png"
        let originalURL = directory.appendingPathComponent(originalName)
        let stickerURL = directory.appendingPathComponent(stickerName)

        do {
            guard let originalData = input.originalImage.jpegData(compressionQuality: 0.92),
                  let stickerData = input.stickerImage.pngData() else {
                throw PendingDrinkDraftError.encodingFailed
            }

            try originalData.write(to: originalURL, options: .atomic)
            try stickerData.write(to: stickerURL, options: .atomic)

            let draft = PendingDrinkDraft(
                id: input.existingDraft?.id ?? UUID(),
                createdAt: input.existingDraft?.createdAt ?? .now,
                originalImageName: originalName,
                stickerImageName: stickerName,
                brand: input.brand.trimmingCharacters(in: .whitespacesAndNewlines),
                name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
                sweetness: input.sweetness,
                iceLevel: input.iceLevel,
                rating: input.rating,
                consumedAt: input.consumedAt,
                note: input.note.trimmingCharacters(in: .whitespacesAndNewlines),
                isLimited: input.isLimited,
                cupCount: max(1, input.cupCount)
            )

            let nextDrafts = draftsByUpserting(draft, into: drafts)
            try saveManifest(nextDrafts)
            drafts = nextDrafts

            if let replacedDraft = input.existingDraft {
                deleteImageFiles(for: replacedDraft)
            }
            imageCache.setObject(input.originalImage, forKey: originalName as NSString, cost: imageCost(input.originalImage))
            imageCache.setObject(input.stickerImage, forKey: stickerName as NSString, cost: imageCost(input.stickerImage))
            thumbnailCache.removeAllObjects()

            return draft
        } catch {
            try? fileManager.removeItem(at: originalURL)
            try? fileManager.removeItem(at: stickerURL)
            throw error
        }
    }

    func delete(_ draft: PendingDrinkDraft) {
        let nextDrafts = drafts.filter { $0.id != draft.id }
        do {
            try saveManifest(nextDrafts)
            drafts = nextDrafts
        } catch {
            return
        }
        deleteImageFiles(for: draft)
        thumbnailCache.removeAllObjects()
    }

    func originalImage(for draft: PendingDrinkDraft) -> UIImage? {
        loadImage(named: draft.originalImageName)
    }

    func stickerImage(for draft: PendingDrinkDraft) -> UIImage? {
        loadImage(named: draft.stickerImageName)
    }

    func thumbnail(for draft: PendingDrinkDraft) -> UIImage? {
        let key = "\(draft.originalImageName)-thumb" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let image = downsampledImage(at: directory.appendingPathComponent(draft.originalImageName), maxPixel: 180) else {
            return stickerImage(for: draft)
        }
        thumbnailCache.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    private var directory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingDrinkDrafts", isDirectory: true)
    }

    private var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func loadDrafts() {
        do {
            try ensureDirectoryExists()
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                drafts = []
                return
            }
            let data = try Data(contentsOf: manifestURL)
            let decoded = try JSONDecoder.pendingDraftDecoder.decode([PendingDrinkDraft].self, from: data)
            drafts = decoded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            drafts = []
        }
    }

    private func saveManifest(_ draftsToSave: [PendingDrinkDraft]) throws {
        try ensureDirectoryExists()
        let data = try JSONEncoder.pendingDraftEncoder.encode(draftsToSave.sorted { $0.createdAt > $1.createdAt })
        try data.write(to: manifestURL, options: .atomic)
    }

    private func draftsByUpserting(_ draft: PendingDrinkDraft, into existingDrafts: [PendingDrinkDraft]) -> [PendingDrinkDraft] {
        var nextDrafts = existingDrafts.filter { $0.id != draft.id }
        nextDrafts.append(draft)
        nextDrafts.sort { $0.createdAt > $1.createdAt }
        return nextDrafts
    }

    private func loadImage(named name: String) -> UIImage? {
        let key = name as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else {
            return nil
        }
        imageCache.setObject(image, forKey: key, cost: imageCost(image))
        return image
    }

    private func deleteImageFiles(for draft: PendingDrinkDraft) {
        [draft.originalImageName, draft.stickerImageName].forEach { name in
            imageCache.removeObject(forKey: name as NSString)
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func imageCost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

enum PendingDrinkDraftError: LocalizedError {
    case encodingFailed
    case missingImage

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "待记录照片保存失败，请换一张照片后重试。"
        case .missingImage:
            return "找不到这张待记录照片，请重新拍摄。"
        }
    }
}

private extension JSONEncoder {
    static var pendingDraftEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var pendingDraftDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
