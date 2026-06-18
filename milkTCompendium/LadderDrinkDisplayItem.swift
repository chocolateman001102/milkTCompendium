import Foundation
import UIKit

struct LadderDrinkDisplayItem: Identifiable {
    let id: String
    let localDrink: Drink?
    let brand: String
    let name: String
    let sweetness: String
    let iceLevel: String
    let rating: Double
    let consumedAt: Date
    let location: String
    let note: String
    let isLimited: Bool
    let stickerImageName: String?
    let stickerFileURL: URL?
    let createdAt: Date

    var isEditable: Bool {
        localDrink != nil
    }

    var stickerImage: UIImage? {
        if let stickerImageName {
            return ImageStore.load(stickerImageName)
        }
        if let stickerFileURL {
            return UIImage(contentsOfFile: stickerFileURL.path)
        }
        return nil
    }

    init(drink: Drink) {
        id = "local-\(drink.createdAt.timeIntervalSince1970)-\(drink.brand)-\(drink.name)"
        localDrink = drink
        brand = drink.brand
        name = drink.name
        sweetness = drink.sweetness
        iceLevel = drink.iceLevel
        rating = drink.rating
        consumedAt = drink.consumedAt
        location = drink.location
        note = drink.note
        isLimited = drink.isLimited
        stickerImageName = drink.stickerImageName
        stickerFileURL = nil
        createdAt = drink.createdAt
    }

    init(sharedDrink: SharedDrink, ownerID: String) {
        id = "shared-\(ownerID)-\(sharedDrink.id)"
        localDrink = nil
        brand = sharedDrink.brand
        name = sharedDrink.name
        sweetness = sharedDrink.sweetness
        iceLevel = sharedDrink.iceLevel
        rating = sharedDrink.rating
        consumedAt = sharedDrink.consumedAt
        location = sharedDrink.location
        note = sharedDrink.note
        isLimited = sharedDrink.isLimited
        stickerImageName = nil
        stickerFileURL = SharedCompendiumStore.stickerURL(ownerID: ownerID, fileName: sharedDrink.stickerFileName)
        createdAt = sharedDrink.createdAt
    }
}
