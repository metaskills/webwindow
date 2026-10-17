APP        := WebWindow.app
BUILD      := build/$(APP)
PREFIX     ?= /Applications
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build install uninstall run clean

build:
	rm -rf $(BUILD)
	mkdir -p $(BUILD)/Contents/MacOS $(BUILD)/Contents/Resources
	swiftc -O -o $(BUILD)/Contents/MacOS/WebWindow main.swift -framework Cocoa -framework WebKit
	cp Info.plist $(BUILD)/Contents/Info.plist
	cp AppIcon.icns $(BUILD)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUILD)
	@echo "Built $(BUILD)"

install: build
	rm -rf "$(PREFIX)/$(APP)"
	mkdir -p "$(PREFIX)"
	ditto $(BUILD) "$(PREFIX)/$(APP)"
	$(LSREGISTER) -f "$(PREFIX)/$(APP)"
	mdimport "$(PREFIX)/$(APP)"
	@echo "Installed $(PREFIX)/$(APP) - find it in Spotlight, Launchpad, or Finder."

uninstall:
	rm -rf "$(PREFIX)/$(APP)"
	@echo "Removed $(PREFIX)/$(APP). Cookies and cache live in ~/Library/WebKit/com.kencollins.webwindow"

run: build
	open $(BUILD)

clean:
	rm -rf build
