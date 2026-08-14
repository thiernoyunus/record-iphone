#!/bin/zsh
# Builds the Swift package and assembles a runnable, ad-hoc-signed .app bundle.
set -e
cd "$(dirname "$0")"

if [ ! -f Vendor/UxPlay/lib/raop.h ]; then
  echo "Cloning UxPlay (AirPlay receiver library)…"
  rm -rf Vendor/UxPlay
  git clone --depth 1 https://github.com/FDH2/UxPlay.git Vendor/UxPlay
fi
# Current iPhones attach the live picture to type-0x05 packets.
if [ -f Sources/AirPlayHelper/raop_rtp_mirror.c ]; then
  cp Sources/AirPlayHelper/raop_rtp_mirror.c Vendor/UxPlay/lib/raop_rtp_mirror.c
fi

echo "Building airplay-helper…"
cmake -S Sources/AirPlayHelper -B .build-airplay -DCMAKE_BUILD_TYPE=Release
cmake --build .build-airplay --config Release

swift build -c release

APP="dist/Record iPhone.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/RecordIphone" "$APP/Contents/MacOS/Record iPhone"
cp ".build-airplay/airplay-helper" "$APP/Contents/MacOS/airplay-helper"
cp Info.plist "$APP/Contents/Info.plist"
cp PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
# Ad-hoc + hardened runtime for local use. To ship: replace "-" with your
# Developer ID Application identity, then: xcrun notarytool submit …
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  "$APP/Contents/MacOS/airplay-helper"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements RecordIphone.entitlements \
  "$APP"
echo "Built: $APP"
