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
    destination="{{install_path}}"
    executable="$destination/Contents/MacOS/XMT"
    staged_root="$(mktemp -d /Applications/.xmt-install.XXXXXX)"
    staged="$staged_root/XMT.app"
    backup=""
    cleanup() {
        status=$?
        if (( status != 0 )) && [[ -n "$backup" && -e "$backup" ]]; then
            rm -rf "$destination"
            mv "$backup" "$destination"
        fi
        rm -rf "$staged_root"
        [[ -z "$backup" || ! -e "$backup" ]] || rm -rf "$backup"
        exit "$status"
    }
    trap cleanup EXIT
    installed_pids() { pgrep -f "^${executable}$" || true; }
    if [[ -n "$(installed_pids)" ]]; then
        osascript -e 'tell application id "com.xavierchanth.xmt" to quit' 2>/dev/null || true
        for _ in {1..50}; do [[ -n "$(installed_pids)" ]] || break; sleep 0.1; done
        if [[ -n "$(installed_pids)" ]]; then
            while read -r pid; do [[ -z "$pid" ]] || kill -TERM "$pid"; done < <(installed_pids)
        fi
        for _ in {1..20}; do [[ -n "$(installed_pids)" ]] || break; sleep 0.1; done
        [[ -z "$(installed_pids)" ]] || { echo "installed XMT did not terminate" >&2; exit 1; }
    fi
    ditto "{{app}}" "$staged"
    codesign --verify --deep --strict "$staged"
    if [[ -e "$destination" ]]; then
        backup="/Applications/.xmt-backup.$$"
        mv "$destination" "$backup"
    fi
    mv "$staged" "$destination"
    open -n "$destination"
    pid=""
    for _ in {1..50}; do pid="$(installed_pids | head -1)"; [[ -z "$pid" ]] || break; sleep 0.1; done
    [[ -n "$pid" ]] || { echo "XMT did not launch from $destination" >&2; exit 1; }
    sleep 1
    kill -0 "$pid" 2>/dev/null || { echo "XMT did not remain running after launch" >&2; exit 1; }
    [[ "$(ps -p "$pid" -o command= | xargs)" == "$executable" ]] || { echo "unexpected XMT executable path" >&2; exit 1; }
    if [[ -n "$backup" ]]; then rm -rf "$backup"; backup=""; fi

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
