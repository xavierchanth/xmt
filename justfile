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

# Build and install XMT in /Applications, then launch it.
install: build
    pkill -x XMT 2>/dev/null || true
    if [[ -e "{{install_path}}" ]]; then rm -rf "{{install_path}}"; fi
    ditto "{{app}}" "{{install_path}}"
    open "{{install_path}}"

# Build and launch without installing.
run: build
    open "{{app}}"

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
