import ImageIO
import UIKit

enum ImageStore {
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("DrinkImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func saveOriginal(_ image: UIImage) throws -> String {
        let name = UUID().uuidString + ".jpg"
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw ImageStoreError.encodingFailed
        }
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func saveSticker(_ image: UIImage) throws -> String {
        let name = UUID().uuidString + ".png"
        guard let data = image.pngData() else {
            throw ImageStoreError.encodingFailed
        }
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func saveStickerData(_ data: Data, preferredExtension: String) throws -> String {
        let cleanExtension = preferredExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let name = UUID().uuidString + "." + (cleanExtension.isEmpty ? "png" : cleanExtension)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    static func load(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        let key = name as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else {
            return nil
        }
        imageCache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    static func thumbnail(_ name: String?, maxPixel: CGFloat = 120) -> UIImage? {
        guard let name else { return nil }
        let key = "\(name)-\(Int(maxPixel))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let thumbnail = downsampledImage(at: directory.appendingPathComponent(name), maxPixel: maxPixel) else {
            return nil
        }
        thumbnailCache.setObject(thumbnail, forKey: key, cost: cost(of: thumbnail))
        return thumbnail
    }

    static func thumbnail(at url: URL?, maxPixel: CGFloat = 120) -> UIImage? {
        guard let url else { return nil }
        let key = "file:\(url.path)-\(Int(maxPixel))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let thumbnail = downsampledImage(at: url, maxPixel: maxPixel) else { return nil }
        thumbnailCache.setObject(thumbnail, forKey: key, cost: cost(of: thumbnail))
        return thumbnail
    }

    static func data(_ name: String?) -> Data? {
        guard let name else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        imageCache.removeObject(forKey: name as NSString)
        thumbnailCache.removeAllObjects()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
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

    private static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

enum ImageStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "图片保存失败，请换一张照片后重试。"
    }
}
