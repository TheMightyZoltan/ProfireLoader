#!/bin/zsh
# Build the ProFire loader app with the embedded ProFireOHCI dext.
#
#   ./build.sh                    ad-hoc signed, for SIP-disabled local testing
#   TEAM=ABCDE12345 ./build.sh    team-signed by Xcode (needs Apple's DriverKit
#                                 PCI entitlement on that team)
#
# Xcode won't ad-hoc sign restricted DriverKit entitlements, so the default path
# builds unsigned and signs with codesign afterwards.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required (DriverKit SDK + iig)."
  exit 1
fi
xcodebuild -showsdks | grep -qi driverkit || { echo "DriverKit SDK not found in this Xcode."; exit 1; }
command -v xcodegen >/dev/null || brew install xcodegen

xcodegen generate -q

APP=build/Build/Products/Debug/ProFireLoader.app
DEXT="$APP/Contents/Library/SystemExtensions/local.profire.Loader.ProFireOHCI.dext"

if [[ -n "${TEAM:-}" ]]; then
  xcodebuild -project ProFireDriver.xcodeproj -scheme ProFireLoader -configuration Debug \
    -derivedDataPath build -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" build
else
  rm -rf "$APP"
  xcodebuild -project ProFireDriver.xcodeproj -scheme ProFireLoader -configuration Debug \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
  # Inner bundle first, then the app that contains it.
  codesign --force --sign - --timestamp=none \
    --entitlements ProFireOHCI/ProFireOHCI.entitlements "$DEXT"
  codesign --force --sign - --timestamp=none --options runtime \
    --entitlements ProFireLoader/ProFireLoader.entitlements "$APP"
fi

codesign --verify --deep --strict "$APP" && echo "Signature OK"
echo
echo "Built: $APP"
echo "Install with:"
echo "  rm -rf /Applications/ProFireLoader.app && cp -R $APP /Applications/ && open /Applications/ProFireLoader.app"
