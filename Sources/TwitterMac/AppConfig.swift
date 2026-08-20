import Foundation

/// Runtime configuration read from `~/.config/twitter-mac/config.json`.
///
/// Secrets live here and nowhere else — never in the repo, never in the .app bundle,
/// and never handed to page JavaScript. The Gemini call is made by GeminiGrader on
/// the native side precisely so the key stays out of x.com's JS context.
struct AppConfig {
    var geminiAPIKey: String = ""
    var geminiModel: String = "gemini-2.5-flash"
    /// Overrides the whole User-Agent string. Empty = let WebKit build a Safari UA.
    var userAgent: String = ""

    var hasGeminiKey: Bool { !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("twitter-mac", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// User-editable copies of the filter scripts; these win over the bundled ones.
    static var userScriptsOverrideDirectory: URL {
        directory.appendingPathComponent("userscripts", isDirectory: true)
    }

    static func load() -> AppConfig {
        var config = AppConfig()
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }

        if let key = json["GEMINI_API_KEY"] as? String { config.geminiAPIKey = key }
        if let model = (json["GEMINI_MODEL"] as? String), !model.isEmpty { config.geminiModel = model }
        if let ua = json["USER_AGENT"] as? String { config.userAgent = ua }
        return config
    }

    /// Writes a key-less template on first launch. Never overwrites an existing file.
    @discardableResult
    static func createTemplateIfMissing() -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return false }
        let template = """
        {
          "GEMINI_API_KEY": "",
          "GEMINI_MODEL": "gemini-2.5-flash",
          "USER_AGENT": ""
        }

        """
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try template.data(using: .utf8)!.write(to: fileURL, options: .withoutOverwriting)
            // Owner-only: this file is where an API key will land.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("TwitterMac: could not create \(fileURL.path): \(error)")
            return false
        }
    }

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("TwitterMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
