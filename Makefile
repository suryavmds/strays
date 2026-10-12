PROJECT      := Strays.xcodeproj
SCHEME       := Strays
CONFIG       ?= Debug
DERIVED_DATA := build
APP          := $(DERIVED_DATA)/Build/Products/$(CONFIG)/Strays.app
VERSION      := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' StraysCore/Sources/StraysCore/StraysCore.swift)
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
                -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: generate build test test-xcode run package icon snapshots check-shaders clean

## Generate Strays.xcodeproj from project.yml (the .xcodeproj is not committed).
generate:
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	xcodegen generate --quiet

## Build the app.
build: generate
	$(XCODEBUILD) build | ./scripts/xcfilter.sh

## Run the StraysCore unit tests (SwiftPM: fast, and needs no Xcode project).
test:
	swift test --package-path StraysCore

## Run the same tests through the Xcode scheme.
test-xcode: generate
	$(XCODEBUILD) test | ./scripts/xcfilter.sh

## Build, then launch the app (it lives in the menu bar).
## `make run ARGS=--demo` shows made-up data; `ARGS=--dashboard` opens the window.
run: build
	@pkill -x Strays 2>/dev/null || true
	open $(APP) --args $(ARGS)

## Build a universal Release app and zip it into dist/, as the release
## workflow does but signed for running locally. Not notarized.
package:
	$(MAKE) build CONFIG=Release
	@mkdir -p dist
	@rm -f dist/Strays-$(VERSION).zip
	ditto -c -k --keepParent $(DERIVED_DATA)/Build/Products/Release/Strays.app dist/Strays-$(VERSION).zip
	@echo "dist/Strays-$(VERSION).zip  $$(lipo -archs $(DERIVED_DATA)/Build/Products/Release/Strays.app/Contents/MacOS/Strays)"
	@shasum -a 256 dist/Strays-$(VERSION).zip

## Redraw the app icon from scripts/make-icon.swift.
icon:
	swift scripts/make-icon.swift Strays/Resources/Assets.xcassets/AppIcon.appiconset

## Render the UI to PNGs with demo data: make snapshots OUT=/tmp/strays-snapshots
snapshots: build
	./scripts/snapshots.sh $(or $(OUT),/tmp/strays-snapshots)

## Syntax-check the Metal shaders (works without the Metal toolchain).
check-shaders:
	swift scripts/check-shaders.swift

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) StraysCore/.build strays-cli/.build dist
