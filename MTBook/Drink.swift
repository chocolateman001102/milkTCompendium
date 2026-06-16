import Foundation
import SwiftData

@Model
final class Drink {
    var brand: String
    var name: String
    var sweetness: String
    var iceLevel: String
    var rating: Double
    var consumedAt: Date
    var location: String
    var originalImageName: String?
    var stickerImageName: String?
    var createdAt: Date

    init(
        brand: String,
        name: String,
        sweetness: String,
        iceLevel: String,
        rating: Double,
        consumedAt: Date,
        location: String,
        originalImageName: String?,
        stickerImageName: String?
    ) {
        self.brand = brand
        self.name = name
        self.sweetness = sweetness
        self.iceLevel = iceLevel
        self.rating = rating
        self.consumedAt = consumedAt
        self.location = location
        self.originalImageName = originalImageName
        self.stickerImageName = stickerImageName
        self.createdAt = .now
    }
}
