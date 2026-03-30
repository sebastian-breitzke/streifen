PREFIX ?= /usr/local
BINARY = Streifen
BUILD_DIR = .build/release

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD_DIR)/$(BINARY) $(PREFIX)/bin/streifen

uninstall:
	rm -f $(PREFIX)/bin/streifen

clean:
	swift package clean
