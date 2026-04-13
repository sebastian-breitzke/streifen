.PHONY: app release clean

# Build a signed .app bundle in dist/
app:
	./scripts/build-app.sh

# Full release: build + sign + notarize + DMG
# Usage: make release VERSION=0.2.0
release:
	./scripts/build-app.sh "$(VERSION)" --notarize --dmg

clean:
	swift package clean
	rm -rf dist/
