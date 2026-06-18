import UIKit

enum ImageStore {
    private static let imageCache = NSCache<NSString, UIImage>()
    private static let thumbnailCache = NSCache<NSString, UIImage>()

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

    static func load(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        let key = name as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) else {
            return nil
        }
        imageCache.setObject(image, forKey: key)
        return image
    }

    static func thumbnail(_ name: String?, maxPixel: CGFloat = 120) -> UIImage? {
        guard let name else { return nil }
        let key = "\(name)-\(Int(maxPixel))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let image = load(name) else { return nil }
        let thumbnail = image.resizedThumbnail(maxPixel: maxPixel)
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    static func thumbnail(at url: URL?, maxPixel: CGFloat = 120) -> UIImage? {
        guard let url else { return nil }
        let key = "file:\(url.path)-\(Int(maxPixel))" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let thumbnail = image.resizedThumbnail(maxPixel: maxPixel)
        thumbnailCache.setObject(thumbnail, forKey: key)
        return thumbnail
    }

    static func data(_ name: String?) -> Data? {
        guard let name else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        imageCache.removeObject(forKey: name as NSString)
        thumbnailCache.removeObject(forKey: "\(name)-120" as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

private extension UIImage {
    func resizedThumbnail(maxPixel: CGFloat) -> UIImage {
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

enum ImageStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "图片保存失败，请换一张照片后重试。"
    }
}
