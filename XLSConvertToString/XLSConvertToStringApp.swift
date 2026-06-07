import Cocoa
import SwiftUI

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct XLSConvertToStringApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainContentView()
        }
    }
}
