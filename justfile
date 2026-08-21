set shell := ["bash", "-euo", "pipefail", "-c"]

project := "Swapper.xcodeproj"
scheme := "Swapper"
build_dir := ".build/xcode"
app := build_dir + "/Build/Products/Release/Swapper.app"
install_path := "/Applications/Swapper.app"

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

# Build and install Swapper in /Applications, then launch it.
install: build
    pkill -x Swapper 2>/dev/null || true
    if [[ -e "{{install_path}}" ]]; then rm -rf "{{install_path}}"; fi
    ditto "{{app}}" "{{install_path}}"
    open "{{install_path}}"

# Build and launch without installing.
run: build
    open "{{app}}"

# Validate the documentation tree: headings, links, fragments, and index reachability.
docs-check:
    node assets/check-docs.mjs

# Run all configured repository checks.
check: docs-check

# Remove local build output.
clean:
    if [[ -d "{{build_dir}}" ]]; then rm -rf "{{build_dir}}"; fi
