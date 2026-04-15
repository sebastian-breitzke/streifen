# Local App Spawn On Activate

## Summary

When an app is activated and it has no window on the current Streifen workspace, Streifen should be able to create a new local window instead of switching to another workspace. This must be opt-in per app. Default behavior stays unchanged for all other apps.

Initial target apps:

- Terminal apps: `Terminal`, `Ghostty`, `iTerm`, `Warp`
- Browsers: `Edge`, `Chrome`, `Safari`, `Zen`, `Firefox`

This feature is triggered on app activation in general, not only `Cmd-Tab`. That includes App Switcher, Dock clicks, and comparable activation paths that surface through `NSWorkspace.didActivateApplicationNotification`.

## Problem

Today, Streifen treats app activation as a workspace-routing event:

- If the activated app has a local window on the active workspace, Streifen stays local.
- If not, Streifen switches to the workspace that already contains one of that app's windows.

That breaks down for apps with many open windows, especially terminals and browsers. The user intention is often "bring me a terminal or browser here", not "teleport me to whichever workspace already owns one".

## Goals

- Keep app activation local when the app is configured for local spawning.
- Preserve the current switching behavior for all apps that are not opted in.
- Reuse the existing window-discovery and workspace-assignment flow instead of adding a parallel path.
- Fail safely: if local spawning does not work, fall back to today's workspace switch behavior.

## Non-Goals

- No generic automation layer for arbitrary apps.
- No attempt to distinguish `Cmd-Tab` from Dock clicks or other activation sources.
- No change to `follow`, `pinned`, or `floating` semantics beyond making sure they still coexist cleanly.
- No promise that every browser or terminal will support automation equally well on the first pass.

## Current Behavior

Relevant path today:

1. `WindowTracker` emits `onAppActivated` on `NSWorkspace.didActivateApplicationNotification`.
2. `WorkspaceManager.handleAppActivated(_:)` runs.
3. If the app has a local window on the active workspace, Streifen focuses that local window.
4. Otherwise Streifen finds a window of that app on another workspace and switches there.

This is structurally good. The change belongs in this activation path, not in ad-hoc hotkey handling and not in the `follow` path.

## Options Considered

### Option 1: New activation behavior per app

Introduce an app-specific activation policy:

- `switchToExisting`
- `spawnLocalIfMissing`

Behavior:

- Local window exists: focus it.
- No local window:
  - `spawnLocalIfMissing`: create a new local window.
  - `switchToExisting`: keep today's behavior and switch to the existing workspace.

Pros:

- Matches the requested behavior exactly.
- Default-safe.
- Keeps semantics explicit.

Cons:

- Requires app-specific spawn handlers.

### Option 2: Always spawn locally when nothing is local

Pros:

- Simple rule.

Cons:

- Too broad.
- Would surprise users for apps like Teams, Outlook, Slack, Finder, and others where workspace switching is still the right behavior.

### Option 3: Extend `follow` to cover this

Pros:

- Reuses an existing concept.

Cons:

- Wrong abstraction.
- `follow` moves an existing window; this feature creates a new local one.
- Would blur semantics and make config harder to reason about.

## Decision

Use Option 1.

Add a new app-level activation behavior with default `switchToExisting`. Mark selected terminals and browsers as `spawnLocalIfMissing`.

## Design

### Config Model

Add a new config mapping:

- `activateBehaviors: [String: ActivateBehavior]`

With:

```swift
enum ActivateBehavior: String, Sendable, Codable {
    case switchToExisting
    case spawnLocalIfMissing
}
```

Rules:

- Unknown apps default to `switchToExisting`.
- Existing config files without this field continue to decode by applying defaults.
- Hardcoded defaults set `spawnLocalIfMissing` for the initial browser and terminal bundle IDs.

### Activation Flow

`WorkspaceManager.handleAppActivated(_:)` becomes:

