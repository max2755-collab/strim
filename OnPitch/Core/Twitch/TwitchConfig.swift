import Foundation

/// Twitch app credentials for chat OAuth (register at https://dev.twitch.tv/console).
/// Redirect URI must be exactly `onpitch://twitch-oauth`.
enum TwitchConfig {
    static let authorizeURL = URL(string: "https://id.twitch.tv/oauth2/authorize")!
    static let validateURL = URL(string: "https://id.twitch.tv/oauth2/validate")!
    static let helixUsersURL = URL(string: "https://api.twitch.tv/helix/users")!
    static let ircWebSocketURL = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
    static let redirectURI = "onpitch://twitch-oauth"
    static let callbackScheme = "onpitch"
    static let scopes = "chat:read chat:edit"

    private static let clientIDKey = "onpitch.twitch.client_id"
    private static let accessAccount = "twitch.access_token"
    private static let loginKey = "onpitch.twitch.login"

    static var clientID: String {
        get {
            if let plist = Bundle.main.configValue("TwitchClientID", placeholder: "YOUR_TWITCH_CLIENT_ID") {
                return plist
            }
            return UserDefaults.standard.string(forKey: clientIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey)
        }
    }

    static var isConfigured: Bool { !clientID.isEmpty }

    static var accessToken: String? {
        get { KeychainStore.string(account: accessAccount) }
        set { KeychainStore.setString(newValue, account: accessAccount) }
    }

    static var login: String {
        get { UserDefaults.standard.string(forKey: loginKey) ?? "" }
        set { UserDefaults.standard.set(newValue.lowercased(), forKey: loginKey) }
    }
}
