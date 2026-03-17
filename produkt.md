# Streifen

**Scrolling Window Manager for macOS**

---

## Konzept

Fenster werden horizontal nebeneinander in einem scrollbaren Strip angeordnet. Pro Workspace ein Strip, 9 virtuelle Workspaces, schnelles Switching via Hyper-Keys.

```
[ Workspace 1 ]
┌──────────┐  ┌──────────────────┐  ┌──────────┐  ┌──────────────┐
│ Terminal  │  │     Browser      │  │  Slack   │  │    Code      │
│   (S)    │  │      (L)         │  │   (M)    │  │    (L)       │
└──────────┘  └──────────────────┘  └──────────┘  └──────────────┘
              ← Hyper+H/L oder Pfeiltasten →
```

- **Flat Strip:** Kein Tree, kein Nesting. Fenster nebeneinander.
- **Virtual Workspaces:** 1-9, off-screen hiding (kein SIP, keine private APIs)
- **T-Shirt Sizes:** App-aware Breiten (XS–Full) statt harter Pixel-Werte
- **Peek-Layout:** Nachbar-Fenster ragen am Rand hervor

---

## T-Shirt Size System

Jedes Fenster hat eine **AppSize** (XS, S, M, L, XL, Full). Die tatsächliche Breite wird aus Size + Screen-Klasse berechnet:

| Size | Laptop | Desktop | Ultrawide |
|------|--------|---------|-----------|
| XS   | 33%    | 20%     | 20%       |
| S    | 50%    | 25%     | 20%       |
| M    | 100%   | 33%     | 25%       |
| L    | 100%   | 50%     | 33%       |
| XL   | 100%   | 67%     | 50%       |
| Full | 100%   | 100%    | 100%      |

### Screen-Klassen

| Klasse    | Aspect Ratio | Beispiel            |
|-----------|-------------|---------------------|
| Laptop    | < 1.5       | MacBook 13"/14"     |
| Desktop   | 1.5 – 2.3  | 16:9, 16:10 Monitor |
| Ultrawide | ≥ 2.3       | 21:9, 32:9          |

### App-Defaults

Neue Fenster bekommen automatisch die passende Size basierend auf bundleId:

- **Terminals** (Ghostty, Terminal, iTerm, Warp) → S
- **Browsers** (Edge, Chrome, Safari, Zen, Firefox) → L
- **IDEs** (VSCode, JetBrains) → L
- **Communication** (Teams, Outlook, Slack) → M
- **Small Tools** (Calculator) → XS
- **Utilities** (Finder, ForkLift, Spotify) → S
- **Unbekannte Apps** → L (default)

---

## Hotkeys (Hyper = Ctrl+Alt+Cmd)

### Workspace Navigation

| Aktion | Binding |
|--------|---------|
| Workspace wechseln | Hyper+1-9 |
| Nächster Workspace | Hyper+↑ |
| Vorheriger Workspace | Hyper+↓ |

### Fenster-Navigation

| Aktion | Binding |
|--------|---------|
| Fokus links | Hyper+H / Hyper+← / Hyper+ß |
| Fokus rechts | Hyper+L / Hyper+→ / Hyper+´ |

### Fenster verschieben

| Aktion | Binding |
|--------|---------|
| In Workspace verschieben | Hyper+Shift+1-9 |
| Nächster Workspace | Hyper+Shift+↑ |
| Vorheriger Workspace | Hyper+Shift+↓ |
| Im Strip nach links | Hyper+Shift+← / Hyper+Shift+ß |
| Im Strip nach rechts | Hyper+Shift+→ / Hyper+Shift+´ |

### T-Shirt Sizes setzen

| Binding | Aktion | Ultrawide | Desktop | Laptop |
|---------|--------|-----------|---------|--------|
| Hyper+F1 | Full | 100% | 100% | 100% |
| Hyper+F2 | XL | 50% | 67% | 100% |
| Hyper+F3 | L | 33% | 50% | 100% |
| Hyper+F4 | M | 25% | 33% | 100% |
| Hyper+F5 | S | 20% | 25% | 50% |

