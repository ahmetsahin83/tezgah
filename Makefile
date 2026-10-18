APP_NAME := Tezgah
CONFIG   ?= release
APP      := build/$(APP_NAME).app
# No dSYM for release: the prebuilt tree-sitter grammars reference object files from their
# author's machine and dsymutil prints a warning for each one. Symbol names stay in the binary.
SWIFT_FLAGS := $(if $(filter release,$(CONFIG)),-debug-info-format none)

.PHONY: build app run install clean icon

build:
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

# Wraps the SwiftPM executable in a signed (ad-hoc) .app bundle.
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
	codesign --force --sign - "$(APP)"

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
