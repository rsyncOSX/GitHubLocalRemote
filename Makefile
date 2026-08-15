# sudo ditto "build/GitBranchStatus.app" "/Applications/GitBranchStatus.app"
APP := GitBranchStatus
PROJECT := $(APP).xcodeproj
SCHEME := $(APP)
TEAM_ID ?= 93M47F4H9T
NOTARY_PROFILE ?= RsyncUI
VERSION := $(shell grep -m 1 'MARKETING_VERSION' $(PROJECT)/project.pbxproj | awk -F' = ' '{print $$2}' | tr -d ';')
BUILD_PATH := $(CURDIR)/build
ARCHIVE_PATH := $(BUILD_PATH)/$(APP).xcarchive
APP_PATH := $(BUILD_PATH)/$(APP).app
EXECUTABLE_PATH := $(APP_PATH)/Contents/MacOS/$(APP)
ZIP_PATH := $(BUILD_PATH)/$(APP).$(VERSION).zip
DMG_PATH := $(CURDIR)/$(APP).$(VERSION).dmg
DMG_SHA256_PATH := $(DMG_PATH).sha256
CREATE_DMG ?= ../RawCull/create-dmg/create-dmg
TEST_DESTINATION := platform=macOS
XCODE_TEST_FLAGS := -project $(PROJECT) -scheme $(SCHEME) -destination '$(TEST_DESTINATION)'
XCODE_RELEASE_FLAGS := -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' -configuration Release
XCODE_ARCH_FLAGS := ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64

.DEFAULT_GOAL := build

# Build, sign, notarize, and package the release.
build: archive sign-app notarize staple prepare-dmg hash-dmg open

# Build a locally signed debug archive without notarization.
debug: archive-debug open-debug

test-smoke:
	xcodebuild test $(XCODE_TEST_FLAGS) -enableCodeCoverage NO \
		-only-testing:GitBranchStatusTests/WelcomeRenderingTests

test-full:
	xcodebuild test $(XCODE_TEST_FLAGS)

# --- MAIN WORKFLOW FUNCTIONS --- #
archive: clean
	@osascript -e 'display notification "Exporting application archive..." with title "Build $(APP)"'
	@echo "Exporting application archive (RELEASE)..."
	xcodebuild \
		$(XCODE_RELEASE_FLAGS) archive \
		-archivePath "$(ARCHIVE_PATH)" \
		$(XCODE_ARCH_FLAGS)
	@echo "Application built, starting archive export..."
	xcodebuild -exportArchive \
		-exportOptionsPlist "exportOptions.plist" \
		-archivePath "$(ARCHIVE_PATH)" \
		-exportPath "$(BUILD_PATH)" \
		-allowProvisioningUpdates
	@$(MAKE) --no-print-directory verify-arch
	@echo "Project archived successfully (RELEASE)"

archive-debug: clean
	@osascript -e 'display notification "Building debug version..." with title "Build $(APP)"'
	@echo "Building application (DEBUG)..."
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination 'platform=macOS,arch=arm64' \
		-configuration Debug archive \
		-archivePath "$(ARCHIVE_PATH)" \
		$(XCODE_ARCH_FLAGS)
	@echo "Application built, starting archive export..."
	xcodebuild -exportArchive \
		-exportOptionsPlist "exportOptionsDebug.plist" \
		-archivePath "$(ARCHIVE_PATH)" \
		-exportPath "$(BUILD_PATH)"
	@$(MAKE) --no-print-directory verify-arch
	@echo "Debug build completed successfully"

sign-app:
	@osascript -e 'display notification "Verifying Developer ID signature..." with title "Build $(APP)"'
	@echo "Verifying exported Developer ID signature..."
	codesign --verify --deep --strict --verbose=2 "$(APP_PATH)"
	@APP_SIGNATURE=$$(codesign -dv --verbose=4 "$(APP_PATH)" 2>&1); \
		echo "$$APP_SIGNATURE"; \
		echo "$$APP_SIGNATURE" | grep -q "Authority=Developer ID Application:" || \
			(echo "$(APP) is not signed with Developer ID Application"; exit 1); \
		echo "$$APP_SIGNATURE" | grep -q "Timestamp=" || \
			(echo "$(APP) signature has no secure timestamp"; exit 1)
	@echo "Creating zip for notarization..."
	ditto -c -k --keepParent "$(APP_PATH)" "$(ZIP_PATH)"
	@echo "Developer ID signature verified successfully"

