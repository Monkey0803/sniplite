#!/bin/sh
# build.sh: the macOS port (mac/). Assembles build/sniplite.app out of the app's ObjC,
# the compatibility layer and the shared C of src/ (lang.c, config.c, util.c), then
# signs it ad-hoc. The Windows build (build.bat) is untouched and does not use this.
#
#   ./build.sh          build build/sniplite.app
#   ./build.sh test     build and run the unit tests of the shared C
#   SIGN_ID=... ./build.sh
#                       sign with another identity (a local self-signed certificate makes
#                       the screen recording permission survive rebuilds)
set -eu
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
BUILD=$ROOT/build
APP=$BUILD/sniplite.app
NAME=sniplite

# arm64: the port targets Apple Silicon. The Windows build stays x86-64.
CFLAGS="-O2 -g -std=gnu11 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers
        -I$ROOT/mac -I$ROOT/src -target arm64-apple-macos14.0"
LIBS="-framework Cocoa -framework Carbon -framework QuartzCore -framework ScreenCaptureKit -framework CoreMedia -framework ImageIO -framework UniformTypeIdentifiers"
SHARED="$ROOT/src/lang.c $ROOT/src/config.c $ROOT/src/util.c $ROOT/mac/compat.m"

mkdir -p "$BUILD"

if [ "${1:-}" = "pintest" ]; then
    # shellcheck disable=SC2086
    clang $CFLAGS -o "$BUILD/sniplite-pintest" tests/pin_test.m pin.m output.m annotate.m draw_cg.c icons_data.c $SHARED $LIBS
    exec "$BUILD/sniplite-pintest"
fi

if [ "${1:-}" = "uitest-app" ]; then
    # the same checks, but launched from Finder (open), where the app may take the focus
    APP=$BUILD/SnipliteUITest.app
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    clang $CFLAGS -DSNIPLITE_TEST -o "$APP/Contents/MacOS/SnipliteUITest" tests/ui_test.m overlay.m capture.m output.m annotate.m draw_cg.c toolbar.c icons_data.c longscreen.m stitch.c pin.m $SHARED $LIBS
    cp tests/uitest-Info.plist "$APP/Contents/Info.plist"
    codesign --force --sign - "$APP" 2>/dev/null || true
    rm -f /tmp/sniplite-ui-result.txt
    pkill -f SnipliteUITest 2>/dev/null || true
    open -n "$APP"
    i=0
    # the file appears as soon as the test starts; wait for its last line instead
    while [ $i -lt 300 ] && ! grep -q "DONE" /tmp/sniplite-ui-result.txt 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
    pkill -f SnipliteUITest 2>/dev/null || true
    cat /tmp/sniplite-ui-result.txt 2>/dev/null || echo "no result file"
    if grep -qE "DONE [0-9]+ 0$" /tmp/sniplite-ui-result.txt 2>/dev/null; then
        exit 0
    fi
    exit 1
fi

if [ "${1:-}" = "uitest" ]; then
    clang $CFLAGS -DSNIPLITE_TEST -o "$BUILD/sniplite-uitest" tests/ui_test.m overlay.m capture.m output.m annotate.m draw_cg.c toolbar.c icons_data.c longscreen.m stitch.c pin.m $SHARED $LIBS
    exec "$BUILD/sniplite-uitest"
fi

if [ "${1:-}" = "longtest" ]; then
    clang $CFLAGS -o "$BUILD/sniplite-longtest" tests/long_test.m longscreen.m stitch.c capture.m pin.m output.m annotate.m draw_cg.c icons_data.c $SHARED $LIBS
    exec "$BUILD/sniplite-longtest"
fi

if [ "${1:-}" = "stitchtest" ]; then
    clang $CFLAGS -o "$BUILD/sniplite-stitchtest" tests/stitch_test.m stitch.c $LIBS
    exec "$BUILD/sniplite-stitchtest"
fi

if [ "${1:-}" = "annotest" ]; then
    # shellcheck disable=SC2086
    clang $CFLAGS -o "$BUILD/sniplite-annotest" tests/anno_test.m annotate.m draw_cg.c output.m icons_data.c $SHARED $LIBS
    exec "$BUILD/sniplite-annotest"
fi

if [ "${1:-}" = "captest" ]; then
    # shellcheck disable=SC2086
    clang $CFLAGS -o "$BUILD/sniplite-captest" tests/capture_test.m capture.m output.m annotate.m draw_cg.c icons_data.c $SHARED $LIBS
    exec "$BUILD/sniplite-captest"
fi

if [ "${1:-}" = "test" ]; then
    # shellcheck disable=SC2086
    clang $CFLAGS -o "$BUILD/sniplite-tests" tests/core_test.m hotkey.c $SHARED $LIBS
    exec "$BUILD/sniplite-tests"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# shellcheck disable=SC2086
clang $CFLAGS -o "$APP/Contents/MacOS/$NAME" app.m hotkey.c capture.m overlay.m output.m pin.m annotate.m draw_cg.c toolbar.c icons_data.c longscreen.m stitch.c settings.m $SHARED $LIBS

cp Info.plist "$APP/Contents/Info.plist"

# app icon: the repository keeps one 256px png, so the larger slots are upscaled here
ICONSET=$BUILD/icon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
emit() { sips -z "$2" "$2" "$ROOT/pics/icon.png" --out "$ICONSET/$1" >/dev/null 2>&1; }
emit icon_16x16.png 16
emit icon_16x16@2x.png 32
emit icon_32x32.png 32
emit icon_32x32@2x.png 64
emit icon_128x128.png 128
emit icon_128x128@2x.png 256
emit icon_256x256.png 256
emit icon_256x256@2x.png 512
emit icon_512x512.png 512
emit icon_512x512@2x.png 1024
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/sniplite.icns" 2>/dev/null || true

codesign --force --sign "${SIGN_ID:--}" --identifier io.github.sniplite.macos "$APP" 2>/dev/null || true

echo "built $APP"
