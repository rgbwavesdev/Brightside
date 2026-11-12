#!/bin/zsh
# Runs Sources/Model.swift against fake displays (Tests/ModelHarness/Fakes.swift): no DDC, no gamma, no DisplayServices,
# so it never touches the real monitors. Checks Move Together, the auto-brightness gate and Match by Eye.
set -e
cd "${0:A:h}/.."
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos14 Sources/Model.swift Tests/ModelHarness/*.swift -o build/brightside-harness
result=0
build/brightside-harness || result=$?
# The harness saves settings like the app does, under its own name; don't leave them behind.
defaults delete brightside-harness 2>/dev/null || true
rm -f ~/Library/Preferences/brightside-harness.plist
exit $result
