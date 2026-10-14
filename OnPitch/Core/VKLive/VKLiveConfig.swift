import Foundation

/// VK Видео Live DevAPI app credentials.
/// Portal only allows `https://` redirect URLs. Host `oauth/vk-live.html` somewhere,
/// register that HTTPS URL in the app form, then set the same value here / in Settings.
/// The HTML page bounces to `onpitch://vk-live-oauth` so ASWebAuthenticationSession can finish.
enum VKLiveConfig {
    static let apiHost = URL(string: "https://api.live.vkvideo.ru")!
    static let authorizeURL = URL(string: "https://auth.live.vkvideo.ru/app/oauth2/authorize")!
    static let tokenURL = URL(string: "https://api.live.vkvideo.ru/oauth/server/token")!
    /// Deep-link scheme caught by ASWebAuthenticationSession after the HTTPS bridge page.
    static let callbackScheme = "onpitch"

    private static let redirectURIKey = "onpitch.vklive.redirect_uri"

    /// HTTPS redirect registered in DevAPI. Must match token exchange exactly.
    static var redirectURI: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: redirectURIKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !saved.isEmpty {
                return saved
            }
            if let plist = Bundle.main.configValue("VKLiveRedirectURI", placeholder: "YOUR_VK_LIVE_REDIRECT_URI") {
                return plist
            }
            // Hosted bridge page (oauth/vk-live.html).
            return "https://ementis.ru/onpitch"
        }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: redirectURIKey
            )
        }
    }

    /// Chat-only scopes — RTMP keys are entered manually in Destinations.
    static let defaultScopes = [
        "chat:settings",
        "chat:message:send"
    ].joined(separator: ",")

    private static let clientIDKey = "onpitch.vklive.client_id"
    private static let clientSecretAccount = "vklive.client_secret"

    /// Prefer Info.plist, fall back to Settings-saved values.
    static var clientID: String {
        get {
            if let plist = Bundle.main.configValue("VKLiveClientID", placeholder: "YOUR_VK_LIVE_CLIENT_ID") {
                return plist
            }
            return UserDefaults.standard.string(forKey: clientIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey)
        }
    }

    static var clientSecret: String {
        get {
            if let plist = Bundle.main.configValue("VKLiveClientSecret", placeholder: "YOUR_VK_LIVE_CLIENT_SECRET") {
                return plist
            }
            return KeychainStore.string(account: clientSecretAccount) ?? ""
        }
        set { KeychainStore.setString(newValue, account: clientSecretAccount) }
    }

    static var isConfigured: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty && !redirectURI.isEmpty
    }
}
