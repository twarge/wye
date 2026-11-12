# Wye — the single build entry point.
#
# Every app target here drives `xcodebuild` against Wye.xcodeproj, so
# `make build` produces exactly what Build & Run in Xcode produces.
#
# Package.swift stays: the Xcode project consumes it as a local package for
# GitKit and WyeUI, and `make test` runs its tests.
#
#   make            Debug build of the macOS app
#   make run        build it, then launch it
#   make release    Release build
#   make ios        build for the iOS Simulator
#   make test       run the tests
#   make deps       fetch the libgit2 submodule
#   make icon       regenerate the app icon from scripts/make-app-icon.swift
#   make symbol     regenerate the branch symbol from scripts/make-branch-symbol.swift
#   make strings    bring the string catalogs up to date with the sources
#   make archive    Release .xcarchive for the App Store (PLATFORM=macOS or iOS)
#   make upload     export that archive to App Store Connect
#   make clean      remove build products
#   make help       list targets

PROJECT     := Wye.xcodeproj
SCHEME      := Wye
CONFIG      ?= Debug
DESTINATION ?= platform=macOS
DERIVED     := .build/xcode
# Extra xcodebuild settings, e.g. CI passing CODE_SIGNING_ALLOWED=NO.
XCODE_FLAGS ?=

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

LIBGIT2 := Vendor/libgit2/include/git2.h

.PHONY: all build run release ios test deps clean help icon symbol strings archive upload

all: build

## deps: fetch libgit2, which is compiled from source as part of the build
deps: $(LIBGIT2)

$(LIBGIT2):
	git submodule update --init Vendor/libgit2

## build: build the macOS app exactly as Xcode's Build & Run does
build: deps
	$(XCODEBUILD) -destination '$(DESTINATION)' $(XCODE_FLAGS) build

## run: build the macOS app, then launch it
run: build
	open $(DERIVED)/Build/Products/$(CONFIG)/Wye.app

## release: Release build of the macOS app
release:
	$(MAKE) build CONFIG=Release

## ios: build for the iOS Simulator
ios: deps
	$(XCODEBUILD) -destination 'generic/platform=iOS Simulator' $(XCODE_FLAGS) build

## test: run the tests
test: deps
	swift test

## icon: regenerate App/Resources/AppIcon.icon from scripts/make-app-icon.swift
icon:
	swift scripts/make-app-icon.swift

## symbol: regenerate the branch symbol in App/Resources/Assets.xcassets
symbol:
	swift scripts/make-branch-symbol.swift

## strings: bring the string catalogs up to date with the sources
strings: deps
	scripts/sync-strings.sh

# ---------------------------------------------------------------------------
# App Store distribution
#
# `make archive` then `make upload` is what the release workflow
# (.github/workflows/appstore.yml) runs, so a release can be reproduced locally
# with the same flags. Signing uses Xcode's cloud signing: with
# -allowProvisioningUpdates and an App Store Connect API key, Xcode creates and
# refreshes the distribution certificate and the App Store provisioning
# profiles itself, so no .p12 or .mobileprovision has to be stored anywhere.
#
# The API key is passed through XCODE_FLAGS, e.g.
#   make archive upload PLATFORM=macOS \
#     XCODE_FLAGS='-authenticationKeyPath /path/AuthKey.p8 \
#                  -authenticationKeyID ABC123 \
#                  -authenticationKeyIssuerID 1234-...'
#
# docs/app-store.md has the rest of the submission checklist.
PLATFORM       ?= macOS
ARCHIVE_PATH   ?= build/release/Wye-$(PLATFORM).xcarchive
EXPORT_PATH    ?= build/release/export-$(PLATFORM)
EXPORT_OPTIONS ?= App/ExportOptions-AppStore.plist

## archive: Release .xcarchive for PLATFORM (macOS or iOS)
archive: deps
	xcodebuild archive \
		-project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=$(PLATFORM)' \
		-archivePath '$(ARCHIVE_PATH)' \
		-allowProvisioningUpdates \
		$(XCODE_FLAGS)

## upload: export the archive and send it to App Store Connect
upload:
	xcodebuild -exportArchive \
		-archivePath '$(ARCHIVE_PATH)' \
		-exportOptionsPlist '$(EXPORT_OPTIONS)' \
		-exportPath '$(EXPORT_PATH)' \
		-allowProvisioningUpdates \
		$(XCODE_FLAGS)

# Removes .build, which holds Xcode's products and the SwiftPM directory
# `make test` uses. It leaves build/ alone: that holds release archives, not
# build output.
## clean: remove build products
clean:
	rm -rf .build

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
