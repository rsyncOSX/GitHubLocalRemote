sudo ditto "build/Build/Products/Release/GitBranchStatus.app" "/Applications/GitBranchStatus.app"
APP := GitBranchStatus
PROJECT := $(APP).xcodeproj
SCHEME := $(APP)
CONFIGURATION ?= Release
BUILD_PATH := $(CURDIR)/build
APP_PATH := $(BUILD_PATH)/Build/Products/$(CONFIGURATION)/$(APP).app
EXECUTABLE_PATH := $(APP_PATH)/Contents/MacOS/$(APP)
DESTINATION := platform=macOS,arch=arm64

.DEFAULT_GOAL := build

# Build an Apple Silicon-only release by default.
build: clean
	@echo "Building $(APP) ($(CONFIGURATION), arm64)..."
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination '$(DESTINATION)' \
		-derivedDataPath "$(BUILD_PATH)" \
		ARCHS=arm64 \
		ONLY_ACTIVE_ARCH=NO \
		EXCLUDED_ARCHS=x86_64 \
		CODE_SIGNING_ALLOWED=NO \
		build
	@$(MAKE) --no-print-directory verify-arch CONFIGURATION="$(CONFIGURATION)"
	@echo "Build complete: $(APP_PATH)"

# Build an Apple Silicon-only debug app.
debug:
	@$(MAKE) --no-print-directory build CONFIGURATION=Debug

test:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-destination '$(DESTINATION)' \
		-derivedDataPath "$(BUILD_PATH)" \
		ARCHS=arm64 \
		ONLY_ACTIVE_ARCH=NO \
		EXCLUDED_ARCHS=x86_64 \
		CODE_SIGNING_ALLOWED=NO \
		test

verify-arch:
	@test -x "$(EXECUTABLE_PATH)" || { \
		echo "Missing app executable: $(EXECUTABLE_PATH)"; \
		exit 1; \
	}
	@BUILT_ARCHS="$$(lipo -archs "$(EXECUTABLE_PATH)")"; \
	if [ "$$BUILT_ARCHS" != "arm64" ]; then \
		echo "Expected arm64, found: $$BUILT_ARCHS"; \
		exit 1; \
	fi; \
	echo "Verified architecture: $$BUILT_ARCHS"

clean:
	rm -rf "$(BUILD_PATH)"

open:
	open "$(APP_PATH)"

.PHONY: build debug test verify-arch clean open