### App-Defaults setzen

| Binding | Aktion |
|---------|--------|
| Hyper+Shift+F1 | App-Default → Full |
| Hyper+Shift+F2 | App-Default → XL |
| Hyper+Shift+F3 | App-Default → L |
| Hyper+Shift+F4 | App-Default → M |
| Hyper+Shift+F5 | App-Default → S |

Setzt die Size als Default für die App (bundleId). Alle Fenster dieser App über alle Workspaces werden sofort aktualisiert.

### Reset

| Binding | Aktion |
|---------|--------|
| Hyper+Shift+Escape | Alle Fenster im Workspace auf App-Defaults zurücksetzen |

### Debug

| Binding | Aktion |
|---------|--------|
| Hyper+Shift+F12 | AX-Properties des fokussierten Fensters dumpen |

---

## Architektur

```
Streifen.app (Menu Bar, LSUIElement)
├── WindowTracker        — AX-basierte Window Discovery + Observer
├── WorkspaceManager     — 9 Workspaces, Off-screen Hiding, State Persistence
├── StripLayout          — Horizontales Layout mit Gaps + Peek
├── HotkeyManager        — Hyper+Key Bindings (NSEvent Monitor)
├── DebugServer          — HTTP localhost:22222, JSON State API
├── MenuBarView          — SwiftUI MenuBarExtra
└── StreifenConfig       — AppSize, ScreenClass, Pinned/Follow Apps
```

---

## Config

Aktuell hardcoded in `StreifenConfig.default`:

```swift
// Pinned Apps: Erster Window geht in Ziel-Workspace
pinnedApps: [
    "com.microsoft.teams2": 1,      // Business → WS 1
    "com.microsoft.Outlook": 1,
    "com.tdesktop.Telegram": 3,     // Private → WS 3
    "net.whatsapp.WhatsApp": 3,
]

// Follow Apps: Folgen dem Fokus zum aktiven Workspace
followApps: ["com.apple.finder", "com.apple.calculator", "com.binarynights.ForkLift"]

// App Sizes: bundleId → T-Shirt Size
appSizes: [
    "com.mitchellh.ghostty": .s,
    "com.microsoft.edgemac": .l,
    "com.microsoft.VSCode": .l,
    "com.microsoft.teams2": .m,
    // ...
]
defaultSize: .l
```

---

## Debug API

HTTP Server auf `localhost:22222`.

| Endpoint | Beschreibung |
|----------|-------------|
| `GET /state` | Vollständiger State: alle Workspaces, Fenster, Config, Screen |
| `GET /active` | Aktiver Workspace |
| `GET /windows` | Flache Liste aller Fenster |
| `GET /workspace/{1-9}` | Einzelner Workspace |

Response enthält pro Fenster: `appSize`, `widthRatio`, `bundleId`, `frame`, `offscreen`.
Response enthält global: `screenClass`, `defaultSize`, `appSizes`.

---

## Tech Stack

- **Swift 6** + SwiftUI (MenuBarExtra)
- **AXSwift** — Type-safe Accessibility API
- **HotKey** — Global Keyboard Shortcuts (Dependency, aktuell NSEvent Monitor)
- **TOMLKit** — Config-Parsing (vorbereitet)
- **Kein SIP nötig** — nur Accessibility + Input Monitoring Permissions

---

## Phasen

- [x] Phase 1: App Skeleton + Window Tracking
- [x] Phase 2: Virtual Workspaces + Hotkeys
- [x] Phase 3: Strip Layout + Peek
- [x] Phase 4: T-Shirt Sizes + App-aware Defaults
- [ ] Phase 5: TOML Config + Persistence
- [ ] Phase 6: Trackpad-Gesten (3-Finger-Swipe)
- [ ] Phase 7: Multi-Monitor

---

## Namensherkunft

**Streifen** — dt. für "Stripes/Strips". Horizontale Streifen von Fenstern.
