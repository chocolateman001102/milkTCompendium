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
    var note: String = ""
    var isLimited: Bool = false
    var cupCount: Int = 1
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
        note: String = "",
        isLimited: Bool = false,
        cupCount: Int = 1,
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
        self.note = note
        self.isLimited = isLimited
        self.cupCount = max(1, cupCount)
        self.originalImageName = originalImageName
        self.stickerImageName = stickerImageName
        self.createdAt = .now
    }
}
