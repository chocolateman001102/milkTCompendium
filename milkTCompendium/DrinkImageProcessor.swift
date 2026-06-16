import CoreImage
import UIKit
import Vision

struct ProcessedDrinkImage {
    let sticker: UIImage
    let recognizedText: [String]
}

enum DrinkImageProcessor {
    static func process(_ image: UIImage) async throws -> ProcessedDrinkImage {
        let normalizedImage = image.normalizedForProcessing()
        guard let cgImage = normalizedImage.cgImage else {
            throw ProcessingError.invalidImage
        }

        async let sticker = createSticker(from: cgImage)
        async let text = recognizeText(in: cgImage)
        return try await ProcessedDrinkImage(sticker: sticker, recognizedText: text)
    }

    private static func createSticker(from cgImage: CGImage) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
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
                .addingStickerOutline()
        }.value
    }

    private static func recognizeText(in cgImage: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let context = CIContext()
            let source = quickOCRImage(from: CIImage(cgImage: cgImage), context: context) ?? cgImage
            let sources = [source]
            let lines = try sources.flatMap { try recognizeTextLines(in: $0) }
            return uniqueLines(lines)
        }.value
    }

    private static func quickOCRImage(from image: CIImage, context: CIContext) -> CGImage? {
        let normalized = image.oriented(.up)
        let longestSide = max(normalized.extent.width, normalized.extent.height)
        let scale = min(1, 1400 / max(longestSide, 1))
        let resized = normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .enhancedForOCR()
        return context.createCGImage(resized, from: resized.extent.integral)
    }

    private static func labelCandidateImages(from cgImage: CGImage, context: CIContext) -> [CGImage] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumConfidence = 0.32
        request.minimumSize = 0.035
        request.minimumAspectRatio = 0.18
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 45

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let ciImage = CIImage(cgImage: cgImage)
        return (request.results ?? [])
            .sorted { $0.confidence > $1.confidence }
            .flatMap { observation in
                perspectiveCorrectedImages(from: ciImage, observation: observation, context: context)
            }
    }

    private static func perspectiveCorrectedImages(
        from image: CIImage,
        observation: VNRectangleObservation,
        context: CIContext
    ) -> [CGImage] {
        let width = image.extent.width
        let height = image.extent.height

        func imagePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * width, y: point.y * height)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return [] }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: imagePoint(observation.topLeft)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: imagePoint(observation.topRight)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: imagePoint(observation.bottomLeft)), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: imagePoint(observation.bottomRight)), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return [] }
        return ocrVariants(from: output, context: context)
    }

    private static func ocrVariants(from image: CIImage, context: CIContext) -> [CGImage] {
        let normalized = image.oriented(.up)
        let variants = [
            normalized,
            normalized.enhancedForOCR(),
            normalized.highContrastForOCR()
        ]

        return variants.compactMap { variant in
            let extent = variant.extent.integral
            guard extent.width >= 80, extent.height >= 32 else { return nil }
            return context.createCGImage(variant, from: extent)
        }
    }

    private static func recognizeTextLines(in cgImage: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = [
            "多冰", "正常冰", "标准冰", "少冰", "微冰", "去冰", "不加冰", "常温", "温热", "热饮",
            "全糖", "正常糖", "少糖", "七分糖", "半糖", "五分糖", "三分糖", "微糖", "无糖",
            "芝芝", "莓莓", "波波", "珍珠", "拿铁", "乌龙", "茉莉", "柠檬"
        ]
        request.minimumTextHeight = 0.018
        if #available(iOS 16.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func uniqueLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}

private extension CIImage {
    func enhancedForOCR() -> CIImage {
        applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.28,
            kCIInputBrightnessKey: 0.03
        ])
        .applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.55
        ])
    }

    func highContrastForOCR() -> CIImage {
        applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.65,
            kCIInputBrightnessKey: 0.08
        ])
        .applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.6,
            kCIInputIntensityKey: 0.55
        ])
    }
}

private extension UIImage {
    func normalizedForProcessing() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
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
        format.scale = scale
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
        format.scale = scale
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
        format.scale = scale
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
