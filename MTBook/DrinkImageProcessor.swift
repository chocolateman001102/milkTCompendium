import CoreImage
import UIKit
import Vision

struct ProcessedDrinkImage {
    let sticker: UIImage
    let recognizedText: [String]
}

enum DrinkImageProcessor {
    static func process(_ image: UIImage) async throws -> ProcessedDrinkImage {
        guard let cgImage = image.cgImage else {
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
            return UIImage(cgImage: result)
        }.value
    }

    private static func recognizeText(in cgImage: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            return request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        }.value
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
