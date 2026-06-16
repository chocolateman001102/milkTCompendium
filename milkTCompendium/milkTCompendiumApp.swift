import SwiftData
import SwiftUI

@main
struct milkTCompendiumApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Drink.self)
    }
}
