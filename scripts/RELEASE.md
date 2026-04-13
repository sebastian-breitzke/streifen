# Streifen Release Setup

## Local Release

```bash
# Build only (sign, no notarize, no DMG)
./scripts/build-app.sh

# Full local release (requires Apple credentials)
APPLE_ID=$(hort --secret apple-id) \
APPLE_TEAM_ID=N73TK4MNFF \
APPLE_APP_SPECIFIC_PASSWORD=$(hort --secret apple-app-specific-password) \
./scripts/build-app.sh 0.2.0 --notarize --dmg
```

Output lands in `dist/`:
- `Streifen.app` — signed + notarized + stapled
- `Streifen-0.2.0-arm64.dmg` — signed + notarized + stapled

## CI Release via GitHub Actions

Triggered automatically on tag push (`v*`) or via workflow_dispatch.

```bash
git tag v0.2.0
git push origin v0.2.0
```

The workflow builds, signs, notarizes, creates a GitHub Release with the DMG,
and pushes an updated Cask to `sebastian-breitzke/homebrew-tap`.

## Required GitHub Secrets

Set these at https://github.com/sebastian-breitzke/streifen/settings/secrets/actions

| Secret | Value | How to obtain |
|---|---|---|
| `CSC_LINK` | Base64-encoded `.p12` of Developer ID Application cert | See below |
| `CSC_KEY_PASSWORD` | Password for the `.p12` | Set when exporting |
| `APPLE_ID` | Apple ID email | `hort --secret apple-id` |
| `APPLE_TEAM_ID` | `N73TK4MNFF` | From Developer account |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password | `hort --secret apple-app-specific-password` |
| `HOMEBREW_TAP_GITHUB_TOKEN` | PAT with `repo` scope | Create at https://github.com/settings/tokens |

### Exporting the `.p12`

1. Open **Keychain Access**
2. Find "Developer ID Application: Sebastian Breitzke (N73TK4MNFF)"
3. Right-click → **Export** → choose `.p12` format
4. Set a strong password (save for `CSC_KEY_PASSWORD`)
5. Convert to base64:
   ```bash
   base64 -i ~/Downloads/streifen-cert.p12 | pbcopy
   ```
6. Paste into `CSC_LINK` secret

### Creating the `HOMEBREW_TAP_GITHUB_TOKEN`

1. Go to https://github.com/settings/tokens/new
2. Name: `streifen-release-cask-update`
3. Expiration: 1 year (or no expiration)
4. Scope: `repo` (full)
5. Copy token, paste into `HOMEBREW_TAP_GITHUB_TOKEN` secret

## Verification

After release:
```bash
brew update
brew install --cask sebastian-breitzke/tap/streifen
open /Applications/Streifen.app
```

Accessibility permissions granted once will persist across updates
because the code signature is stable.
