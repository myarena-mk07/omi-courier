import AppIntents
import Foundation

/// An action for the Shortcuts app. An automation can run it, for example each morning or when the charger is
/// connected. It starts the app in the background and connects to the pendant again. This also works after
/// the app was closed with a swipe. It shows no window.
@available(iOS 16.0, macOS 13.0, *)
struct StartCourierIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Omi Courier"
    static var description = IntentDescription("Starts the link to the pendant again, also after the app was closed.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        Hub.shared.start()
        Hub.shared.beat(force: true)
        Log.write("started by the Shortcuts action")
        try? await Task.sleep(nanoseconds: 4_000_000_000)     // time to connect before iOS lets the app sleep
        return .result()
    }
}
