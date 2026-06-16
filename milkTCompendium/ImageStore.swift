import UIKit

enum ImageStore {
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
        return UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }
}

enum ImageStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "图片保存失败，请换一张照片后重试。"
    }
}
