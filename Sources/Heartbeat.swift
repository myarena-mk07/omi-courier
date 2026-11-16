import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A small status message to the Mac mini, so that the Mac mini can see when something stops. Wi-Fi only.
enum Heartbeat {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func send(status: Status) {
        DispatchQueue.main.async {
            let info = Bundle.main.infoDictionary
            var body: [String: Any] = [
                "app": "omi-courier",
                "version": info?["CFBundleShortVersionString"] as? String ?? "",
                "build": info?["CFBundleVersion"] as? String ?? "",
                "link": status.link,
                "firmware": status.firmware,
                "pending_files": Uploader.outboxFiles().count,
                "uploaded_files": status.uploadedFiles,
                "last_error": status.lastError,
                "sent": Date().timeIntervalSince1970,
            ]
            if let value = status.battery { body["pendant_battery"] = value }
            if let value = status.lastAudio { body["last_audio"] = value.timeIntervalSince1970 }
            if let value = status.lastUpload { body["last_upload"] = value.timeIntervalSince1970 }
            if let value = status.signatureEnd { body["first_signature_end"] = value.timeIntervalSince1970 }
            #if canImport(UIKit)
            body["ios"] = UIDevice.current.systemVersion
            #endif
            guard let url = Settings.url("_status"),
                  let data = try? JSONSerialization.data(withJSONObject: body) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            session.dataTask(with: request).resume()
        }
    }
}
