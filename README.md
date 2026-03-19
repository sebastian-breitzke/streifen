# Streifen

**A scrolling window manager for macOS.**

Windows sit side by side in a horizontal strip. One strip per workspace, nine workspaces, instant switching. Your screen is divided into slices — window widths are integer multiples. Predictable, composable, keyboard-driven.

Inspired by [PaperWM](https://github.com/paperwm/PaperWM) for GNOME. Rebuilt from scratch as a native macOS app.

**Website:** [streifen.eu](https://streifen.eu)

---

## How It Works

```
[ Workspace 1 ]
┌──────────┐  ┌──────────────────┐  ┌──────────┐  ┌──────────────┐
│ Terminal  │  │     Browser      │  │  Slack   │  │    VS Code   │
│  2 slices │  │    4 slices      │  │ 3 slices │  │   4 slices   │
└──────────┘  └──────────────────┘  └──────────┘  └──────────────┘
              ← Hyper+H/L or arrow keys →
```

- **Horizontal Strip** — Windows arranged side by side in a scrollable band. No grid, no floating, no stacking.
- **9 Workspaces** — `Hyper+1`–`Hyper+9`. Each workspace has its own strip. Off-screen hiding, no SIP required.
- **Slice Grid** — Your screen is a grid of columns. Window widths snap to integer slice counts. Same apps, different screens, always fitting.
- **Peek Layout** — Neighbor windows peek at the edges so you always know what's next.

---

## The Slice Grid

Every screen has a fixed number of slices based on its aspect ratio. Windows take 1, 2, 3… slices. They compose together like a layout raster.

| Screen Class | Slices | Example |
|-------------|--------|---------|
| Laptop | 4 | MacBook 13"/14" |
| Desktop | 6 | 16:9, 16:10 monitors |
| Ultrawide | 8 | 21:9, 32:9 |

F-keys set the slice count directly (`F1`=1 through `F8`=8). Values above the screen's max cap at full width.

---

## App Defaults

Every app gets a default size based on its bundle ID:

| Size | Apps |
|------|------|
| **XS** | Calculator |
| **S** | Terminal, Ghostty, iTerm, Finder, ForkLift, Spotify |
| **M** | Teams, Slack, Outlook, Telegram, WhatsApp, Signal, Discord, Zoom |
| **L** | Browser, VS Code (default for unknown apps) |
| **XL** | JetBrains IDEs, Excel |

### Behaviors

- **Pinned** — First window goes to a fixed workspace. Additional windows land wherever you are.
- **Follow** — Focus the window and it moves to your current workspace.
- **Stay** — Windows stay where you put them. Switch away, they hide. Come back, they reappear.

---

## Keyboard Shortcuts

**Hyper = Ctrl + Alt + Cmd**

### Workspaces

| Shortcut | Action |
|----------|--------|
| `Hyper + 1–9` | Switch workspace |
| `Hyper + ↑/↓` | Next / previous workspace |
| `Hyper + Shift + 1–9` | Send window to workspace |
| `Hyper + Shift + ↑/↓` | Send window to next / previous workspace |

### Navigation

| Shortcut | Action |
|----------|--------|
| `Hyper + H` or `Hyper + ←` | Focus previous window |
| `Hyper + L` or `Hyper + →` | Focus next window |
| `Hyper + Shift + ←/→` | Reorder window in strip |
| `4-finger pan ←/→` | Smooth-scroll strip, then snap to the centered window |

### Sizing — Slice Grid

| Shortcut | Action |
|----------|--------|
| `Hyper + F1–F8` | Set slice count (1 → 8) |
| `Hyper + ß` | Step −1 slice |
| `Hyper + ´` | Step +1 slice |
| `Hyper + Shift + F1–F5` | Set app default (XS → XL) |
| `Hyper + Shift + Esc` | Reset all windows to defaults |

### Debug

| Shortcut | Action |
|----------|--------|
| `Hyper + Shift + F12` | Dump AX properties of focused window |

---

## Architecture

```
Streifen.app (Menu Bar, LSUIElement)
├── WindowTracker        — AX-based window discovery + observer
├── WorkspaceManager     — 9 workspaces, off-screen hiding
├── StripLayout          — Horizontal layout with gaps + peek
├── HotkeyManager        — Hyper+key bindings (NSEvent monitor)
├── StreifenConfig        — Slice grid, app sizes, behaviors
├── DebugServer          — HTTP API on localhost:22222
└── MenuBarView          — SwiftUI MenuBarExtra
```

## Debug API

HTTP server on `localhost:22222`.

| Endpoint | Description |
|----------|------------|
| `GET /state` | Full state: all workspaces, windows, config, screen |
| `GET /active` | Active workspace |
| `GET /windows` | Flat list of all windows |
| `GET /workspace/{1-9}` | Single workspace |

---

## Requirements

- macOS 14+
- Accessibility permission
- Input Monitoring permission
- No SIP disable required

## Tech Stack

- **Swift 6** + SwiftUI (MenuBarExtra)
- **AXSwift** — Type-safe Accessibility API
- **HotKey** — Global keyboard shortcuts
- **MultitouchSupport** — Raw trackpad input for smooth 4-finger strip navigation
- **TOMLKit** — Config parsing (prepared)

---

## Roadmap

- [x] Window tracking + AX observation
- [x] Virtual workspaces + hotkeys
- [x] Strip layout + peek
- [x] Slice grid + app-aware defaults
- [ ] TOML config + persistence
- [x] Trackpad gestures (smooth 4-finger pan + snap)
- [ ] Multi-monitor support

---

## Name

**Streifen** — German for "stripes" or "strips". Horizontal strips of windows.

## License

[MIT](LICENSE)