notarize:
	@osascript -e 'display notification "Submitting app for notarization..." with title "Build $(APP)"'
	@echo "Submitting app for notarization..."
	@RESULT=$$(xcrun notarytool submit --keychain-profile "$(NOTARY_PROFILE)" --wait "$(ZIP_PATH)" 2>&1); \
		echo "$$RESULT"; \
		if echo "$$RESULT" | grep -q "status: Accepted"; then \
			echo "$(APP) successfully notarized"; \
		else \
			echo "Notarization failed"; \
			SUBMISSION_ID=$$(echo "$$RESULT" | grep "id:" | head -1 | awk '{print $$2}'); \
			if [ -n "$$SUBMISSION_ID" ]; then \
				xcrun notarytool log "$$SUBMISSION_ID" --keychain-profile "$(NOTARY_PROFILE)"; \
			fi; \
			exit 1; \
		fi

staple:
	@osascript -e 'display notification "Stapling $(APP)..." with title "Build $(APP)"'
	@echo "Stapling notarization ticket to application..."
	xcrun stapler staple "$(APP_PATH)"
	@echo "Verifying stapled application..."
	spctl -a -t exec -vvv "$(APP_PATH)"
	@osascript -e 'display notification "$(APP) successfully stapled" with title "Build $(APP)"'

prepare-dmg:
	@test -x "$(CREATE_DMG)" || (echo "Missing create-dmg tool: $(CREATE_DMG)"; exit 1)
	@osascript -e 'display notification "Creating DMG..." with title "Build $(APP)"'
	@echo "Creating DMG installer..."
	"$(CREATE_DMG)" \
		--volname "$(APP) ver $(VERSION)" \
		--window-pos 200 120 \
		--window-size 500 320 \
		--icon-size 80 \
		--icon "$(APP).app" 125 175 \
		--hide-extension "$(APP).app" \
		--app-drop-link 375 175 \
		--no-internet-enable \
		--codesign "$(TEAM_ID)" \
		"$(DMG_PATH)" \
		"$(APP_PATH)"
	@echo "DMG created successfully"
	@echo "Submitting DMG for notarization..."
	xcrun notarytool submit --keychain-profile "$(NOTARY_PROFILE)" --wait "$(DMG_PATH)"
	@echo "Stapling ticket to DMG..."
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"
	hdiutil verify "$(DMG_PATH)"
	@echo "DMG is signed, notarized, and stapled"

hash-dmg:
	@echo "Writing final DMG SHA-256..."
	shasum -a 256 "$(DMG_PATH)" > "$(DMG_SHA256_PATH)"
	@cat "$(DMG_SHA256_PATH)"

verify-downloaded-dmg:
	@test -n "$(DOWNLOADED_DMG)" || (echo "Set DOWNLOADED_DMG to the downloaded DMG path"; exit 1)
	@test -f "$(DMG_SHA256_PATH)" || (echo "Missing $(DMG_SHA256_PATH)"; exit 1)
	@test -f "$(DOWNLOADED_DMG)" || (echo "Missing downloaded DMG: $(DOWNLOADED_DMG)"; exit 1)
	@EXPECTED=$$(awk '{print $$1}' "$(DMG_SHA256_PATH)"); \
		ACTUAL=$$(shasum -a 256 "$(DOWNLOADED_DMG)" | awk '{print $$1}'); \
		test "$$EXPECTED" = "$$ACTUAL" || (echo "Downloaded DMG SHA-256 mismatch"; exit 1); \
		echo "Downloaded DMG SHA-256 reproduced: $$ACTUAL"

verify-arch:
	@test -x "$(EXECUTABLE_PATH)" || (echo "Missing app executable: $(EXECUTABLE_PATH)"; exit 1)
	@BUILT_ARCHS=$$(lipo -archs "$(EXECUTABLE_PATH)"); \
		if [ "$$BUILT_ARCHS" != "arm64" ]; then \
			echo "Expected arm64, found: $$BUILT_ARCHS"; \
			exit 1; \
		fi; \
		echo "Verified architecture: $$BUILT_ARCHS"

# --- HELPERS --- #
clean:
	rm -rf "$(BUILD_PATH)"
	@if [ -f "$(DMG_PATH)" ]; then rm "$(DMG_PATH)"; fi
	@if [ -f "$(DMG_SHA256_PATH)" ]; then rm "$(DMG_SHA256_PATH)"; fi

history:
	xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)"

check-cert:
	@echo "Available code signing certificates:"
	@security find-identity -v -p codesigning

open:
	@osascript -e 'display notification "$(APP) signed and ready for distribution" with title "Build $(APP)"'
	@echo "Opening working folder..."
	open "$(CURDIR)"

open-debug:
	@osascript -e 'display notification "$(APP) debug build ready" with title "Build $(APP)"'
	@echo "Opening working folder..."
	open "$(CURDIR)"
	@echo "Debug build complete — app is at: $(APP_PATH)"

.PHONY: build debug test-smoke test-full archive archive-debug sign-app notarize staple \
	prepare-dmg hash-dmg verify-downloaded-dmg verify-arch clean history check-cert open open-debug
