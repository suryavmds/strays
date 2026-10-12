PROJECT      := Strays.xcodeproj
SCHEME       := Strays
CONFIG       ?= Debug
DERIVED_DATA := build
APP          := $(DERIVED_DATA)/Build/Products/$(CONFIG)/Strays.app
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
                -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: generate build test test-xcode run clean

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
run: build
	@pkill -x Strays 2>/dev/null || true
	open $(APP)

clean:
	rm -rf $(DERIVED_DATA) $(PROJECT) StraysCore/.build
