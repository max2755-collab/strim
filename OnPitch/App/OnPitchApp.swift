import HaishinKit
import RTMPHaishinKit
import SwiftUI

@main
struct OnPitchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DestinationStore()
    @StateObject private var engine = StreamEngine()
    @StateObject private var vkChat = VKChatClient()
    @StateObject private var twitchChat = TwitchChatClient()
    @StateObject private var vkViewer = VKViewerMonitor()
    @StateObject private var vkLive = VKLiveAuthController()
    @StateObject private var twitch = TwitchAuthController()
    @StateObject private var scoreboard = ScoreboardController()
    @StateObject private var teams = TeamLibrary()
    @StateObject private var branding = BrandingController()
    @StateObject private var twitchViewer = TwitchViewerMonitor()
    @ObservedObject private var bootstrap = StreamingBootstrap.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if bootstrap.isReady {
                    RootTabView()
                        .environmentObject(store)
                        .environmentObject(engine)
                        .environmentObject(vkChat)
                        .environmentObject(twitchChat)
                        .environmentObject(vkViewer)
                        .environmentObject(vkLive)
                        .environmentObject(twitch)
                        .environmentObject(scoreboard)
                        .environmentObject(teams)
                        .environmentObject(branding)
                        .environmentObject(twitchViewer)
                        .onAppear {
                            scoreboard.attach(engine: engine, library: teams)
                            branding.attach(engine: engine)
                            engine.onMixerReady = {
                                scoreboard.resync()
                                branding.resync()
                            }
                            // Goals logged during a local recording become clips afterwards.
                            let board = scoreboard
                            engine.highlightMomentsProvider = {
                                board.state.goals.map { goal in
                                    HighlightMoment(title: goal.scorer ?? goal.teamName, at: goal.recordedAt)
                                }
                            }
                            let auth = vkLive
                            vkChat.accessTokenProvider = {
                                guard auth.isSignedIn else { return nil }
                                return try await auth.accessToken()
                            }
                            let tw = twitch
                            twitchChat.accessTokenProvider = { tw.accessToken() }
                            twitchChat.loginProvider = { tw.login.isEmpty ? nil : tw.login }
                        }
                        .task {
                            await twitch.validateStoredToken()
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
