# Streifen

**A scrolling window manager for macOS.**

Windows sit side by side in a horizontal strip. One strip per workspace, nine workspaces, instant switching. Your screen is divided into slices — window widths are integer multiples. Predictable, composable, keyboard-driven.

Inspired by [PaperWM](https://github.com/paperwm/PaperWM) for GNOME. Rebuilt from scratch as a native macOS app.

**Website:** [streifen.eu](https://streifen.eu)

---

## Install

```bash
brew tap sebastian-breitzke/tap
brew install --cask streifen
```

Grant Accessibility access when prompted (System Settings → Privacy & Security → Accessibility). Permissions persist across updates.

### Update

```bash
brew upgrade streifen
```

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

- **Horizontal Strip** — Windows arranged side by side in a scrollable band. No grid, no stacking.
- **9 Workspaces** — `Hyper+1`–`Hyper+9`. Each workspace has its own strip. Off-screen hiding, no SIP required.
- **Slice Grid** — Your screen is a grid of columns. Window widths snap to integer slice counts. Same apps, different screens, always fitting.

---

## The Slice Grid

Every screen has a fixed number of slices based on its aspect ratio. Windows take 1, 2, 3… slices.

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
| **S** | Terminal, Ghostty, iTerm, Finder, ForkLift, Spotify |
| **M** | Teams, Slack, Outlook, Telegram, WhatsApp, Signal, Discord, Zoom |
| **L** | Browser, VS Code (default for unknown apps) |
| **XL** | JetBrains IDEs, Excel |

### Behaviors

- **Pinned** — First window goes to a fixed workspace. Additional windows land wherever you are.
- **Follow** — Focus the window and it moves to your current workspace.
- **Floating** — Not part of the strip. Stays where you put it, always visible, survives workspace switches.
- **Stay** — Windows stay where you put them. Switch away, they hide. Come back, they reappear.

### Configuration

Config lives at `~/.config/streifen/config.json`. Edit directly or use the App Info Panel (`Hyper+Shift+F1`) to change size, pinned workspace, follow, and floating per app — changes apply immediately and persist.

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
| `4-finger pan ←/→` | Smooth-scroll strip, then snap to nearest window |

### Sizing

| Shortcut | Action |
|----------|--------|
| `Hyper + F1–F8` | Set slice count (1 → 8) |
| `Hyper + -` or `Hyper + ß` | Step −1 slice |
| `Hyper + +` or `Hyper + ´` | Step +1 slice |
| `Hyper + Shift + Esc` | Reset all windows to defaults |

### App Info & System

| Shortcut | Action |
|----------|--------|
| `Hyper + Shift + F1` | App Info Panel — change size, pin, follow, float |
| `Hyper + Shift + F12` | Restart Streifen |

---

## Architecture

```
Streifen.app (Menu Bar, LSUIElement)
├── WindowTracker        — AX-based window discovery + observer
├── WorkspaceManager     — 9 workspaces, off-screen hiding, minimize tracking
├── StripLayout          — Horizontal layout with gap spacing
├── HotkeyManager        — Hyper+key bindings (CGEvent tap)
├── AppInfoPanel         — Interactive panel for per-app config
├── StreifenConfig        — JSON config file, load/save
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
- No SIP disable required

## Tech Stack

- **Swift 6** + SwiftUI (MenuBarExtra)
- **AXSwift** — Type-safe Accessibility API
- **MultitouchSupport** — Raw trackpad input for 4-finger strip navigation
- Signed with Developer ID, Apple-notarized

---

## Development

```bash
# Debug build
swift build

# Run dev build (stops brew service automatically, restores on exit)
.build/debug/Streifen

# Build signed .app
./scripts/build-app.sh

# Full release (notarize + DMG)
APPLE_ID=$(hort --secret apple-id) \
APPLE_TEAM_ID=N73TK4MNFF \
APPLE_APP_SPECIFIC_PASSWORD=$(hort --secret apple-app-specific-password) \
./scripts/build-app.sh 0.2.0 --notarize --dmg
```

Dev builds show an orange dot on the menu bar icon.

### Release

Push a tag to trigger the CI pipeline:

```bash
git tag v0.3.0
git push origin v0.3.0
```

GitHub Actions builds, signs, notarizes, creates a GitHub Release with DMG, and updates the Homebrew Cask automatically.

---

## Name

**Streifen** — German for "stripes" or "strips". Horizontal strips of windows.

## License

[MIT](LICENSE)
