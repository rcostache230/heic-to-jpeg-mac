#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$repo_root/.build/HEIC to JPEG.app"
sdk=$(xcrun --sdk macosx --show-sdk-path)

# Use the most recent compatible SDK shipped with Command Line Tools.
for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk; do
    if [ -d "$candidate" ]; then sdk=$candidate; break; fi
done

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p "$repo_root/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
cp "$repo_root/Info.plist" "$app/Contents/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$repo_root/Resources/BrandMark.png" "$app/Contents/Resources/BrandMark.png"

swiftc -parse-as-library -O \
    -sdk "$sdk" \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$app/Contents/MacOS/HeicToJpeg" \
    "$repo_root/Sources/HeicToJpeg.swift" \
    -framework AppKit -framework SwiftUI -framework ImageIO -framework UniformTypeIdentifiers

codesign --force --deep --sign - "$app"
echo "Built $app"
