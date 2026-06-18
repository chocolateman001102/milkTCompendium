import CoreImage
import UIKit
import Vision

struct RecognizedDrinkInfo {
    var brand: String?
    var name: String?
    var sweetness: String?
    var iceLevel: String?
    var confidence: Float
}

enum DrinkTextRecognizer {
    private static let sweetnessWords = ["全糖", "正常糖", "少糖", "七分糖", "半糖", "三分糖", "微糖", "无糖", "不另外加糖"]
    private static let iceWords = ["多冰", "正常冰", "少冰", "微冰", "去冰", "常温", "温", "热"]
    private static let ignoredTokens = Set(["冰", "温", "糖", "饮品", "标签", "订单"])

    static func recognize(from image: UIImage) async throws -> RecognizedDrinkInfo {
        try await Task.detached(priority: .userInitiated) {
            let candidates = image.recognitionCandidates()
            var allLines: [(text: String, confidence: Float)] = []

            for candidate in candidates {
                guard let cgImage = candidate.cgImage else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                request.customWords = BrandStore.commonBrands + sweetnessWords + iceWords

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])
                let lines = request.results?.compactMap { observation -> (String, Float)? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let cleaned = normalize(candidate.string)
                    guard cleaned.count > 1 else { return nil }
                    return (cleaned, candidate.confidence)
                } ?? []
                allLines.append(contentsOf: lines)
            }

            return parse(lines: allLines)
        }.value
    }

    private static func parse(lines: [(text: String, confidence: Float)]) -> RecognizedDrinkInfo {
        let sorted = lines.sorted { $0.confidence > $1.confidence }
        let brand = BrandStore.allKnownBrands.first { brand in
            sorted.contains { $0.text.localizedCaseInsensitiveContains(brand) && $0.confidence >= 0.45 }
        }
        let sweetness = sweetnessWords.first { word in
            sorted.contains { $0.text.contains(word) && $0.confidence >= 0.42 }
        }
        let iceLevel = iceWords.first { word in
            sorted.contains { $0.text.contains(word) && $0.confidence >= 0.42 }
        }
        let name = sorted.first { line in
            guard line.confidence >= 0.38 else { return false }
            guard !ignoredTokens.contains(line.text) else { return false }
            guard brand.map({ !line.text.contains($0) }) ?? true else { return false }
            guard sweetness.map({ !line.text.contains($0) }) ?? true else { return false }
            guard iceLevel.map({ !line.text.contains($0) }) ?? true else { return false }
            return line.text.count >= 2 && line.text.count <= 18
        }?.text

        let confidence = sorted.first?.confidence ?? 0
        return RecognizedDrinkInfo(
            brand: brand,
            name: name,
            sweetness: sweetness,
            iceLevel: iceLevel,
            confidence: confidence
        )
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "：", with: ":")
    }
}

private let sharedRecognitionCIContext = CIContext()

private extension UIImage {
    func recognitionCandidates() -> [UIImage] {
        let normalized = resizedForRecognition(maxPixel: 1_200)
        var candidates = [normalized]

        if let corrected = normalized.perspectiveCorrectedTextRegion() {
            candidates.append(corrected)
            if let enhancedCorrected = corrected.enhancedForTextRecognition() {
                candidates.append(enhancedCorrected)
            }
        }
        if let enhanced = normalized.enhancedForTextRecognition() {
            candidates.append(enhanced)
        }
        if normalized.size.width > 2, normalized.size.height > 2 {
            let cropRect = CGRect(
                x: normalized.size.width * 0.08,
                y: normalized.size.height * 0.12,
                width: normalized.size.width * 0.84,
                height: normalized.size.height * 0.76
            )
            if let cropped = normalized.cropped(to: cropRect) {
                candidates.append(cropped)
                if let enhancedCrop = cropped.enhancedForTextRecognition() {
                    candidates.append(enhancedCrop)
                }
            }
        }

        return candidates
    }

    func resizedForRecognition(maxPixel: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxPixel || imageOrientation != .up else { return self }
        let ratio = min(1, maxPixel / longestSide)
        let targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func enhancedForTextRecognition() -> UIImage? {
        guard let cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.45,
                kCIInputSaturationKey: 0.2,
                kCIInputBrightnessKey: 0.03
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.65
            ])
        guard let output = sharedRecognitionCIContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    func perspectiveCorrectedTextRegion() -> UIImage? {
        guard let cgImage else { return nil }
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.45
        request.minimumAspectRatio = 0.18
        request.maximumObservations = 2

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let rectangle = request.results?.first else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ciImage = CIImage(cgImage: cgImage)
        let corrected = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: CGPoint(x: rectangle.topLeft.x * width, y: rectangle.topLeft.y * height)),
            "inputTopRight": CIVector(cgPoint: CGPoint(x: rectangle.topRight.x * width, y: rectangle.topRight.y * height)),
            "inputBottomLeft": CIVector(cgPoint: CGPoint(x: rectangle.bottomLeft.x * width, y: rectangle.bottomLeft.y * height)),
            "inputBottomRight": CIVector(cgPoint: CGPoint(x: rectangle.bottomRight.x * width, y: rectangle.bottomRight.y * height))
        ])
        guard let output = sharedRecognitionCIContext.createCGImage(corrected, from: corrected.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    func cropped(to rect: CGRect) -> UIImage? {
        guard let cgImage else { return nil }
        let scaleX = CGFloat(cgImage.width) / size.width
        let scaleY = CGFloat(cgImage.height) / size.height
        let pixelRect = CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
