import SwiftUI
#if canImport(UIKit)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Hub.shared.start()        // also when iOS starts the app in the background for the pendant
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Uploader.shared.backgroundCompletion = completionHandler
        Hub.shared.start()
        Uploader.shared.kick()
    }
}

@main
struct OmiCourierApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            StatusView().environmentObject(Hub.shared.status)
        }
    }
}
#endif
