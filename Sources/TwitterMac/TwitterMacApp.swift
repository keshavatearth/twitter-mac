import AppKit
import SwiftUI
import WebKit

struct TwitterMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("TwitterMac", id: "main") {
            BrowserView()
        }
        .commands { AppCommands() }
    }
}

/// Hands SwiftUI the one long-lived WKWebView. Creating it here instead would risk a
/// re-render replacing the view and dropping the logged-in session.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject private var model = BrowserModel.shared
    @ObservedObject private var stats = BrowserModel.shared.stats

    var body: some View {
        WebViewHost(webView: model.webView)
            .frame(minWidth: 760, minHeight: 520)
            .navigationTitle(model.pageTitle)
            .navigationSubtitle(stats.hidden > 0 ? "\(stats.hidden) hidden" : "")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var zoomMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfig.createTemplateIfMissing()
        let model = BrowserModel.shared
        model.loadInitialPage()

        if let window = NSApp.windows.first {
            window.setFrameAutosaveName("TwitterMacMainWindow")
            window.isRestorable = true
            window.tabbingMode = .disallowed
            if window.frame.width < 800 {
                window.setContentSize(NSSize(width: 1180, height: 820))
                window.center()
            }
        }

        // A menu item with key equivalent "+" only fires for Cmd-Shift-=, but everyone
        // types Cmd-= for zoom in. Catch the unshifted variant here.
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "="
            else { return event }
            BrowserModel.shared.zoomIn()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserModel.shared.grader.saveCache()
        if let monitor = zoomMonitor { NSEvent.removeMonitor(monitor) }
    }
}
