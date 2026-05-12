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

## Architecture

A `LSUIElement=YES` menubar-only app with no SwiftUI scenes. The `App` body is `Settings { EmptyView() }` purely to satisfy the protocol; the real entry point is `AppDelegate.applicationDidFinishLaunching`, which:
1. Installs the launchd agent (`LaunchAgentInstaller`).
2. Checks if `com.anthropic.claudefordesktop` is running (`ClaudeAppLifecycle`); terminates immediately if not.
3. Creates `NSStatusItem` directly (not `MenuBarExtra` — we need a click-action, not a popover) and wires it to a fetch loop driven by `UsageMonitor`.
4. Subscribes to `NSWorkspace.didWakeNotification` for sleep/wake refresh and `didTerminateApplicationNotification` to self-terminate when Claude.app quits.

### Data source

Polls the **undocumented** OAuth endpoint `https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20`. The bearer token comes from the macOS Keychain service `Claude Code-credentials`, written by the `claude` CLI. `KeychainTokenStore` handles both raw-string and JSON-wrapped (`accessToken` field) forms.

**Important gotcha**: the API returns percentages as **0–100 doubles**, not 0–1 utilization fractions. Don't multiply by 100 in `UsageMonitor`. `UsageAPI.extractBucket` accepts several key aliases (`five_hour`/`fiveHour`/`session`/...) defensively — if the response shape shifts, add to the alias list rather than rewriting.

### Adaptive polling & activity

`ActivityWatcher` opens an `FSEventStream` on `~/.claude/projects/` and stamps `lastActivityAt` on any JSONL mtime change. `UsageMonitor.currentInterval()` returns 15s / 60s / 300s depending on time-since-activity. FSEvents also trigger an immediate (debounced 5s) fetch and reschedule the timer — that's the "active again" path. 429 responses are surfaced as `.rateLimited` and *do not* update display state.

### Lifecycle (start with Claude / quit with Claude)

`NSApp.terminate` runs the moment Claude.app's termination notification fires. To re-launch, the app installs `~/Library/LaunchAgents/com.simonbarer.claude-usage-toolbar.plist` with `StartInterval=5`. The plist invokes a small shell script (written to `~/Library/Application Support/ClaudeUsageToolbar/launch.sh`) that does `pgrep Claude && pgrep -v ClaudeUsageToolbar && open -gj <APP_PATH>`.

**`<APP_PATH>` is captured from `Bundle.main.bundleURL` at install time.** If the `.app` is moved after first launch, the LaunchAgent script will reference the stale path. Solution: launch the app once from its new location — the installer rewrites the script (via `writeIfChanged`) and `bootout`/`bootstrap`s the agent.

### Weekly alert

`UsageMonitor.maybeFireWeeklyAlert` fires `WeeklyAlert.show` only on the rising edge (`weekly >= 90 && lastWeeklyPercent < 90`). Per-week dedup uses `UserDefaults` keyed by the ISO-formatted `resets_at` value — the same reset-window string won't re-alert even after restarts.

## First-run UX caveats

- macOS will prompt for Keychain access on first read of `Claude Code-credentials`. The user must choose **Always Allow** for silent operation. There is no way to pre-grant this from code.
- Ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`). Don't enable hardened runtime entitlements that would require a real signing identity.
- App sandbox is **off** by design — needs Keychain (cross-app), FSEvents outside container, and `NSWorkspace.openApplication`.

## When in doubt

Read the plan that produced this project: [`/Users/simonbarer/.claude/plans/create-a-new-xcode-crispy-tide.md`](../../../.claude/plans/create-a-new-xcode-crispy-tide.md). It has the rationale for the major decisions (NSStatusItem vs MenuBarExtra, LaunchAgent vs alternatives, adaptive-poll thresholds).
