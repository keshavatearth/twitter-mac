# TwitterMac

> **Retired, November 2026.** Kept as a record and not maintained. The files date
> from 20 August 2026. The folder was never under Git, so the first commit here is an
> import dated to that day. `REPORT.md` has the code-signing identity and team ID
> removed. The filters were ported from
> [twitter-politics-filter](https://github.com/keshavatearth/twitter-politics-filter).

A native macOS client for Twitter/X: a WKWebView shell around x.com with content
filters injected, plus native Mac ergonomics. Built with SwiftPM + SwiftUI, no
Xcode project, no full Xcode required.

## What it is

- A SwiftUI app (`TwitterMac`) with a single window containing a `WKWebView`
  loading `https://x.com`.
- Persistent login via the default `WKWebsiteDataStore` — cookies survive relaunch.
- Swipe and keyboard back/forward navigation.
- Injected user scripts (WKUserScript + MutationObserver) that port the
  "Twitter Politics Filter" Chrome extension's DOM-detection and filtering logic:
  - **Politics filter**: heuristic keyword pass (weighted STRONG/MEDIUM/EXEMPT lists).
  - **Engagement-bait filter**: regex patterns encoding the blocking criteria from
    `grading_instructions.txt`.
  - **Optional LLM grading**: calls the Gemini API for a second opinion on tweets
    that pass the heuristics. Off by default, key read from config.
- Filtered tweets collapse to a thin "hidden (reason)" bar — click to reveal.
  Nothing is ever deleted from the DOM.
- Verdicts cached by tweet ID so the same tweet isn't re-graded.
- Declutter toggles (each a menu item, persisted in UserDefaults):
  - Hide promoted posts
  - Hide right sidebar (trends / who-to-follow)
  - Following feed only (hide "For You" tab, default to Following)

## Build and run

```sh
# Build, assemble the .app bundle, ad-hoc sign, and launch:
scripts/build_app.sh debug run

# Build only (no launch):
scripts/build_app.sh debug

# Release build:
scripts/build_app.sh release

# Build then run the headless filter self-test:
scripts/build_app.sh debug test
```

The build uses only the SwiftPM Command Line Tools — `swift build`, then
hand-assembles `build/TwitterMac.app`, copies the user scripts and icon into the
bundle, and ad-hoc (or Developer ID) codesigns it.

If a stable codesigning identity is found on the machine (Apple Development /
Developer ID), the build uses it so the WebKit data store and TCC grants persist
across rebuilds. Otherwise it falls back to ad-hoc (`-`), which works but may
reset x.com login on each rebuild.

## Config

```
~/.config/twitter-mac/config.json
```

The app creates this file with an empty key on first launch. Edit it to enable
LLM grading:

```json
{
  "GEMINI_API_KEY": "your-key-here",
  "GEMINI_MODEL": "gemini-2.5-flash",
  "USER_AGENT": ""
}
```

- `GEMINI_API_KEY`: needed only for LLM grading. The key is never bundled into
  the app or handed to page JavaScript — the Gemini call is made natively by
  `GeminiGrader.swift`.
- `GEMINI_MODEL`: defaults to `gemini-2.5-flash`. Any `generateContent` model works.
- `USER_AGENT`: optional custom User-Agent. Empty = WebKit's default Safari UA.

The file is created with `0600` permissions (owner-only).

### User script overrides

Filter scripts can be overridden without touching the bundle:

```
~/.config/twitter-mac/userscripts/10-core.js
~/.config/twitter-mac/userscripts/20-politics.js
...
```

Copy a file from `Resources/userscripts/` into that directory, edit it, and
use **Filters > Reload Filter Scripts** (Cmd-Shift-R) to re-inject. The app
prefers files in `~/.config/twitter-mac/userscripts/` over the bundled copies.

The `TWITTERMAC_USERSCRIPTS` environment variable also works (for dev/CI).

## How filters work

1. At `documentStart`, `window.__tmacSettings` is injected with the current
   toggle state.
2. At `documentEnd`, the filter scripts run in order:
   - `10-core.js` — the engine: MutationObserver, tweet scanning, collapse UI,
     verdict cache, stats reporting, LLM request bridge.
   - `20-politics.js` — registers a politics classifier (weighted keyword match).
   - `30-engagement-bait.js` — registers an engagement-bait classifier (regex).
   - `40-declutter.js` — sidebar hiding, Following-only tab switching.
   - `90-boot.js` — starts the engine once all classifiers are registered.
3. The MutationObserver watches for `article[data-testid="tweet"]` nodes added
   by X's infinite scroll. Each tweet is classified:
   - Promoted posts are collapsed immediately (if the toggle is on).
   - The text classifiers score the tweet. If any classifier's score meets its
     threshold, the tweet is collapsed with a reason label.
   - If heuristics say "fine" and LLM grading is on, the tweet text is sent to
     the native side for a Gemini call. The verdict is cached and applied.
4. Collapsed tweets show a thin bar: "hidden (politics)" / "hidden (engagement
   bait)" / "hidden (promoted)" / "hidden (llm)". Click the bar to reveal the
   tweet. Click again to re-hide.
