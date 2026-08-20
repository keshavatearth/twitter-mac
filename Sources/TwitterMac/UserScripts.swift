import Foundation
import WebKit

/// Locates and loads the filter JavaScript.
///
/// Resolution order per file, first hit wins:
///   1. `~/.config/twitter-mac/userscripts/<name>`  (user override — edit freely)
///   2. `$TWITTERMAC_USERSCRIPTS/<name>`            (dev/CI override)
///   3. `TwitterMac.app/Contents/Resources/userscripts/<name>`
///   4. `<repo>/Resources/userscripts/<name>`       (found by walking up from the binary,
///                                                   so `swift run` works without a bundle)
enum UserScripts {
    /// Injection order matters: core defines the engine, classifiers register into it,
    /// boot starts it once everything is present.
    static let order = [
        "10-core.js",
        "20-politics.js",
        "30-engagement-bait.js",
        "40-declutter.js",
        "90-boot.js"
    ]

    static let gradingInstructionsFile = "grading_instructions.txt"

    static func searchDirectories() -> [URL] {
        var dirs: [URL] = [AppConfig.userScriptsOverrideDirectory]
        if let env = ProcessInfo.processInfo.environment["TWITTERMAC_USERSCRIPTS"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("userscripts", isDirectory: true))
        }
        var probe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<7 {
            dirs.append(probe.appendingPathComponent("Resources/userscripts", isDirectory: true))
            probe = probe.deletingLastPathComponent()
        }
        return dirs
    }

    static func url(for name: String) -> URL? {
        for dir in searchDirectories() {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func source(for name: String) -> String? {
        guard let url = url(for: name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func gradingInstructions() -> String {
        source(for: gradingInstructionsFile) ?? """
        You are a tweet analyzer. Respond with ONLY "blocked" or "not_blocked". \
        Block clickbait, engagement bait, viral trends, and low-quality viral content.
        """
    }

    /// The directory the bundled scripts actually came from, for "Reveal in Finder".
    static func effectiveDirectory() -> URL? {
        url(for: order[0])?.deletingLastPathComponent()
    }

    /// Every WKUserScript to install, in order. `settings` is injected at documentStart
    /// so the engine sees its configuration before it runs at documentEnd.
    static func makeUserScripts(settingsJSON: String) -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            WKUserScript(
                source: "window.__tmacSettings = \(settingsJSON);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        ]
        for name in order {
            guard let src = source(for: name) else {
                NSLog("TwitterMac: missing user script \(name) — searched \(searchDirectories().map(\.path))")
                continue
            }
            scripts.append(WKUserScript(
                source: src,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        return scripts
    }
}
