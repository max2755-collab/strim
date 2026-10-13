import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                }

            DestinationsView()
                .tabItem {
                    Label("Destinations", systemImage: "antenna.radiowaves.left.and.right")
                }

            StreamSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
        }
        .tint(Color("AccentColor"))
    }
}