5. Verdicts are cached by tweet ID in memory (page) and on disk (LLM), so
   scrolling past the same tweet twice never re-grades it.

### Scoring

**Politics** (threshold 3): STRONG terms (Trump, BJP, Gaza, etc.) add 3 each.
MEDIUM terms (president, election, protest) add 2 each. EXEMPT phrases
("conservative estimate", "liberal arts") subtract 3.

**Engagement bait** (threshold 3): STRONG patterns (clickbait, "give me one
reason", "RT if", viral trends, spam, sensationalism) add 3 each. WEAK patterns
(thread, emoji spam, ALL-CAPS) add 1 each. EXEMPT patterns (announcing, hiring,
paper, benchmark) subtract 3.

### LLM grading

When enabled, tweets that pass the heuristics are sent to Gemini with the
grading instructions from `grading_instructions.txt`. The model responds with
"blocked" or "not_blocked". Verdicts are cached on disk at
`~/Library/Application Support/TwitterMac/verdicts.json` (30-day TTL, 20K entries
max). A per-session cap (default 200, configurable via
`filter.llmMaxPerSession` in UserDefaults) prevents runaway API costs.

## Keyboard map

| Shortcut | Action |
|---|---|
| Cmd-1 | Home |
| Cmd-2 | Notifications |
| Cmd-3 | Messages |
| Cmd-4 | Bookmarks |
| Cmd-5 | Explore |
| Cmd-N | New Post (compose) |
| Cmd-R | Reload page |
| Cmd-+ | Zoom in |
| Cmd-= | Zoom in (unshifted) |
| Cmd-- | Zoom out |
| Cmd-0 | Reset zoom |
| Cmd-[ | Back |
| Cmd-] | Forward |
| Cmd-Shift-O | Open current page in default browser |
| Cmd-Shift-P | Toggle politics filter |
| Cmd-Shift-E | Toggle engagement-bait filter |
| Cmd-Shift-L | Toggle LLM grading |
| Cmd-Shift-H | Reveal all hidden posts |
| Cmd-Shift-R | Reload filter scripts (re-read from disk) |

Swipe left/right with two fingers also navigates back/forward.

## Headless tools

```sh
# Run the filter test suite (parses every script + asserts classifier verdicts):
.build/debug/TwitterMac selftest

# Score a single tweet against both filters:
.build/debug/TwitterMac classify "Trump announces new tariffs"

# Snapshot a local HTML file with filters applied (no login needed):
.build/debug/TwitterMac shot Resources/test-fixture/timeline.html out.png
```

## Project layout

```
twitter-mac/
  Package.swift                  SwiftPM package (single executable target)
  Sources/TwitterMac/
    Main.swift                   Entry point: routes selftest/classify/shot/launch
    TwitterMacApp.swift          SwiftUI app + AppDelegate
    AppCommands.swift            Menu bar (Go, Filters, zoom, navigation)
    BrowserModel.swift           WKWebView owner, navigation/UI/download delegates, page bridge
    UserScripts.swift            Locates + loads user scripts (override dirs, bundle, repo)
    GeminiGrader.swift           Optional LLM grading (native Gemini API call)
    AppConfig.swift             ~/.config/twitter-mac/config.json loader
    FilterSettings.swift         Persisted toggles + volatile stats
    SelfTest.swift               Headless filter test harness (JavaScriptCore)
    Snapshot.swift               Headless WKWebView snapshot mode
  Resources/
    Info.plist
    userscripts/                 Editable filter JS (shipped loose, not compiled)
      10-core.js                 Engine: MutationObserver, collapse UI, verdict cache
      20-politics.js             Politics keyword classifier
      30-engagement-bait.js      Engagement-bait regex classifier
      40-declutter.js            Sidebar hiding, Following-only switching
      90-boot.js                 Starts the engine
      grading_instructions.txt  System prompt for LLM grading
    config.example.json          Template for ~/.config/twitter-mac/config.json
    test-fixture/
      timeline.html              Offline x.com stand-in for snapshot testing
  scripts/
    build_app.sh                 Build, bundle, sign, (optionally) launch
    make_icon.swift              Renders AppIcon.icns (funnel on X-blue badge)
  TwitterMac.entitlements        No sandbox; network + camera + mic
  build/
    TwitterMac.app               The assembled app (after build)
```
