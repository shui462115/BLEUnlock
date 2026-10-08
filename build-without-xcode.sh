#!/bin/bash
#
# build-without-xcode.sh — build BLEUnlock.app using only the Xcode Command Line Tools.
#
# The Xcode project needs xcodebuild/ibtool/actool, which ship only with a full Xcode
# install. This script instead:
#
#   1. compiles every source file in BLEUnlock/ (Swift + lowlevel.c) against the CLT SDK,
#      linking the same public and private frameworks as the Xcode target,
#   2. reuses the *compiled* UI resources — MainMenu.nib, AboutBox.nib, Assets.car,
#      AppIcon.icns and the Launcher login-item nib — from the official 1.12.2 release,
#      because .xib/.xcassets sources can only be compiled by Interface Builder,
#   3. assembles the bundle, ad-hoc signs it and (with --zip) packages it.
#
# Every Swift source, every localization and the Launcher sources are taken from this
# checkout, so merged code changes are always reflected in the built app.
#
# Usage:  ./build-without-xcode.sh [--zip]
# Env:    MIN_MACOS=12.0   ARCHS="arm64 x86_64"   BUILD_DIR=build   HTTPS_PROXY=...
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
MADE_ZIP=no
if [ $# -gt 0 ] && [ "$1" = "--zip" ]; then MADE_ZIP=yes; fi

if [ -n "${BUILD_DIR:-}" ]; then BUILD=$BUILD_DIR; else BUILD=$ROOT/build; fi
OBJ=$BUILD/obj
APP=$BUILD/BLEUnlock.app

APP_NAME=BLEUnlock
BUNDLE_ID=jp.sone.BLEUnlock
LAUNCHER_ID=jp.sone.BLEUnlock.Launcher
if [ -n "${VENDOR_VERSION:-}" ]; then VENDOR_VERSION=$VENDOR_VERSION; else VENDOR_VERSION=1.12.2; fi
if [ -n "${MIN_MACOS:-}" ]; then MIN_MACOS=$MIN_MACOS; else MIN_MACOS=12.0; fi
if [ -n "${ARCHS:-}" ]; then ARCHS=$ARCHS; else ARCHS="arm64 x86_64"; fi

blue() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null || die "xcrun not found - install the Command Line Tools (xcode-select --install)"
SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null) || die "no macOS SDK found"
[ -d "$SDK/System/Library/PrivateFrameworks" ] || warn "SDK has no PrivateFrameworks directory"

# ------------------------------------------------------------- compiled UI bits
# The official release is used only as a source of pre-compiled Interface Builder
# output. It is fetched once into $BUILD/vendor and reused afterwards.
vendor_app() {
    local dir="$BUILD/vendor/$VENDOR_VERSION"
    local app="$dir/$APP_NAME.app"
    if [ -d "$app" ]; then printf '%s' "$app"; return; fi
    mkdir -p "$dir"

    local installed="/Applications/$APP_NAME.app"
    local installed_version=""
    if [ -f "$installed/Contents/Info.plist" ]; then
        installed_version=$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist" 2>/dev/null || true)
    fi
    if [ "$installed_version" = "$VENDOR_VERSION" ] && [ -e "$installed/Contents/Resources/Base.lproj/AboutBox.nib" ]; then
        blue "using compiled UI resources from $installed"
        rm -rf "$app"
        ditto "$installed" "$app"
        printf '%s' "$app"; return
    fi

    local zip="$dir/$APP_NAME-$VENDOR_VERSION.zip"
    local url="https://github.com/ts1/BLEUnlock/releases/download/$VENDOR_VERSION/$APP_NAME-$VENDOR_VERSION.zip"
    blue "downloading $url"
    curl -fL --retry 3 --connect-timeout 20 -o "$zip" "$url" \
        || die "download failed - set HTTPS_PROXY=http://host:port if you are behind a proxy"
    ( cd "$dir" && ditto -x -k "$zip" . ) || die "could not unpack $zip"
    [ -d "$app" ] || die "unexpected archive layout in $zip"
    printf '%s' "$app"
}

