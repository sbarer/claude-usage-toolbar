# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

```bash
# Build
xcodebuild -project ClaudeUsageToolbar.xcodeproj -scheme ClaudeUsageToolbar -configuration Debug build

# Launch (Claude.app must be running, or the app self-terminates by design)
open "$(xcodebuild -project ClaudeUsageToolbar.xcodeproj -scheme ClaudeUsageToolbar -showBuildSettings 2>/dev/null | awk '/^[[:space:]]*BUILT_PRODUCTS_DIR/{print $3}')/ClaudeUsageToolbar.app"

# Tail logs (NSLog goes through stderr when launched from a terminal)
"$BUILT_PRODUCTS_DIR/ClaudeUsageToolbar.app/Contents/MacOS/ClaudeUsageToolbar"
```

There are no tests, no linter config, no package manager — just `xcodebuild`. The `project.pbxproj` was hand-written and is intentionally minimal; if Xcode rewrites it, diff carefully before committing.

## Source layout

```
App/
  ClaudeUsageToolbarApp.swift   @main entry point (SwiftUI App wrapper only)
  AppDelegate.swift             lifecycle orchestration (@MainActor)
  ClaudeUsageOpener.swift       opens claude://usage + activates Claude.app
MenuBar/
  MenuBarController.swift       owns NSStatusItem, renders UsageState, dispatches clicks
  MenuBarMenuBuilder.swift      builds the Option+click NSMenu from state + callbacks
  MenuBarLabel.swift            attributed-string helpers, hotThreshold, hotBackground
Usage/
  UsageState.swift              value type passed to the UI layer; Kind.ok carries OkData struct
  UsageMonitor.swift            @MainActor polling loop + adaptive timer + weekly-alert gating
  UsageAPI.swift                async HTTP fetch logic
  UsageResponse.swift           parsed response model (fiveHour / sevenDay buckets)
  UsageFetchResult.swift        enum: success / unauthenticated / rateLimited / failure
  UsageAPIDebugLog.swift        appends recent call records to the Logs/ directory
Security/
  KeychainTokenStore.swift      reads "Claude Code-credentials" from Keychain (async, in-memory cache only)
  ClaudeCookieStore.swift       reads + decrypts claude.ai session cookies from Chrome-format SQLite DB
System/
  ActivityWatcher.swift         FSEventStream on ~/.claude/projects/ → stamps lastActivityAt
  ClaudeAppLifecycle.swift      watches for Claude.app termination
  LaunchAgentInstaller.swift    writes + bootstraps ~/Library/LaunchAgents plist
Alerts/
  WeeklyAlert.swift             modal alert on rising edge at 90% weekly usage
```

## Architecture

A `LSUIElement=YES` menubar-only app with no SwiftUI scenes. The `App` body is `Settings { EmptyView() }` purely to satisfy the protocol; the real entry point is `AppDelegate.applicationDidFinishLaunching`, which:
1. Installs the launchd agent (`LaunchAgentInstaller`).
2. Checks if `com.anthropic.claudefordesktop` is running (`ClaudeAppLifecycle`); terminates immediately if not.
3. Creates `MenuBarController` (which owns the `NSStatusItem`) and wires it to a fetch loop driven by `UsageMonitor`. Left-click opens Claude usage via `ClaudeUsageOpener`; **Option+click** calls `MenuBarMenuBuilder.build(...)` and shows the resulting menu — session/weekly usage, reset countdowns, last-fetched time, and Restart/Quit actions.
4. Calls `KeychainTokenStore.requestAccess()` (async) to pre-warm the token cache and prompt Keychain access before the first fetch.
5. Subscribes to `NSWorkspace.didWakeNotification` for sleep/wake refresh and `didTerminateApplicationNotification` to self-terminate when Claude.app quits.

### Data source

Primary: the **claude.ai web API** (`https://claude.ai/api/organizations/<orgId>/usage`), authenticated via cookies read from the Chrome-format SQLite DB at `~/Library/Application Support/Claude/Cookies`. `ClaudeCookieStore` decrypts the AES-encrypted cookie values using the key from `Claude Safe Storage` in the Keychain (Chromium PBKDF2-SHA1 scheme).

Fallback: the **undocumented OAuth endpoint** `https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20`. The bearer token comes from the macOS Keychain service `Claude Code-credentials`, written by the `claude` CLI. `KeychainTokenStore` handles both raw-string and JSON-wrapped (`accessToken` / `claudeAiOauth.accessToken` fields) forms.

On 401/403 the cookie path falls back to OAuth automatically. On 401/403 the OAuth path invalidates the in-memory token cache.

**Important gotcha**: the API returns percentages as **0–100 doubles**, not 0–1 utilization fractions. Don't multiply by 100 in `UsageMonitor`. `UsageAPI.extractBucket` accepts several key aliases (`five_hour`/`fiveHour`/`session`/...) defensively — if the response shape shifts, add to the alias list rather than rewriting.