1. Ignore activation noise during the existing post-switch cooldown.
2. Look for a local window of the activated app on the active workspace.
3. If a local window exists, focus it and stay on the current workspace.
4. If no local window exists:
   - Read the app's `ActivateBehavior`.
   - If behavior is `spawnLocalIfMissing`, ask a dedicated spawner to create a new local window.
   - Wait briefly for the new AX window to appear.
   - If it appears, let the normal `handleWindowsUpdate(_:)` path place it on the active workspace.
   - If spawning fails or times out, fall back to the current workspace-switch behavior.
5. If behavior is `switchToExisting`, keep current logic unchanged.

Important constraint:

- Do not immediately switch away while a local spawn attempt is in flight.

### Local Window Spawner

Introduce a focused helper, for example `LocalWindowSpawner`.

Responsibility:

- Given an activated `NSRunningApplication`, try to create a new top-level window for that app.
- Return success/failure synchronously or via a small completion wrapper around a timeout.

Scope:

- First version only supports known browser and terminal bundle IDs.
- Unsupported apps return failure immediately.

Mechanism:

- Prefer explicit app-specific Apple Event / scripting commands to "new window".
- Do not simulate keystrokes.
- Do not restart the app.
- Do not build a generic UI automation fallback.

Reasoning:

- Keystroke injection is brittle and can target the wrong app.
- Restarting the app is user-hostile and semantically wrong.
- Explicit per-app handlers keep the failure mode understandable.

### Workspace Assignment

No new placement path should be added.

The intended sequence is:

1. App activates.
2. Streifen requests a new window.
3. `WindowTracker` discovers the new AX window.
4. `WorkspaceManager.handleWindowsUpdate(_:)` inserts it.
5. Because the window was created while the current workspace is active, it lands on the current workspace by existing logic.

This keeps window routing canonical and avoids dual logic.

### Fallback Rules

If any of the following happens, Streifen falls back to `switchToExisting`:

- App is not supported by the spawner.
- Apple Event automation is denied by macOS.
- The app-specific spawn command errors.
- No new top-level AX window appears before timeout.

Fallback means:

- Find the existing window on another workspace.
- Switch there using today's logic.

This ensures the feature never strands activation in a half-failed state.

### Interaction With Existing Policies

`pinned`

- Unchanged.
- If the local spawn results in a brand-new window while the current workspace is active, it should still be assigned by the existing insertion logic.
- The existing "first pinned window goes to pinned workspace" rule remains intact for normal discovery.

`follow`

- Unchanged.
- `follow` moves an existing window into the current workspace when focus lands on that window.
- `spawnLocalIfMissing` is only used when there is no local window and we want a new one.

`floating`

- Unchanged.
- Floating apps should not use local spawning in the first iteration.

## Error Handling And Observability

Add clear logs for:

- activation behavior chosen
- local spawn attempt started
- local spawn succeeded
- local spawn failed with reason
- fallback to workspace switch

This matters because macOS automation permissions may interfere and failures need to be diagnosable.

## Verification Plan

Manual verification for first implementation:

1. Activated app already has a local window:
   - Streifen stays on the current workspace.
   - Correct local window gets focus.

2. App configured as `spawnLocalIfMissing`, no local window, existing window elsewhere:
   - Streifen attempts local spawn.
   - New window appears on current workspace.
   - No workspace switch occurs.

3. App configured as `switchToExisting`, no local window, existing window elsewhere:
   - Streifen switches to the workspace containing that app.

4. Spawn-capable app with automation blocked or failed:
   - Streifen logs the failure.
   - Streifen falls back to switching to the existing workspace window.

5. Existing `follow`, `pinned`, and normal new-window discovery still work after the change.

## Risks

- macOS may require Automation permission for Apple Events.
- Some target apps may expose inconsistent or partial scripting support.
- Browser and terminal apps may differ in whether "new window" creates a top-level standard window visible to AX immediately.

These are acceptable for the first pass because the fallback path preserves current behavior.

## Implementation Shape

Expected code touch points:

- `Sources/Streifen/StreifenConfig.swift`
- `Sources/Streifen/WorkspaceManager.swift`
- new helper for app-specific local spawning
- possibly `Info.plist` if Automation usage strings or related entitlements become necessary

No UI changes are required for the first pass. Config can start as hardcoded defaults plus file-backed support.
