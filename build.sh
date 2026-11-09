#!/bin/zsh
# Builds "Resume Versions.app" into ~/Documents/Resume using only the Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Documents/Resume/Resume Versions.app"
ARCH="$(uname -m)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$ARCH-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/ResumeVersions"

cp Info.plist "$APP/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
