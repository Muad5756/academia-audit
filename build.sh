#!/usr/bin/env bash
# build.sh — local macOS compile (requires Xcode + ldid)
# brew install ldid
set -euo pipefail

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT="AcademiaAudit.dylib"

echo "[*] SDK  : $SDK"
echo "[*] out  : $OUT"
echo "[*] compiling..."

xcrun --sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$SDK" \
    -miphoneos-version-min=14.0 \
    -shared \
    -fmodules \
    -fobjc-arc \
    -O2 \
    -framework Foundation \
    -framework UIKit \
    -framework Security \
    -lobjc \
    fishhook.c \
    AcademiaAudit.m \
    -o "$OUT"

ldid -S "$OUT"

echo "[+] done : $OUT ($(du -sh "$OUT" | cut -f1))"
echo ""
echo "── inject ──────────────────────────────────────────────────"
echo "  ./inject.sh <Academia.ipa> \"iPhone Developer: Name (ID)\""
