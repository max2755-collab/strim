import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Prep screens are portrait on iPhone; the camera screen locks landscape itself.
    /// (iPad is unlocked by `OrientationHelper.lockForPrep()` when the home screen appears.)
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Warm RTMP factories during launch so Live isn't blocked on first open.
        StreamingBootstrap.shared.startIfNeeded()
        return true
    }
}
