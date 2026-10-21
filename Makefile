APP_NAME := Tezgah
CONFIG   ?= release
APP      := build/$(APP_NAME).app
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
DMG      := build/$(APP_NAME)-$(VERSION).dmg
# No dSYM for release: the prebuilt tree-sitter grammars reference object files from their
# author's machine and dsymutil prints a warning for each one. Symbol names stay in the binary.
SWIFT_FLAGS := $(if $(filter release,$(CONFIG)),-debug-info-format none)

.PHONY: build app dmg run install clean icon

build:
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

# Signed with the first Apple Development certificate in the Keychain, if there is one: the
# Keychain then knows the app across builds and "Always Allow" on its password prompts sticks.
# Ad hoc otherwise, which the Keychain sees as a new app after every build.
SIGN_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development:[^"]*"' | tr -d '"'),-)

# Wraps the SwiftPM executable in a signed .app bundle.
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/"
	# SwiftPM resource bundles (tree-sitter queries etc.) are looked up in Contents/Resources.
	for bundle in "$$(swift build -c $(CONFIG) --show-bin-path)"/*.bundle; do \
		cp -R "$$bundle" "$(APP)/Contents/Resources/"; \
	done
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"

# A disk image with the app and a shortcut to /Applications, for GitHub releases.
dmg: app
	rm -rf build/dmg "$(DMG)"
	mkdir -p build/dmg
	cp -R "$(APP)" build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder build/dmg -ov -format UDZO "$(DMG)"
	rm -rf build/dmg

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/

# Regenerates Support/AppIcon.icns from Support/make-icon.swift.
icon:
	swift Support/make-icon.swift

clean:
	rm -rf .build build
