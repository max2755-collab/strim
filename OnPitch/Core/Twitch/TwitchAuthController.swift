import AuthenticationServices
import Foundation
import SwiftUI

/// Twitch implicit OAuth for IRC chat (chat:read + chat:edit).
@MainActor
final class TwitchAuthController: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false
    @Published private(set) var login: String = TwitchConfig.login
    @Published var lastError: String?
    @Published var clientIDDraft = TwitchConfig.clientID

    private let webAuth = WebAuthSession()

    init() {
        isSignedIn = !(TwitchConfig.accessToken ?? "").isEmpty && !TwitchConfig.login.isEmpty
    }

    func persistClientID() {
        TwitchConfig.clientID = clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func signIn() async {
        lastError = nil
        persistClientID()
        guard TwitchConfig.isConfigured else {
            lastError = String(localized: "Paste your Twitch Client ID above, then tap Sign in again.")
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            let state = UUID().uuidString
            var components = URLComponents(url: TwitchConfig.authorizeURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: TwitchConfig.clientID),
                URLQueryItem(name: "redirect_uri", value: TwitchConfig.redirectURI),
                URLQueryItem(name: "response_type", value: "token"),
                URLQueryItem(name: "scope", value: TwitchConfig.scopes),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "force_verify", value: "true")
            ]
            guard let url = components.url else { throw URLError(.badURL) }

            let callback = try await webAuth.start(url: url, callbackScheme: TwitchConfig.callbackScheme)
            let token = try parseAccessToken(from: callback, expectedState: state)
            TwitchConfig.accessToken = token
            let userLogin = try await fetchLogin(accessToken: token)
            TwitchConfig.login = userLogin
            login = userLogin
            isSignedIn = true
            lastError = nil
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // dismissed
        } catch {
            lastError = error.localizedDescription
            isSignedIn = false
        }
    }

    func signOut() {
        TwitchConfig.accessToken = nil
        TwitchConfig.login = ""
        login = ""
        isSignedIn = false
        lastError = nil
    }

    /// Implicit-flow tokens expire (~60 days). Drop a dead one at launch so the UI asks
    /// to sign in again instead of chat silently failing on the pitch.
    func validateStoredToken() async {
        guard let token = TwitchConfig.accessToken else { return }
        var request = URLRequest(url: TwitchConfig.validateURL)
        request.timeoutInterval = 15
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        // Offline / server trouble: keep the token, only a definite 401 signs out.
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 401
        else { return }
        signOut()
        lastError = String(localized: "Twitch sign-in expired — sign in again")
    }

    func accessToken() -> String? {
        TwitchConfig.accessToken
    }

    // MARK: - Private

    private func parseAccessToken(from url: URL, expectedState: String) throws -> String {
        // Implicit flow returns params in the fragment; some browsers put them in query.
        let raw = url.fragment?.isEmpty == false ? (url.fragment ?? "") : (url.query ?? "")
        var items: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                items[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        if let err = items["error"] {
            throw NSError(domain: "TwitchAuth", code: 401, userInfo: [
                NSLocalizedDescriptionKey: items["error_description"] ?? err
            ])
        }
        if let returned = items["state"], returned != expectedState {
            throw NSError(domain: "TwitchAuth", code: 401, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Twitch OAuth state mismatch")
            ])
        }
        guard let token = items["access_token"], !token.isEmpty else {
            throw NSError(domain: "TwitchAuth", code: 401, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Missing Twitch access token")
            ])
        }
        return token
    }

    private func fetchLogin(accessToken: String) async throws -> String {
        var request = URLRequest(url: TwitchConfig.helixUsersURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(TwitchConfig.clientID, forHTTPHeaderField: "Client-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Envelope: Decodable {
            struct User: Decodable { let login: String }
            let data: [User]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let login = envelope.data.first?.login, !login.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return login.lowercased()
    }
}
