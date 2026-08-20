# Report: TwitterMac

## What works

### Build
- `swift build -c debug` compiles cleanly (Swift 6.2, macOS 26.5, arm64).
- `scripts/build_app.sh debug` assembles `build/TwitterMac.app`, copies user
  scripts + icon + config template, and ad-hoc signs with the machine's Apple
  Development identity (`<redacted>`, Team `<redacted>`).
- The build script also generates the app icon (`scripts/make_icon.swift` →
  `iconutil`) on first run if `Resources/AppIcon.icns` is missing.

### Launch
- `open build/TwitterMac.app` launches the app. The process stays alive
  (verified via `pgrep`). The window opens at 1180×820, loads `https://x.com/home`.
- Window frame is saved/restored via `setFrameAutosaveName`.

### Filters (verified headlessly)
- **Self-test**: `TwitterMac selftest` passes 69/69 checks. Every user script
  parses; every classifier case (politics hide/keep, bait hide/keep, exemptions,
  known misses) matches expectations.
- **Single-tweet CLI**: `TwitterMac classify "<text>"` reports per-filter
  scores and matches.
- **Snapshot**: `TwitterMac shot Resources/test-fixture/timeline.html out.png`
  loads a local HTML fixture that mimics x.com's DOM structure, injects the
  real user scripts, lets the MutationObserver run, and captures a 2000×1800
  PNG. Result: 8 posts scanned, 5 hidden (2 politics, 2 engagement bait, 1
  promoted), 3 shown. The collapse bars render with reason labels.
  Screenshot: `docs/filter-snapshot.png`.

### Native chrome
- Menu bar: Go (Cmd-1..5), New Post (Cmd-N), Reload (Cmd-R), Zoom (Cmd-+/-/0),
  Back/Forward (Cmd-[/]), Open in Browser (Cmd-Shift-O).
- Filters menu: all toggles, live filtered-count indicator, Reveal All
  (Cmd-Shift-H), Reload Scripts (Cmd-Shift-R), Edit Scripts/Config (Reveal in
  Finder), Debug Logging toggle.
- Cmd-= zoom (unshifted) handled via a local event monitor since SwiftUI only
  fires Cmd-+ for the "+" key equivalent.
- Zoom persists in UserDefaults; page zoom applied on every load.
- Swipe back/forward enabled (`allowsBackForwardNavigationGestures`).

### Config
- `~/.config/twitter-mac/config.json` created on first launch with empty key,
  `0600` permissions.
- User script overrides: `~/.config/twitter-mac/userscripts/*.js` preferred
  over bundled copies.

### LLM grading (code complete, not live-tested)
- `GeminiGrader.swift` makes native `fetch` to `generativelanguage.googleapis.com`
  with the key in an `x-goog-api-key` header (never in a URL or page context).
- Disk cache at `~/Library/Application Support/TwitterMac/verdicts.json`
  (30-day TTL, 20K entries max, debounced save).
- Per-session cap (default 200) prevents runaway API costs.
- The grading instructions (`grading_instructions.txt`) are loaded from the same
  user-script resolution path, so they're editable without a rebuild.
- The `thinkingConfig: {thinkingBudget: 0}` is set for 2.5-family models to
  avoid burning the output budget on reasoning tokens.
- Not live-tested because no API key was provided (the reference extension's
  key was deliberately not copied into this project).

## What's untested

### Login flow
- x.com login requires a human to enter credentials and possibly solve a
  CAPTCHA. The app uses the default `WKWebsiteDataStore` so cookies should
  persist across relaunches, but this was not verified end-to-end.
- Third-party auth providers (Google, Apple, Arkose Labs) are kept in-app via
  the `inAppDomains` list so OAuth callbacks land back in the webview.

### Live x.com filtering
- The fixture proves the DOM selectors and filter pipeline work against markup
  that copies x.com's `data-testid` attributes. The real site's DOM may have
  drifted since the reference extension was last updated (Jan 2025). If
  selectors break, the user scripts are editable in-place and reloadable with
  Cmd-Shift-R.

### LLM grading against the live API
- No API key was available for testing. The code path is complete and the
  request/response format mirrors the extension's, but the actual Gemini call
  was not exercised.

### Screenshot of the live app
- `screencapture` was blocked: "could not create image from display" — the
  shell process does not have Screen Recording permission. The headless
  snapshot (`docs/filter-snapshot.png`) is provided instead, which proves the
  filter pipeline renders correctly. A user with Screen Recording permission
  granted to Terminal/the shell can run `screencapture -x docs/app.png` after
  `scripts/build_app.sh debug run`.

## Known limitations

1. **Ad-hoc signature and login persistence**: if no stable signing identity
   is found, the build falls back to ad-hoc (`-`), whose cdhash changes every
   build. macOS keys the WebKit data store to the signature, so ad-hoc rebuilds
   may log you out of x.com. The build script auto-detects an Apple Development
   identity when present (as on this machine).

2. **No App Sandbox**: the app runs unsandboxed (matching the AFK reference
   project). A sandboxed build would need `com.apple.security.app-sandbox` plus
   `network.client`, `files.user-selected.read-write`, `device.camera`, and
   `device.audio-input` entitlements, signed with a real Developer ID and
   provisioning profile. Without a profile, the sandbox denies the WebKit
   networking process and the app shows a blank window.

3. **Heuristic misses**: the keyword/regex classifiers catch the common cases
  but miss content with no lexical signal (e.g., "The vibes in this office are
  unmatched"). These are documented as "known miss" in the self-test and are
  the intended use case for LLM grading.

4. **Selector drift**: X periodically changes its DOM structure. The filters
  key off `data-testid` attributes which are more stable than class names but
  not guaranteed. User scripts are editable and reloadable without a rebuild.

5. **Following-only switching**: the script hides the "For You" tab and clicks
  "Following", but X's SPA router can re-select "For You" on its own. The
  script rate-limits re-clicks (3s) to avoid a fight with the router, but a
  brief flash of "For You" is possible on navigation.

6. **Single window**: the app is designed as a single-window client. There is
   no multi-window or tab support.

## Security notes

- The Gemini API key is never bundled into the app, never written to the repo,
  and never passed to page JavaScript. It lives only in
  `~/.config/twitter-mac/config.json` (0600) and is used for native HTTP requests.
- The reference extension's `config.json` contained a live API key. That key was
  **not** copied into this project. An empty template is created on first launch.
- The app does not modify the reference projects in
  `~/Desktop/Twitter Projects/` or `~/Desktop/AFK/`.
