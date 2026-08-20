import AppKit
import SwiftUI

/// Menu bar. Cmd-1..4 jump between the four places you actually go on X; the Filters
/// menu carries every toggle plus a live count of what has been hidden.
struct AppCommands: Commands {
    @ObservedObject private var model = BrowserModel.shared
    @ObservedObject private var settings = BrowserModel.shared.settings
    @ObservedObject private var stats = BrowserModel.shared.stats

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Post") { model.go(.compose) }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Open Current Page in Browser") { model.openCurrentPageInBrowser() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            Button("Home") { model.go(.home) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Notifications") { model.go(.notifications) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Messages") { model.go(.messages) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Bookmarks") { model.go(.bookmarks) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Explore") { model.go(.explore) }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
        }

        CommandMenu("Account") {
            Button("Sign in from Chrome\u{2026}") { model.signInFromChrome() }
            Button("Sign in manually") { model.signInManually() }
        }

        CommandGroup(after: .toolbar) {
            Button("Reload Page") { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandMenu("Filters") {
            Toggle("Hide Politics", isOn: $settings.politicsEnabled)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Toggle("Hide Engagement Bait", isOn: $settings.baitEnabled)
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Toggle("LLM Grading (Gemini)", isOn: $settings.llmEnabled)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.config.hasGeminiKey)

            Divider()

            Toggle("Hide Promoted Posts", isOn: $settings.hidePromoted)
            Toggle("Hide Right Sidebar", isOn: $settings.hideSidebar)
            Toggle("Following Feed Only", isOn: $settings.followingOnly)
            Toggle("Open Links in Default Browser", isOn: $settings.openLinksExternally)

            Divider()

            Text(stats.summary)
            if settings.llmEnabled {
                Text("LLM graded \(stats.llmGraded) · cached \(model.grader.cacheCount)")
            }
            if let status = stats.llmStatus {
                Text("LLM: \(status)")
            }
            if !model.config.hasGeminiKey {
                Text("LLM grading needs a key in ~/.config/twitter-mac/config.json")
            }

            Divider()

            Button("Reveal All Hidden Posts") { model.revealAllHidden() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Reload Filter Scripts") { model.reloadUserScripts() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Edit Filter Scripts…") { revealScripts() }
            Button("Edit Config…") { revealConfig() }
            Toggle("Debug Logging", isOn: $settings.debugLogging)
        }
    }

    private func revealScripts() {
        guard let dir = UserScripts.effectiveDirectory() else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    private func revealConfig() {
        AppConfig.createTemplateIfMissing()
        NSWorkspace.shared.selectFile(AppConfig.fileURL.path,
                                      inFileViewerRootedAtPath: AppConfig.directory.path)
    }
}
