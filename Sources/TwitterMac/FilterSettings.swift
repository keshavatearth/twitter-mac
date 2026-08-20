import Foundation
import Combine

/// Persisted filter/declutter toggles. Every change is written to UserDefaults and
/// pushed into the live page through `onChange` (wired up by BrowserModel).
@MainActor
final class FilterSettings: ObservableObject {
    private enum Key {
        static let politics = "filter.politics"
        static let bait = "filter.bait"
        static let llm = "filter.llm"
        static let promoted = "declutter.hidePromoted"
        static let sidebar = "declutter.hideSidebar"
        static let following = "declutter.followingOnly"
        static let external = "nav.openLinksExternally"
        static let debug = "filter.debug"
        static let llmCap = "filter.llmMaxPerSession"
    }

    @Published var politicsEnabled: Bool { didSet { persist(politicsEnabled, Key.politics) } }
    @Published var baitEnabled: Bool { didSet { persist(baitEnabled, Key.bait) } }
    /// Optional LLM second opinion. Off by default: it costs money and needs a key.
    @Published var llmEnabled: Bool { didSet { persist(llmEnabled, Key.llm) } }
    @Published var hidePromoted: Bool { didSet { persist(hidePromoted, Key.promoted) } }
    @Published var hideSidebar: Bool { didSet { persist(hideSidebar, Key.sidebar) } }
    @Published var followingOnly: Bool { didSet { persist(followingOnly, Key.following) } }
    @Published var openLinksExternally: Bool { didSet { persist(openLinksExternally, Key.external) } }
    @Published var debugLogging: Bool { didSet { persist(debugLogging, Key.debug) } }

    /// Hard ceiling on LLM calls per launch, so a long scroll session can't quietly
    /// run up an API bill. Editable in UserDefaults, not exposed in the menu.
    let llmMaxPerSession: Int

    /// Called after any toggle changes.
    var onChange: (() -> Void)?

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.politics: true,
            Key.bait: true,
            Key.llm: false,
            Key.promoted: true,
            Key.sidebar: false,
            Key.following: false,
            Key.external: true,
            Key.debug: false,
            Key.llmCap: 200
        ])
        politicsEnabled = d.bool(forKey: Key.politics)
        baitEnabled = d.bool(forKey: Key.bait)
        llmEnabled = d.bool(forKey: Key.llm)
        hidePromoted = d.bool(forKey: Key.promoted)
        hideSidebar = d.bool(forKey: Key.sidebar)
        followingOnly = d.bool(forKey: Key.following)
        openLinksExternally = d.bool(forKey: Key.external)
        debugLogging = d.bool(forKey: Key.debug)
        llmMaxPerSession = max(0, d.integer(forKey: Key.llmCap))
    }

    private func persist(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }

    /// The object handed to page JS as `window.__tmacSettings`.
    var jsPayload: [String: Any] {
        [
            "politicsEnabled": politicsEnabled,
            "baitEnabled": baitEnabled,
            "llmEnabled": llmEnabled,
            "hidePromoted": hidePromoted,
            "hideSidebar": hideSidebar,
            "followingOnly": followingOnly,
            "debug": debugLogging,
            "llmMaxPerSession": llmMaxPerSession
        ]
    }

    var jsPayloadJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsPayload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }
}

/// Volatile per-session counters reported by the page, shown in the Filters menu.
@MainActor
final class FilterStats: ObservableObject {
    @Published var scanned = 0
    @Published var hidden = 0
    @Published var byReason: [String: Int] = [:]
    /// Last LLM error, surfaced in the menu instead of failing silently.
    @Published var llmStatus: String?
    @Published var llmGraded = 0

    var summary: String {
        guard hidden > 0 else { return "Nothing hidden yet (\(scanned) scanned)" }
        let parts = byReason
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
        return "Hidden \(hidden) of \(scanned): " + parts.joined(separator: ", ")
    }

    func reset() {
        scanned = 0
        hidden = 0
        byReason = [:]
    }
}
