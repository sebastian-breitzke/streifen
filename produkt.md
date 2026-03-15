# Streifen

**Scrolling Window Manager for macOS**

---

## Was ist Streifen?

Ein schlanker, nativer macOS Window Manager als Menu Bar App. Fenster werden horizontal nebeneinander in einem scrollbaren Strip angeordnet — pro Workspace ein Strip, 9 virtuelle Workspaces, schnelles Switching via Hotkeys.

## Warum?

- AeroSpace: zu starres Tiling, kein horizontales Scrolling
- PaperWM.spoon / Paneru: Hammerspoon-basiert, ab Sequoia/macOS 26 broken
- Kein existierender macOS WM macht horizontale Strips + virtuelle Workspaces zuverlässig

## Kernkonzept

```
[ Workspace 1 ]
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│ Browser  │  │  Code    │  │ Terminal │  │  Slack   │
│  (50%)   │  │  (66%)   │  │  (33%)   │  │  (33%)   │
└──────────┘  └──────────┘  └──────────┘  └──────────┘
              ← 3-Finger-Swipe oder Hyper+H/L →
```

- **Flat Strip:** Kein Tree, kein Nesting. Fenster nebeneinander, fertig.
- **Virtual Workspaces:** 1-9, off-screen hiding (kein SIP, keine private APIs)
- **Anchor-Layout:** Fokussiertes Fenster als Anker, Rest links/rechts auslegen
- **Width Cycling:** 33% → 50% → 66% pro Fenster

## Hotkeys (Hyper = Ctrl+Alt+Cmd)

| Aktion | Binding |
|--------|---------|
| Workspace wechseln | Hyper+1-9 |
| Fenster verschieben | Hyper+Shift+1-9 |
| Fokus links/rechts | Hyper+H/L oder Hyper+←/→ |
| Breite cyclen | Hyper+Pad0 |
| Breite rückwärts | Hyper+Shift+Pad0 |
| Volle Breite toggle | Hyper+PadEnter |

## Tech Stack

- **Swift 6** + SwiftUI (MenuBarExtra)
- **AXSwift** — Type-safe Accessibility API
- **HotKey** — Global keyboard shortcuts
- **TOMLKit** — Config-Parsing
- **Kein SIP nötig** — nur Accessibility + Input Monitoring Permissions

## Architektur

```
Streifen.app (Menu Bar, LSUIElement)
├── WindowTracker        — AX-basierte Window Discovery
├── WorkspaceManager     — 9 Workspaces, off-screen hiding
├── StripLayout          — Horizontales Layout mit Gaps
├── HotkeyManager        — Hyper+Key Bindings
├── GestureManager       — Trackpad 3-Finger-Swipe (Phase 4)
└── ConfigManager        — TOML Config (Phase 5)
```

## Status

- [x] Phase 1: App Skeleton + Window Tracking
- [x] Phase 2: Virtual Workspaces + Hotkeys
- [x] Phase 3: Strip Layout
- [ ] Phase 4: Trackpad-Gesten
- [ ] Phase 5: App-Kategorien + TOML Config
- [ ] Phase 6: Multi-Monitor + Polish

## Config (geplant)

`~/.config/streifen/config.toml`

```toml
[general]
gap = 10
cycle_widths = [0.33, 0.50, 0.66]

[categories]
browsing = ["com.google.Chrome", "app.zen-browser.desktop"]
development = ["com.microsoft.VSCode"]
communication = ["com.microsoft.teams2"]

[pinned]
1 = ["communication"]
"7-9" = ["development"]
```

## Namensherkunft

**Streifen** — dt. für "Stripes/Strips". Horizontale Streifen von Fenstern.