# ---------------------------------------------------------------------- compile
compile_app() {
    mkdir -p "$OBJ"
    local bins=""
    local arch
    for arch in $ARCHS; do
        blue "compiling $arch (minimum macOS $MIN_MACOS)"
        xcrun clang -c -O2 -arch "$arch" -mmacosx-version-min="$MIN_MACOS" \
            -include CoreFoundation/CoreFoundation.h \
            -o "$OBJ/lowlevel-$arch.o" "$ROOT/BLEUnlock/lowlevel.c"
        xcrun swiftc \
            -module-name "$APP_NAME" \
            -target "$arch-apple-macos$MIN_MACOS" \
            -swift-version 5 \
            -O -whole-module-optimization \
            -import-objc-header "$ROOT/BLEUnlock/BLEUnlock-Bridging-Header.h" \
            -F"$SDK/System/Library/PrivateFrameworks" -F/System/Library/PrivateFrameworks \
            -framework MediaRemote -framework login \
            -framework Cocoa -framework ServiceManagement -framework CoreBluetooth \
            -framework QuartzCore -framework Accelerate -lsqlite3 \
            -o "$OBJ/$APP_NAME-$arch" \
            "$ROOT"/BLEUnlock/*.swift "$OBJ/lowlevel-$arch.o"
        bins="$bins $OBJ/$APP_NAME-$arch"
    done
    set -- $bins
    if [ $# -gt 1 ]; then
        blue "creating universal binary"
        xcrun lipo -create "$@" -output "$OBJ/$APP_NAME"
    else
        cp "$1" "$OBJ/$APP_NAME"
    fi
}

compile_launcher() {
    local out=$1
    local bins=""
    local arch
    mkdir -p "$out/Contents/MacOS"
    for arch in $ARCHS; do
        xcrun clang -O2 -arch "$arch" -mmacosx-version-min="$MIN_MACOS" -fobjc-arc \
            -framework Cocoa -o "$OBJ/Launcher-$arch" \
            "$ROOT/Launcher/main.m" "$ROOT/Launcher/AppDelegate.m"
        bins="$bins $OBJ/Launcher-$arch"
    done
    set -- $bins
    if [ $# -gt 1 ]; then
        xcrun lipo -create "$@" -output "$out/Contents/MacOS/Launcher"
    else
        cp "$1" "$out/Contents/MacOS/Launcher"
    fi
}

render_plist() {
    # Expands the build settings Xcode would substitute into Info.plist.
    sed -e "s|\$(DEVELOPMENT_LANGUAGE)|en|g" \
        -e "s|\$(EXECUTABLE_NAME)|$1|g" \
        -e "s|\$(PRODUCT_NAME)|$1|g" \
        -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$2|g" \
        -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|$MIN_MACOS|g" \
        "$3" > "$4"
    plutil -lint "$4" >/dev/null || die "generated Info.plist is not a valid plist: $4"
}

# --------------------------------------------------------------------- assemble
assemble() {
    local vendor=$1
    blue "assembling $APP"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Base.lproj" "$APP/Contents/Library/LoginItems"

    render_plist "$APP_NAME" "$BUNDLE_ID" "$ROOT/BLEUnlock/Info.plist" "$APP/Contents/Info.plist"
    cp "$OBJ/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

    local f nib
    for f in Assets.car AppIcon.icns; do
        [ -f "$vendor/Contents/Resources/$f" ] && cp "$vendor/Contents/Resources/$f" "$APP/Contents/Resources/$f"
    done
    for nib in MainMenu.nib AboutBox.nib; do
        [ -e "$vendor/Contents/Resources/Base.lproj/$nib" ] || die "missing $nib in the vendored release"
        cp -R "$vendor/Contents/Resources/Base.lproj/$nib" "$APP/Contents/Resources/Base.lproj/$nib"
    done

    # Localizations always come from this checkout, so merged translations apply.
    local lproj lang file
    for lproj in "$ROOT"/BLEUnlock/*.lproj; do
        lang=$(basename "$lproj")
        mkdir -p "$APP/Contents/Resources/$lang"
        for file in "$lproj"/*.strings; do
            [ -e "$file" ] || continue
            plutil -convert binary1 -o "$APP/Contents/Resources/$lang/$(basename "$file")" "$file"
        done
    done

    # Login item: built from this checkout, using the vendored compiled nib.
    local launcher="$APP/Contents/Library/LoginItems/Launcher.app"
    compile_launcher "$launcher"
    render_plist "Launcher" "$LAUNCHER_ID" "$ROOT/Launcher/Info.plist" "$launcher/Contents/Info.plist"
    local launcher_nib="$vendor/Contents/Library/LoginItems/Launcher.app/Contents/Resources/MainMenu.nib"
    [ -e "$launcher_nib" ] || die "missing the Launcher nib in the vendored release"
    mkdir -p "$launcher/Contents/Resources"
    cp "$launcher_nib" "$launcher/Contents/Resources/MainMenu.nib"

    printf 'APPL????' > "$APP/Contents/PkgInfo"
}

sign() {
    blue "signing (ad-hoc)"
    local launcher="$APP/Contents/Library/LoginItems/Launcher.app"
    codesign --force --sign - --timestamp=none \
        --entitlements "$ROOT/Launcher/Launcher.entitlements" \
        "$launcher/Contents/MacOS/Launcher" >/dev/null 2>&1 || warn "launcher binary signing failed"
    codesign --force --sign - --timestamp=none \
        --entitlements "$ROOT/Launcher/Launcher.entitlements" "$launcher" >/dev/null 2>&1 \
        || warn "launcher bundle signing failed"
    codesign --force --sign - --timestamp=none --options runtime \
        --entitlements "$ROOT/BLEUnlock/BLEUnlock.entitlements" "$APP" >/dev/null 2>&1 \
        || warn "app signing failed (the app may still run)"
    if codesign --verify --strict "$APP" >/dev/null 2>&1; then
        blue "signature verified"
    else
        warn "signature verification reported problems"
    fi
}

main() {
    local vendor
    vendor=$(vendor_app)
    compile_app
    assemble "$vendor"
    sign
    local version build
    version=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
    build=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
    blue "built $APP (version $version, build $build)"
    if [ "$MADE_ZIP" = yes ]; then
        local zip="$BUILD/$APP_NAME-$version-build$build.zip"
        rm -f "$zip"
        ditto -c -k --keepParent "$APP" "$zip"
        blue "packaged $zip"
    fi
}

main "$@"
