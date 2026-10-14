import AuthenticationServices
import Foundation
import SwiftUI

/// Owns VK Live OAuth for chat only (RTMP stays manual in Destinations).
@MainActor
final class VKLiveAuthController: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false
    @Published var lastError: String?
    @Published private(set) var displayNick: String?

    private let accessAccount = "vklive.access_token"
    private let refreshAccount = "vklive.refresh_token"
    private let expiryKey = "onpitch.vklive.expires_at"
    private let nickKey = "onpitch.vklive.display_nick"

    private let webAuth = WebAuthSession()
    /// One refresh at a time: refresh tokens are single-use, so a second concurrent
    /// refresh (chat connect + send) would fail and look like a sign-out.
    private var refreshTask: Task<String, Error>?

    init() {
        displayNick = UserDefaults.standard.string(forKey: nickKey)
        isSignedIn = KeychainStore.string(account: accessAccount) != nil
    }

    func signIn() async {
        lastError = nil
        guard VKLiveConfig.isConfigured else {
            lastError = String(localized: "Add VK Live Client ID, Secret, and https Redirect URI first")
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            let state = UUID().uuidString
            let url = try VKLiveAPIClient.makeAuthorizeURL(state: state)
            let callback = try await webAuth.start(url: url, callbackScheme: VKLiveConfig.callbackScheme)
            guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
                throw VKLiveAPIClient.APIError.badURL
            }
            if let err = items.first(where: { $0.name == "error" })?.value {
                throw VKLiveAPIClient.APIError.http(401, err)
            }
            if let returnedState = items.first(where: { $0.name == "state" })?.value,
               returnedState != state {
                throw VKLiveAPIClient.APIError.http(401, "state mismatch")
            }
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw VKLiveAPIClient.APIError.http(401, "missing code")
            }
            let tokens = try await VKLiveAPIClient.exchangeCode(code)
            try persist(tokens: tokens)
            isSignedIn = true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User dismissed the browser — not an error.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        KeychainStore.delete(account: accessAccount)
        KeychainStore.delete(account: refreshAccount)
        UserDefaults.standard.removeObject(forKey: expiryKey)
        isSignedIn = false
        displayNick = nil
        UserDefaults.standard.removeObject(forKey: nickKey)
    }

    func refreshSignedInProfile() async {
        guard isSignedIn else { return }
        do {
            let token = try await validAccessToken()
            let user = try await VKLiveAPIClient.fetchCurrentUser(accessToken: token)
            displayNick = user.resolvedName
            UserDefaults.standard.set(user.resolvedName, forKey: nickKey)
        } catch {
            // Soft — profile is optional chrome.
        }
    }

    // MARK: - Tokens

    private func persist(tokens: VKLiveTokenResponse) throws {
        try KeychainStore.save(key: tokens.accessToken, account: accessAccount)
        if let refresh = tokens.refreshToken, !refresh.isEmpty {
            try KeychainStore.save(key: refresh, account: refreshAccount)
        }
        if let expires = tokens.expiresIn {
            let date = Date().addingTimeInterval(TimeInterval(expires) - 60)
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: expiryKey)
        }
    }

    /// Access token for official VK chat send. Refreshes when stale.
    func accessToken() async throws -> String {
        try await validAccessToken()
    }

    private func validAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        if let expiry = UserDefaults.standard.object(forKey: expiryKey) as? TimeInterval,
           Date().timeIntervalSince1970 > expiry,
           let refresh = KeychainStore.string(account: refreshAccount) {
            let task = Task { () throws -> String in
                let tokens = try await VKLiveAPIClient.refresh(refreshToken: refresh)
                try self.persist(tokens: tokens)
                return tokens.accessToken
            }
            refreshTask = task
            defer { refreshTask = nil }
            do {
                return try await task.value
            } catch let error as VKLiveAPIClient.APIError where error.isAuthRejected {
                // Refresh token is dead — show "signed out" instead of failing forever.
                signOut()
                throw error
            }
        }
        guard let token = KeychainStore.string(account: accessAccount) else {
            isSignedIn = false
            throw VKLiveAPIClient.APIError.http(401, "not signed in")
        }
        return token
    }
}
