import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            GenerateView()
                .tabItem { Label("Create", systemImage: "wand.and.stars") }
            FeedView()
                .tabItem { Label("Feed", systemImage: "sparkles.tv") }
            StudioView()
                .tabItem { Label("Studio", systemImage: "paintpalette") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(Theme.cyan)
    }
}
