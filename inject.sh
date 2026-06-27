#!/usr/bin/env bash
# inject.sh — patch Academia.ipa with AcademiaBypass.dylib
# Requirements: insert_dylib (brew install insert_dylib), Xcode
# Usage: ./inject.sh <path/to/Academia.ipa> <cert-name>
# cert-name: run `security find-identity -v -p codesigning` to get yours

set -euo pipefail

IPA="${1:?usage: $0 <Academy.ipa> <cert-name>}"
CERT="${2:?usage: $0 <Academy.ipa> <cert-name>}"
DYLIB="AcademiaBypass.dylib"
WORK=$(mktemp -d)

trap 'rm -rf "$WORK"' EXIT

echo "[*] unpacking $IPA"
unzip -q "$IPA" -d "$WORK"

APP=$(find "$WORK/Payload" -maxdepth 1 -name "*.app" | head -1)
APPNAME=$(basename "$APP")
BINARY="$APP/${APPNAME%.app}"

echo "[*] target binary: $BINARY"

# copy dylib into bundle Frameworks dir
mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/$DYLIB"

echo "[*] injecting LC_LOAD_DYLIB"
insert_dylib \
    --strip-codesig \
    --inplace \
    "@executable_path/Frameworks/$DYLIB" \
    "$BINARY"

echo "[*] re-signing"
codesign --force --sign "$CERT" "$APP/Frameworks/$DYLIB"
codesign --force --sign "$CERT" --entitlements entitlements.plist "$APP" 2>/dev/null || \
codesign --force --sign "$CERT" "$APP"

echo "[*] repacking"
OUT="${IPA%.ipa}_patched.ipa"
(cd "$WORK" && zip -qr - Payload/) > "$OUT"

echo "[+] done: $OUT"
