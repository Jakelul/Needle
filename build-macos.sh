#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/Needle.app"
compatible_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

# The 27.0 CLT SDK requires SwiftUI macro plugins not shipped with these CLT.
if [[ -d "$compatible_sdk" && ! -d /Applications/Xcode.app ]]; then
  export SDKROOT="$compatible_sdk"
fi
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/cache/swiftpm"

swift build --build-system native --disable-sandbox -c release --product Needle --package-path "$project_dir"
bin_dir=$(swift build --build-system native --disable-sandbox -c release --show-bin-path --package-path "$project_dir")
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Needle" "$app_dir/Contents/MacOS/Needle"
cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Support/Needle.icns" "$app_dir/Contents/Resources/Needle.icns"
cp -R "$bin_dir/Needle_Needle.bundle" "$app_dir/Contents/Resources/"
codesign --force --sign - "$app_dir"

print "완료: $app_dir"
