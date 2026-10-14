import UIKit

@MainActor
enum OrientationHelper {
    static func setMask(_ mask: UIInterfaceOrientationMask, prefer preferred: UIInterfaceOrientation? = nil) {
        AppDelegate.orientationLock = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let orientations: UIInterfaceOrientationMask
        if let preferred {
            switch preferred {
            case .landscapeLeft: orientations = .landscapeLeft
            case .landscapeRight: orientations = .landscapeRight
            case .portrait: orientations = .portrait
            case .portraitUpsideDown: orientations = .portraitUpsideDown
            default: orientations = mask
            }
        } else {
            orientations = mask
        }

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
        scene.requestGeometryUpdate(preferences) { _ in }

        let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    static func lockLandscape() {
        setMask(.landscape, prefer: .landscapeRight)
    }

    static func lockPortrait() {
        setMask(.portrait, prefer: .portrait)
    }

    static func unlockAll() {
        setMask([.portrait, .landscapeLeft, .landscapeRight])
    }
}
