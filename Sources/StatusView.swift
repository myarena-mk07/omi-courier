import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct StatusView: View {
    @EnvironmentObject var status: Status

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Pendant")) {
                    row("Link", status.link)
                    row("Battery", status.battery.map { "\($0) %" } ?? "-")
                    row("Firmware", status.firmware.isEmpty ? "-" : status.firmware)
                    row("Last audio", time(status.lastAudio))
                }
                Section(header: Text("Upload to the Mac mini")) {
                    row("Files that wait", "\(status.pendingFiles)")
                    row("Files sent", "\(status.uploadedFiles)")
                    row("Last upload", time(status.lastUpload))
                    if !status.lastError.isEmpty { row("Last fault", status.lastError) }
                }
                Section(header: Text("Server")) {
                    row("Address", status.serverSet ? "set" : "not set")
                    #if canImport(UIKit)
                    Button("Paste the setup text") {
                        if let text = UIPasteboard.general.string, Settings.accept(text) {
                            status.serverSet = true
                            Uploader.shared.kick()
                            Hub.shared.beat(force: true)
                        }
                    }
                    #endif
                }
                Section(header: Text("App")) {
                    row("First signature ends", time(status.signatureEnd))
                    row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                }
            }
            .navigationTitle("Omi Courier")
            .onAppear { status.serverSet = Settings.baseURL != nil }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func time(_ date: Date?) -> String {
        guard let date = date else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
