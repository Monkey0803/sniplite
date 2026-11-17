#!/bin/sh
# build.sh: Phase 0 spike only. Assembles build/SnipliteSpike.app out of spike.m, ad-hoc
# signed, so the screen recording permission is asked for "SnipliteSpike" and not for the
# terminal that started it. The real build script (mac/build.sh) arrives with Phase 1.
set -eu
cd "$(dirname "$0")"

APP=build/SnipliteSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -fobjc-arc -fmodules -O1 -g -Wall -Wextra -Wno-unused-parameter \
    -target arm64-apple-macos14.0 \
    -framework Cocoa -framework ScreenCaptureKit -framework CoreGraphics \
    -framework ImageIO -framework UniformTypeIdentifiers -framework QuartzCore \
    -framework CoreMedia \
    -o "$APP/Contents/MacOS/SnipliteSpike" spike.m

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier io.github.sniplite.spike "$APP" 2>/dev/null || true

echo "built $APP"
