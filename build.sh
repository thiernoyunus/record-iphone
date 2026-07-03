#!/bin/zsh
# Builds the Swift package and assembles a runnable, ad-hoc-signed .app bundle.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="dist/Record iPhone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/RecordIphone" "$APP/Contents/MacOS/Record iPhone"
cp Info.plist "$APP/Contents/Info.plist"
# ponytail: ad-hoc signature — fine for local dev; switch to Developer ID when distributing
codesign --force --sign - "$APP"
echo "Built: $APP"
