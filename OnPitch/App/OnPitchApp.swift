import HaishinKit
import RTMPHaishinKit
import SwiftUI

@main
struct OnPitchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DestinationStore()
    @StateObject private var engine = StreamEngine()
    @StateObject private var vkChat = VKChatClient()
    @StateObject private var vkViewer = VKViewerMonitor()
    @StateObject private var scoreboard = ScoreboardController()
    @ObservedObject private var bootstrap = StreamingBootstrap.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if bootstrap.isReady {
                    RootTabView()
                        .environmentObject(store)
                        .environmentObject(engine)
                        .environmentObject(vkChat)
                        .environmentObject(vkViewer)
                        .environmentObject(scoreboard)
                        .onAppear {
                            scoreboard.attach(engine: engine)
                            engine.onMixerReady = {
                                scoreboard.resync()
                            }
                        }
                } else {
                    LaunchView()
                        .onAppear {
                            bootstrap.startIfNeeded()
                        }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: bootstrap.isReady)
            .preferredColorScheme(.dark)
        }
    }
}
