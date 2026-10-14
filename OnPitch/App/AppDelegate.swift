import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Default to landscape for horizontal football streaming.
    static var orientationLock: UIInterfaceOrientationMask = .landscape

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
        // Ask the system to prefer landscape as soon as the app launches.
        DispatchQueue.main.async {
            OrientationHelper.lockLandscape()
        }
        return true
    }
}
