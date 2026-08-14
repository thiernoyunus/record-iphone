#!/bin/zsh
# Builds the Swift package and assembles a runnable, ad-hoc-signed .app bundle.
set -e
cd "$(dirname "$0")"

# Pinned, audited UxPlay revision. Do not follow the moving default branch.
UXPLAY_REPO="https://github.com/FDH2/UxPlay.git"
UXPLAY_COMMIT="a3c19cbc7fcc870d74a0960bc97817a2569b4808"

if [ ! -f Vendor/UxPlay/lib/raop.h ]; then
  echo "Cloning UxPlay (AirPlay receiver library) at ${UXPLAY_COMMIT}…"
  rm -rf Vendor/UxPlay
  git clone --depth 1 "${UXPLAY_REPO}" Vendor/UxPlay
fi
if ! git -C Vendor/UxPlay rev-parse --verify "${UXPLAY_COMMIT}^{commit}" >/dev/null 2>&1; then
  git -C Vendor/UxPlay fetch --depth 1 origin "${UXPLAY_COMMIT}"
fi
git -C Vendor/UxPlay checkout --detach "${UXPLAY_COMMIT}"
UXPLAY_HEAD="$(git -C Vendor/UxPlay rev-parse HEAD)"
if [ "${UXPLAY_HEAD}" != "${UXPLAY_COMMIT}" ]; then
  echo "error: UxPlay HEAD ${UXPLAY_HEAD} does not match pinned ${UXPLAY_COMMIT}" >&2
  exit 1
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
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"
mkdir -p "$APP/Contents/Resources/licenses"
if [ -f Vendor/UxPlay/LICENSE ]; then
  cp Vendor/UxPlay/LICENSE "$APP/Contents/Resources/licenses/UxPlay.LICENSE"
fi
# Ad-hoc + hardened runtime for local use. To ship: replace "-" with your
# Developer ID Application identity, then: xcrun notarytool submit …
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  "$APP/Contents/MacOS/airplay-helper"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements RecordIphone.entitlements \
  "$APP"
echo "Built: $APP"
