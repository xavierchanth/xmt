set shell := ["bash", "-euo", "pipefail", "-c"]

project := "XMT.xcodeproj"
scheme := "XMT"
build_dir := ".build/xcode"
app := build_dir + "/Build/Products/Release/XMT.app"
install_path := "/Applications/XMT.app"

# List available commands.
default:
    @just --list

# Build a local release app.
build:
    xcodebuild build \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath "{{build_dir}}"

# Build and install XMT in /Applications, then launch and verify it.
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    if pgrep -x XMT >/dev/null; then
        osascript -e 'tell application id "com.xavierchanth.xmt" to quit' 2>/dev/null || pkill -TERM -x XMT || true
        for _ in {1..50}; do pgrep -x XMT >/dev/null || break; sleep 0.1; done
        if pgrep -x XMT >/dev/null; then pkill -KILL -x XMT; fi
        for _ in {1..20}; do pgrep -x XMT >/dev/null || break; sleep 0.1; done
        if pgrep -x XMT >/dev/null; then echo "XMT did not terminate" >&2; exit 1; fi
    fi
    staged="/Applications/.XMT.app.new.$$"
    backup="/Applications/.XMT.app.old.$$"
    ditto "{{app}}" "$staged"
    codesign --verify --deep --strict "$staged"
    if [[ -e "{{install_path}}" ]]; then mv "{{install_path}}" "$backup"; fi
    if ! mv "$staged" "{{install_path}}"; then
        if [[ -e "$backup" ]]; then mv "$backup" "{{install_path}}"; fi
        exit 1
    fi
    if [[ -e "$backup" ]]; then rm -rf "$backup"; fi
    open -n "{{install_path}}"
    for _ in {1..50}; do pgrep -x XMT >/dev/null && exit 0; sleep 0.1; done
    echo "XMT did not remain running after launch" >&2
    exit 1

# Build and launch a fresh instance without installing.
run: build
    open -n "{{app}}"

# Build the inert DriverKit virtual-keyboard spike target, unsigned. Not part of `check`.
build-dext:
    xcodebuild build \
        -project "{{project}}" \
        -target XMTVirtualKeyboard \
        -configuration Release \
        CONFIGURATION_BUILD_DIR="$PWD/{{build_dir}}/dext/Products" \
        OBJROOT="$PWD/{{build_dir}}/dext/obj" \
        SYMROOT="$PWD/{{build_dir}}/dext/sym" \
        SHARED_PRECOMPS_DIR="$PWD/{{build_dir}}/dext/pch"

# Validate the documentation tree: headings, links, fragments, and index reachability.
docs-check:
    node assets/check-docs.mjs

# Run unit tests.
test:
    xcodebuild test \
        -project "{{project}}" \
        -scheme "{{scheme}}" \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "{{build_dir}}"

# Run all configured repository checks.
check: docs-check test

# Remove local build output.
clean:
    if [[ -d "{{build_dir}}" ]]; then rm -rf "{{build_dir}}"; fi
