import AuthenticationServices
import Foundation
import UIKit

/// `ASWebAuthenticationSession` behind async/await — shared by VK Live and Twitch sign-in.
@MainActor
final class WebAuthSession: NSObject {
    enum WebAuthError: LocalizedError {
        case couldNotStart
        case noCallback

        var errorDescription: String? {
            switch self {
            case .couldNotStart: return String(localized: "Could not open the sign-in sheet")
            case .noCallback: return String(localized: "Sign-in returned no result")
            }
        }
    }

    /// Kept alive for the duration of the sheet.
    private var session: ASWebAuthenticationSession?

    /// Opens the sign-in sheet and returns the callback URL (`scheme://…`).
    /// Throws `ASWebAuthenticationSessionError.canceledLogin` when the user dismisses it.
    func start(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let completion: ASWebAuthenticationSession.CompletionHandler = { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: WebAuthError.noCallback)
                }
            }
            let session: ASWebAuthenticationSession
            if #available(iOS 17.4, *) {
                session = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(callbackScheme),
                    completionHandler: completion
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme,
                    completionHandler: completion
                )
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: WebAuthError.couldNotStart)
            }
        }
    }
}

extension WebAuthSession: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        if let key = windows.first(where: \.isKeyWindow) { return key }
        if let visible = windows.first(where: { !$0.isHidden && $0.alpha > 0 }) { return visible }
        return windows.first ?? ASPresentationAnchor()
    }
}

extension Bundle {
    /// Non-empty Info.plist string that isn't the `YOUR_…` placeholder.
    func configValue(_ key: String, placeholder: String) -> String? {
        guard let raw = object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == placeholder ? nil : value
    }
}