**API response shape varies**: sometimes buckets are nested objects with `resets_at` dates, sometimes they're plain doubles (no reset date). The parser handles both, but reset countdowns will only display when the object form is returned.

### Concurrency model

`UsageMonitor` is `@MainActor`. All mutable state lives on the main actor. `UsageAPI.fetch` is `async` and runs off-main (URLSession cooperative thread); when it returns, `handleFetchResult` executes back on main. An `isFetching` bool guards against overlapping in-flight requests (checked + set synchronously on main before the first suspension point).

`KeychainTokenStore` uses a private serial `DispatchQueue` internally and exposes `async throws` functions via `withCheckedThrowingContinuation`. `AppDelegate` is `@MainActor`.

### Adaptive polling & activity

`ActivityWatcher` opens an `FSEventStream` on `~/.claude/projects/`, `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig`, and `~/.vscode/globalStorage/anthropic.claude-code`, and stamps `lastActivityAt` on any JSONL mtime change. `UsageMonitor.currentInterval()` returns:

- **15s** — last activity < 60s ago (very active)
- **60s** — last activity < 1h ago (normal)
- **300s** — idle

FSEvents also trigger an immediate (debounced 5s) fetch and reschedule the timer — that's the "active again" path. 429 responses are surfaced as `.rateLimited` and *do not* update display state.

### Lifecycle (start with Claude / quit with Claude)

`NSApp.terminate` runs the moment Claude.app's termination notification fires. To re-launch, the app installs `~/Library/LaunchAgents/com.simonbarer.claude-usage-toolbar.plist` with `StartInterval=5`. The plist invokes a small shell script (written to `~/Library/Application Support/ClaudeUsageToolbar/launch.sh`) that does `pgrep Claude && pgrep -v ClaudeUsageToolbar && open -gj <APP_PATH>`.

**`<APP_PATH>` is captured from `Bundle.main.bundleURL` at install time.** If the `.app` is moved after first launch, the LaunchAgent script will reference the stale path. Solution: launch the app once from its new location — the installer rewrites the script (via `writeIfChanged`) and `bootout`/`bootstrap`s the agent.

### Weekly alert

`UsageMonitor.maybeFireWeeklyAlert` fires `WeeklyAlert.show` only on the rising edge (`newWeekly >= 90 && lastKnownWeeklyPercent < 90`). The check reads `lastKnownWeeklyPercent` (the previous fetch's value) **before** updating it, so the field serves double duty as both the display carry-over value and the edge-detection baseline. Per-week dedup uses `UserDefaults` keyed by the ISO-formatted `resets_at` value — the same reset-window string won't re-alert even after restarts.

### Menu bar display

`MenuBarController` owns the `NSStatusItem` and calls `MenuBarLabel` helpers to compute attributed strings. The button background is colored via its layer (not via `.backgroundColor` on the attributed string — that only covers glyphs, not the full button). At 100% session usage, the label switches from percentage to a countdown (`H:MM`) until the session resets. `isHot` controls whether the layer gets the red background color (`hotBackground`). Don't use `sizeToFit()` removal or `.backgroundColor` on attributed strings — those were tried and don't work correctly with `NSStatusBarButton`.

`MenuBarMenuBuilder.build(stateProvider:lastFetchAtProvider:onQuit:onOpenDebugLog:onForceFetch:)` constructs the Option+click menu. Menu items that need actions use the private `ClosureMenuItem` helper (holds a closure, acts as its own `@objc` target) to avoid needing `@objc` selectors on `AppDelegate`. `UsageMonitor.lastFetchAt` is stamped at the start of each `performFetch` call and shown as "Last fetched Xs ago / Xm Xs ago / Xh Xm ago" — the 2nd item in the menu, below the status.

`UsageState.Kind.ok` carries an `OkData` struct (not positional associated values) with `sessionPercent`, `weeklyPercent`, `weeklyResetsAt`, and `sessionResetsAt`. Pattern-match with `case .ok(let d)` and access fields by name.

## First-run UX caveats

- macOS will prompt for Keychain access on first read of `Claude Code-credentials` and `Claude Safe Storage`. The user must choose **Always Allow** for silent operation. There is no way to pre-grant this from code.
- Ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`). Don't enable hardened runtime entitlements that would require a real signing identity.
- App sandbox is **off** by design — needs Keychain (cross-app), FSEvents outside container, `NSWorkspace.openApplication`, and direct SQLite access to Chrome-format cookie DBs.

## When in doubt

Read the plan that produced this project: [`/Users/simonbarer/.claude/plans/create-a-new-xcode-crispy-tide.md`](../../../.claude/plans/create-a-new-xcode-crispy-tide.md). It has the rationale for the major decisions (NSStatusItem vs MenuBarExtra, LaunchAgent vs alternatives, adaptive-poll thresholds).
