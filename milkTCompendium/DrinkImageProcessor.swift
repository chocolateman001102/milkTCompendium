import CoreImage
import ImageIO
import UIKit
import Vision

struct ProcessedDrinkImage {
    let sticker: UIImage
}

enum DrinkImageProcessor {
    fileprivate static let ciContext = CIContext()

    static func process(_ image: UIImage) async throws -> ProcessedDrinkImage {
        let normalizedImage = image
            .resizedAndNormalizedToFit(maxDimension: 3_200)
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
                guard let result = createCGImage(from: ciImage) else {
                    throw ProcessingError.renderFailed
                }
                let cutout = UIImage(cgImage: result)
                return cutout
                    .bestUprightDrinkOrientation(sourceSize: CGSize(width: cgImage.width, height: cgImage.height))
                    .resizedAndNormalizedToFit(maxDimension: 1_760)
                    .removingLikelyHands()
                    .trimmingTransparentPadding(padding: 8)
                    .enhancedForSticker()
                    .addingStickerOutline()
                    .resizedWithLanczosToFit(maxDimension: 1_800)
            }
        }.value
    }

    fileprivate static func createCGImage(from image: CIImage, extent: CGRect? = nil) -> CGImage? {
        ciContext.createCGImage(image, from: (extent ?? image.extent).integral)
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

    func bestUprightDrinkOrientation(sourceSize: CGSize) -> UIImage {
        let candidates = (0...3).map { turns in
            let image = rotatedByQuarterTurns(turns)
            return (turns: turns, image: image, metrics: image.uprightDrinkMetrics)
        }
        let original = candidates[0]
        let sideways = [candidates[1], candidates[3]]
            .max { $0.metrics.score < $1.metrics.score }
        let cropAspect = original.image.size.width / max(original.image.size.height, 1)
        let sourceLooksLandscape = sourceSize.width > sourceSize.height * 1.08
        let originalLooksSideways = sourceLooksLandscape
            ? cropAspect > 1.08
            : cropAspect > 1.32

        if originalLooksSideways,
           let sideways,
           sideways.metrics.score > original.metrics.score + 0.12 ||
            (sideways.metrics.verticalScore > original.metrics.verticalScore * 1.22 && sideways.metrics.score > original.metrics.score - 0.03) {
            return sideways.image
        }

        return original.image
    }

    func removingLikelyHands() -> UIImage {
        guard let cgImage else { return self }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 18, height > 18 else { return self }

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
            return self
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var alphaPixelCount = 0
        var candidate = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let alpha = pixels[pixelIndex + 3]
                guard alpha > 40 else { continue }
                alphaPixelCount += 1

                let red = pixels[pixelIndex]
                let green = pixels[pixelIndex + 1]
                let blue = pixels[pixelIndex + 2]
                let inHandZone = x < width * 26 / 100 || x > width * 74 / 100 || y > height * 62 / 100
                if inHandZone, Self.looksLikeSkin(red: red, green: green, blue: blue) {
                    candidate[y * width + x] = true
                }
            }
        }

        var visited = [Bool](repeating: false, count: width * height)
        var removal = [Bool](repeating: false, count: width * height)
        let minimumComponentSize = max(80, width * height / 700)

        for start in candidate.indices where candidate[start] && !visited[start] {
            var stack = [start]
            var component: [Int] = []
            visited[start] = true
            var touchesEdge = false
            var sidePixels = 0
            var lowerPixels = 0
            var centralCorePixels = 0
            var exposedPixels = 0
            var edgeEntryPixels = 0
            var minX = width
            var maxX = 0
            var minY = height
            var maxY = 0

            while let current = stack.popLast() {
                component.append(current)
                let x = current % width
                let y = current / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                touchesEdge = touchesEdge || x <= 1 || y <= 1 || x >= width - 2 || y >= height - 2
                if x < width * 28 / 100 || x > width * 72 / 100 {
                    sidePixels += 1
                }
                if y > height * 60 / 100 {
                    lowerPixels += 1
                }
                if x > width * 32 / 100, x < width * 68 / 100, y < height * 82 / 100 {
                    centralCorePixels += 1
                }
                if Self.hasTransparentNeighbor(around: current, width: width, height: height, pixels: pixels, bytesPerPixel: bytesPerPixel, bytesPerRow: bytesPerRow) {
                    exposedPixels += 1
                    if x < width * 12 / 100 || x > width * 88 / 100 || y > height * 88 / 100 {
                        edgeEntryPixels += 1
                    }
                }

                let neighbors = [
                    x > 0 ? current - 1 : nil,
                    x < width - 1 ? current + 1 : nil,
                    y > 0 ? current - width : nil,
                    y < height - 1 ? current + width : nil
                ].compactMap { $0 }

                for next in neighbors where candidate[next] && !visited[next] {
                    visited[next] = true
                    stack.append(next)
                }
            }

            let size = component.count
            let sideRatio = CGFloat(sidePixels) / CGFloat(max(size, 1))
            let lowerRatio = CGFloat(lowerPixels) / CGFloat(max(size, 1))
            let centralCoreRatio = CGFloat(centralCorePixels) / CGFloat(max(size, 1))
            let exposedRatio = CGFloat(exposedPixels) / CGFloat(max(size, 1))
            let edgeEntryRatio = CGFloat(edgeEntryPixels) / CGFloat(max(size, 1))
            let componentRatio = CGFloat(size) / CGFloat(max(alphaPixelCount, 1))
            let componentWidthRatio = CGFloat(maxX - minX + 1) / CGFloat(width)
            let componentHeightRatio = CGFloat(maxY - minY + 1) / CGFloat(height)
            let entersFromOuterEdge = touchesEdge || edgeEntryRatio > 0.08
            let staysOutsideDrinkCore = centralCoreRatio < 0.34
            let hasHandScale = componentRatio > 0.006 &&
                componentRatio < 0.22 &&
                componentWidthRatio < 0.56 &&
                componentHeightRatio < 0.62
            let hasExposedSilhouette = exposedRatio > 0.18 && edgeEntryRatio > 0.025
            let hasHandPlacement = sideRatio > 0.52 || lowerRatio > 0.58 || (sideRatio > 0.36 && lowerRatio > 0.36)
            let shouldRemove = size >= minimumComponentSize &&
                hasHandScale &&
                entersFromOuterEdge &&
                hasExposedSilhouette &&
                staysOutsideDrinkCore &&
                hasHandPlacement
            guard shouldRemove else { continue }

            for index in component {
                let x = index % width
                let y = index / width
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nextX = x + dx
                        let nextY = y + dy
                        guard nextX >= 0, nextY >= 0, nextX < width, nextY < height else { continue }
                        removal[nextY * width + nextX] = true
                    }
                }
            }
        }

        guard removal.contains(true) else { return self }

        for index in removal.indices where removal[index] {
            pixels[index * bytesPerPixel + 3] = 0
        }

        guard let outputContext = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
              let outputImage = outputContext.makeImage() else {
            return self
        }
        return UIImage(cgImage: outputImage, scale: scale, orientation: .up)
    }

    func trimmingTransparentPadding(padding: CGFloat) -> UIImage {
        guard let cgImage else { return self }
        let width = cgImage.width
        let height = cgImage.height
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
            return self
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                guard alpha > 24 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }

        guard maxX > minX, maxY > minY else { return self }
        let inset = Int(padding.rounded())
        let crop = CGRect(
            x: max(0, minX - inset),
            y: max(0, minY - inset),
            width: min(width - max(0, minX - inset), maxX - minX + 1 + inset * 2),
            height: min(height - max(0, minY - inset), maxY - minY + 1 + inset * 2)
        )
        guard crop.width < CGFloat(width) || crop.height < CGFloat(height),
              let cropped = cgImage.cropping(to: crop) else {
            return self
        }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    func enhancedForSticker() -> UIImage {
        guard let cgImage else { return self }

        var output = CIImage(cgImage: cgImage)
        output = output.applyingFilter(
            "CIHighlightShadowAdjust",
            parameters: [
                "inputShadowAmount": 0.34,
                "inputHighlightAmount": 0.96
            ]
        )
        output = output.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 1.02,
                kCIInputBrightnessKey: 0.008,
                kCIInputContrastKey: 1.03
            ]
        )
        output = output.applyingFilter(
            "CIVibrance",
            parameters: [
                "inputAmount": 0.08
            ]
        )
        output = output.applyingFilter(
            "CIUnsharpMask",
            parameters: [
                kCIInputRadiusKey: 0.48,
                kCIInputIntensityKey: 0.56
            ]
        )

        guard let rendered = DrinkImageProcessor.createCGImage(from: output, extent: output.extent) else {
            return self
        }
        return UIImage(cgImage: rendered, scale: scale, orientation: .up)
    }

    func addingStickerOutline() -> UIImage {
        guard let cgImage else { return self }

        let outerRadius: CGFloat = 16
        let innerRadius: CGFloat = 12
        let glowRadius: CGFloat = 22
        let canvasInset = glowRadius + 8
        let canvasExtent = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(cgImage.width) + canvasInset * 2,
            height: CGFloat(cgImage.height) + canvasInset * 2
        )
        let source = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: canvasInset, y: canvasInset))
        let clearCanvas = CIImage(color: .clear).cropped(to: canvasExtent)
        let sourceOnCanvas = source.composited(over: clearCanvas).cropped(to: canvasExtent)
        let silhouette = solidColorImage(
            color: CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            maskedBy: sourceOnCanvas,
            extent: canvasExtent
        )

        let glow = solidColorImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.10),
            maskedBy: expandedSilhouette(from: silhouette, radius: glowRadius, extent: canvasExtent),
            extent: canvasExtent
        )
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.5])
            .cropped(to: canvasExtent)
        let outerOutline = solidColorImage(
            color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92),
            maskedBy: expandedSilhouette(from: silhouette, radius: outerRadius, extent: canvasExtent),
            extent: canvasExtent
        )
        let innerOutline = solidColorImage(
            color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.98),
            maskedBy: expandedSilhouette(from: silhouette, radius: innerRadius, extent: canvasExtent),
            extent: canvasExtent
        )

        let output = sourceOnCanvas
            .composited(over: innerOutline)
            .composited(over: outerOutline)
            .composited(over: glow)
            .cropped(to: canvasExtent)

        guard let rendered = DrinkImageProcessor.createCGImage(from: output, extent: canvasExtent) else {
            return self
        }
        return UIImage(cgImage: rendered, scale: scale, orientation: .up)
    }

    func resizedWithLanczosToFit(maxDimension: CGFloat) -> UIImage {
        guard let cgImage else { return self }
        let longestSide = max(CGFloat(cgImage.width), CGFloat(cgImage.height))
        guard longestSide > maxDimension else { return self }

        let input = CIImage(cgImage: cgImage)
        let scale = maxDimension / longestSide
        let output = input.applyingFilter(
            "CILanczosScaleTransform",
            parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ]
        )
        let targetExtent = CGRect(
            x: output.extent.origin.x,
            y: output.extent.origin.y,
            width: floor(output.extent.width),
            height: floor(output.extent.height)
        )

        guard let rendered = DrinkImageProcessor.createCGImage(from: output, extent: targetExtent) else {
            return resizedAndNormalizedToFit(maxDimension: maxDimension)
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    private func expandedSilhouette(from image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        image
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    private func solidColorImage(color: CIColor, maskedBy mask: CIImage, extent: CGRect) -> CIImage {
        CIImage(color: color)
            .cropped(to: extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            .cropped(to: extent)
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

    private static func looksLikeSkin(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let r = Int(red)
        let g = Int(green)
        let b = Int(blue)
        let maxChannel = max(r, max(g, b))
        let minChannel = min(r, min(g, b))
        return r > 92 &&
            g > 48 &&
            b > 32 &&
            r >= g &&
            r > b + 18 &&
            maxChannel - minChannel > 22 &&
            abs(r - g) < 96
    }

    private static func hasTransparentNeighbor(
        around index: Int,
        width: Int,
        height: Int,
        pixels: [UInt8],
        bytesPerPixel: Int,
        bytesPerRow: Int
    ) -> Bool {
        let x = index % width
        let y = index / width

        for dy in -2...2 {
            for dx in -2...2 where dx != 0 || dy != 0 {
                let nextX = x + dx
                let nextY = y + dy
                guard nextX >= 0, nextY >= 0, nextX < width, nextY < height else {
                    return true
                }
                let alpha = pixels[nextY * bytesPerRow + nextX * bytesPerPixel + 3]
                if alpha <= 40 {
                    return true
                }
            }
        }

        return false
    }

    private var uprightDrinkMetrics: (score: CGFloat, mouthScore: CGFloat, verticalScore: CGFloat) {
        guard let cgImage else { return (0, 0, 0) }

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
            return (0, 0, 0)
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

        guard alphaCount > 0, maxX > minX, maxY > minY else { return (0, 0, 0) }

        let boundingWidth = CGFloat(maxX - minX + 1)
        let boundingHeight = CGFloat(maxY - minY + 1)
        let verticalScore = boundingHeight / max(boundingWidth, 1)
        let centroidY = weightedY / alphaCount / CGFloat(height)
        let topWidth = averageRowWidth(from: minY, to: minY + (maxY - minY) / 3, rowMinX: rowMinX, rowMaxX: rowMaxX)
        let bottomWidth = averageRowWidth(from: maxY - (maxY - minY) / 3, to: maxY, rowMinX: rowMinX, rowMaxX: rowMaxX)
        let mouthScore = (topWidth - bottomWidth) / max(boundingWidth, 1)

        let score = verticalScore * 2 + mouthScore * 1.4 + centroidY * 0.35
        return (score, mouthScore, verticalScore)
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
