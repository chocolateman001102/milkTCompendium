import CoreImage
import ImageIO
import UIKit
import Vision

struct ProcessedDrinkImage {
    let sticker: UIImage
}

enum DrinkImageProcessor {
    static func process(_ image: UIImage) async throws -> ProcessedDrinkImage {
        let normalizedImage = image
            .resizedAndNormalizedToFit(maxDimension: 2_400)
        guard let cgImage = normalizedImage.cgImage else {
            throw ProcessingError.invalidImage
        }

        let sticker = try await createSticker(from: cgImage)
        return ProcessedDrinkImage(sticker: sticker)
    }

    private static func createSticker(from cgImage: CGImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])

                guard let observation = request.results?.first,
                      !observation.allInstances.isEmpty else {
                    throw ProcessingError.noForeground
                }

                let buffer = try observation.generateMaskedImage(
                    ofInstances: observation.allInstances,
                    from: handler,
                    croppedToInstancesExtent: true
                )
                let ciImage = CIImage(cvPixelBuffer: buffer)
                let context = CIContext()
                guard let result = context.createCGImage(ciImage, from: ciImage.extent) else {
                    throw ProcessingError.renderFailed
                }
                let cutout = UIImage(cgImage: result)
                return cutout
                    .bestUprightDrinkOrientation()
                    .resizedAndNormalizedToFit(maxDimension: 1_800)
                    .addingStickerOutline()
            }
        }.value
    }

}

private extension UIImage {
    func resizedAndNormalizedToFit(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension || imageOrientation != .up else { return self }

        let ratio = min(1, maxDimension / longestSide)
        let targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func bestUprightDrinkOrientation() -> UIImage {
        let candidates = (0...3).map { turns in
            let image = rotatedByQuarterTurns(turns)
            return (turns: turns, image: image, metrics: image.uprightDrinkMetrics)
        }
        let original = candidates[0]
        let sideways = [candidates[1], candidates[3]]
            .max { $0.metrics.score < $1.metrics.score }
        let originalLooksSideways = original.image.size.width > original.image.size.height * 1.12

        if originalLooksSideways,
           let sideways,
           sideways.metrics.score > original.metrics.score + 0.22 {
            return sideways.image
        }

        return original.image
    }

    func addingStickerOutline() -> UIImage {
        let outerWidth: CGFloat = 18
        let innerWidth: CGFloat = 11
        let canvasInset = outerWidth + 4
        let canvasSize = CGSize(width: size.width + canvasInset * 2, height: size.height + canvasInset * 2)
        let origin = CGPoint(x: canvasInset, y: canvasInset)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { _ in
            let outerMask = tintedSilhouette(color: UIColor(red: 0.92, green: 0.67, blue: 0.38, alpha: 0.88))
            let innerMask = tintedSilhouette(color: .white.withAlphaComponent(0.98))

            drawMask(outerMask, radius: outerWidth, around: origin)
            drawMask(innerMask, radius: innerWidth, around: origin)

            draw(at: origin)
        }
    }

    private func tintedSilhouette(color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            draw(at: .zero, blendMode: .destinationIn, alpha: 1)
        }
    }

    private func drawMask(_ mask: UIImage, radius: CGFloat, around origin: CGPoint) {
        let steps = 32
        for index in 0..<steps {
            let angle = CGFloat(index) / CGFloat(steps) * .pi * 2
            let offset = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            mask.draw(at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y))
        }

        let diagonalRadius = radius * 0.72
        for index in 0..<steps {
            let angle = (CGFloat(index) + 0.5) / CGFloat(steps) * .pi * 2
            let offset = CGPoint(x: cos(angle) * diagonalRadius, y: sin(angle) * diagonalRadius)
            mask.draw(at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y))
        }
    }

    private func rotatedByQuarterTurns(_ turns: Int) -> UIImage {
        let normalizedTurns = ((turns % 4) + 4) % 4
        guard normalizedTurns != 0 else { return self }

        let isSideways = normalizedTurns == 1 || normalizedTurns == 3
        let canvasSize = isSideways ? CGSize(width: size.height, height: size.width) : size
        let radians = CGFloat(normalizedTurns) * .pi / 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            cgContext.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }

    private var uprightDrinkMetrics: (score: CGFloat, mouthScore: CGFloat) {
        guard let cgImage else { return (0, 0) }

        let width = min(cgImage.width, 320)
        let height = max(1, Int(CGFloat(cgImage.height) * CGFloat(width) / CGFloat(cgImage.width)))
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        var weightedY: CGFloat = 0
        var alphaCount: CGFloat = 0
        var rowMinX = [Int](repeating: width, count: height)
        var rowMaxX = [Int](repeating: 0, count: height)

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                guard alpha > 32 else { continue }

                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                rowMinX[y] = min(rowMinX[y], x)
                rowMaxX[y] = max(rowMaxX[y], x)
                weightedY += CGFloat(y)
                alphaCount += 1
            }
        }

        guard alphaCount > 0, maxX > minX, maxY > minY else { return (0, 0) }

        let boundingWidth = CGFloat(maxX - minX + 1)
        let boundingHeight = CGFloat(maxY - minY + 1)
        let verticalScore = boundingHeight / max(boundingWidth, 1)
        let centroidY = weightedY / alphaCount / CGFloat(height)
        let topWidth = averageRowWidth(from: minY, to: minY + (maxY - minY) / 3, rowMinX: rowMinX, rowMaxX: rowMaxX)
        let bottomWidth = averageRowWidth(from: maxY - (maxY - minY) / 3, to: maxY, rowMinX: rowMinX, rowMaxX: rowMaxX)
        let mouthScore = (topWidth - bottomWidth) / max(boundingWidth, 1)

        let score = verticalScore * 2 + mouthScore * 1.4 + centroidY * 0.35
        return (score, mouthScore)
    }

    private func averageRowWidth(from start: Int, to end: Int, rowMinX: [Int], rowMaxX: [Int]) -> CGFloat {
        let lower = max(0, start)
        let upper = min(rowMinX.count - 1, end)
        guard lower <= upper else { return 0 }

        let widths = (lower...upper).compactMap { row -> CGFloat? in
            guard rowMaxX[row] > rowMinX[row] else { return nil }
            return CGFloat(rowMaxX[row] - rowMinX[row] + 1)
        }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) / CGFloat(widths.count)
    }
}

enum ProcessingError: LocalizedError {
    case invalidImage
    case noForeground
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法读取这张图片。"
        case .noForeground:
            "没有识别到清晰的饮品主体，请换一张背景更简洁的照片。"
        case .renderFailed:
            "贴图生成失败，请重试。"
        }
    }
}

extension Data {
    func downsampledImage(maxDimension: CGFloat) throws -> UIImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(self as CFData, options) else {
            throw ProcessingError.invalidImage
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ProcessingError.invalidImage
        }
        return UIImage(cgImage: cgImage)
    }
}
