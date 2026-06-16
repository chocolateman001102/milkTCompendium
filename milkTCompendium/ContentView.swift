import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var showingNewDrink = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CollectionView(showingNewDrink: $showingNewDrink)
            }
            .tabItem {
                Label("图鉴", systemImage: "square.grid.2x2.fill")
            }
            .tag(0)

            NavigationStack {
                DrinkFormView(mode: .standalone) {
                    selectedTab = 0
                }
            }
            .tabItem {
                Label("记录", systemImage: "plus.circle.fill")
            }
            .tag(1)
        }
        .tint(.primary)
        .sheet(isPresented: $showingNewDrink) {
            NavigationStack {
                DrinkFormView(mode: .sheet) {
                    showingNewDrink = false
                }
            }
        }
    }
}
