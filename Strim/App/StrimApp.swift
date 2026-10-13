import HaishinKit
import RTMPHaishinKit
import SwiftUI

@main
struct StrimApp: App {
    @StateObject private var store = DestinationStore()
    @StateObject private var engine = StreamEngine()
    @State private var isReady = false

    var body: some Scene {
        WindowGroup {
            Group {
                if isReady {
                    RootTabView()
                        .environmentObject(store)
                        .environmentObject(engine)
                } else {
                    LaunchView()
                        .task {
                            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
                            isReady = true
                        }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Strim")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Multi-destination RTMP")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                ProgressView()
                    .tint(.white)
                    .padding(.top, 12)
            }
        }
    }
}
